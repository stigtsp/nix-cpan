use v5.38;
use Test::More;
use File::Temp qw(tempdir);

use_ok("Nix::PerlPackages::Errata::Suggest");
use_ok("Nix::MetaCPANCache");
Nix::PerlPackages::Errata::Suggest->import(qw(parse_missing_modules suggest_from_log add_errata_entries));

# --- parse_missing_modules: real fixture + synthetic forms ---
my $fixture = "t/var/build-fail-missing-dep.log";
if (-f $fixture) {
  open my $fh, "<", $fixture or die $!;
  local $/; my $log = <$fh>; close $fh;
  my @m = parse_missing_modules($log);
  is_deeply(\@m, ["Test::NoWarnings"], "parses module from real nix-build failure log (hint form)");
}

my $log2 = "blah\nCan't locate Foo/Bar.pm in \@INC (you may need to install the Foo::Bar module) at x line 1.\n";
is_deeply([parse_missing_modules($log2)], ["Foo::Bar"], "hint form");

my $log3 = "Can't locate Acme/Widget.pm in \@INC at t/x.t line 2.\n"; # no hint -> path reconstruction
is_deeply([parse_missing_modules($log3)], ["Acme::Widget"], "path-reconstruction fallback");

my $log4 = "Can't locate A/B.pm in \@INC (...)\nCan't locate A/B.pm in \@INC (...)\n";
is_deeply([parse_missing_modules($log4)], ["A::B"], "de-duplicates");

is_deeply([parse_missing_modules("all good, tests passed")], [], "no false positives");

# --- suggest_from_log: errata candidate vs stale-derivation (mock cache) ---
{
  my $td = tempdir(CLEANUP => 1);
  my $mcc = Nix::MetaCPANCache->new(
    cache_file => "$td/dl.jsonl.gz", db_file => "$td/cache.db");
  my $sha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
  my sub rel ($name,$dist,$mod,$deps=[]) {
    +{ name=>$name, distribution=>$dist, main_module=>$mod, version=>"1.0",
       version_numified=>1, checksum_sha256=>$sha,
       download_url=>"https://cpan.metacpan.org/authors/id/X/XX/XXX/$name.tar.gz",
       dependency=>$deps, provides=>{ $mod => { file=>"x.pm" } } };
  }
  $mcc->write_releases([
    rel("TestHelper-1.0","TestHelper","Test::Helper"),
    # WidgetA already declares Test::Helper in metadata (test phase) -> stale, not errata
    rel("WidgetA-1.0","WidgetA","WidgetA",
        [ { module=>"Test::Helper", relationship=>"requires", phase=>"test", version=>"0" } ]),
    # WidgetB does NOT declare it -> genuine errata candidate
    rel("WidgetB-1.0","WidgetB","WidgetB"),
  ]);

  my $log = "Can't locate Test/Helper.pm in \@INC (you may need to install the Test::Helper module) at t/x.t line 1.\n";

  my $ra = suggest_from_log($mcc, $log, "WidgetA");
  is(scalar $ra->{suggestions}->@*, 0, "WidgetA: no errata suggested (metadata has it)");
  is(scalar $ra->{stale}->@*, 1, "WidgetA: classified as stale (regenerate via deps_only)");
  is($ra->{stale}[0]{attr}, "TestHelper", "stale attr resolved");

  my $rb = suggest_from_log($mcc, $log, "WidgetB");
  is(scalar $rb->{suggestions}->@*, 1, "WidgetB: errata suggested (metadata misses it)");
  is($rb->{suggestions}[0]{bucket}, "extraBuildDependencies", "errata targets build bucket");
  is($rb->{suggestions}[0]{attr}, "TestHelper", "errata attr resolved");
  is(scalar $rb->{stale}->@*, 0, "WidgetB: nothing stale");
}

# --- add_errata_entries: surgical YAML insertion ---
my $tmp = tempdir(CLEANUP => 1);
my $yaml = "$tmp/Errata.yaml";
open my $wh, ">", $yaml or die $!;
print {$wh} <<'YAML';
extraBuildDependencies:
  Archive-Zip:
    - Test::MockModule
  Zebra-Dist:
    - Test::More
extraRuntimeDependencies:
  Some-Dist:
    - Helper
YAML
close $wh;

# 1) add to existing dist block, 2) new dist in existing bucket,
# 3) duplicate (skip), 4) brand-new bucket
my $added = add_errata_entries($yaml, [
  { bucket => "extraBuildDependencies", dist => "Archive-Zip", module => "Test::Deep" },
  { bucket => "extraBuildDependencies", dist => "New-Dist",    module => "Test::Fatal" },
  { bucket => "extraBuildDependencies", dist => "Archive-Zip", module => "Test::MockModule" }, # dup
  { bucket => "buildFunctionOverrides", dist => "Whatever",    module => "Module" },
]);
is($added, 3, "added 3 (duplicate skipped)");

open my $rh, "<", $yaml or die $!; local $/; my $out = <$rh>; close $rh;

like($out, qr/  Archive-Zip:\n    - Test::MockModule\n    - Test::Deep\n/,
     "appended to existing dist block");
like($out, qr/extraBuildDependencies:.*\n(?:.*\n)*?  New-Dist:\n    - Test::Fatal\n/,
     "created new dist block in existing bucket");
my $count_mockmodule = () = ($out =~ /- Test::MockModule/g);
is($count_mockmodule, 1, "duplicate not added twice");
like($out, qr/buildFunctionOverrides:\n  Whatever:\n    - Module\n/, "created brand-new bucket at EOF");
# existing content preserved
like($out, qr/extraRuntimeDependencies:\n  Some-Dist:\n    - Helper\n/, "unrelated bucket preserved");

done_testing();
