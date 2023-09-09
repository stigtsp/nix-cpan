#!/usr/bin/env perl

# Work in progress :-) Run this in the root of your nixpkgs checkout.
#
# Generate derivation snippet:
#   nix-cpan.pl --generate --distribution=HTML-FormHandler
#
# Generate shell.nix file with dependencies:
#   nix-cpan.pl --generate --shell --distribution=App-Presto --deps > shell.nix
#
# Update perl-packages.nix in place:
#   nix-cpan.pl --update --inplace
#
# Update perl-packages.nix with nix-cpan commits:
#   git checkout -b nix-update-perl/$(date +%s)
#   nix-cpan.pl --update --commit
#
#
# --verbose and --debug can be useful options


use v5.38;
use Applify;

use strict;
use warnings;

use feature qw(signatures try);
use experimental qw(try multidimensional);
## no critic (Subroutines::ProhibitSubroutinePrototypes)

use Data::Dumper;
use HTTP::Tiny::Cache;
use File::Util::Tempdir;
use Regexp::Common;
use Text::Diff;
use Smart::Comments -ENV;
use MIME::Base64;
use Math::BigInt;
use Sort::Versions;

use Mojo::File 'path';
use Cpanel::JSON::XS 'decode_json';
use Mojo::Template;
use List::Util 'uniq';
use Perl6::Junction qw(one none);

use Module::CoreList;
use Carp qw(croak);
use Log::Log4perl qw(:easy);
use DBI;
use Time::HiRes qw(time);

our $VERSION = 0.01;

our $ERRATA = require(path(path(__FILE__)->dirname, "errata.conf"));

my $db_file_default = "/var/tmp/metacpan-cache.db";

version $VERSION;

## option string  => "git_opts" => "Options to pass to git";

option file    => "db_file"   => "SQLite file to store metacpan data in" => $db_file_default;

option bool    => "list_nix_file"  => "Parses Nix file and prints attributes";
option bool    => "check_updates"  => "Checks your nix-file against the metacpan-latest DB for updated";

option bool    => "generate"       => "Generate a derivation, print it";
option bool    => "shell"          => "generate: Wrap output in a shell.nix skeleton";

option string  => "distribution" => "generate: Name of Perl distribution to generate";
option string  => "module"       => "generate: Name of Perl module in distribution to generate";

option bool    => "update"       => "Update perlPackages in nix-file";


option string  => "attr"         => "update: Name of single attr to update";
option bool    => "commit"       => "update: Create one commit per update (implies --inplace)" => 0;
option bool    => "force"        => "update: Ignores git repo sanity checks" => 0;
option bool    => "inplace"      => "update: Modify nix-file inplace" => 0;

option bool    => "deps"         => "Also add new dependencies if they don't already exist in nixpkgs";

option bool    => "debug"        => "Output debug information" => 0;
option bool    => "clear_cache"  => "Clear the cache used by HTTP::Tiny::Cache" => 0;
option file    => "nix_file"       => "(optional) Path to perl-packages.nix" => "pkgs/top-level/perl-packages.nix";

option bool  => "verbose"    => "Show changes and determinations being made" => 0;


our $ua = HTTP::Tiny::Cache->new( agent => "nix-update-perl-packages/$VERSION",
                                  verify_SSL => 1 );

app {
    my $app = shift;
    Log::Log4perl->easy_init({
            level =>  ($app->debug ? $DEBUG : ($app->verbose ? $INFO : undef)),
            layout => '%X{distro}%m%n'
        });
    Log::Log4perl::MDC->put('distro', q{});

    $app->http_tiny_clear_cache() if $app->clear_cache;

    return $app->run_check_updates if $app->check_updates;
    return $app->run_list_nix_file if $app->list_nix_file;
    return $app->run_generate if $app->generate;
    return $app->run_update if $app->update;
    $app->_script->print_help;
    return 1;
};

sub dbh ($app) {
    state $sql = DBI->connect("dbi:SQLite:". $app->db_file, {RaiseError=>1});
    return $sql;
}

sub db_get_distro($app, $distro) {
    my ($json) = $app->dbh->selectrow_array(
        "SELECT data FROM releases WHERE distribution=?", undef, $distro);
    return unless $json;
    return decode_json($json);
}

