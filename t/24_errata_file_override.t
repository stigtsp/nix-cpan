use v5.38;
use Test::More;
use File::Temp qw(tempdir);

use_ok("Nix::PerlPackages::Errata");

my $dir = tempdir(CLEANUP => 1);
my $custom = "$dir/custom-errata.yaml";
open my $fh, ">", $custom or die $!;
print {$fh} <<'YAML';
extraBuildDependencies:
  MyDist:
    - Some::Module
ignoreModule:
  - Foo::Bar
YAML
close $fh;

# Default: the bundled file.
like(Nix::PerlPackages::Errata::errata_file(), qr{lib/Nix/PerlPackages/Errata\.yaml$},
     "default errata_file is the bundled one");

# NIX_CPAN_ERRATA_FILE env var overrides the default.
{
  local $ENV{NIX_CPAN_ERRATA_FILE} = $custom;
  Nix::PerlPackages::Errata::set_errata_file(undef); # no explicit override -> env wins
  is(Nix::PerlPackages::Errata::errata_file(), $custom, "env var overrides default path");
}

# Explicit set_errata_file (what --errata-file uses) overrides everything and
# makes errata() load from that path.
Nix::PerlPackages::Errata::set_errata_file($custom);
is(Nix::PerlPackages::Errata::errata_file(), $custom, "set_errata_file overrides path");

my $cfg = Nix::PerlPackages::Errata::errata();
is_deeply($cfg->{extraBuildDependencies}{MyDist}, ["Some::Module"],
          "errata() loads extraBuildDependencies from the override file");
is_deeply($cfg->{ignoreModule}, ["Foo::Bar"],
          "errata() loads ignoreModule from the override file");

# Clearing the override returns to the default (singleton reloads).
Nix::PerlPackages::Errata::set_errata_file(undef);
like(Nix::PerlPackages::Errata::errata_file(), qr{Errata\.yaml$},
     "clearing the override returns to the bundled default");

done_testing();
