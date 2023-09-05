#!/usr/bin/env perl
#
# TODO
# - Better cache handling, add --clear-cache
# - Get dependencies from the bulk MetaCPAN API queries
# - Check for Build.PL trough MetaCPAN API

use v5.38;
use experimental qw(signatures);
use Applify;
use File::Spec::Functions;
use File::stat;
use Data::Dumper;
use Mojo::SQLite;
use MetaCPAN::Client;
use Smart::Comments;
use Cpanel::JSON::XS qw(encode_json decode_json);
use Log::Log4perl qw(:easy);

my $db_file_default = catfile( $ENV{XDG_RUNTIME_DIR} || "/var/tmp/",
                               "metacpan-cache.db" );

option file    => "db_file"   => "SQLite file to store metacpan data in" => $db_file_default;
option string  => "distro"    => "Get distro info" => undef;
option bool    => "download"  => "Download latest distributions from MetaCPAN API" => 0;
option bool    => "update_dependencies" => "Update dependencies" => 0;
option bool    => "debug"     => "Enable debug messages" => 0;

app {
  my $app = shift;
  Log::Log4perl->easy_init({
    level =>  ($app->debug ? $DEBUG : $INFO),
  });
  return $app->run_distro if $app->distro;
  return $app->run_download if $app->download;
  return $app->run_update_dependencies if $app->update_dependencies;
  $app->_script->print_help;
  return 1;
};

sub run_distro ($app) {
  say $app->sql->db->query("SELECT data FROM releases WHERE distribution=?", $app->distro)->hash->{data};
  return 0;
}

sub run_download ($app) {
  INFO("Getting releases");
  my $releases = $app->get_releases();
  INFO("Filtering releases");
  my $filtered = filter_releases($releases);
  if (-f $app->db_file) {
    INFO("Removing ".$app->db_file);
    unlink($app->db_file);
  }
  INFO("Writing releases to: ".$app->db_file);
  $app->write_releases($releases);

  $app->run_update_dependencies();
  return 0;
}


sub run_update_dependencies ($app) {
  unless (-f $app->db_file) {
    WARN("Can't find DB file");
    return 1;
  }
  INFO("Writing dependencies to: ".$app->db_file);
  $app->write_dependencies();
  INFO("Done");
  return 0;
}


sub sql ($app) {
  return Mojo::SQLite->new("sqlite:".$app->db_file);
}

sub write_releases($app, $releases) {
  my $db = $app->sql->db;
  $db->query("DROP TABLE IF EXISTS releases");
  $db->query("CREATE TABLE releases (name varchar(255) primary key, distribution varchar(255), data blob)");
  foreach my $r (@$releases) {
    $db->insert('releases', {
      name => $r->{name},
      distribution => $r->{distribution},
      data => encode_json($r)
    });
  }
}

sub each_release($app, $cb) {
  my $db = $app->sql->db;
  my $results = $db->query('select * FROM releases ORDER BY distribution');
  my @ins;
  while (my $row = $results->hash) {
    my $release = decode_json($row->{data});
    $cb->($release);
  }
}

sub write_dependencies ($app) {
  my $db = $app->sql->db;

  my @ins;
  ### Iterating over releases
  $app->each_release(
    sub ($r) {
      return unless $r->{dependency};
      foreach my $d (@{$r->{dependency}}) {
        push @ins, {
          distribution => $r->{distribution},
          %$d };
      }
    });

  ### Writing dependencies

  $db->query("DROP TABLE IF EXISTS dependency");
  $db->query("CREATE TABLE dependency (
distribution varchar(255),
relationship varchar(255),
module varchar(255),
version varchar(255),
phase varchar(255)
)");

  my $tx = $db->begin;
  foreach my $d (@ins) {
    $db->insert('dependency', $d);
  }
  $tx->commit;
}


sub get_releases ($app) {
  my $mc = MetaCPAN::Client->new();

  my $release_results = $mc->release({
    all => [ { status     => 'latest' },
             { authorized => !!1      } ]
  });

  my @releases;

  my $total = $release_results->total;
  foreach ( 1..$total ) { ### Downloading metadata on $total releases |===[%]    |
    my $release = $release_results->next;
    push @releases, $release->{data};
  }
  return \@releases;
}

sub filter_releases ($releases) {
  my %distros;
  foreach my $release (@$releases) {
    my $d = $release->{distribution};
    if ($distros{$d} && $release->{version_numified} < $distros{$d}->{version_numified}) {
      my $cur_v  = $release->{version_numified};
      my $prev_c = $distros{$d}->{version_numified};
      warn "Skipping ".$release->{name}." ($cur_v) since ".$distros{$d}->{name}." ($prev_c) is newer\n";
      next;
    }
    $distros{$d} = $release;
  }

  my @releases =
    map { $distros{$_} }
    sort { $distros{$a}->{distribution} cmp $distros{$b}->{distribution} }
    keys %distros;

  return \@releases;
}

# sub get_distro($distro) {
#   my $data = sql()->db->query("SELECT * FROM releases WHERE distribution=?", $distro)->hash->{data};
#   return decode_json($data);
# }


exit(0);