sub db_get_module($app, $module) {
    my ($json) = $app->dbh->selectrow_array(
        "SELECT data FROM releases WHERE main_module=?", undef, $module);
    return unless $json;
    return decode_json($json);
}



sub run_check_updates ($app) {
    my @drvs = parse_nix_file($app->nix_file);
    foreach (@drvs) {
        my $state = "UNKNOWN";

        my $cur_attr  = $_->[1];
        my $cur_ver   = get_attr($_->[3], "version");
        my $cur_name  = get_attr($_->[3], "name");

        my $db = $app->db_get_distro($cur_name);
        if (!$db) {
            $state = "NOTFOUND";
        } else {
            my $db_ver = $db->{version};
            $db_ver =~ s/^v//;
            my $ver_cmp = (versioncmp($cur_ver, $db_ver) == -1);
            if ( $ver_cmp == 1 ) {
                $state = "UPDATE to $db_ver";
            } elsif ( $ver_cmp == 0 ) {
                $state = "SAME";
            } elsif ( $ver_cmp == -1) {
                $state = "DOWNGRADE to $db_ver";
            }
        }

        printf("%-40s %-40s %-10s (%s)\n",
               $cur_attr, $cur_name, $cur_ver, $state);

    }
    return 0;
}

sub run_list_nix_file ($app) {
    my @drvs = parse_nix_file($app->nix_file);
    foreach (@drvs) {
        print "$_->[1]\n";
    }
    return 0;
}

sub parse_nix_file($nix_file, $cb=undef) { # Parses a perl-packages.nix file

    die "no .nix file provided" unless -f $nix_file;

    open(my $fh, "<", $nix_file) || die $!;

    my $attr = {};
    my %in;
    my $i = 0;

    my $start = time();

    while (my $l = <$fh>) {
        if ($l=~m/(\s+)(([\w-]+)\s+=\s+buildPerl(Package|Module)\s+(?:rec)?\s*)\{/) {
            %in = (
                ws          => $1,
                prepart     => $2,
                attrname    => $3,
                build_fun   => $4,
            );
            DEBUG("parse_nix_file: Found $in{attrname}");
        } elsif ( %in && $l =~ m/^$in{ws}\};/ ) {
            DEBUG("parse_nix_file: Found end of $in{attrname}");
            %in = ();
        } elsif ( %in ) {
            DEBUG("parse_nix_file: Line $i to $in{attrname} ## $l");
            my $h = $attr->{ $in{attrname} } //= { %in };
            push @{$h->{lines}}, [$i, $l];
            $h->{part} .= $l;
        }
        $i++;
    }
    close $fh;

    my @ret;
    foreach my $k (sort keys %$attr) {
        my $h = $attr->{$k};
        push @ret, [ $h->{prepart},
                     $h->{attrname},
                     $h->{build_fun},
                     $h->{part} ];
    }
    return @ret;
}

sub run_update ($app) {
    unless ($app->nix_file) {
        $app->_script->print_help;
        return 0;
    }

    my $write = $app->inplace || $app->commit;

    my $nix_file = $app->nix_file;
    INFO("# Updating derivations in $nix_file ".($write ? "WRITE" : "READONLY"));
    my (@updated_drv, @missing);
    foreach my $m (parse_nix_file($nix_file)) {
        my ($prepart, $attrname, $build_fun, $part) = @$m;
        if (!$app->attr || $app->attr eq $attrname) {
            my ($drv, @rest) = $app->update_derivation($attrname, $build_fun, $part);
            if ($drv) {
                push @updated_drv, $drv;
                if (@rest) {
                    push @missing, @rest;
                }
            } else {
                WARN("No update for $attrname");
            }
        }
    }



    if ($app->commit) {
        ### Checking git_sanity
        if ($app->force) {
            try {
                git_sanity($nix_file);
            } catch ($e) {
                warn "Git sanity check failed, but --force is enabled so proceeding anyway\n";
                warn "$e\n";
            }
        } else {
            git_sanity($nix_file);
        }


    }


    ### updated_drv: @updated_drv
    for my $drv (@updated_drv) {
        ### drv: $drv

        for (qw[code version]) {
            die "$drv->{attrname}: Woops? No new or old $_"
              unless $drv->{"old_$_"} && $drv->{"new_$_"};
        }
        if ($write) {
            my $newnix = Mojo::File->new($nix_file)->slurp;
            $newnix =~ s/\Q$drv->{old_code}\E/$drv->{new_code}/gs;
            Mojo::File->new($nix_file)->spurt($newnix);
            if ($app->commit) {
                git_commit($nix_file,
                           "perlPackages.$drv->{attrname}: "
                             . "$drv->{old_version} -> $drv->{new_version}");
            }
        }
    };



    ### missing: @missing

    for my $distro (@missing) {
        if ($write) {
            INFO("Adding distro $distro->{distribution}");
            my $newnix = Mojo::File->new($nix_file)->slurp;
            my $end_marker = "} // lib.optionalAttrs (config.allowAliases or true) {";
            $newnix =~ s/\Q$end_marker\E/$distro->{code}\n\n$end_marker/gs;
            my $attr = distro_name_to_attr($distro);
            Mojo::File->new($nix_file)->spurt($newnix);
            INFO("[nix-cpan] perlPackages.$attr: init at $distro->{version}");
            #if ($app->commit) {
                #git_commit($nix_file,
                #           "[nix-cpan] perlPackages.$m->{attrname}: "
                #             . "$drv->{old_version} -> $drv->{new_version}");
            #}

        }
    }

    return 0;
}

