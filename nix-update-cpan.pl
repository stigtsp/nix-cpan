#! /usr/bin/env nix-shell
#! nix-shell -i perl -p perl perlPackages.Applify perlPackages.RegexpCommon perlPackages.Mojolicious perlPackages.SmartComments perlPackages.MetaCPANClient perlPackages.SortVersions perlPackages.HTTPTinyCache perlPackages.TryTiny perlPackages.TextDiff perlPackages.Perl6Junction

#
# Typical usage:
#   git checkout -b nix-update-perl/$(date +%s`)
#   nix-update-perl-packages.pl --nix-file pkgs/top-level/perl-packages.nix --commit
#

use strict;
use v5.34;

use experimental 'signatures';
use feature 'try';
use warnings qw(all -experimental);

use Data::Dumper;
use HTTP::Tiny::Cache;
use Regexp::Common;
use Text::Diff;
use Smart::Comments;

use Sort::Versions;
use Mojo::File;
use Mojo::JSON 'decode_json';
use Mojo::Template;
use Applify;
use List::Util 'uniq';
use Perl6::Junction qw(one none);
# use MetaCPAN::Client 2.029;

use Module::CoreList;
use Carp qw(croak);

our $VERSION = 0.01;

version $VERSION;


# TODO: option to control caching
option file    => "nix_file" => "Path to perl-packages.nix file to update";
option string  => "attr"     => "Name of single attr to update";
## option string  => "git_opts" => "Options to pass to git";
option string  => "generate" => "Name of Perl distribution to generate";

option bool  => "commit"     => "Create one commit per update (implies --inplace)" => 0;
option bool  => "inplace"    => "Modify .nix file inplace" => 0;

option bool  => "verbose"    => "Show changes and determinations being made" => 0;
option bool  => "debug"      => "Output debug information" => 0;

our $ua = new HTTP::Tiny::Cache ( agent => "nix-update-perl-packages/$VERSION" );

our ($VERBOSE, $DEBUG);

app {
    my $app = shift;

    # XXX: Should be a better way to do this
    $VERBOSE = $app->verbose;
    $ENV{Smart_Comments} = $DEBUG = $app->debug ;

    $app->generate && return $app->run_generate;

    
    unless ($app->nix_file) {
        $app->_script->print_help;
        return 0;
    }

    my $nix_file = $app->nix_file;
    ### nix_file: $nix_file

    die "no .nix file provided" unless -f $nix_file;
    my $nix = Mojo::File->new($nix_file)->slurp;

    my (@modules);
    while ($nix =~ m/((\w+)\s+=\s+buildPerl(Package|Module)\s+(?:rec)?\s*)
                     ($RE{balanced}{-parens=>'{}'})/gx) {
        my ($prepart, $attrname, $build_fun, $part) = ($1, $2, $3, $4);
        if (!$app->attr || $app->attr eq $attrname) {
            push @modules, parse_module($attrname, $build_fun, $part);
        }
    }

    if ($app->commit) {
        git_sanity($nix_file);
    }

    for my $module (@modules) { ### Looping over modules [|||   ]
        for (qw[code version]) {
            die "$module->{attrname}: Woops? No new or old $_"
              unless $module->{"old_$_"} && $module->{"new_$_"};
        }
        if ($app->inplace || $app->commit) {
            #git_sanity($nix_file) if ($app->commit); # Maybe a bit excessive to
                                                      # check this before every
                                                      # commit
            my $newnix = Mojo::File->new($nix_file)->slurp;
            $newnix =~ s/\Q$module->{old_code}\E/$module->{new_code}/gs;
            Mojo::File->new($nix_file)->spurt($newnix);
            if ($app->commit) {
                git_commit($nix_file,
                           "[nix-cpan] perlPackages.$module->{attrname}: "
                             . "$module->{old_version} -> $module->{new_version}");
            }
        }

    }
};

