#!/usr/bin/env perl


use v5.38;
use Applify;

use strict;
use warnings;
use Log::Log4perl qw(:easy);
use Smart::Comments;
use File::Basename;
use Perl6::Junction qw(any);
use lib qw(lib);

use Nix::PerlPackages;
use Nix::MetaCPANCache;
use IPC::Cmd qw(run);

use experimental qw(signatures try);

our $VERSION = 0.2;

option bool    => "debug"          => "Output debug information" => 0;
option bool    => "verbose"        => "Show changes and determinations being made" => 0;
option file    => "nix_file"       => "Path to perl-packages.nix" => "pkgs/top-level/perl-packages.nix";

#option string => "db_file"        => "Path to store DB cache";
#option string => "download_cache" => "Path to store responses from MetaCPAN API";

subcommand compare => "Compare perl-packages.nix against MetaCPANCache" => sub {

};

subcommand update_db => "Update MetaCPANCache" => sub {
};

subcommand update => "Update one or more perlPackage derivations" => sub {
  option bool => "inplace" => "Write changes to nix_file" => 0;
  option bool => "commit"  => "Commit changes" => 0;
};



sub init_logging {
    my $app = shift;
    Log::Log4perl->easy_init({
            level =>  ($app->debug ? $DEBUG : ($app->verbose ? $INFO : undef)),
            layout => '%X{distro}%m%n'
          });
    Log::Log4perl::MDC->put('distro', q{});
}

sub command_refresh_db ($app) {
  $app->init_logging;
  my $mcc = Nix::MetaCPANCache->new;
  $mcc->clear_caches();
  $mcc->update();
  return 0;
}

sub command_compare ($app, @args) {
  $app->init_logging;
  my $metacpan = Nix::MetaCPANCache->new;
  die "MetaCPAN cache does not exist, download it with:\n    $0 update_db\n\n"
    unless $metacpan->db_file_exists;

  my $pp = Nix::PerlPackages->new( nix_file => $app->nix_file );

  my @drvs = $pp->drvs;
  if (@args) {
    @drvs = grep { $_->attrname eq any(@args) } @drvs;
  }
  foreach my $drv (@drvs) {
    my $name = $drv->name;
    my $mc = $metacpan->get_by(distribution => $name);
    unless ($mc) {
      WARN("Cannot find $name in MetaCPAN");
      next;
    }
    my $state = "NA";
    if ($mc->newer_than($drv->version)) {
      $state = "UPDATE";
    }
    printf("%-40s %-40s %-10s %-10s (%s)\n",
           $drv->attrname, $name, $drv->version, $mc->version, $state);

    say "|.. " . join(", ", $drv->build_inputs);
    say "|++ " . join(", ", $mc->build_inputs);


    say "#.. " . join(", ", $drv->propagated_build_inputs);
    say "#++ " . join(", ", $mc->propagated_build_inputs);
  }
}

sub compare_dependencies($app, $drv, $mc) {


}

sub command_update ($app, @attrs) {
  $app->init_logging;
  my $metacpan = Nix::MetaCPANCache->new;
  die "MetaCPAN cache does not exist, download it with:\n    $0 update_db\n\n"
    unless $metacpan->db_file_exists;

  my $pp = Nix::PerlPackages->new( nix_file => $app->nix_file );

  unless (@attrs) {
    @attrs = map { $_->attrname } $pp->drvs;
  }

  my (@updated, @ok, @fail);
  foreach my $a (@attrs) {
    try {
      my $d = $app->update_attr($metacpan, $pp, $a);
      if ($d && $d->dirty) {
        push @updated, $d;
      } else {
        push @ok, [$a];
      }
    } catch ($e) {
      warn $e;
      push @fail, [$a, $e];
    }
  }


  INFO("Updates for ".scalar(@updated)." packages, ok ".scalar(@ok).", failed ".scalar(@fail));

  foreach my $d (@updated) { ### Updating inplace [===|    ] % done
    if ($app->inplace || $app->commit) {
      $pp->update_inplace($d);
      if ($app->commit) {
        $app->git_cmd("commit","--no-gpg-sign","-m", $d->git_message);
      }
    }

  }

  return 0;
}

 sub git_cmd ($app, @args) {
   my $file = $app->nix_file;
   die "git_cmd: Invalid nix_file $file" unless $file && -f $file;
   my $dir = dirname($file);
   my $rel_file = basename($file);

   my ($ok, $err, $buf) = run( command => ["git", "-C", $dir, @args, $rel_file] );
   die "$err: ".join ("", @$buf) unless $ok;
   return join "", $buf->@*;
}

sub git_sanity ($app) {
    my @err;
    my $nix_file = $app->nix_file;
    my $pwd_branch = $app->git_cmd(qw(rev-parse --abbrev-ref HEAD));
    push @err, "* pwd is in '$pwd_branch' branch, this is probably not what you want\n"
      if $pwd_branch=~/(master|main)/;

    my $file_status = $app->git_cmd(qw(status --porcelain $nix_file));
    push @err, "* $nix_file is not clean, maybe it has uncommitted changes?\n"
      if $file_status || $?;

    die "git_sanity error:\n".join("", @err) if @err;
}



sub update_attr ($app, $metacpan, $pp, $attrname) {
  my $drv = $pp->drv_by_attrname($attrname);
  unless ($drv) {
    die "Cannot find $attrname in perlPackages";
  }

  my $mc = $metacpan->get_by(distribution => $drv->name);
  unless ($mc) {
    die "Cannot find " . $drv->name . "on MetaCPAN";
  }

  unless ($mc->newer_than($drv->version)) {
    return;
  }

  $drv->update_from_metacpan($mc);

  return $drv;
}


app {
    my $app = shift;
    $app->init_logging();
    $app->_script->print_help;

    return 1;
};
