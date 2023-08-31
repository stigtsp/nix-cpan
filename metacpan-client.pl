#! /usr/bin/env nix-shell
#! nix-shell -i perl -p "with perl.pkgs; [ perl MetaCPANClient Mojolicious CpanelJSONXS SmartComments ]"

# TODO
# - Better cache handling, add --clear-cache
# - Get dependencies from the bulk MetaCPAN API queries
# - Check for Build.PL trough MetaCPAN API

use v5.38;
use strict;
use MetaCPAN::Client;
use Data::Dumper;
use Smart::Comments;
use Mojo::File qw(path);
use Mojo::JSON qw(decode_json encode_json);

my $cache_file = path($ENV{XDG_RUNTIME_DIR}, "metacpan-cache.json");

sub get_releases_cached ($cache_file) {
  if (-f $cache_file) {
    ### Parsing cache of all latest releases
    return decode_json($cache_file->slurp);
  }
  my $releases = get_releases();
  $cache_file->spurt(encode_json($releases));
  return $releases;
}

sub get_releases  {
  my $mc = MetaCPAN::Client->new();

  my @spec =
    (
      {
        all => [ { status => 'latest' }, { authorized=>!!1 } ]
      },
      # {
      #   #fields => [qw/release/],
      #   fields => [qw/ distribution version version_numified checksum_sha256 download_url
      #                  license name abstract author authorized provides main_module /],
      #   #'_source' => [qw/ distribution dependency version release provides /]
      # }
  );

  my $release_results = $mc->release(@spec);
  my @releases;

  my $total = $release_results->total;
  foreach ( 1..$total ) { ### Downloading metadata on $total releases |===[%]    |
    my $release = $release_results->next;
    push @releases, $release->{data};
  }
  return \@releases;
}


my $releases = get_releases_cached($cache_file);

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
