use v5.38;
use Test::More;
use File::Temp qw(tempdir);

use_ok("Nix::PerlPackages");

my $tmpdir = tempdir(CLEANUP => 1);
my $nix_file = "$tmpdir/perl-packages-mini.nix";

open my $fh, ">", $nix_file or die $!;
print {$fh} <<'NIX';
{
  Foo = buildPerlPackage {
    name = "Same-1.0";
    url = "mirror://cpan/authors/id/S/SA/SAME/Same-1.0.tar.gz";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    buildInputs = [  ];
    propagatedBuildInputs = [  ];
  };
  Bar = buildPerlPackage {
    name = "Same-1.0";
    url = "mirror://cpan/authors/id/S/SA/SAME/Same-1.0.tar.gz";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    buildInputs = [  ];
    propagatedBuildInputs = [  ];
  };
}
NIX
close $fh;

my $pp = new_ok("Nix::PerlPackages" => [nix_file => $nix_file], "Nix::PerlPackages");

my $foo = $pp->drv_by_attrname("Foo");
ok($foo, "found Foo derivation");
$foo->set_attr("url", "mirror://cpan/authors/id/S/SA/SAME/Same-1.1.tar.gz");

my $ok = eval { $pp->update_inplace($foo); 1 };
ok(!$ok, "update_inplace fails when part is not uniquely identifiable");
like($@, qr/expected exactly one match/, "update_inplace emits useful uniqueness error");

done_testing();