sub run_generate ($app) {
    my $distro;
    if (my $dn = $app->distribution) {
        Log::Log4perl::MDC->put('distro', "[$dn] ");
        INFO("Looking up distribution...");
        $distro = get_release($dn);
    } elsif (my $module = $app->module) {
        Log::Log4perl::MDC->put('distro', "[$module] ");
        INFO("Looking up distribution from module name...");
        $distro = get_release_by_module_name($module);
    } else {
        die "generate: Missing either `--module=Foo::Bar` or `--distribution=Foo-Bar` option.";
    }
    my (@distro_deps) = $app->generate_distro($distro, !!($app->deps));
    $distro = shift(@distro_deps);

    my $distro_name = $distro->{distribution};

    @distro_deps = unique_distros(@distro_deps);

    my $attr = distro_name_to_attr($distro_name);
    say <<EOT if $app->shell;
with import <nixpkgs> { } ;
with perlPackages;
with lib;
let
EOT
    INFO("### $distro_name ".(@distro_deps ? scalar(@distro_deps)." dependencies ": ""));
    say $distro->{code};
    foreach my $dep (@distro_deps) {
        INFO("### dependency $dep->{distribution} ###");
        say $dep->{code};
    }
    say <<EOT if $app->shell;
in pkgs.mkShell {
  buildInputs = [ $attr perl ];
}
EOT


    return 0;
}