sub run_generate ($app) {
    my $arg = $app->generate;
    ### run_xgenerate: $arg
    my $m = get_release($arg);
    ### got distribution: $m->{distribution}

    my $get_deps = sub {
        my ($relationship_re, $phase_re) = @_;
        my @deps = grep { $_->{phase} =~ $phase_re
                            && $_->{relationship} =~ $relationship_re }
          @{ $m->{dependency} || [] };
        my @r = grep { !Module::CoreList::is_core($_->{module}) } @deps;
        return @r;
    };



    $m->{build_inputs} = [ uniq sort map { distr_name_to_attr($_->{module}) } $get_deps->( qr/^requires$/, qr/^(configure|build|test)$/ ) ];
    $m->{propagated_build_inputs} = [ grep { none(@{$m->{build_inputs}}) eq $_ } uniq sort map { distr_name_to_attr($_->{module}) } $get_deps->( qr/^requires$/, qr/^runtime$/ ) ];

    my $build_fun = one(@{$m->{build_inputs}}) eq "ModuleBuild"
      ? "buildPerlModule" : "buildPerlPackage";

    ### build_fun: $build_fun

    ### buildi: $m->{build_inputs}


    die generate_module($m, distr_name_to_attr($m->{distribution}), $build_fun);
}

sub git_sanity ($nix_file) {
    my @err;
    chomp(my $pwd_branch = qx(git rev-parse --abbrev-ref HEAD));
    push @err, "* pwd is in '$pwd_branch' branch, this is probably not what you want\n"
      if $pwd_branch=~/(master|main)/;

    chomp(my $file_status = qx(git status --porcelain $nix_file));
    push @err, "* $nix_file is not clean, maybe it has uncommitted changes?\n"
      if $file_status || $?;

    croak "git_sanity error:\n".join("", @err) if @err;
}

sub git_commit ($nix_file, $message) {
    my @git_cmd = (qw(git commit -m), $message, $nix_file);
    (system(@git_cmd) == 0) or die "commit failed";
}

sub parse_module ($attrname, $build_fun, $part) {
    my $m = {};

    $m->{attrname} = $attrname;

    $m->{url}     = get_attr($part, 'url');
    $m->{pname}   = get_attr($part, 'pname');
    $m->{version} = get_attr($part, 'version');
    $m->{sha256}  = get_attr($part, 'sha256');

    $m->{build_fun} = $build_fun;

    $m->{build_inputs} = [ get_attr_list($part, 'buildInputs') ];
    $m->{propagated_build_inputs} = [ get_attr_list($part, 'propagatedBuildInputs') ];


    unless ($m->{url} =~ m|^mirror://cpan/|) {
        warn "skipping: $attrname \$url is not mirror://cpan";
        return;
    }
    unless ($m->{pname} && $m->{url} && $m->{version} && $m->{sha256}) {
        warn "skipping: $attrname missing \$version, \$pname, \$url, or \$sha256";
        return;
    }

    my $cpan = {};
    try {
        $cpan = get_release($m->{pname});
    } catch ($e) {
        warn "skipping: $attrname $e";
        return;
    }


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
        print(diff \$part, \$code) if $VERBOSE;


        printf("%-30s | %8s | %8s \n", $m->{pname}, $m->{version}, $cpan->{version});
    } else {
        return;
    }

    return $m;
}

sub generate_module ($m, $attr_name, $build_fun) {
    my $attr     = attr_is_reserved($attr_name) ? "\"$attr_name\"" : $attr_name;
    my $license  = render_license($m->{license}->[0]);
    ### license: $license;
    ### attr: $attr
    return Mojo::Template->new->render(<<'EOF', $build_fun, $attr, $m, $license);
% my ($build_fun, $attr, $m, $license) = @_;
  <%= $attr %> = <%= $build_fun %> {
    pname = "<%= $m->{distribution} %>";
    version = "<%= $m->{version} %>";
    src = fetchurl {
      url = "<%= $m->{download_url} %>";
      sha256 = "<%= $m->{checksum_sha256} %>";
    };
% if (my @b = @{$m->{build_inputs} || [] }) {
    buildInputs = [ <%= join ' ', @b %> ];
% }
% if (my @b = @{$m->{propagated_build_inputs} || [] }) {
    propagatedBuildInputs = [ <%= join ' ', @b %> ];
% }
    meta = {
% my $homepage = $m->{resources}->{repository} && $m->{resources}->{repository}->{url};
% if ($homepage) {
      homepage = "<%= $homepage %>";
% }
% if ($m->{abstract} && $m->{abstract} ne "Unknown") {
      description = "<%= $m->{abstract} %>";
% }
      license = <%= $license %>;
    };
  };
EOF
}

