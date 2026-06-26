package Nix::PerlPackages::Errata::Audit;

use v5.38;
use strict;
use warnings;
use feature qw(signatures);
no warnings qw(experimental::signatures);
use Exporter qw(import);

our @EXPORT_OK = qw(classify_extra_dependencies commented_dist_blocks);

# Buckets that inject extra dependency attrs, and the dependency() phases each
# one maps to in the generated derivation:
#   extraBuildDependencies   -> buildInputs            (build/test/configure)
#   extraRuntimeDependencies -> propagatedBuildInputs  (runtime)
my %BUCKET_PHASES = (
  extraBuildDependencies   => [qw(build test configure)],
  extraRuntimeDependencies => [qw(runtime)],
);

# Classify every extra-dependency errata entry against the live MetaCPAN cache.
#
# An entry (dist => module) in a bucket is PROVABLY REDUNDANT iff the module's
# resolved attr is already present in dist's dependency()-derived attrs for that
# bucket's phases. Removing such an entry cannot change build_inputs() /
# propagated_build_inputs() output (those are dependency-attrs + errata-extras,
# deduped), so it is safe to prune with no rebuild.
#
# Returns:
# {
#   buckets => {
#     <bucket> => {
#       redundant    => [ { dist, module, attr } ... ],   # safe to prune
#       load_bearing => [ { dist, module, attr } ... ],   # changes output if removed
#       total        => N,
#     }, ...
#   },
#   findings => [ { type, dist, module? } ... ],  # rot the audit surfaces
# }
sub classify_extra_dependencies ($mcc, $cfg) {
  my %buckets;
  my @findings;

  for my $bucket (sort keys %BUCKET_PHASES) {
    my $map = $cfg->{$bucket};
    next unless $map && ref($map) eq "HASH";
    my $phases = $BUCKET_PHASES{$bucket};
    my $b = $buckets{$bucket} = { redundant => [], load_bearing => [], total => 0 };

    for my $dist (sort keys %$map) {
      my $mods = $map->{$dist};
      next unless $mods && ref($mods) eq "ARRAY";

      my $rel = $mcc->get_by(distribution => $dist);
      unless ($rel) {
        push @findings, { type => "dist_not_in_cache", dist => $dist };
        $b->{total} += scalar @$mods;
        next;
      }

      # Baseline = without-errata bucket attrs. dependency() can die on an
      # unresolvable module; that is itself rot worth surfacing, not a crash.
      my %raw;
      my $ok = eval {
        %raw = map { $_->attrname => 1 } $rel->dependency($phases)->@*;
        1;
      };
      unless ($ok) {
        my $err = $@;
        $err =~ s/\s+at .*$//s;
        push @findings, { type => "deps_unresolvable", dist => $dist, error => $err };
        $b->{total} += scalar @$mods;
        next;
      }

      for my $module (@$mods) {
        next unless defined $module && length $module;
        $b->{total}++;
        my $erel = $mcc->resolve_module($module)
                || $mcc->get_by(distribution => $module);
        unless ($erel) {
          push @findings, { type => "errata_module_unresolvable", dist => $dist, module => $module };
          next;
        }
        my $attr = $erel->attrname;
        my $rec = { dist => $dist, module => $module, attr => $attr };
        if ($raw{$attr}) {
          push @{ $b->{redundant} }, $rec;
        } else {
          push @{ $b->{load_bearing} }, $rec;
        }
      }
    }
  }

  return { buckets => \%buckets, findings => \@findings };
}

# Scan the raw Errata.yaml text and return which distribution blocks carry a
# comment. A comment signals deliberate intent (e.g. a hedge against MetaCPAN
# snapshot unreliability — "MetaCPAN can miss module->distribution mapping ...");
# such entries must NOT be auto-pruned even when currently redundant.
# Returns { bucket => { dist => 1 } }.
sub commented_dist_blocks ($file) {
  open my $fh, "<", $file or die "Cannot read $file: $!";
  my @lines = <$fh>;
  close $fh;

  my %commented;
  my $cur_bucket = q{};
  my $i = 0;
  while ($i < @lines) {
    my $line = $lines[$i];
    if ($line =~ /^(\w+):\s*$/) { $cur_bucket = $1; $i++; next; }
    if ($line =~ /^\s{2}(\S[^:]*):\s*$/) {
      my $dist = $1;
      my $j = $i + 1;
      my $has_comment = 0;
      while ($j < @lines && $lines[$j] !~ /^\s{0,2}\S/) {
        $has_comment = 1 if $lines[$j] =~ /^\s*#/;
        $j++;
      }
      $commented{$cur_bucket}{$dist} = 1 if $has_comment;
      $i = $j;
      next;
    }
    $i++;
  }
  return \%commented;
}

1;