sub generate_distro ($app, $distro, $resolve_deps=0) {

    my $distro_name = $distro->{distribution};
    INFO("Generating distro...");
    die "\resolve_deps level too high" if $resolve_deps > 5;
    DEBUG("Ended up with distribution: $distro->{distribution}");

    my $attr = distro_name_to_attr($distro_name);

    my $get_deps = sub ($rels, $phases) { # Function for
        #my ($rels, $phases) = @_;

        my @deps = grep {
            $_->{phase} eq one(@$phases)
              && $_->{relationship} eq one(@$rels)
              && $_->{module} eq none(qw(perl))
              && $_->{module} eq none(@{$ERRATA->{ignore}->{module}})
          } @{$distro->{dependency}};

        my @distros = grep {
              !Module::CoreList::is_core($_->{main_module})
          } map { get_release_by_module_name($_->{module} ) } @deps;

        return @distros;
    };

    my @build_deps = $get_deps->( [qw(requires)], [qw(configure build test)] );
    my @runtime_deps = $get_deps->( [qw(requires)], [qw(runtime)] );

    my $have_build_pl = eval {
        my $url = "https://fastapi.metacpan.org/source/$distro->{author}/$distro->{release}/Build.PL";

        my $res = $ua->get($url);
        my $log = "GET $url ($res->{status} $res->{reason})";
        DEBUG($log);
        return $res->{success};
    };

    my $build_fun = ( $have_build_pl || grep { $_->{main_module} eq 'Module::Build' } @build_deps )
      ? "buildPerlModule" : "buildPerlPackage";

    $distro->{build_inputs} = [
        uniq sort
        map { distro_name_to_attr($_->{distribution}) }
        grep { $_->{module} ne one(qw(Module::Build)) }
        @build_deps
    ];

    $distro->{propagated_build_inputs} = [
        uniq sort
        grep { none(@{$distro->{build_inputs}}) eq $_ }
        map { distro_name_to_attr($_->{distribution}) }
        @runtime_deps
    ];

    my (@exists, @missing);
    if ($resolve_deps) {
        foreach my $dep (@build_deps, @runtime_deps) {
            if ($app->exists_in_nix_file(distro_name_to_attr($dep->{distribution}))) {
                DEBUG("$dep->{distribution} exists in nixpkgs");
                push @exists, $dep;
            } else {
                DEBUG("$dep->{distribution} is missing");
                push @missing, $dep;
            }
        }
        $distro->{missing} = \@missing;
        $distro->{exists}  = \@exists;
    }



    my $code = generate_nix_derivation($distro, $attr, $build_fun);

    $distro->{code} = $code;

    if (@missing) {
        INFO("$attr is missing dependencies: ".join(" ", map {$_->{distribution}} @missing));
    }

    my @rest;
    foreach my $missing (@missing) {
        push @rest, $app->generate_distro($missing, $resolve_deps+1);
    }
    return ($distro, @rest);
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

sub update_derivation ($app, $attrname, $build_fun, $part) {
    my $drv = {};

    $drv->{attrname} = $attrname;

    $drv->{url}     = get_attr($part, 'url');
    $drv->{pname}   = get_attr($part, 'pname');
    $drv->{version} = get_attr($part, 'version');
    $drv->{hash}    = get_attr($part, 'hash');

    $drv->{build_fun} = $build_fun;

    $drv->{build_inputs} = [ get_attr_list($part, 'buildInputs') ];
    $drv->{propagated_build_inputs} = [ get_attr_list($part, 'propagatedBuildInputs') ];

    unless ($drv->{url} =~ m|^mirror://cpan/|) {
        warn "skipping: $attrname \$url is not mirror://cpan";
        return;
    }
    unless ($drv->{pname} && $drv->{url} && $drv->{version} && $drv->{hash}) {
        warn "skipping: $attrname missing \$version, \$pname, \$url, or \$hash";
        return;
    }

    my $cpan = {};
    try {
        $cpan = get_release($drv->{pname});
    } catch ($e) {
        warn "skipping: $attrname $e";
        return;
    }

    my ($distro, @missing) = $app->generate_distro($cpan, 1);
    my $newer =($drv->{version} && $cpan->{version} && versioncmp($drv->{version}, $cpan->{version}) == -1);
    if ($newer) {

        my $code = set_attrs($part,
                             version => $cpan->{version},
                             url     => $cpan->{download_url},
                             hash    => sha256_hex_to_sri($cpan->{checksum_sha256})
                         );

        $drv->{old_version} = $drv->{version};
        $drv->{new_version} = $cpan->{version};

        $drv->{old_code} = $part;
        $drv->{new_code} = $code;

        INFO("# perlPackages.$drv->{attrname}: $drv->{version} -> $cpan->{version}");
        INFO(diff \$part, \$code);

    } else {
        return;
    }

    return ($drv, @missing);
}

sub generate_nix_derivation ($distro, $attr_name, $build_fun) {
    Log::Log4perl::MDC->put('distro', "[$distro->{distribution}] ");

    my $attr     = attr_is_reserved($attr_name) ? "\"$attr_name\"" : $attr_name;
    my $license  = render_license($distro->{license}->[0]);
    my $hash     = sha256_hex_to_sri($distro->{checksum_sha256});

    return Mojo::Template->new->render(<<'EOF', $build_fun, $attr, $distro, $license, $hash);
% my ($build_fun, $attr, $distro, $license, $hash) = @_;
  <%= $attr %> = <%= $build_fun %> {
    pname = "<%= $distro->{distribution} %>";
    version = "<%= $distro->{version} %>";
    src = fetchurl {
      url = "<%= $distro->{download_url} %>";
      hash = "<%= $hash %>";
    };
% if (my @b = @{$distro->{build_inputs} || [] }) {
    buildInputs = [ <%= join ' ', @b %> ];
% }
% if (my @b = @{$distro->{propagated_build_inputs} || [] }) {
    propagatedBuildInputs = [ <%= join ' ', @b %> ];
% }
    meta = {
% my $homepage = $distro->{resources}->{homepage} // ($distro->{resources}->{repository} && $distro->{resources}->{repository}->{url});
% if ($homepage) {
      homepage = "<%= $homepage %>";
% }
% if ($distro->{abstract} && $distro->{abstract} ne "Unknown") {
      description = "<%= $distro->{abstract} %>";
% }
% if ($license) {
      license = <%= $license %>;
% }
    };
  };
EOF
}

sub get_metacpan_api($path) {
    my $url = "https://fastapi.metacpan.org/$path";
    my $res = $ua->get($url);
    my $log = "GET $url ($res->{status} $res->{reason})";
    DEBUG($log);
    die "$log\n$res->{content}" unless $res->{success};
    my $ret = decode_json($res->{content});
    return $ret;
}

sub get_release_by_module_name($module_name) {
    my $module = get_module($module_name);
    return get_release($module->{distribution});
}

sub get_release ($release) { # MetaCPAN::Client doesn't want to return
                             # checksum_sha256, so we fetch the JSON manually
    my $ret = get_metacpan_api("v1/release/$release");
    $ret->{release} = "$release-" . $ret->{version};
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
    return unless defined $val;
    die "get_attr $attr found more than 1 in text: $text" if $cnt>1;
    $val =~ s/^(['"])(.*)\1/$2/;
    return $val;
}

sub get_attr_list ($text, $attr) {
    ### get_attr_list text: $text
    my ($val) = $text =~ m/ $attr\s*=\s*
                            $RE{balanced}{-parens=>'[]'}
                          /gx;
    my @ret = grep { !/^[\[\]]$/ } split(/\s+/, $val) if $val;
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

sub unique_distros (@distros) {
    my $seen = { };
    return grep { !$seen->{$_->{distribution}}++ } @distros;
}

sub distro_name_to_attr ($distro) {
    # Converts perl ditribution or module names to nix attribute
    die "no \$distro_name" unless $distro;
    $distro=~ s/[:-]//g;
    return $distro;
}

sub exists_in_nix_file ($app, $attr) {
    my $found = grep { $_->[1] eq $attr } parse_nix_file($app->nix_file);
    return $found;
}

sub exists_in_nixpkgs ($attr) {
    chomp(my $ret = qx(nix-instantiate --eval -E '(import <nixpkgs> {}).perlPackages.$attr.pname'));
    return $ret =~ m/\".+\"/; #XXX: This should be better...
}

sub sha256_hex_to_sri ($hex) {
    my $num = Math::BigInt->new("0x$hex")->to_bytes();
    return "sha256-" . encode_base64( $num, "" );
}

sub http_tiny_clear_cache($app) {
    my $tempdir = File::Util::Tempdir::get_user_tempdir();
    INFO("Clearing HTTP::Tiny::Cache cache ...");
    my $cachedir = "$tempdir/http_tiny_cache";
    opendir(my $dh, $cachedir) || die "Can't opendir $cachedir: $!";
    my @cache_files = grep { /^[a-f0-9]{64}$/ } readdir($dh);
    closedir($dh);
    ### Deleting cache: @cache_files
    foreach (@cache_files) {
        unlink("$cachedir/$_") || die "$cachedir/$_: $!";
    }
    INFO("Deleted ".scalar(@cache_files)." cache files from $cachedir");
    return @cache_files;
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
        WARN("Unknown license: $cpan_license");
        $licenses = [$cpan_license];
        $in_set   = 0;
    }
    else {
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
            $license_line = "$lic.$licenses->[0]";
        }
        else {
            $license_line = "with $lic; [ " . join( ' ', @$licenses ) . " ]";
        }
    }
    else {
        if ( @$licenses == 1 ) {
            $license_line = $licenses->[0];
        }
        else {
            $license_line = '[ ' . join( ' ', @$licenses ) . ' ]';
        }
    }

    INFO("license: $cpan_license");
    WARN("License '$cpan_license' is ambiguous, please verify") if $amb;
    return $license_line;
}
