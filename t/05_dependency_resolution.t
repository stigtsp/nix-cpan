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

my $releases = [
  {
    name             => "Foo-Bar-1.0",
    distribution     => "Foo-Bar",
    main_module      => "Foo::Bar",
    version          => "1.0",
    version_numified => 1,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/F/FO/FOO/Foo-Bar-1.0.tar.gz",
    dependency       => [],
    provides         => {
      "Foo::Bar"       => { file => "lib/Foo/Bar.pm" },
      "Foo::Bar::Util" => { file => "lib/Foo/Bar/Util.pm" },
    },
  },
  {
    name             => "Baz-1.0",
    distribution     => "Baz",
    main_module      => "Baz",
    version          => "1.0",
    version_numified => 1,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/B/BA/BAZ/Baz-1.0.tar.gz",
    dependency       => [
      {
        module       => "Foo::Bar::Util",
        relationship => "requires",
        phase        => "runtime",
        version      => "0",
      },
      {
        module       => "Win32::Process",
        relationship => "requires",
        phase        => "runtime",
        version      => "0",
      },
      {
        module       => "Does::Not::Exist",
        relationship => "requires",
        phase        => "runtime",
        version      => "0",
      },
    ],
    provides => {
      "Baz" => { file => "lib/Baz.pm" },
    },
  },
  {
    name             => "Win32-Process-0.17",
    distribution     => "Win32-Process",
    main_module      => "Win32::Process",
    version          => "0.17",
    version_numified => 0.17,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/J/JD/JDB/Win32-Process-0.17.tar.gz",
    dependency       => [],
    provides => {
      "Win32::Process" => { file => "lib/Win32/Process.pm" },
    },
  },
];

$mcc->write_releases($releases);

my $resolved = $mcc->resolve_module("Foo::Bar::Util");
is($resolved->distribution, "Foo-Bar",
   "resolve_module can resolve non-main modules through provide index");

my $baz = $mcc->get_by(distribution => "Baz");
my $deps = $baz->dependency(["runtime"], ["requires"]);
is_deeply([ map { $_->attrname } @$deps ], ["FooBar"],
          "dependency resolves available modules, ignores unresolved ones, and filters denylisted platform deps");

done_testing();
