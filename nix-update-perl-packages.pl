#! /usr/bin/env nix-shell
#! nix-shell -i perl -p perl perlPackages.Applify perlPackages.RegexpCommon perlPackages.Mojolicious perlPackages.SmartComments perlPackages.MetaCPANClient perlPackages.SortVersions perlPackages.HTTPTinyCache perlPackages.TryTiny perlPackages.TextDiff

#
# Typical usage:
#   git checkout -b nix-update-perl/$(date +%s`)
#   nix-update-perl-packages.pl --nix-file pkgs/top-level/perl-packages.nix --commit
#

use strict;
use v5.32;
use Data::Dumper;
use HTTP::Tiny::Cache;
use Regexp::Common;
use Text::Diff;
use Smart::Comments;
use Try::Tiny;
use Sort::Versions;
use Mojo::File;
use JSON::PP 'decode_json';
use Applify;
use experimental 'signatures';

version 0.01;

option file    => "nix_file" => "Path to .nix file to update";
option string  => "attr"     => "Name of single attr to update";
option bool  => "commit"    => "Create one commit per update (implies --inplace)" => 0;
option bool  => "inplace"   => "Modify .nix file inplace, without committing" => 0;
option bool  => "verbose"   => "Show changes and determinations being made" => 0;


our $ua = new HTTP::Tiny::Cache ( agent => 'nix-update-perl-packages/0.01' );

app {
    my $app = shift;

    unless ($app->nix_file) {
        $app->_script->print_help;
        return 0;
    }

    my $nix_file = $app->nix_file;
    die "no .nix file provided" unless -f $nix_file;
    my $nix = Mojo::File->new($nix_file)->slurp;



    my (@modules);
    while ($nix =~ m/((\w+)\s+=\s+buildPerl(Package|Module)\s+(?:rec)?\s*)
                     ($RE{balanced}{-parens=>'{}'})/gx) {
        my ($prepart, $attrname, $type, $part) = ($1, $2, $3, $4);
        if (!$app->attr || $app->attr eq $attrname) {
            push @modules, parse_module($attrname, $type, $part);
        }
    }

    warn "Got ".scalar(@modules)." releases to update";

    if ($app->commit) {
        git_sanity($nix_file);
    }

    for my $module (@modules) {
        die "Woops? No new or old code" unless $module->{old_code} && $module->{new_code};
        if ($app->inplace || $app->commit) {
            #git_sanity($nix_file) if ($app->commit); # Maybe a bit excessive to
                                                      # check this before every
                                                      # commit
            my $newnix = Mojo::File->new($nix_file)->slurp;
            $newnix =~ s/\Q$module->{old_code}\E/$module->{new_code}/gs;
            Mojo::File->new($nix_file)->spurt($newnix);
            if ($app->commit) {
                git_commit($nix_file, "perlPackages.$module->{attrname}: $module->{old_version} -> $module->{new_version}");
            }
        }

    }
};

sub git_sanity ($nix_file) {
    my @err;
    chomp(my $pwd_branch = qx(git rev-parse --abbrev-ref HEAD));
    push @err, "* pwd is in '$pwd_branch' branch, this is probably not what you want\n"
      if $pwd_branch=~/(master|main)/;

    chomp(my $file_status = qx(git status --porcelain $nix_file));
    push @err, "* $nix_file is not clean, maybe it has uncommitted changes?\n"
      if $file_status || $?;

    die join("", @err) if @err;
}

sub git_commit ($nix_file, $message) {
    my @git_cmd = (qw(git commit --no-gpg-sign -m), $message, $nix_file);
    (system(@git_cmd) == 0) or die "commit failed";
}

sub parse_module ($attrname, $type, $part) {
    my $m = {};

    $m->{attrname} = $attrname;

    $m->{url}     = get_attr($part, 'url');
    $m->{pname}   = get_attr($part, 'pname');
    $m->{version} = get_attr($part, 'version');
    $m->{sha256}  = get_attr($part, 'sha256');

    unless ($m->{url} =~ m|^mirror://cpan/|) {
        warn "$attrname \$url is not mirror://cpan skipping";
        return;
    }
    unless ($m->{pname} && $m->{url} && $m->{version} && $m->{sha256}) {
        warn "$attrname missing \$version, \$pname, \$url, or \$sha256";
        return;
    }

    my $cpan = {};
    try {
        $cpan = get_release($m->{pname});
    } catch {
        warn shift();
        return;
    };


    if ($m->{version} && $cpan->{version} && versioncmp($m->{version}, $cpan->{version}) == -1) {

        my $code = set_attrs($part,
                             version => $cpan->{version},
                             url     => $cpan->{download_url},
                             sha256  => sha256_to_base32($cpan->{checksum_sha256})
                         );

        $m->{old_version} = $m->{version};
        $m->{new_version} = $cpan->{version};
        $m->{old_code} = $part;
        $m->{new_code} = $code;
#        print(diff \$part, \$code);


        #printf("%-30s | %8s | %8s \n", $m->{pname}, $m->{version}, $cpan->{version});
    } else {
        return;
    }

    return $m;
}

sub get_release ($release) { # MetaCPAN::Client doesn't want to return
                             # checksum_sha256, so we fetch the JSON manually
    my $url = "https://fastapi.metacpan.org/v1/release/$release";
    my $res = $ua->get($url);
    die "$res->{status} $res->{reason}: $url" unless $res->{success};

    my $ret = decode_json($res->{content});
    $ret->{version} =~ s/^v//;
    $ret->{download_url} =~ s|^https://cpan.metacpan.org/|mirror://cpan/|;
    return $ret;
}

sub get_download_url ($module) {
    my $url = "https://fastapi.metacpan.org/v1/download_url/$module";
    my $res = HTTP::Tiny::Cache->new->get($url);
    die "$res->{status} $res->{reason}: $url" unless $res->{success};
    my $download = decode_json($res->{content});
    $download->{version} =~ s/^v//;
    $download->{download_url} =~ s|^https://cpan.metacpan.org/|mirror://cpan/|;
    return $download;
}

sub get_attr ($text, $attr) {
    my $cnt = $text =~ m/$attr\s*=\s*$RE{quoted}{-keep};/;
    my $val = $1;
    die "get_attr $attr found more than 1 in text: $text" if $cnt>1;
    $val =~ s/^(['"])(.*)\1/$2/;
    return $val;
}

sub set_attrs($text, %attrs) {
    foreach my $k (keys %attrs) {
        $text = set_attr($text, $k, $attrs{$k});
    }
    return $text;
}

sub set_attr($text, $attr, $val) {
    my $old_val = get_attr($text, $attr);
    unless (defined $old_val) {
        die "$attr wasn't defined previously";
    }
    $text =~ s/($attr\s*=\s*)$RE{quoted}{-keep};/$1"$val";/g;
    return $text;
}

sub sha256_to_base32 ($hex) {
    die "not hex" unless $hex=~/^[a-f0-9]{64}$/;
    chomp(my $ret=qx(nix-hash --type sha256 --to-base32 $hex));
    return $ret;
}
