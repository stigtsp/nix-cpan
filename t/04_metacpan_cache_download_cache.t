use v5.38;
use Test::More;
use File::Temp qw(tempdir);

use_ok("Nix::MetaCPANCache");

my $tmpdir = tempdir(CLEANUP => 1);
my $cache_file = "$tmpdir/metacpan-download-cache.jsonl.gz";
my $db_file = "$tmpdir/metacpan-cache.db";

my $mcc = new_ok(
  "Nix::MetaCPANCache" => [ cache_file => $cache_file, db_file => $db_file ],
  "Nix::MetaCPANCache"
);

{
  no warnings 'redefine';
  local *Nix::MetaCPANCache::download_releases = sub ($self) {
    return [
      {
        name         => "Foo-1.0",
        distribution => "Foo",
        main_module  => "Foo",
        dependency   => [],
      },
    ];
  };

  my $first = $mcc->cached_download_releases();
  is_deeply(
    $first,
    [
      {
        name         => "Foo-1.0",
        distribution => "Foo",
        main_module  => "Foo",
        dependency   => [],
      },
    ],
    "cached_download_releases returns downloaded releases when cache is missing"
  );
  ok(-f $cache_file, "cached_download_releases writes download cache file");
}

{
  no warnings 'redefine';
  local *Nix::MetaCPANCache::download_releases = sub ($self) {
    die "download_releases should not be called when cache file exists";
  };

  my $second = $mcc->cached_download_releases();
  is($second->[0]->{name}, "Foo-1.0",
     "cached_download_releases reads release data from cached file");
}

{
  open my $fh, ">", $db_file or die $!;
  print {$fh} "db";
  close $fh;
  ok(-f $db_file, "db cache file exists before clear_db_cache");
  ok(-f $cache_file, "download cache file exists before clear_db_cache");

  $mcc->clear_db_cache();
  ok(!-f $db_file, "clear_db_cache removes db file");
  ok(-f $cache_file, "clear_db_cache does not remove download cache file");
}

done_testing();
