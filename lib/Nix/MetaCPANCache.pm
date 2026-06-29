use v5.38;
use strict;
use experimental qw(class);

class Nix::MetaCPANCache {
  use Nix::MetaCPANCache::Release;
  use Nix::PerlPackages::Errata qw(errata);
  use DBI;
  use MetaCPAN::Client;
  use HTTP::Tiny;
  use Cpanel::JSON::XS qw(encode_json decode_json);
  use IO::Zlib qw(:gzip_external 1);
  use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
  use Log::Log4perl qw(:easy);
  use File::Basename qw(basename);
  use File::XDG;

  field $cache_file :param = undef;
  field $db_file    :param = undef;
  field $cpan_02packages_file :param = undef;

  field $transaction_size :param = 2000;

  ADJUST {
    my $xdg = File::XDG->new(name => "nix-cpan", api => 1);

    my $makeCache = sub ($f) {
      my $dir = $xdg->cache_home;
      unless (-d $dir ) {
        INFO("Creating cache directory ".$dir);
        $dir->mkdir;
      }
      return $dir->child($f);
    };

    $db_file    //= $makeCache->("metacpan-cache.db");
    $cache_file //= $makeCache->("metacpan-download-cache.jsonl.gz");
    $cpan_02packages_file //= $makeCache->("cpan-02packages.details.txt.gz");

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

  method resolve_module ($module) {
    my $cfg = errata();
    my $override_map =
      ($cfg && ref($cfg) eq "HASH" && ref($cfg->{moduleResolutionOverrides}) eq "HASH")
      ? $cfg->{moduleResolutionOverrides}
      : {};

    my @candidates = ($module);
    my $parent = $module;
    while ($parent =~ s/::[^:]+$//) {
      push @candidates, $parent;
    }

    foreach my $cand (@candidates) {
      if (my $override = $override_map->{$cand}) {
        state %warned_override;
        my $key = $cand . "=>" . $override;
        WARN("Errata moduleResolutionOverrides applied: $cand => $override")
          unless $warned_override{$key}++;
        my $release = $self->get_by(distribution => $override);
        return $release if $release;
        $release = $self->get_by(main_module => $override);
        return $release if $release;
      }

      my $release = $self->get_by(main_module => $cand);
      return $release if $release;

      my ($distribution) = $self->dbh->selectrow_array(
        "SELECT distribution FROM provide WHERE module=?",
        undef,
        $cand
      );
      if ($distribution) {
        $release = $self->get_by(distribution => $distribution);
        return $release if $release;
      }

      # Fallback for incomplete provide indexes: derive distribution guess from
      # module name (e.g. Types::Serialiser -> Types-Serialiser).
      if ($cand =~ /::/) {
        my $dist_guess = $cand;
        $dist_guess =~ s/::/-/g;
        $release = $self->get_by(distribution => $dist_guess);
        return $release if $release;
      }
    }

    return;
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
    if (-f $cpan_02packages_file) {
      INFO("Removing CPAN 02packages cache: $cpan_02packages_file");
      unlink($cpan_02packages_file);
    }
  }

  method clear_db_cache {
    if (-f $db_file) {
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
      my $fh = IO::Zlib->new($cache_file, "wb9") || die $!;
      foreach my $release (@$releases) {
        print {$fh} encode_json($release)."\n";
      }
      $fh->close;
      return $releases;
    }
  }

  method download_releases {
    my $mc = MetaCPAN::Client->new();

    my $release_results = $mc->release({
      # Use latest releases without filtering by "authorized".
      # Some valid distributions/modules (e.g. URI in certain snapshots)
      # may be absent when this filter is applied, which leaves dependency
      # modules unresolved in the local cache.
      all => [ { status => 'latest' } ]
    });
    my @releases;
    my $total = $release_results->total;
    INFO("Downloading $total releases from MetaCPAN");
    foreach my $n (1..$total) {
      my $release = $release_results->next;
      push @releases, $release->{data};
      INFO("Downloaded $n/$total releases") if $n % 2000 == 0;
    }
    INFO("Downloaded $total releases");
    return [ @releases ];
  }

  method refresh {
    INFO("Getting releases");
    my $releases = $self->cached_download_releases();

    INFO("Filter releases");
    $releases = $self->filter_releases($releases);

    if ($self->db_file_exists) {
      INFO("Removing $db_file");
      $self->unlink_db_file();
    }
    $self->write_releases($releases);
    $self->enrich_provide_from_02packages();
    $self->write_dependencies();
  }

  method cached_download_02packages_file {
    if (-f $cpan_02packages_file) {
      INFO("Using cached CPAN 02packages index from $cpan_02packages_file");
      return $cpan_02packages_file;
    }

    my $url = "https://cpan.metacpan.org/modules/02packages.details.txt.gz";
    INFO("Downloading CPAN 02packages index from $url");
    my $http = HTTP::Tiny->new(timeout => 60);
    my $res = $http->get($url);
    die "Failed downloading $url: $res->{status} $res->{reason}"
      unless $res->{success};

    open my $fh, ">", $cpan_02packages_file
      or die "Cannot write $cpan_02packages_file: $!";
    binmode($fh);
    print {$fh} $res->{content};
    close $fh;

    return $cpan_02packages_file;
  }

  method enrich_provide_from_02packages {
    my $gz_file = $self->cached_download_02packages_file();

    INFO("Indexing module->distribution mappings from CPAN 02packages");
    my %archive_to_distribution;
    $self->each_release(
      sub ($r) {
        my $archive = $r->{archive};
        return unless defined $archive && length $archive;
        my $distribution = $r->{distribution};
        return unless defined $distribution && length $distribution;
        $archive_to_distribution{$archive} //= $distribution;
      }
    );

    my $dbh = $self->dbh;
    $dbh->begin_work;
    my $ins_sth = $dbh->prepare(
      "INSERT OR IGNORE INTO provide (module, distribution) VALUES (?,?)"
    );

    open my $fh, "<", $gz_file or die "Cannot open $gz_file: $!";
    binmode($fh);
    my $content = q{};
    gunzip($fh => \$content) or die "gunzip $gz_file failed: $GunzipError";
    close $fh;

    my $in_body = 0;
    my $inserted = 0;
    my $unresolved = 0;
    foreach my $line (split /\n/, $content) {
      if (!$in_body) {
        $in_body = 1 if $line =~ /^\s*$/;
        next;
      }
      next unless $line =~ /\S/;
      my ($module, $version, $path) = split /\s+/, $line, 3;
      next unless defined $module && defined $path;
      my $archive = basename($path);
      my $distribution = $archive_to_distribution{$archive};
      unless ($distribution) {
        $unresolved++;
        next;
      }
      $ins_sth->execute($module, $distribution);
      $inserted++;
    }
    $dbh->commit;

    INFO("CPAN 02packages enrichment complete: inserted/attempted=$inserted unresolved=$unresolved");
  }

  method write_releases ($releases) {
    my $dbh = $self->dbh;
    INFO("Setting up releases table");


    map { $dbh->do($_) }
      "DROP TABLE IF EXISTS releases",
      "DROP TABLE IF EXISTS provide",
      "CREATE TABLE releases (
              name varchar(255) primary key,
              distribution varchar(255),
              main_module varchar(255),
              data JSON)",
      "CREATE TABLE provide (
              module varchar(255) primary key,
              distribution varchar(255))",
      "CREATE INDEX r_distribution ON releases(distribution)",
      "CREATE INDEX r_main_module ON releases(main_module)",
      "CREATE INDEX p_distribution ON provide(distribution)";

    INFO("Writing releases");

    $dbh->begin_work;

    my $sth = $dbh->prepare(
      "INSERT INTO releases (name, distribution, main_module, data) VALUES (?,?,?,?)");
    my $provide_sth = $dbh->prepare(
      "INSERT OR IGNORE INTO provide (module, distribution) VALUES (?,?)");
    my $i=0;
    foreach my $r (@$releases) {
      $sth->execute( $r->{name},
                     $r->{distribution},
                     $r->{main_module},
                     encode_json($r) );

      my %mods;
      if ($r->{main_module}) {
        $mods{$r->{main_module}} = 1;
      }
      if ($r->{provides}) {
        if (ref($r->{provides}) eq "HASH") {
          foreach my $module (keys $r->{provides}->%*) {
            $mods{$module} = 1 if $module;
          }
        } elsif (ref($r->{provides}) eq "ARRAY") {
          foreach my $module ($r->{provides}->@*) {
            $mods{$module} = 1 if defined $module && length $module;
          }
        }
      }
      foreach my $module (keys %mods) {
        $provide_sth->execute($module, $r->{distribution});
      }

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
