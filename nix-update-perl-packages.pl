#! /usr/bin/env nix-shell
#! nix-shell -I nixpkgs=/home/sgo/nixpkgs/ -i perl -p perl perlPackages.RegexpCommon perlPackages.Mojolicious perlPackages.SmartComments perlPackages.MetaCPANClient perlPackages.SortVersions perlPackages.HTTPTinyCache perlPackages.TryTiny perlPackages.TextDiff

use strict;
use Text::Diff;
use v5.32;
use experimental 'signatures';
use Try::Tiny;
use Sort::Versions;
use Mojo::File;
use Regexp::Common;
use Data::Dumper;
use HTTP::Tiny::Cache;
use JSON::PP 'decode_json';

my $ua = new HTTP::Tiny::Cache ( agent => 'nix-update-perl-packages/0.01' );

my $nix_file = $ARGV[0];
die "no .nix file provided" unless -f $ARGV[0];

my $nix = Mojo::File->new($nix_file)->slurp;


my (@modules, @skipped);
while ($nix =~ m/(\w+)\s+=\s+buildPerl(Package|Module)\s+
                 ($RE{balanced}{-parens=>'{}'})/gx) {
    my ($attrname, $type, $part) = ($1, $2, $3);
    push @modules, parse_module($attrname, $type, $part);
}

sub parse_module ($attrname, $type, $part) {
    my $m = {};

    $m->{url}     = get_attr($part, 'url');
    $m->{pname}   = get_attr($part, 'pname');
    $m->{version} = get_attr($part, 'version');
    $m->{sha256}  = get_attr($part, 'sha256');

    unless ($m->{url} =~ m|^mirror://cpan/|) {
        warn "$attrname \$url is not mirror://cpan skipping";
        next;
    }
    unless ($m->{pname} && $m->{url} && $m->{version} && $m->{sha256}) {
        warn "$attrname missing \$version, \$pname, \$url, or \$sha256";
        next;
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
                             url => $cpan->{download_url},
                             sha256 => sha256_to_base32($cpan->{checksum_sha256})
                         );

        $m->{old_code} = $part;
        $m->{new_code} = $code;

        print(diff \$part, \$code);

        printf("%-30s | %8s | %8s \n", $m->{pname}, $m->{version}, $cpan->{version});
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
    my $release = decode_json($res->{content});
    $release->{version} =~ s/^v//;
    $release->{download_url} =~ s|^https://cpan.metacpan.org/|mirror://cpan/|;
    return $release;
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
