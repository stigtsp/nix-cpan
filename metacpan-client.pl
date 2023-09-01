#! /usr/bin/env nix-shell
#! nix-shell -i perl -p "with perl.pkgs; [ perl MetaCPANClient DataMessagePack SmartComments ]"

# TODO
# - Better cache handling, add --clear-cache
# - Get dependencies from the bulk MetaCPAN API queries
# - Check for Build.PL trough MetaCPAN API

use v5.38;
use File::Spec::Functions;
use File::stat;
use IO::Zlib;
use Data::Dumper;

use MetaCPAN::Client;
use Smart::Comments;
use Data::MessagePack;

my $cache_file = catfile( $ENV{XDG_RUNTIME_DIR} || "/var/tmp/" ,
                          "metacpan-cache.messagepack.gz");

my $cache_ttl = 86400 * 3;

sub get_releases_cached ($cache_file) {
  my $mp = Data::MessagePack->new();

  if (-f $cache_file) {
    my $ago = time() - stat($cache_file)->mtime;
    if (1) { #}$ago > $cache_ttl) {
      warn sprintf("Warning: $cache_file is %d days old, consider refreshing it\n",
                   ($ago / 86400));
    }
    ### Loading cache from: $cache_file
    my $fh = IO::Zlib->new($cache_file, "rb") || die $!;
    my $unpacked = $mp->unpack(join "", <$fh>);
    $fh->close;
    return $unpacked;
  }
  my $releases = get_releases();

  ### Packing cache
  my $packed = $mp->pack($releases);

  ### Writing cache to: $cache_file
  my $wh = IO::Zlib->new($cache_file, "wb3") || die $!;
  print $wh $packed;
  $wh->close;
  return $releases;
}

sub get_releases  {
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




my $releases = get_releases_cached($cache_file);
my $total = @$releases;

### Got releases: $total

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

foreach my $release (@releases) {
  printf "%s %s %s %s\n", $release->{distribution}, $release->{version}, $release->{download_url}, $release->{checksum_sha256};
}


warn "Total ".scalar(@releases)."\n";

my %dup;
foreach (@releases) {
   $dup{$_->{distribution}}++;
}

# my @dups = grep { $dup{$_} > 1 } keys %dup;
#  warn "Total dupes: ".scalar(@dups)."\n";

# my @authorized = grep { $_->{authorized} } @releases;
# warn "Total authorized: ".scalar(@authorized)."\n";
