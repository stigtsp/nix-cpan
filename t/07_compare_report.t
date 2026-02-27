use v5.38;
use Test::More;
use File::Temp qw(tempdir);
use lib qw(t/lib);
use Test::CommandUtil qw(run_nix_cpan);

use_ok("Nix::MetaCPANCache");

my $tmpdir = tempdir(CLEANUP => 1);
my $cache_dir = "$tmpdir/nix-cpan";
mkdir $cache_dir or die $!;

my $db_file = "$cache_dir/metacpan-cache.db";
my $cache_file = 't/var/metacpan-download-cache.jsonl.gz';

my $mcc = new_ok(
  "Nix::MetaCPANCache" => [ cache_file => $cache_file, db_file => $db_file ],
  "Nix::MetaCPANCache"
);
my $releases = $mcc->cached_download_releases();
$mcc->write_releases($releases);
$mcc->write_dependencies();

my $res = run_nix_cpan(
  $tmpdir,
  {},
  "compare",
  "--report",
  "--report_missing",
  "--nix-file",
  "t/var/perl-packages.nix",
);
ok($res->{ok}, "compare --report command succeeds");
ok(!defined($res->{err}) || $res->{err} eq "", "compare --report has no stderr");

my $out = $res->{out};
like($out, qr/Updates:\s+\d+\s+total/, "report prints total update count");
like($out, qr/safe\s+\(dep changes = 0\):\s+\d+/, "report prints safe bucket count");
like($out, qr/moderate\s+\(dep changes 1-6\):\s+\d+/, "report prints moderate bucket count");
like($out, qr/high\s+\(dep changes >=7\):\s+\d+/, "report prints high bucket count");
like($out, qr/High priority updates:/, "report includes high-priority section");
like($out, qr/Moderate priority updates:/, "report includes moderate-priority section");
like($out, qr/Safe priority updates:/, "report includes safe-priority section");
like($out, qr/Missing dependencies not present in nix_file:\s+\d+/,
     "report_missing prints missing-dependency summary");
unlike($out, qr/\(UPDATE\)/, "report mode suppresses line-by-line compare output");

done_testing();
