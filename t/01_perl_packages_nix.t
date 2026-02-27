use v5.38;
use Test::More;
use Data::Dumper;

use_ok("Nix::PerlPackages");
use_ok("Nix::PerlPackages::Drv");

my $perlPackages = new_ok( "Nix::PerlPackages" => [ nix_file => 't/var/perl-packages.nix'],
                           "Nix::PerlPackages" );

$perlPackages->parse_nix_file();

is(scalar $perlPackages->drvs, 1831); # XXX: TermReadKey doesn't parse

my $moose = $perlPackages->drv_by_attrname("Moose");

isa_ok($moose, "Nix::PerlPackages::Drv", "Moose object has correct class");

is( $moose->get_attr("url"), "mirror://cpan/authors/id/E/ET/ETHER/Moose-2.2013.tar.gz",
    "Moose has expected url");

is( $moose->get_attr("hash"), "sha256-33TceAiJIReO33LYJwF9bJJzfJhmWfLa3FM64kZ153w=",
    "Moose has expected hash");

is_deeply( [ $moose->get_attr_list("buildInputs") ],
           [ qw/CPANMetaCheck TestCleanNamespaces TestFatal TestRequires/ ],
           "Moose has expected buildInputs");

is_deeply( [ $moose->get_attr_list("propagatedBuildInputs") ],
           [ qw/ClassLoadXS DevelGlobalDestruction DevelOverloadInfo
                DevelStackTrace EvalClosure ModuleRuntimeConflicts
                PackageDeprecationManager PackageStashXS SubExporter/ ],
           "Moose has expected propagatedBuildInputs" );

isnt($moose->dirty, !!1, "Moose is not dirty, no changes have happened yet");

$moose->set_attr("url", "https://nixos.org");

is( $moose->get_attr("url"), "https://nixos.org", "Moose had it's url changed" );

is( $moose->dirty, !!1, "Moose is dirty, after the url was changed" );

is_deeply( [ $moose->build_inputs ],
           [ qw/CPANMetaCheck TestCleanNamespaces TestFatal TestRequires/ ],
           "Moose has expected buildInputs" );

is_deeply( [ $moose->propagated_build_inputs ],
           [ qw/ClassLoadXS DevelGlobalDestruction DevelOverloadInfo
                DevelStackTrace EvalClosure ModuleRuntimeConflicts
                PackageDeprecationManager PackageStashXS SubExporter/ ],
           "Moose has expected propagatedBuildInputs" );

$moose->set_build_inputs( qw/DevelGlobalDestruction DevelOverloadInfo ClassLoadXS / ); # Not ordered

is_deeply( [ $moose->build_inputs() ],
           [ qw/ClassLoadXS DevelGlobalDestruction DevelOverloadInfo/ ],
           "Could set new build inputs for Moose" );

$moose->set_propagated_build_inputs( qw/Moo/ );

is_deeply( [ $moose->propagated_build_inputs() ],
           [ qw/Moo/ ],
           "Could set new propagated build inputs for Moose" );

{
  package Test::FakeRelease;
  sub new { bless {}, shift }
  sub distribution { return "Fake-Distro" }
  sub version { return "9.99" }
  sub checksum_sha256 {
    return "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
  }
  sub download_url {
    return "https://cpan.metacpan.org/authors/id/F/FO/FOO/Foo-Bar-9.99.tar.gz";
  }
  sub build_inputs { return qw/Zeta Alpha/ }
  sub propagated_build_inputs { return qw/Gamma Beta/ }
}

{
  package Test::FakeReleaseEmptyDeps;
  sub new { bless {}, shift }
  sub distribution { return "Fake-Empty" }
  sub version { return "1.1" }
  sub checksum_sha256 {
    return "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
  }
  sub download_url {
    return "https://cpan.metacpan.org/authors/id/F/FO/FOO/Fake-Empty-1.1.tar.gz";
  }
  sub build_inputs { return () }
  sub propagated_build_inputs { return () }
}

$moose->update_from_metacpan(Test::FakeRelease->new());

is($moose->version, "9.99", "update_from_metacpan sets version");
is($moose->get_attr("url"),
   "mirror://cpan/authors/id/F/FO/FOO/Foo-Bar-9.99.tar.gz",
   "update_from_metacpan normalizes cpan URL");
