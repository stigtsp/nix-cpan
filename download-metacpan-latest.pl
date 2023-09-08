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
use DBI;
use MetaCPAN::Client;
use Smart::Comments;
use Cpanel::JSON::XS qw(encode_json decode_json);
use Log::Log4perl qw(:easy);

my $db_file_default = "/var/tmp/metacpan-cache.db";

option file    => "db_file"   => "SQLite file to store metacpan data in" => $db_file_default;

option string  => "get_distribution"    => "Get distribution" => undef;
option string  => "get_main_module"     => "Get by main module" => undef;
option string  => "get_dependency"      => "Get by dependency" => undef;

option bool    => "download"            => "Download latest distributions from MetaCPAN API" => 0;
option bool    => "update_dependencies" => "Update dependencies" => 0;
option bool    => "debug"               => "Enable debug messages" => 0;

app {
  my $app = shift;
  Log::Log4perl->easy_init({
    level =>  ($app->debug ? $DEBUG : $INFO),
  });
  return $app->run_get_distribution if $app->get_distribution;
  return $app->run_get_main_module  if $app->get_main_module;
  return $app->run_get_dependency   if $app->get_dependency;


  return $app->run_download if $app->download;
  return $app->run_update_dependencies if $app->update_dependencies;
  $app->_script->print_help;
  return 1;
};

sub run_get_distribution ($app) {
  say $app->dbh->selectrow_array("SELECT data FROM releases WHERE distribution=?", undef,
                                 $app->get_distribution);
  return 0;
}

sub run_get_main_module ($app) {
  say $app->dbh->selectrow_array("SELECT data FROM releases WHERE main_module=?", undef,
                                 $app->get_main_module);

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

  $app->write_releases($releases);
  $app->run_update_dependencies();
  return 0;
}


sub run_update_dependencies ($app) {
  unless (-f $app->db_file) {
    WARN("Can't find DB file");
    return 1;
  }
  $app->write_dependencies();
  return 0;
}


sub dbh ($app) {
  state $dbh =DBI->connect("dbi:SQLite:dbname=".$app->db_file,
                      { RaiseError => 1, AutoCommit => 1});
  return $dbh;
}

sub write_releases($app, $releases) {
  my $dbh = $app->dbh;

  INFO("Setting up releases table");

  map { $dbh->do($_) }
    "DROP TABLE IF EXISTS releases",
    "CREATE TABLE releases (
              name varchar(255) primary key,
              distribution varchar(255),
              main_module varchar(255),
              data JSON)",
    "CREATE INDEX r_distribution ON releases(distribution)",
    "CREATE INDEX r_main_module ON releases(main_module)";

  INFO("Writing releases");
  my $sth = $dbh->prepare("INSERT INTO releases (name, distribution, main_module, data) VALUES (?,?,?,?)");
  foreach my $r (@$releases) {
    $sth->execute( $r->{name},
                   $r->{distribution},
                   $r->{main_module},
                   encode_json($r) );
  }
}

sub each_release($app, $cb) {
  my $dbh = $app->dbh;

  my $sth = $dbh->prepare('select * FROM releases ORDER BY distribution');
  $sth->execute();

  while (my $row = $sth->fetchrow_hashref()) {
    $cb->(decode_json($row->{data}));
  }
}

sub write_dependencies ($app) {
  my $dbh = $app->dbh;

  INFO("Setting up dependency table");

  map { $dbh->do($_) }
    "DROP TABLE IF EXISTS dependency",
    "CREATE TABLE dependency (
       distribution varchar(255),
       relationship varchar(255),
       module varchar(255),
       version varchar(255),
       phase varchar(255))",
    "CREATE INDEX d_distribution_phase ON dependency(distribution,phase)",
    "CREATE INDEX d_module ON dependency(module)";

  INFO("Writing dependency table");

  my $ins_sth = $dbh->prepare(
    "INSERT INTO dependency (distribution, relationship, module, version, phase)
     VALUES (?,?,?,?,?)" );

  $app->each_release(
    sub ($r) {
      return unless $r->{dependency};
      foreach my $d (@{$r->{dependency}}) {
        my $values = [$r->{distribution},
                      $d->{relationship},
                      $d->{module},
                      $d->{version},
                      $d->{phase}];

        $ins_sth->execute(@$values);
      }
    });
}


sub get_releases ($app) {
  my $mc = MetaCPAN::Client->new();

  my $release_results = $mc->release({
    all => [ { status     => 'latest' },
             { authorized => !!1      } ]
  });

  my @releases;

  my $total = $release_results->total;
  # This foreach is made so Smart::Comments understand progress :)
  foreach ( 1..$total ) { ### Downloading $total releases [===|    ] % done
    my $release = $release_results->next;
    push @releases, $release->{data};
  }
  return \@releases;
}

sub filter_releases ($releases) {
  INFO("Filtering release data from MetaCPAN");
  my %distros;
  foreach my $release (@$releases) {
    my $d = $release->{distribution};
    if ($distros{$d} && $release->{version_numified} < $distros{$d}->{version_numified}) {
      my $cur_v  = $release->{version_numified};
      my $prev_c = $distros{$d}->{version_numified};
      WARN("Skipping ".$release->{name}." ($cur_v) since ".$distros{$d}->{name}." ($prev_c) is newer");
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