sub get_metacpan_api($path) {
    my $url = "https://fastapi.metacpan.org/$path";
    my $res = $ua->get($url);
    croak "$res->{status} $res->{reason}: $url" unless $res->{success};
    my $ret = decode_json($res->{content});
    return $ret;
}

sub get_release ($release) { # MetaCPAN::Client doesn't want to return
                             # checksum_sha256, so we fetch the JSON manually
    my $ret = get_metacpan_api("v1/release/$release");
    $ret->{version} =~ s/^v//; # XXX: This should maybe not be here?
    $ret->{download_url} =~ s|^https://cpan.metacpan.org/|mirror://cpan/|;
    return $ret;
}

sub get_module ($module) {
    return get_metacpan_api("v1/module/$module");
}

sub get_attr ($text, $attr) {
    my $cnt = $text =~ m/$attr\s*=\s*$RE{quoted}{-keep};/;
    my $val = $1;
    die "get_attr $attr found more than 1 in text: $text" if $cnt>1;
    $val =~ s/^(['"])(.*)\1/$2/;
    return $val;
}

sub get_attr_list ($text, $attr) {
    ### get_attr_list text: $text
    my ($val) = $text =~ m/ $attr\s*=\s*
                            $RE{balanced}{-parens=>'[]'}
                          /gx;
    my @ret = grep { !/^[\[\]]$/ } split(/\s+/, $val);
    ### get_attr_list: @ret
    return sort @ret;
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

sub distr_name_to_attr ($distr) {
    # Converts perl ditribution or module names to nix attribute
    $distr=~ s/[:-]//g;
    return $distr;
}
sub sha256_to_base32 ($hex) {
    die "not hex" unless $hex=~/^[a-f0-9]{64}$/;
    chomp(my $ret=qx(nix-hash --type sha256 --to-base32 $hex));
    return $ret;
}

##
## Utils from nix-generate-from-cpan.pl
##


sub attr_is_reserved {
    my ($pkg) = @_;

    return $pkg =~ /^(?: assert    |
                         else      |
                         if        |
                         import    |
                         in        |
                         inherit   |
                         let       |
                         rec       |
                         then      |
                         while     |
                         with      )$/x;
}

sub license_map ($cpan_license) {
    my %LICENSE_MAP = (

        # The Perl 5 License (Artistic 1 & GPL 1 or later).
        perl_5 => {
            licenses => [qw( artistic1 gpl1Plus )]
        },

        # GNU Affero General Public License, Version 3.
        agpl_3 => {
            licenses => [qw( agpl3Plus )],
            amb      => 1
        },

        # Apache Software License, Version 1.1.
        apache_1_1 => {
            licenses => ["Apache License 1.1"],
            in_set   => 0
        },

        # Apache License, Version 2.0.
        apache_2_0 => {
            licenses => [qw( asl20 )]
        },

        # Artistic License, (Version 1).
        artistic_1 => {
            licenses => [qw( artistic1 )]
        },

        # Artistic License, Version 2.0.
        artistic_2 => {
            licenses => [qw( artistic2 )]
        },

        # BSD License (three-clause).
        bsd => {
            licenses => [qw( bsd3 )],
            amb      => 1
        },

        # FreeBSD License (two-clause).
        freebsd => {
            licenses => [qw( bsd2 )]
        },

        # GNU Free Documentation License, Version 1.2.
        gfdl_1_2 => {
            licenses => [qw( fdl12 )]
        },

        # GNU Free Documentation License, Version 1.3.
        gfdl_1_3 => {
            licenses => [qw( fdl13 )]
        },

        # GNU General Public License, Version 1.
        gpl_1 => {
            licenses => [qw( gpl1Plus )],
            amb      => 1
        },

        # GNU General Public License, Version 2. Note, we will interpret
        # "gpl" alone as GPL v2+.
        gpl_2 => {
            licenses => [qw( gpl2Plus )],
            amb      => 1
        },

        # GNU General Public License, Version 3.
        gpl_3 => {
            licenses => [qw( gpl3Plus )],
            amb      => 1
        },

        # GNU Lesser General Public License, Version 2.1. Note, we will
        # interpret "gpl" alone as LGPL v2.1+.
        lgpl_2_1 => {
            licenses => [qw( lgpl21Plus )],
            amb      => 1
        },

        # GNU Lesser General Public License, Version 3.0.
        lgpl_3_0 => {
            licenses => [qw( lgpl3Plus )],
            amb      => 1
        },

        # MIT (aka X11) License.
        mit => {
            licenses => [qw( mit )]
        },

        # Mozilla Public License, Version 1.0.
        mozilla_1_0 => {
            licenses => [qw( mpl10 )]
        },

        # Mozilla Public License, Version 1.1.
        mozilla_1_1 => {
            licenses => [qw( mpl11 )]
        },

        # OpenSSL License.
        openssl => {
            licenses => [qw( openssl )]
        },

        # Q Public License, Version 1.0.
        qpl_1_0 => {
            licenses => [qw( qpl )]
        },

        # Original SSLeay License.
        ssleay => {
            licenses => ["Original SSLeay License"],
            in_set   => 0
        },

        # Sun Internet Standards Source License (SISSL).
        sun => {
            licenses => ["Sun Industry Standards Source License v1.1"],
            in_set   => 0
        },

        # zlib License.
        zlib => {
            licenses => [qw( zlib )]
        },

        # Other Open Source Initiative (OSI) approved license.
        open_source => {
            licenses => [qw( free )],
            amb      => 1
        },

        # Requires special permission from copyright holder.
        restricted => {
            licenses => [qw( unfree )],
            amb      => 1
        },

        # Not an OSI approved license, but not restricted. Note, we
        # currently map this to unfreeRedistributable, which is a
        # conservative choice.
        unrestricted => {
            licenses => [qw( unfreeRedistributable )],
            amb      => 1
        },

        # License not provided in metadata.
        unknown => {
            licenses => [],
            amb      => 1
        }
    );
    return $LICENSE_MAP{$cpan_license};
}

sub render_license {
    my ($cpan_license) = @_;

    return if !defined $cpan_license;

    my $licenses;

    # If the license is ambiguous then we'll print an extra warning.
    # For example, "gpl_2" is ambiguous since it may refer to exactly
    # "GPL v2" or to "GPL v2 or later".
    my $amb = 0;

    # Whether the license is available inside `lib.licenses`.
    my $in_set = 1;

    ### lookup: $cpan_license

    my $nix_license = license_map($cpan_license);
    if ( !$nix_license ) {
        ### aa
        warn("Unknown license: $cpan_license");
        $licenses = [$cpan_license];
        $in_set   = 0;
    }
    else {
        ### bb
        $licenses = $nix_license->{licenses};
        $amb      = $nix_license->{amb};
        $in_set   = !$nix_license->{in_set};
    }

    my $license_line;

    if ( @$licenses == 0 ) {

        # Avoid defining the license line.
    }
    elsif ($in_set) {
        my $lic = 'lib.licenses';
        if ( @$licenses == 1 ) {
            ### a
            $license_line = "$lic.$licenses->[0]";
        }
        else {
            ### b
            $license_line = "with $lic; [ " . join( ' ', @$licenses ) . " ]";
        }
    }
    else {
        if ( @$licenses == 1 ) {
            ### c
            $license_line = $licenses->[0];
        }
        else {
            ### d
            $license_line = '[ ' . join( ' ', @$licenses ) . ' ]';
        }
    }

    #INFO("license: $cpan_license");
    #WARN("License '$cpan_license' is ambiguous, please verify") if $amb;
    ### license_line: $license_line
    return $license_line;
}
