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
    pname = "Foo";
    version = "1.0";
    postPatch = ''
      echo "this has braces { and }"
      echo 'qr/CHI stats: {' 'qr/CHI stats: \{'
    '';
    # comment with brace {
    /* block comment with } */
  };

  AliasAfter = self.Foo;
}
NIX
close $fh;

{
  local $ENV{NIX_CPAN_LEGACY_PARSER} = 1;
  my $legacy = Nix::PerlPackages->new(nix_file => $nix_file);
  my %a = map { $_ => 1 } $legacy->all_attrnames;
  ok(!$a{AliasAfter}, "legacy parser still available and demonstrates old depth drift behavior");
}

{
  local $ENV{NIX_CPAN_LEGACY_PARSER} = 0;
  my $proper = Nix::PerlPackages->new(nix_file => $nix_file);
  my %a = map { $_ => 1 } $proper->all_attrnames;
  ok($a{AliasAfter}, "proper parser captures attrs after braces in strings/comments");
}

{
  my $pp = Nix::PerlPackages->new(nix_file => $nix_file);
  $pp->parse_nix_file_legacy();
  my %a = map { $_ => 1 } $pp->all_attrnames;
  ok(!$a{AliasAfter}, "can explicitly run legacy parser method");

  $pp->parse_nix_file_proper();
  %a = map { $_ => 1 } $pp->all_attrnames;
  ok($a{AliasAfter}, "can explicitly run proper parser method");
}

done_testing();
