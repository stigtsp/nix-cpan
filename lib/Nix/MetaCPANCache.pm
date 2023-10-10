use v5.38;
use strict;
use experimental qw(class);

class Nix::MetaCPANCache {
  use Nix::MetaCPANCache::Release;
  use DBI;
  use MetaCPAN::Client;
  use Cpanel::JSON::XS qw(encode_json decode_json);
  use IO::Zlib qw(:gzip_external 1);
  use Log::Log4perl qw(:easy);
  use Smart::Comments;

  field $cache_file :param = "/var/tmp/metacpan-download-cache.jsonl.gz";
  field $db_file    :param = "/var/tmp/metacpan-cache.db";

  field $transaction_size :param = 2000;

  ADJUST {
    ERROR("Missing $db_file, run update()") unless -f $db_file;
  };

  method dbh {
    state $dbh = DBI->connect("dbi:SQLite:dbname=$db_file",
                              { RaiseError => 1, AutoCommit => 0});
    return $dbh;
  }

  method get_by ($key, $val) {
     my $h = $self->dbh->selectrow_hashref("SELECT * FROM releases WHERE $key=?", undef,
                                           $val);
     return unless $h;
     return Nix::MetaCPANCache::Release->new(%$h, _mcc => $self);
  }


  method db_file_exists {
    return -f $db_file;
  }

  method unlink_db_file {
    unlink($db_file) || die $!;
  }

  method clear_caches {
    $self->clear_download_cache;
    $self->clear_db_cache;
  }

  method clear_download_cache {
    if (-f $cache_file) {
      INFO("Removing download cache: $cache_file");
      unlink($cache_file);
    }
  }

  method clear_db_cache {
    if (-f $cache_file) {
      INFO("Removing db cache: $db_file");
      unlink($db_file);
    }
  }

  method cached_download_releases {
    if (-f $cache_file) {
      INFO("Using cached MetaCPAN API responses from $cache_file");

      my @releases;
      my $fh = IO::Zlib->new($cache_file, "rb") || die $!;
      while (my $l = <$fh>) {
        push @releases, decode_json($l);
      }
      $fh->close;
      return [ @releases ];
    } else {
      INFO("Downloading release data from MetaCPAN API (slow)");
      my $releases = $self->download_releases;
      my $wh = IO::Zlib->new($cache_file, "wb3") || die $!;
      foreach (@$releases) {
        print $wh encode_json($_) . "\n";
      }
      $wh->close;
      return $releases;
    }
  }

  method download_releases {
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
    return [ @releases ];
  }

  method update {
    INFO("Getting releases");
    my $releases = $self->cached_download_releases();

    INFO("Filter releases");
    $releases = $self->filter_releases($releases);

    if ($self->db_file_exists) {
      INFO("Removing $db_file");
      $self->unlink_db_file();
    }
    $self->write_releases($releases);
    $self->write_dependencies();
  }

  method write_releases ($releases) {
    my $dbh = $self->dbh;
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

    $dbh->begin_work;

    my $sth = $dbh->prepare(
      "INSERT INTO releases (name, distribution, main_module, data) VALUES (?,?,?,?)");
    my $i=0;
    foreach my $r (@$releases) {
      $sth->execute( $r->{name},
                     $r->{distribution},
                     $r->{main_module},
                     encode_json($r) );
      if (++$i % $transaction_size == 0) {
        DEBUG("Committing $i");
        $dbh->commit;
        $dbh->begin_work;
      }
    }
    $dbh->commit;
  }

  method filter_releases ($releases) {
    INFO("Filtering release data from MetaCPAN");

    my %distros;
    foreach my $release (@$releases) {
      my $d = $release->{distribution};

      # Handle duplicate distributions returned by the MetaCPAN API
      if ($distros{$d}) {

        my $cur_v  = $release->{version_numified};
        my $prev_v = $distros{$d}->{version_numified};

        if ( $release->{version_numified} < $distros{$d}->{version_numified} ) {
          WARN("Skipping ".$release->{name}." ($cur_v) since ".$distros{$d}->{name}." ($prev_v) is newer");
          next;
        }

        if ( $release->{version_numified} > $distros{$d}->{version_numified} ) {
          WARN("Using ".$release->{name}." ($cur_v) since ".$distros{$d}->{name}." ($prev_v) is older");
        }
      }
      $distros{$d} = $release;
    }

    # Sort by distribution name
    my @releases =
      map { $distros{$_} }
      sort { $distros{$a}->{distribution} cmp $distros{$b}->{distribution} }
      keys %distros;
    return \@releases;
  }

  method write_dependencies {
    my $dbh = $self->dbh;

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

    $dbh->begin_work;

    my $ins_sth = $dbh->prepare(
      "INSERT INTO dependency (distribution, relationship, module, version, phase)
       VALUES (?,?,?,?,?)" );

    my $i = 0;
    $self->each_release(
      sub ($r) {
        return unless $r->{dependency};
        foreach my $d (@{$r->{dependency}}) {
          my $values = [$r->{distribution},
                        $d->{relationship},
                        $d->{module},
                        $d->{version},
                        $d->{phase}];
          $ins_sth->execute(@$values);
          if (++$i % $transaction_size == 0) {
            DEBUG("Committing $i");
            $dbh->commit;
            $dbh->begin_work;
          }
        }
      });
    $dbh->commit;
  }


  method each_release($cb = undef) {
    my $dbh = $self->dbh;
    my $sth = $dbh->prepare('select * FROM releases ORDER BY distribution');
    $sth->execute();
    my @r;
    while (my $row = $sth->fetchrow_hashref()) {
      my $data = decode_json($row->{data});
      push @r, ( $cb ? $cb->($data) : $data);
    }
    return @r;
  }




}
