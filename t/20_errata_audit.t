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

# --- buildFunctionOverrides + ignoreModule classifiers (own mock cache) ---
Nix::PerlPackages::Errata::Audit->import(
  qw(classify_build_function_overrides classify_ignore_modules));
{
  my $td2 = tempdir(CLEANUP => 1);
  my $m2 = Nix::MetaCPANCache->new(
    cache_file => "$td2/dl.jsonl.gz", db_file => "$td2/cache.db");
  my $sha2 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
  my sub rel2 ($name,$dist,$mod,%extra) {
    +{ name=>$name, distribution=>$dist, main_module=>$mod, version=>"1.0",
       version_numified=>1, checksum_sha256=>$sha2,
       download_url=>"https://cpan.metacpan.org/authors/id/X/XX/XXX/$name.tar.gz",
       dependency=>[], provides=>{ $mod => { file=>"x.pm" } }, %extra };
  }
  $m2->write_releases([
    # metadata configure-requires Module::Build -> build_fun_from_metadata = Module
    rel2("ModBuilt-1.0","ModBuilt","ModBuilt",
         metadata => { prereqs => { configure => { requires => { "Module::Build" => "0" } } } }),
    # no metadata -> build_fun_from_metadata = undef
    rel2("Undecided-1.0","Undecided","Undecided"),
    # a resolvable module for the ignore test
    rel2("Excludable-1.0","Excludable","Excludable"),
  ]);

  my $cfg2 = {
    buildFunctionOverrides => {
      ModBuilt  => "Module",   # metadata already yields Module -> redundant
      Undecided => "Module",   # metadata undecided -> load-bearing
    },
    ignoreModule => [
      "Carp",          # core -> redundant (core filter catches it)
      "Excludable",    # resolves -> load-bearing (excludes a real dep)
      "No::Such::Mod", # unresolvable -> load-bearing (prevents die)
    ],
  };

  my $bfo = classify_build_function_overrides($m2, $cfg2);
  is_deeply([map { $_->{dist} } $bfo->{redundant}->@*], ["ModBuilt"],
            "buildFunctionOverrides: metadata-agreeing override is redundant");
  is_deeply([map { $_->{dist} } $bfo->{load_bearing}->@*], ["Undecided"],
            "buildFunctionOverrides: metadata-undecided override is load-bearing");

  my $ign = classify_ignore_modules($m2, $cfg2);
  is_deeply([map { $_->{module} } $ign->{redundant}->@*], ["Carp"],
            "ignoreModule: core module is redundant");
  my %lb = map { $_->{module} => $_->{class} } $ign->{load_bearing}->@*;
  is($lb{"Excludable"}, "excludes resolvable dep", "ignoreModule: resolvable is load-bearing");
  is($lb{"No::Such::Mod"}, "prevents unresolvable-die", "ignoreModule: unresolvable is load-bearing");
}

done_testing();
