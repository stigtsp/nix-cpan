package Nix::PerlPackages::Errata::Suggest;

use v5.38;
use strict;
use warnings;
use feature qw(signatures);
no warnings qw(experimental::signatures);
use Exporter qw(import);
use Module::CoreList;

our @EXPORT_OK = qw(parse_missing_modules suggest_from_log add_errata_entries);

# Extract the Perl modules a build complained it could not find. The canonical
# Perl error includes both the path form and an explicit module-name hint:
#   Can't locate Test/NoWarnings.pm in @INC (you may need to install the
#   Test::NoWarnings module) ...
# We prefer the hint; otherwise we reconstruct the module from the .pm path.
# Returns a de-duplicated, order-preserving list of module names.
sub parse_missing_modules ($log) {
  return () unless defined $log && length $log;
  my %seen;
  my @mods;
  for my $line (split /\n/, $log) {
    while ($line =~ /Can't locate (\S+?)\.pm in \@INC(?:\s*\(you may need to install the (\S+) module\))?/g) {
      my $module = $2 // do { my $p = $1; $p =~ s{/}{::}g; $p };
      next unless defined $module && length $module;
      push @mods, $module unless $seen{$module}++;
    }
  }
  return @mods;
}

# Turn a failing build log into errata-addition suggestions for $dist.
#
# Build-time failures (a module missing during configure/build/test) mean the
# module is needed to *build* the distribution, so suggestions target
# extraBuildDependencies. (Runtime-only needs cannot be observed from a build —
# the sufficiency/minimality asymmetry — so we never infer extraRuntime here.)
#
# Crucially, we only suggest *errata* for a missing module that MetaCPAN's
# metadata does NOT already declare for $dist. If metadata already declares it
# (in build/test/configure), the derivation's buildInputs are merely stale — the
# right fix is `update --deps_only` to regenerate from metadata, NOT a new errata
# entry (which would just become "redundant" in the audit). Such cases are
# returned under `stale` instead of `suggestions`.
#
# Returns {
#   suggestions => [ { bucket, dist, module, attr } ],  # metadata misses it
#   stale       => [ { dist, module, attr } ],          # metadata has it; regenerate
#   findings    => [ { type, module } ],                # core / unresolvable
# }
sub suggest_from_log ($mcc, $log, $dist) {
  my @missing = parse_missing_modules($log);
  my (@suggestions, @stale, @findings);

  # Baseline: the dist's build-phase attrs per metadata (without errata).
  my %meta_attrs;
  if (my $rel = $mcc->get_by(distribution => $dist)) {
    eval {
      %meta_attrs = map { $_->attrname => 1 }
                    $rel->dependency([qw(build test configure)])->@*;
      1;
    };
  }

  my %seen_attr;
  for my $module (@missing) {
    if (Module::CoreList::is_core($module)) {
      push @findings, { type => "core_module", module => $module };
      next;
    }
    my $rel = $mcc->resolve_module($module) || $mcc->get_by(distribution => $module);
    unless ($rel) {
      push @findings, { type => "unresolvable_module", module => $module };
      next;
    }
    my $attr = $rel->attrname;
    next if $seen_attr{$attr}++;

    if ($meta_attrs{$attr}) {
      push @stale, { dist => $dist, module => $module, attr => $attr };
      next;
    }
    push @suggestions, {
      bucket => "extraBuildDependencies",
      dist   => $dist,
      module => $module,
      attr   => $attr,
    };
  }
  return { suggestions => \@suggestions, stale => \@stale, findings => \@findings };
}

# Add `- Module` entries under bucket/dist keys in Errata.yaml, preserving
# comments and layout. Inserts into an existing dist block (after its last item),
# or creates the dist block (at the end of an existing bucket), or appends a new
# bucket at end of file. Skips entries already present. Returns count added.
sub add_errata_entries ($file, $entries) {
  open my $fh, "<", $file or die "Cannot read $file: $!";
  local $/ = "\n";   # read line-by-line regardless of the caller's $/
  my @lines = <$fh>;
  close $fh;
  # Guarantee the last line is newline-terminated so a splice can't concatenate
  # a new entry onto it (`    - Helper    - NewMod`).
  $lines[-1] .= "\n" if @lines && $lines[-1] !~ /\n\z/;

  my $added = 0;
  for my $e (@$entries) {
    my ($bucket, $dist, $module) = @{$e}{qw(bucket dist module)};
    next unless defined $bucket && defined $dist && defined $module;

    my ($b_start, $b_end) = _bucket_span(\@lines, $bucket);
    if (!defined $b_start) {
      # Append a new bucket at EOF.
      push @lines, "\n" unless @lines && $lines[-1] =~ /\n\z/;
      push @lines, "$bucket:\n", "  $dist:\n", "    - $module\n";
      $added++;
      next;
    }

    my ($d_start, $d_end) = _dist_span(\@lines, $b_start, $b_end, $dist);
    if (!defined $d_start) {
      # Insert a new dist block at the end of the bucket.
      splice @lines, $b_end + 1, 0, "  $dist:\n", "    - $module\n";
      $added++;
      next;
    }

    # Skip if already present in the dist block.
    my $present = 0;
    for my $i ($d_start .. $d_end) {
      if ($lines[$i] =~ /^\s{4}-\s*\Q$module\E\s*$/) { $present = 1; last; }
    }
    next if $present;

    splice @lines, $d_end + 1, 0, "    - $module\n";
    $added++;
  }

  open my $wh, ">", $file or die "Cannot write $file: $!";
  print {$wh} @lines;
  close $wh;
  return $added;
}

# [start,end] line indices of a top-level "bucket:" block (the key line through
# its last child line), or () if absent.
sub _bucket_span ($lines, $bucket) {
  my $start;
  for (my $i = 0; $i < @$lines; $i++) {
    if ($lines->[$i] =~ /^(\w+):\s*$/ && $1 eq $bucket) { $start = $i; last; }
  }
  return () unless defined $start;
  my $end = $start;
  for (my $j = $start + 1; $j < @$lines; $j++) {
    last if $lines->[$j] =~ /^\w/;       # next top-level key
    $end = $j;
  }
  return ($start, $end);
}

# [start,end] line indices of a "  Dist:" block within a bucket span, or ().
sub _dist_span ($lines, $b_start, $b_end, $dist) {
  my $start;
  for my $i ($b_start + 1 .. $b_end) {
    if ($lines->[$i] =~ /^\s{2}(\S[^:]*):\s*$/ && $1 eq $dist) { $start = $i; last; }
  }
  return () unless defined $start;
  my $end = $start;
  for (my $j = $start + 1; $j <= $b_end; $j++) {
    last if $lines->[$j] =~ /^\s{0,2}\S/;   # next dist key or bucket end
    $end = $j;
  }
  # Back up past any trailing blank lines / comments so a new `- Module` is
  # spliced right after the last actual item, not after a dangling blank/comment.
  my $last_item = $start;
  for my $i ($start + 1 .. $end) {
    $last_item = $i if $lines->[$i] =~ /^\s{4}-/;
  }
  $end = $last_item;
  return ($start, $end);
}

1;
