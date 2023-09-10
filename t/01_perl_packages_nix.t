use v5.38;
use Test::More;
use Data::Dumper;

use_ok("Nix::PerlPackages");

my $perlPackages = new_ok( "Nix::PerlPackages" => [ nix_file => 't/var/perl-packages.nix'],
                           "Nix::PerlPackages" );

$perlPackages->parse_nix_file();

is(scalar $perlPackages->drvs, 1831); # XXX: TermReadKey doesn't parse

my $moose = $perlPackages->drv_by_attrname("Moose");

isa_ok($moose, "Nix::PerlDrv");

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
           "Moose has expected propagatedBuildInputs");

isnt($moose->dirty, !!1, "Moose is not dirty, no changes have happened yet");

$moose->set_attr("url","https://nixos.org");

is( $moose->get_attr("url"), "https://nixos.org", "Moose had it's url changed" );

is( $moose->dirty, !!1, "Moose is dirty!" );

done_testing();
