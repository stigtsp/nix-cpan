use v5.38;
use Test::More;
use File::Temp qw(tempdir);

use_ok("Nix::MetaCPANCache");
use_ok("Nix::PerlPackages::Errata::Audit");
Nix::PerlPackages::Errata::Audit->import(qw(classify_extra_dependencies commented_dist_blocks));

my $tmpdir = tempdir(CLEANUP => 1);
my $mcc = Nix::MetaCPANCache->new(
  cache_file => "$tmpdir/dl.jsonl.gz",
  db_file    => "$tmpdir/cache.db",
);

my $sha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
sub rel ($name, $dist, $mod, $deps = []) {
  return {
    name => $name, distribution => $dist, main_module => $mod,
    version => "1.0", version_numified => 1, checksum_sha256 => $sha,
    download_url => "https://cpan.metacpan.org/authors/id/X/XX/XXX/$name.tar.gz",
    dependency => $deps, provides => { $mod => { file => "lib.pm" } },
  };
}

# WidgetCore already declares Helper as a runtime dep -> errata entry redundant.
# Lonely declares nothing -> errata entry is load-bearing.
my $releases = [
  rel("Helper-1.0", "Helper", "Helper"),
  rel("WidgetCore-1.0", "WidgetCore", "WidgetCore",
      [ { module => "Helper", relationship => "requires", phase => "runtime", version => "0" } ]),
  rel("Lonely-1.0", "Lonely", "Lonely"),
];
$mcc->write_releases($releases);

my $cfg = {
  extraRuntimeDependencies => {
    WidgetCore => [ "Helper" ],   # redundant (metadata declares it)
    Lonely     => [ "Helper" ],   # load-bearing (metadata does not)
  },
};

my $res = classify_extra_dependencies($mcc, $cfg);
my $b = $res->{buckets}{extraRuntimeDependencies};

is(scalar $b->{redundant}->@*, 1, "one redundant entry detected");
is($b->{redundant}[0]{dist}, "WidgetCore", "WidgetCore:Helper is redundant");
is(scalar $b->{load_bearing}->@*, 1, "one load-bearing entry detected");
is($b->{load_bearing}[0]{dist}, "Lonely", "Lonely:Helper is load-bearing");
is(scalar $res->{findings}->@*, 0, "no findings for resolvable fixture");

# commented_dist_blocks: a comment marks a block as a deliberate hedge.
my $yaml = "$tmpdir/Errata.yaml";
open my $fh, ">", $yaml or die $!;
print {$fh} <<'YAML';
extraRuntimeDependencies:
  WidgetCore:
    # deliberate hedge against snapshot flakiness
    - Helper
  Lonely:
    - Helper
YAML
close $fh;

my $commented = commented_dist_blocks($yaml);
ok($commented->{extraRuntimeDependencies}{WidgetCore}, "commented block detected as hedge");
ok(!$commented->{extraRuntimeDependencies}{Lonely}, "uncommented block not a hedge");

done_testing();
