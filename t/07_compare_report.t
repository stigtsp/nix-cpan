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
ok(!$res->{ok}, "compare --report fails fast on unresolved dependencies in strict mode");

my $diag = ($res->{out} // q{}) . "\n" . ($res->{err} // q{});
like($diag, qr/Cannot resolve dependency module/,
     "strict mode reports unresolved dependency module");
like($diag, qr/Errata\.yaml ignoreModule/,
     "strict mode points to explicit exception mechanism");

done_testing();
