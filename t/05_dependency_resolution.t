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
    name             => "Any-Moose-0.27",
    distribution     => "Any-Moose",
    main_module      => "Any::Moose",
    version          => "0.27",
    version_numified => 0.27,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/F/FO/FOO/Any-Moose-0.27.tar.gz",
    dependency       => [],
    provides => {
      "Any::Moose" => { file => "lib/Any/Moose.pm" },
    },
  },
  {
    name             => "Mouse-2.5.11",
    distribution     => "Mouse",
    main_module      => "Mouse",
    version          => "2.5.11",
    version_numified => 2.5,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/G/GF/GFUJI/Mouse-2.5.11.tar.gz",
    dependency       => [],
    provides => {
      "Mouse" => { file => "lib/Mouse.pm" },
    },
  },
  {
    name             => "Moose-2.2",
    distribution     => "Moose",
    main_module      => "Moose",
    version          => "2.2",
    version_numified => 2.2,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/E/ET/ETHER/Moose-2.2.tar.gz",
    dependency       => [],
    provides => {
      "Moose" => { file => "lib/Moose.pm" },
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
        module       => "URI::_generic",
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
  {
    name             => "Dist-Build-0.026",
    distribution     => "Dist-Build",
    main_module      => "Dist::Build",
    version          => "0.026",
    version_numified => 0.026,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/L/LE/LEONT/Dist-Build-0.026.tar.gz",
    metadata         => {
      prereqs => {
        configure => {
          requires => {
            "ExtUtils::Builder" => "0",
          },
        },
      },
    },
    dependency       => [],
    provides         => { "Dist::Build" => { file => "lib/Dist/Build.pm" } },
  },
  {
    name             => "JSON-XS-4.04",
    distribution     => "JSON-XS",
    main_module      => "JSON::XS",
    version          => "4.04",
    version_numified => 4.04,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/M/ML/MLEHMANN/JSON-XS-4.04.tar.gz",
    dependency       => [
      {
        module       => "Types::Serialiser",
        relationship => "requires",
        phase        => "runtime",
        version      => "0",
      },
    ],
    provides         => { "JSON::XS" => { file => "lib/JSON/XS.pm" } },
  },
  {
    name             => "Types-Serialiser-1.01",
    distribution     => "Types-Serialiser",
    main_module      => undef, # simulate missing module->distribution index
    version          => "1.01",
    version_numified => 1.01,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/M/ML/MLEHMANN/Types-Serialiser-1.01.tar.gz",
    dependency       => [],
    provides         => {},
  },
  {
    name             => "HTTP-Message-7.01",
    distribution     => "HTTP-Message",
    main_module      => "HTTP::Message",
    version          => "7.01",
    version_numified => 7.01,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/O/OA/OALDERS/HTTP-Message-7.01.tar.gz",
    dependency       => [],
    provides => {
      "HTTP::Message" => { file => "lib/HTTP/Message.pm" },
    },
  },
  {
    name             => "URI-5.33",
    distribution     => "URI",
    main_module      => "URI",
    version          => "5.33",
    version_numified => 5.33,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/O/OA/OALDERS/URI-5.33.tar.gz",
    dependency       => [],
    provides         => { "URI" => { file => "lib/URI.pm" } },
  },
  {
    name             => "HTTP-CookieJar-0.014",
    distribution     => "HTTP-CookieJar",
    main_module      => "HTTP::CookieJar",
    version          => "0.014",
    version_numified => 0.014,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/D/DA/DAGOLDEN/HTTP-CookieJar-0.014.tar.gz",
    dependency       => [],
    provides => {
      "HTTP::CookieJar" => { file => "lib/HTTP/CookieJar.pm" },
    },
  },
  {
    name             => "HTML-Parser-3.83",
    distribution     => "HTML-Parser",
    main_module      => "HTML::Parser",
    version          => "3.83",
    version_numified => 3.83,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/O/OA/OALDERS/HTML-Parser-3.83.tar.gz",
    dependency       => [],
    provides => {
      "HTML::Parser" => { file => "lib/HTML/Parser.pm" },
    },
  },
  {
    name             => "libwww-perl-6.81",
    distribution     => "libwww-perl",
    main_module      => "LWP",
    version          => "6.81",
    version_numified => 6.81,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/O/OA/OALDERS/libwww-perl-6.81.tar.gz",
    dependency       => [],
    provides => {
      "LWP" => { file => "lib/LWP.pm" },
    },
  },
  {
    name             => "IO-Socket-SSL-2.098",
    distribution     => "IO-Socket-SSL",
    main_module      => "IO::Socket::SSL",
    version          => "2.098",
    version_numified => 2.098,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/S/SU/SULLR/IO-Socket-SSL-2.098.tar.gz",
    dependency       => [],
    provides         => { "IO::Socket::SSL" => { file => "lib/IO/Socket/SSL.pm" } },
  },
  {
    name             => "Net-HTTPS-NB-0.15",
    distribution     => "Net-HTTPS-NB",
    main_module      => "Net::HTTPS",
    version          => "0.15",
    version_numified => 0.15,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/O/OA/OALDERS/Net-HTTPS-NB-0.15.tar.gz",
    dependency       => [],
    provides         => {
      "Net::HTTPS" => { file => "lib/Net/HTTPS.pm" },
      "Net::HTTPS::NB" => { file => "lib/Net/HTTPS/NB.pm" },
    },
  },
  {
    name             => "Try-Tiny-0.32",
    distribution     => "Try-Tiny",
    main_module      => "Try::Tiny",
    version          => "0.32",
    version_numified => 0.32,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/E/ET/ETHER/Try-Tiny-0.32.tar.gz",
    dependency       => [],
    provides         => { "Try::Tiny" => { file => "lib/Try/Tiny.pm" } },
  },
  {
    name             => "LWP-Protocol-https-6.15",
    distribution     => "LWP-Protocol-https",
    main_module      => "LWP::Protocol::https",
    version          => "6.15",
    version_numified => 6.15,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/O/OA/OALDERS/LWP-Protocol-https-6.15.tar.gz",
    dependency       => [
      {
        module       => "IO::Socket::SSL",
        relationship => "requires",
        phase        => "runtime",
        version      => "0",
      },
      {
        module       => "LWP::UserAgent",
        relationship => "requires",
        phase        => "runtime",
        version      => "0",
      },
      {
        module       => "Net::HTTPS",
        relationship => "requires",
        phase        => "runtime",
        version      => "0",
      },
    ],
    provides         => { "LWP::Protocol::https" => { file => "lib/LWP/Protocol/https.pm" } },
  },
];

$mcc->write_releases($releases);

my $resolved = $mcc->resolve_module("Foo::Bar::Util");
is($resolved->distribution, "Foo-Bar",
   "resolve_module can resolve non-main modules through provide index");

my $baz = $mcc->get_by(distribution => "Baz");
my $deps = $baz->dependency(["runtime"], ["requires"]);
is_deeply([ map { $_->attrname } @$deps ], ["FooBar"],
          "dependency resolves available modules, ignores only explicitly allowlisted unresolved modules, and filters denylisted platform deps");

my $any_moose = $mcc->get_by(distribution => "Any-Moose");
is_deeply([$any_moose->propagated_build_inputs], [qw/Moose Mouse/],
          "errata extraRuntimeDependencies are included in propagated inputs");

my $http_message = $mcc->get_by(distribution => "HTTP-Message");
is_deeply([$http_message->propagated_build_inputs], [qw/URI/],
          "errata can inject fallback distro attr when module->distribution lookup is missing");

my $libwww_perl = $mcc->get_by(distribution => "libwww-perl");
is_deeply([$libwww_perl->propagated_build_inputs], [qw/HTMLParser HTTPCookieJar/],
          "libwww-perl errata injects required distro attrs using parent-module fallback");

my $html_parser = $mcc->get_by(distribution => "HTML-Parser");
is_deeply([$html_parser->propagated_build_inputs], [qw/HTTPMessage URI/],
          "html-parser errata injects HTTP::Headers/URI providers");

my $dist_build = $mcc->get_by(distribution => "Dist-Build");
is($dist_build->preferred_build_fun, "Module",
   "build function override forces Dist-Build to Module for missing generation");

my $json_xs = $mcc->get_by(distribution => "JSON-XS");
is_deeply([$json_xs->propagated_build_inputs], [qw/TypesSerialiser/],
          "module-to-distribution fallback resolves Types::Serialiser for JSON-XS");

my $lwp_https = $mcc->get_by(distribution => "LWP-Protocol-https");
is_deeply([$lwp_https->propagated_build_inputs], [qw/IOSocketSSL NetHTTPSNB libwwwperl/],
          "lwp-protocol-https picks runtime deps via parent fallback + errata");
is_deeply([$lwp_https->build_inputs], [qw/TryTiny/],
          "lwp-protocol-https gets missing test dep from errata");

done_testing();