is($moose->get_attr("hash"),
   "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=",
   "update_from_metacpan converts hex hash to SRI");
is_deeply([$moose->build_inputs], [qw/Alpha Zeta/],
          "update_from_metacpan sets buildInputs from MetaCPAN");
is_deeply([$moose->propagated_build_inputs], [qw/Beta Gamma/],
          "update_from_metacpan sets propagatedBuildInputs from MetaCPAN");

$moose->set_build_inputs(qw/pkgs.openssl OldPerlDep/);
$moose->set_propagated_build_inputs(qw/pkgs.zlib AnotherOldDep/);
$moose->update_from_metacpan(Test::FakeRelease->new());
is_deeply([$moose->build_inputs], [qw/Alpha Zeta pkgs.openssl/],
          "update_from_metacpan preserves pkgs.* buildInputs");
is_deeply([$moose->propagated_build_inputs], [qw/Beta Gamma pkgs.zlib/],
          "update_from_metacpan preserves pkgs.* propagatedBuildInputs");

my $platform_drv = Nix::PerlPackages::Drv->new(
  prepart   => "  PlatformPkg = buildPerlPackage ",
  attrname  => "PlatformPkg",
  build_fun => "Package",
  part      => <<'NIX'
{
    name = "Platform-Pkg";
    version = "1.0";
    url = "mirror://cpan/authors/id/P/PL/PLAT/Platform-Pkg-1.0.tar.gz";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    buildInputs = lib.optional stdenv.isDarwin pkgs.darwin.apple_sdk.frameworks.Carbon;
    propagatedBuildInputs = [ Existing ];
  }
NIX
);

$platform_drv->update_from_metacpan(Test::FakeRelease->new());
like($platform_drv->part,
     qr/buildInputs\s*=\s*lib\.optional stdenv\.isDarwin pkgs\.darwin\.apple_sdk\.frameworks\.Carbon;/,
     "update_from_metacpan does not rewrite platform-conditional buildInputs");
is_deeply([$platform_drv->propagated_build_inputs], [qw/Beta Gamma/],
          "update_from_metacpan still rewrites simple propagatedBuildInputs");

my $no_build_inputs_drv = Nix::PerlPackages::Drv->new(
  prepart   => "  NoBuildInputs = buildPerlPackage ",
  attrname  => "NoBuildInputs",
  build_fun => "Package",
  part      => <<'NIX'
{
    name = "No-BuildInputs";
    version = "1.0";
    url = "mirror://cpan/authors/id/N/NO/NOB/No-BuildInputs-1.0.tar.gz";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    meta = {
      description = "x";
    };
  }
NIX
);
$no_build_inputs_drv->update_from_metacpan(Test::FakeRelease->new());
like($no_build_inputs_drv->part,
     qr/buildInputs\s*=\s*\[\s*Alpha Zeta\s*\];/s,
     "update_from_metacpan adds buildInputs when missing");
like($no_build_inputs_drv->part,
     qr/propagatedBuildInputs\s*=\s*\[\s*Beta Gamma\s*\];/s,
     "update_from_metacpan adds propagatedBuildInputs when missing");

my $no_deps_drv = Nix::PerlPackages::Drv->new(
  prepart   => "  NoDeps = buildPerlPackage ",
  attrname  => "NoDeps",
  build_fun => "Package",
  part      => <<'NIX'
{
    name = "No-Deps";
    version = "1.0";
    url = "mirror://cpan/authors/id/N/NO/NOD/No-Deps-1.0.tar.gz";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    meta = {
      description = "x";
    };
  }
NIX
);
$no_deps_drv->update_from_metacpan(Test::FakeReleaseEmptyDeps->new());
unlike($no_deps_drv->part, qr/buildInputs\s*=\s*\[\s*\]\s*;/s,
       "update_from_metacpan does not add empty buildInputs");
unlike($no_deps_drv->part, qr/propagatedBuildInputs\s*=\s*\[\s*\]\s*;/s,
       "update_from_metacpan does not add empty propagatedBuildInputs");


done_testing();
