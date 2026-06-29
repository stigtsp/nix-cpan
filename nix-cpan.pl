#!/usr/bin/env perl


use v5.38;
use Applify;

use strict;
use warnings;
use Array::Diff;
use Log::Log4perl qw(:easy);
use File::Basename;
use Perl6::Junction qw(any);
use lib qw(lib);
use Cpanel::JSON::XS qw(encode_json);
use CPAN::Meta::YAML ();
use Nix::PerlPackages;
use Nix::MetaCPANCache;
use Nix::PerlPackages::Errata qw(errata);
use Nix::PerlPackages::Errata::Audit qw(
  classify_extra_dependencies
  classify_build_function_overrides
  classify_ignore_modules
  commented_dist_blocks
);
use Nix::PerlPackages::Errata::Suggest qw(suggest_from_log add_errata_entries parse_missing_modules);
use Nix::Util qw(sha256_hex_to_sri render_license);
use Text::Diff ();
use IPC::Cmd qw(run);

use experimental qw(signatures try);

our $VERSION = 0.2;

option bool    => "debug"          => "Output debug information" => 0;
option bool    => "verbose"        => "Show changes and determinations being made" => 0;
option file    => "nix_file"       => "Path to perl-packages.nix" => "pkgs/top-level/perl-packages.nix";
option file    => "errata_file"    => "Path to Errata.yaml (default: the bundled one; use a writable copy to prune/add when running from the nix store)" => undef;

#option string => "db_file"        => "Path to store DB cache";
#option string => "download_cache" => "Path to store responses from MetaCPAN API";

subcommand compare => "Compare perl-packages.nix against MetaCPANCache" => sub {
  option bool => "all" => "Show all packages, even if no op";
  option bool => "report" => "Show prioritized update buckets (safe/moderate/high)";
  option bool => "report_missing" => "Show missing dependencies needed by update candidates";
};

subcommand refresh => "Update MetaCPAN cache" => sub {
};

subcommand update => "Update one or more perlPackage derivations" => sub {
  option bool => "inplace" => "Write changes to nix_file" => 0;
  option bool => "commit"  => "Commit changes" => 0;
  option bool => "diff"    => "Print unified diff for updated derivations" => 0;
  option bool => "missing" => "Also add missing dependency stanzas for updated attrs" => 0;
  option bool => "deps_only" => "Only refresh dependency lists; do not bump version/url/hash" => 0;
};

subcommand generate_missing => "Generate missing dependency stanzas for update candidates" => sub {
  option bool => "inplace" => "Append generated stanzas into nix_file" => 0;
  option file => "out" => "Output file for generated stanzas (used unless --inplace)" => "missing-perl-packages.nix";
};

subcommand errata => "Audit errata extra-dependencies against the MetaCPAN cache" => sub {
  option bool => "prune" => "Remove provably-redundant extra-dependency entries from Errata.yaml" => 0;
};

subcommand diagnose => "Build a derivation and suggest errata for missing build deps" => sub {
  option bool => "apply" => "Write suggested errata additions into Errata.yaml" => 0;
  option file => "log"   => "Parse an existing build log instead of building" => undef;
};

subcommand auto => "Automated build-gated updater: bump, verify, commit per package" => sub {
  option string => "risk"   => "Which candidates: safe (no dep change) | moderate (<=6) | all" => "safe";
  option int    => "max"    => "Limit number of packages processed (0 = no limit)" => 0;
  option bool   => "commit" => "Commit verified bumps (omit for dry-run: verify then revert)" => 0;
  option bool   => "fast"   => "Verify hash via .src only; skip the full build (rely on downstream)" => 0;
  option file   => "report_file" => "Write a machine-readable YAML report to this path" => undef;
};



sub init_logging {
    my $app = shift;
    Log::Log4perl->easy_init({
            level =>  ($app->debug ? $DEBUG : ($app->verbose ? $INFO : undef)),
            layout => '%X{distro}%m%n'
          });
    Log::Log4perl::MDC->put('distro', q{});

    # Point the (lazily-loaded) errata singleton at a user-supplied file before
    # anything reads it. Every command calls init_logging first, so this runs
    # before the first errata() access.
    if (defined $app->errata_file && length $app->errata_file) {
      Nix::PerlPackages::Errata::set_errata_file($app->errata_file);
    }
}

sub command_refresh ($app) {
  $app->init_logging;

  my $mcc = Nix::MetaCPANCache->new;
  $mcc->clear_caches();

  INFO("Downloading and indexing, this takes some time ...");
  $mcc->refresh();
  return 0;
}

sub command_compare ($app, @args) {
  $app->init_logging;
  my $metacpan = Nix::MetaCPANCache->new;
  die "MetaCPAN cache does not exist, download it with:\n    $0 refresh\n\n"
    unless $metacpan->db_file_exists;

  my $pp = Nix::PerlPackages->new( nix_file => $app->nix_file );
  my %existing_attrs = map { $_ => 1 } $pp->all_attrnames;
  my %existing_attrs_lc = map { lc($_) => 1 } keys %existing_attrs;

  my @drvs = $pp->drvs;
  if (@args) {
    @drvs = grep { $_->attrname eq any(@args) } @drvs;
  }
  my @updates;
  my %missing;
  foreach my $drv (@drvs) {
    my $name = $drv->distribution_name;
    unless ($drv->version) {
      WARN("$name has no version");
      next;
    }
    my $mc = $metacpan->get_by(distribution => $name);
    unless ($mc) {
      WARN("Cannot find $name in MetaCPAN");
      next;
    }
    my $state = "NA";
    if ($mc->newer_than($drv->version)) {
      $state = "UPDATE";
    }

    unless ($app->all) {
      next if $state eq "NA";
    }


    my $depDiff = "";
    my $depDelta = 0;
    for my $k (qw(build_inputs propagated_build_inputs)) {
      my @cur =
        grep { ! /^pkgs\./} # skip deps with pkgs. prefix as they are not from perlPackages
        $drv->$k;
      my @new = $mc->$k;
      my $diff = Array::Diff->diff(\@cur, \@new);
      if ($diff->count) {
        my @adds = map { "+".$_ } grep { $_ } @{$diff->added};
        my @dels = map { "-".$_ } grep { $_ } @{$diff->deleted};
        $depDelta += scalar(@adds) + scalar(@dels);
        $depDiff .= encode_json([ @adds, @dels ]);
      }
    }

    if ($state eq "UPDATE") {
      foreach my $dep (
        $mc->dependency([qw(build test configure)])->@*,
        $mc->dependency([qw(runtime)])->@*
      ) {
        my $dep_attr = $dep->attrname;
        next if $existing_attrs{$dep_attr};
        next if $existing_attrs_lc{lc($dep_attr)};
        my $h = $missing{$dep_attr} //= {
          distribution => $dep->distribution,
          required_by  => {},
        };
        $h->{required_by}->{ $drv->attrname } = 1;
      }

      push @updates, {
        attrname  => $drv->attrname,
        name      => $name,
        old_ver   => $drv->version,
        new_ver   => $mc->version,
        dep_delta => $depDelta,
        dep_diff  => $depDiff,
      };
    }

    unless ($app->report) {
      printf("%-40s %-40s %-10s %-10s (%s) %s\n",
             $drv->attrname, $name, $drv->version, $mc->version, $state, $depDiff);
    }

  }

  if ($app->report) {
    $app->print_compare_report(\@updates);
  }
  if ($app->report_missing) {
    $app->print_missing_report(\%missing);
  }
  return 0;
}

sub print_compare_report ($app, $updates) {
  my @safe = sort { $a->{attrname} cmp $b->{attrname} }
             grep { $_->{dep_delta} == 0 } @$updates;
  my @moderate = sort { $b->{dep_delta} <=> $a->{dep_delta} || $a->{attrname} cmp $b->{attrname} }
                 grep { $_->{dep_delta} >= 1 && $_->{dep_delta} <= 6 } @$updates;
  my @high = sort { $b->{dep_delta} <=> $a->{dep_delta} || $a->{attrname} cmp $b->{attrname} }
             grep { $_->{dep_delta} >= 7 } @$updates;

  printf("Updates: %d total\n", scalar(@$updates));
  printf("  safe     (dep changes = 0): %d\n", scalar(@safe));
  printf("  moderate (dep changes 1-6): %d\n", scalar(@moderate));
  printf("  high     (dep changes >=7): %d\n", scalar(@high));

  for my $group (
    [ "High", \@high ],
    [ "Moderate", \@moderate ],
    [ "Safe", \@safe ],
  ) {
    my ($name, $items) = @$group;
    say "";
    say "$name priority updates:";
    foreach my $u (@$items) {
      printf("  %-40s %10s -> %-10s dep=%d %s\n",
             $u->{attrname}, $u->{old_ver}, $u->{new_ver}, $u->{dep_delta}, $u->{dep_diff});
    }
  }
}

sub print_missing_report ($app, $missing) {
  my @attrs = sort keys %$missing;
  say "";
  printf("Missing dependencies not present in nix_file: %d\n", scalar(@attrs));
  foreach my $attr (@attrs) {
    my $h = $missing->{$attr};
    my @required_by = sort keys $h->{required_by}->%*;
    printf("  %-40s distro=%s required_by=[%s]\n",
           $attr, $h->{distribution}, join(", ", @required_by));
  }
}

sub scan_top_level_attrnames ($app) {
  my %attr;
  open my $fh, "<", $app->nix_file or die "Cannot read ".$app->nix_file.": $!";
  while (my $l = <$fh>) {
    if ($l =~ /^  ([\w-]+)\s*=/) {
      $attr{$1} = 1;
    }
  }
  close $fh;
  return %attr;
}

sub collect_missing_dependencies ($app, $metacpan, $pp, @attrs) {
  my %existing = map { $_ => 1 } $pp->all_attrnames;
  my %scanned = $app->scan_top_level_attrnames;
  @existing{keys %scanned} = values %scanned;
  # Also index by lowercase to catch case-insensitive duplicates
  # e.g. LWPProtocolHttps (canonical) vs LWPProtocolhttps (from distro_name_to_attr)
  my %existing_lc = map { lc($_) => 1 } keys %existing;
  my %seen_distribution;
  my %missing;
  my @queue;

  my @drvs = $pp->drvs;
  if (@attrs) {
    @drvs = grep { $_->attrname eq any(@attrs) } @drvs;
  }

  foreach my $drv (@drvs) {
    my $name = $drv->distribution_name;
    next unless defined $name && length $name;

    my $mc = $metacpan->get_by(distribution => $name);
    next unless $mc;
    unless ($app->deps_only_enabled) {
      my $version = $drv->version;
      next unless defined $version && length $version;
      next unless $mc->newer_than($version);
    }
    push @queue, [ $drv->attrname, $mc ];
  }

  while (my $item = shift @queue) {
    my ($root_source, $release) = @$item;
    foreach my $dep (
      $release->dependency([qw(build test configure)])->@*,
      $release->dependency([qw(runtime)])->@*
    ) {
      my $dep_attr = $dep->attrname;
      next if $existing{$dep_attr};
      next if $existing_lc{lc($dep_attr)};

      my $h = $missing{$dep_attr} //= {
        release     => $dep,
        required_by => {},
      };
      $h->{required_by}->{$root_source} = 1;

      next if $seen_distribution{ $dep->distribution }++;
      push @queue, [ $root_source, $dep ];
    }
  }

  return \%missing;
}

sub render_generated_drv ($app, $release) {
  my $attr = $release->attrname;
  my $distribution = $release->distribution;
  my $version = $release->version;
  my $url = $release->download_url;
  die "render_generated_drv: missing download_url for " . $release->distribution
    unless defined $url && length $url;
  my $checksum = $release->checksum_sha256;
  die "render_generated_drv: missing checksum_sha256 for " . $release->distribution
    unless defined $checksum && length $checksum;
  my $hash = sha256_hex_to_sri($checksum);

  $url =~ s|^https://cpan.metacpan.org/|mirror://cpan/|;

  my @build = sort map { $_->attrname } $release->dependency([qw(build test configure)])->@*;
  my @propagated = sort map { $_->attrname } $release->dependency([qw(runtime)])->@*;
  my $preferred_build_fun = $release->preferred_build_fun // "Package";
  my $build_fun = $preferred_build_fun eq "Module" ? "buildPerlModule" : "buildPerlPackage";
  my $homepage = $release->homepage;
  my $description = $release->abstract;
  my $license = render_license($release->license);

  if (defined $description) {
    $description =~ s/\n+/ /g;
    $description =~ s/\s+/ /g;
    $description =~ s/^\s+|\s+$//g;
    $description =~ s/\.$//;
  }
  if (defined $homepage) {
    $homepage =~ s/^\s+|\s+$//g;
  }
  my $esc = sub ($s) {
    return undef unless defined $s;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    return $s;
  };
  $description = $esc->($description);
  $homepage = $esc->($homepage);

  my $build_line = @build ? '    buildInputs = [ '.join(q{ }, @build)." ];\n" : q{};
  my $propagated_line = @propagated ? '    propagatedBuildInputs = [ '.join(q{ }, @propagated)." ];\n" : q{};
  my $meta_block = q{};
  if ((defined $description && length $description) ||
      (defined $homepage && length $homepage) ||
      (defined $license && length $license)) {
    $meta_block .= "    meta = {\n";
    $meta_block .= "      description = \"$description\";\n"
      if defined $description && length $description;
    $meta_block .= "      homepage = \"$homepage\";\n"
      if defined $homepage && length $homepage;
    $meta_block .= "      license = $license;\n"
      if defined $license && length $license;
    $meta_block .= "    };\n";
  }

  my $ret = '';
  $ret .= "  $attr = $build_fun {\n";
  $ret .= "    pname = \"$distribution\";\n";
  $ret .= "    version = \"$version\";\n";
  $ret .= "    src = fetchurl {\n";
  $ret .= "      url = \"$url\";\n";
  $ret .= "      hash = \"$hash\";\n";
  $ret .= "    };\n";
  $ret .= $build_line;
  $ret .= $propagated_line;
  $ret .= $meta_block;
  $ret .= "  };\n";
  return $ret;
}

sub append_generated_stanzas_inplace ($app, $text) {
  my $file = $app->nix_file;
  open my $fh, "<", $file or die "Cannot read $file: $!";
  local $/ = undef;
  my $buf = <$fh>;
  close $fh;

  unless ($buf =~ /\n}\s*\z/s) {
    die "Unable to append into $file: could not find final closing brace";
  }
  $text =~ s/\s+\z//s;
  return if $text eq q{};
  $buf =~ s/\n}\s*\z/\n\n$text\n}\n/s;

  open my $wh, ">", $file or die "Cannot write $file: $!";
  print {$wh} $buf;
  close $wh;
}

sub has_nixfmt ($app) {
  state $checked = 0;
  state $has = 0;
  state $msg = "";
  if (!$checked) {
    my ($ok, $err, $buf) = run(command => ["nixfmt", "--version"]);
    $has = $ok ? 1 : 0;
    $msg = join("", ($buf // [])->@*);
    $msg = $err unless $msg;
    $checked = 1;
  }
  die "nixfmt is required but was not found or failed to run: $msg"
    unless $has;
  return $has;
}

sub nix_file_sig ($app) {
  my @s = stat($app->nix_file);
  return unless @s;
  return join(":", $s[1], $s[7], $s[9]);
}

sub format_nix_file ($app, $pp=undef) {
  $app->has_nixfmt;
  state %last_formatted_sig_by_file;
  my $file = $app->nix_file;
  return $app->format_path_with_nixfmt($file, $pp, \%last_formatted_sig_by_file);
}

sub format_path_with_nixfmt ($app, $file, $pp=undef, $cache=undef) {
  $app->has_nixfmt;
  $cache //= {};
  my $sig_before = $app->nix_file_sig;
  if (defined $file && -f $file) {
    my @s = stat($file);
    $sig_before = @s ? join(":", $s[1], $s[7], $s[9]) : undef;
  }
  if (defined $sig_before &&
      defined $cache->{$file} &&
      $cache->{$file} eq $sig_before) {
    return;
  }
  my ($ok, $err, $buf) = run(command => ["nixfmt", $file]);
  die "nixfmt failed: $err: ".join("", ($buf // [])->@*) unless $ok;
  my $sig_after = undef;
  if (defined $file && -f $file) {
    my @s = stat($file);
    $sig_after = @s ? join(":", $s[1], $s[7], $s[9]) : undef;
  }
  $cache->{$file} = $sig_after if defined $sig_after;
  $pp->parse_nix_file if $pp;
}

sub missing_commit_body ($app, $missing_to_add, @missing_attrs) {
  return unless @missing_attrs;
  my @lines = ("dependencies:");
  foreach my $attr (sort @missing_attrs) {
    my $release = $missing_to_add->{$attr}->{release};
    my $version = $release ? $release->version : "unknown";
    push @lines, "perlPackages.$attr: init at $version";
  }
  return join("\n", @lines);
}

sub format_stanza_block ($app, @stanzas) {
  my @clean;
  foreach my $s (@stanzas) {
    next unless defined $s;
    $s =~ s/\s+\z//s;
    next unless $s =~ /\S/;
    push @clean, $s;
  }
  return q{} unless @clean;
  return join("\n\n", @clean)."\n";
}

sub compare_dependencies($app, $drv, $mc) {


}


sub command_generate ($app, @attrs) {
  $app->init_logging;

}

sub command_generate_missing ($app, @attrs) {
  $app->init_logging;
  my $metacpan = Nix::MetaCPANCache->new;
  die "MetaCPAN cache does not exist, download it with:\n    $0 refresh\n\n"
    unless $metacpan->db_file_exists;

  my $pp = Nix::PerlPackages->new( nix_file => $app->nix_file );
  my $missing = $app->collect_missing_dependencies($metacpan, $pp, @attrs);
  my @attrs_sorted = sort keys %$missing;

  my $text = q{};
  my @stanzas;
  foreach my $attr (@attrs_sorted) {
    my $release = $missing->{$attr}->{release};
    push @stanzas, $app->render_generated_drv($release);
  }
  $text = $app->format_stanza_block(@stanzas);

  if ($app->inplace) {
    $app->append_generated_stanzas_inplace($text);
    $app->format_nix_file();
    say "Appended ".scalar(@attrs_sorted)." missing dependency stanzas to ".$app->nix_file;
  } else {
    # The --out file is a *fragment* of attribute bindings (for review / pasting
    # into perl-packages.nix), not a complete Nix expression, so we must NOT run
    # nixfmt on it (nixfmt would fail to parse a bare set of bindings). The
    # stanzas are already rendered canonically by render_generated_drv.
    open my $fh, ">", $app->out or die "Cannot write ".$app->out.": $!";
    print {$fh} "# Generated by nix-cpan generate_missing. These are attribute\n";
    print {$fh} "# bindings to paste into perlPackages (not a standalone Nix file).\n\n";
    print {$fh} $text;
    close $fh;
    say "Generated ".scalar(@attrs_sorted)." missing dependency stanzas into ".$app->out;
  }
  return 0;
}

sub command_errata ($app) {
  $app->init_logging;
  my $mcc = Nix::MetaCPANCache->new;
  die "MetaCPAN cache does not exist, download it with:\n    $0 refresh\n\n"
    unless $mcc->db_file_exists;

  my $cfg = errata();
  my $result = classify_extra_dependencies($mcc, $cfg);
  # A comment on a dist block signals deliberate intent (often a hedge against
  # MetaCPAN snapshot unreliability); such entries are reported but never pruned.
  my $commented = commented_dist_blocks(Nix::PerlPackages::Errata::errata_file());

  my $total_redundant = 0;
  my $total_load = 0;
  my $total_prunable = 0;
  for my $bucket (sort keys $result->{buckets}->%*) {
    my $info = $result->{buckets}->{$bucket};
    my $r = scalar $info->{redundant}->@*;
    my $l = scalar $info->{load_bearing}->@*;
    $total_redundant += $r;
    $total_load += $l;
    printf("%s: %d entries — %d provably redundant, %d load-bearing\n",
           $bucket, $info->{total}, $r, $l);
    for my $e (sort { $a->{dist} cmp $b->{dist} || $a->{module} cmp $b->{module} } $info->{redundant}->@*) {
      my $is_hedge = $commented->{$bucket}{ $e->{dist} } ? 1 : 0;
      $total_prunable++ unless $is_hedge;
      printf("  REDUNDANT%s %-32s %-28s -> %s%s\n",
             $is_hedge ? "*" : " ",
             $e->{dist}, $e->{module}, $e->{attr},
             $is_hedge ? "   [commented hedge — retained]" : "");
    }
  }

  if ($result->{findings}->@*) {
    say "";
    say "Findings (not auto-pruned; review manually):";
    for my $f (sort { ($a->{type} cmp $b->{type}) || ($a->{dist} cmp $b->{dist}) } $result->{findings}->@*) {
      if ($f->{type} eq "dist_not_in_cache") {
        printf("  dist-not-in-cache       %s\n", $f->{dist});
      } elsif ($f->{type} eq "deps_unresolvable") {
        printf("  deps-unresolvable       %-32s %s\n", $f->{dist}, $f->{error} // q{});
      } elsif ($f->{type} eq "errata_module_unresolvable") {
        printf("  errata-mod-unresolvable %-32s %s\n", $f->{dist}, $f->{module});
      } else {
        printf("  %-22s %s\n", $f->{type}, $f->{dist} // q{});
      }
    }
  }

  my $hedges = $total_redundant - $total_prunable;
  say "";
  printf("Summary: %d redundant (%d prunable, %d commented hedges retained), %d load-bearing, %d findings\n",
         $total_redundant, $total_prunable, $hedges, $total_load, scalar $result->{findings}->@*);
  say "* = commented hedge: redundant in this cache snapshot but deliberately kept"
    . " (comment signals intent, e.g. snapshot unreliability)." if $hedges;

  # --- buildFunctionOverrides ---
  my $bfo = classify_build_function_overrides($mcc, $cfg);
  if (($bfo->{redundant}->@* + $bfo->{load_bearing}->@* + $bfo->{findings}->@*)) {
    say "";
    say "buildFunctionOverrides: "
      . scalar($bfo->{redundant}->@*) . " redundant, "
      . scalar($bfo->{load_bearing}->@*) . " load-bearing";
    for my $e ($bfo->{redundant}->@*) {
      say "  REDUNDANT  $e->{dist}: forced=$e->{forced} but metadata already yields $e->{metadata}";
    }
    for my $e ($bfo->{load_bearing}->@*) {
      say "  keep       $e->{dist}: forced=$e->{forced} (metadata: " . ($e->{metadata} // "undecided") . ")";
    }
    for my $f ($bfo->{findings}->@*) {
      say "  finding    $f->{type}: $f->{dist}";
    }
  }

  # --- ignoreModule ---
  my $ign = classify_ignore_modules($mcc, $cfg);
  if (($ign->{redundant}->@* + $ign->{load_bearing}->@*)) {
    say "";
    say "ignoreModule: "
      . scalar($ign->{redundant}->@*) . " redundant, "
      . scalar($ign->{load_bearing}->@*) . " load-bearing";
    for my $e ($ign->{redundant}->@*) {
      say "  REDUNDANT  $e->{module} — $e->{reason}";
    }
    for my $e ($ign->{load_bearing}->@*) {
      say "  keep       $e->{module} — $e->{class}" . (defined $e->{attr} ? " ($e->{attr})" : "");
    }
  }

  # --- moduleResolutionOverrides ---
  if (!($cfg->{moduleResolutionOverrides} && ref($cfg->{moduleResolutionOverrides}) eq "HASH"
        && keys $cfg->{moduleResolutionOverrides}->%*)) {
    say "";
    say "moduleResolutionOverrides: (none configured)";
  }

  if ($app->prune) {
    if ($total_prunable == 0) {
      say "Nothing prunable (all redundant entries are commented hedges).";
      return 0;
    }
    my @to_remove;
    for my $bucket (sort keys $result->{buckets}->%*) {
      for my $e ($result->{buckets}->{$bucket}->{redundant}->@*) {
        next if $commented->{$bucket}{ $e->{dist} }; # never prune commented hedges
        push @to_remove, [ $bucket, $e->{dist}, $e->{module} ];
      }
    }
    my $removed = $app->prune_errata_entries(\@to_remove);
    say "Pruned $removed redundant, uncommented errata entr" . ($removed == 1 ? "y" : "ies") . " from " . Nix::PerlPackages::Errata::errata_file();
  } else {
    say "Re-run with --prune to remove the $total_prunable redundant + uncommented entries." if $total_prunable;
  }
  return 0;
}

# Surgically remove `- Module::Name` lines under specific bucket/dist keys from
# Errata.yaml, preserving comments and layout (CPAN::Meta::YAML round-trips do
# not preserve comments, so we edit the text directly).
#
# Each distribution key is treated as a block: the "  Dist:" line plus the
# following comment/item lines (indent >= 3) up to the next key. We drop the
# redundant item lines; if a block has no item lines left, the whole block
# (key + its comments) is removed. Comments are kept whenever any item remains.
sub prune_errata_entries ($app, $to_remove) {
  my $file = Nix::PerlPackages::Errata::errata_file();
  open my $fh, "<", $file or die "Cannot read $file: $!";
  local $/ = "\n";   # read line-by-line regardless of the caller's $/
  my @lines = <$fh>;
  close $fh;

  # Index removals: { bucket => { dist => { module => 1 } } }
  my %rm;
  for my $t (@$to_remove) {
    my ($bucket, $dist, $module) = @$t;
    $rm{$bucket}{$dist}{$module} = 1;
  }

  my @out;
  my $removed = 0;
  my $cur_bucket = q{};
  my $i = 0;
  while ($i < @lines) {
    my $line = $lines[$i];

    # Top-level bucket key, e.g. "extraBuildDependencies:"
    if ($line =~ /^(\w+):\s*$/) {
      $cur_bucket = $1;
      push @out, $line;
      $i++;
      next;
    }

    # Distribution key with an empty value (a list follows), e.g. "  Archive-Zip:"
    if ($line =~ /^\s{2}(\S[^:]*):\s*$/) {
      my $dist = $1;
      # Gather the block: subsequent lines indented deeper than a key
      # (i.e. not matching ^\s{0,2}\S), which are this dist's comments/items.
      my @block;
      my $j = $i + 1;
      while ($j < @lines && $lines[$j] !~ /^\s{0,2}\S/) {
        push @block, $lines[$j];
        $j++;
      }

      my $removals = $rm{$cur_bucket}{$dist} // {};
      my @kept;
      for my $bl (@block) {
        if ($bl =~ /^\s{4}-\s*(\S.*?)\s*$/) {
          my $module = $1;
          if ($removals->{$module}) { $removed++; next; }
        }
        push @kept, $bl;
      }

      my $has_item = grep { /^\s{4}-/ } @kept;
      if ($has_item) {
        push @out, $line, @kept;
      }
      # else: drop the whole block (key + comments) — nothing pushed.
      $i = $j;
      next;
    }

    push @out, $line;
    $i++;
  }

  open my $wh, ">", $file or die "Cannot write $file: $!";
  print {$wh} @out;
  close $wh;
  return $removed;
}

sub nixpkgs_root ($app) {
  my $f = $app->nix_file;
  my $suffix = "/pkgs/top-level/perl-packages.nix";
  if (length($f) >= length($suffix) && substr($f, -length($suffix)) eq $suffix) {
    return substr($f, 0, length($f) - length($suffix));
  }
  return;
}

sub command_diagnose ($app, @attrs) {
  $app->init_logging;
  my $mcc = Nix::MetaCPANCache->new;
  die "MetaCPAN cache does not exist, download it with:\n    $0 refresh\n\n"
    unless $mcc->db_file_exists;

  my $log_opt = $app->can("log") ? $app->log : undef;
  my $pp = Nix::PerlPackages->new( nix_file => $app->nix_file );

  die "diagnose requires at least one attr (or --log with one attr)\n" unless @attrs;

  my @all_suggestions;
  for my $attr (@attrs) {
    my $drv = $pp->drv_by_attrname($attr);
    unless ($drv) { WARN("Skipping $attr: not found in perlPackages"); next; }
    my $dist = $drv->distribution_name;
    unless (defined $dist && length $dist) { WARN("Skipping $attr: no distribution name"); next; }

    my $log;
    if (defined $log_opt) {
      open my $fh, "<", $log_opt or die "Cannot read log $log_opt: $!";
      local $/; $log = <$fh>; close $fh;
      INFO("Parsing existing log for $attr ($dist)");
    } else {
      my $root = $app->nixpkgs_root;
      die "Cannot derive nixpkgs root from nix_file (expected .../pkgs/top-level/perl-packages.nix)\n"
        unless defined $root;
      INFO("Building perlPackages.$attr to observe missing build deps ...");
      my ($ok, $err, $buf) = run(command =>
        ["nix-build", $root, "-A", "perlPackages.$attr", "--no-out-link"]);
      $log = join("", ($buf // [])->@*);
      if ($ok) {
        say "perlPackages.$attr ($dist): builds OK — no missing build deps.";
        next;
      }
      INFO("Build failed for $attr; analysing log");
    }

    my $res = suggest_from_log($mcc, $log, $dist);
    my @sugg  = $res->{suggestions}->@*;
    my @stale = $res->{stale}->@*;
    my @find  = $res->{findings}->@*;

    if (!@sugg && !@stale && !@find) {
      say "perlPackages.$attr ($dist): build failed but no missing-module signature found (different failure).";
      next;
    }

    say "perlPackages.$attr ($dist):";
    for my $s (@sugg) {
      say "  SUGGEST  $s->{bucket}: $dist += $s->{module}  (attr $s->{attr})  [metadata misses it]";
    }
    for my $s (@stale) {
      say "  STALE    $s->{module} (attr $s->{attr}) is in MetaCPAN metadata but missing from the";
      say "           derivation — regenerate with: $0 update --deps_only --inplace $attr   (no errata needed)";
    }
    for my $f (@find) {
      if ($f->{type} eq "core_module") {
        say "  note     $f->{module} is a core module (not an errata dep)";
      } elsif ($f->{type} eq "unresolvable_module") {
        say "  WARN     $f->{module} is missing but unresolvable — likely needs a new package, not errata";
      }
    }
    push @all_suggestions, @sugg;
  }

  if ($app->apply && @all_suggestions) {
    my $added = add_errata_entries(Nix::PerlPackages::Errata::errata_file(), \@all_suggestions);
    say "";
    say "Applied $added errata addition" . ($added == 1 ? "" : "s") . " to " . Nix::PerlPackages::Errata::errata_file() . ".";
    say "Re-run: $0 update --deps_only --inplace <attr>   to apply the new deps, then rebuild.";
  } elsif (@all_suggestions) {
    say "";
    say "Re-run with --apply to write these into Errata.yaml.";
  }
  return 0;
}

# Count of dependency add/removes between the derivation and MetaCPAN (the same
# risk notion as `compare --report`). Can die if a dep is unresolvable.
sub dep_delta ($app, $drv, $mc) {
  my $delta = 0;
  for my $k (qw(build_inputs propagated_build_inputs)) {
    my @cur = grep { ! /^pkgs\./ } $drv->$k;
    my @new = $mc->$k;
    my $diff = Array::Diff->diff(\@cur, \@new);
    $delta += scalar(grep { $_ } @{$diff->added}) + scalar(grep { $_ } @{$diff->deleted});
  }
  return $delta;
}

sub revert_nix_file ($app, $pp) {
  my $file = $app->nix_file;
  my $dir = dirname($file);
  my $rel = basename($file);
  my ($ok, $err, $buf) = run(command => ["git", "-C", $dir, "checkout", "--", $rel]);
  die "revert (git checkout) failed: $err: " . join("", ($buf // [])->@*) unless $ok;
  $pp->parse_nix_file;
}

# Build-gate a single attr. Returns ($ok, $reason). Default is a full `nix-build`
# (with tests); --fast verifies only the `.src` fetch/hash. On a full-build
# failure we mine the log to distinguish a src hash mismatch from missing deps.
sub verify_build ($app, $attr) {
  # Test hook: deterministically fail the gate for the named attrs (comma-list),
  # so the revert/report path can be validated without a naturally-failing build.
  if (my $fail = $ENV{NIX_CPAN_FORCE_BUILD_FAIL}) {
    return (0, "forced build failure (NIX_CPAN_FORCE_BUILD_FAIL)")
      if $attr eq any(split /,/, $fail);
  }

  my $root = $app->nixpkgs_root;
  die "Cannot derive nixpkgs root from nix_file\n" unless defined $root;

  # --fast: verify only that the source fetches with the right hash (relies on
  # downstream Hydra for the actual build).
  if ($app->fast) {
    my ($ok_src) = run(command =>
      ["nix-build", $root, "-A", "perlPackages.$attr.src", "--no-out-link"]);
    return $ok_src ? (1, "src ok (--fast, not built)") : (0, "src fetch/hash failed");
  }

  # Full gate. A wrong src hash fails early in this same build (the FOD src is
  # realised first), so a separate `.src` pre-build would only add a second full
  # evaluation of perl-packages.nix per candidate for no extra coverage. Mine the
  # single build log to distinguish a hash mismatch from missing build deps.
  my ($ok, $err, $buf) = run(command =>
    ["nix-build", $root, "-A", "perlPackages.$attr", "--no-out-link"]);
  return (1, "build+tests passed") if $ok;

  my $log = join("", ($buf // [])->@*);
  return (0, "src hash mismatch")
    if $log =~ /hash mismatch|specified:\s*sha256|got:\s*sha256/i;
  my @missing = parse_missing_modules($log);
  my $reason = "build failed";
  $reason .= " (missing: " . join(", ", @missing) . ")" if @missing;
  return (0, $reason);
}

sub command_auto ($app, @attrs) {
  $app->init_logging;
  my $metacpan = Nix::MetaCPANCache->new;
  die "MetaCPAN cache does not exist, download it with:\n    $0 refresh\n\n"
    unless $metacpan->db_file_exists;
  die "auto requires nix_file at .../pkgs/top-level/perl-packages.nix\n"
    unless defined $app->nixpkgs_root;

  my $risk = $app->risk // "safe";
  die "--risk must be one of: safe, moderate, all\n"
    unless $risk =~ /^(?:safe|moderate|all)$/;

  # auto verifies each candidate by editing the file in place and then reverting
  # via `git checkout -- <file>` (on a failed gate, or after every candidate in
  # dry-run). That revert would discard pre-existing uncommitted edits, so refuse
  # to run on a dirty file regardless of --commit. (git_sanity also enforces this
  # for --commit, plus the branch check.)
  if ($app->git_file_dirty) {
    die "auto: " . $app->nix_file . " has uncommitted changes.\n"
      . "Commit or stash them first — auto reverts via 'git checkout' and would discard them.\n";
  }
  $app->git_sanity if $app->commit;

  my $pp = Nix::PerlPackages->new( nix_file => $app->nix_file );
  my %known = map { $_ => 1 } $pp->all_attrnames;
  my %scanned = $app->scan_top_level_attrnames;
  @known{keys %scanned} = values %scanned;

  my @drvs = $pp->drvs;
  if (@attrs) {
    @drvs = grep { $_->attrname eq any(@attrs) } @drvs;
  }

  my (@updated, @failed, @skipped);

  foreach my $drv (@drvs) {
    my $attr = $drv->attrname;
    my $name = $drv->distribution_name;
    next unless defined $name && length $name;
    my $version = $drv->version;
    next unless defined $version && length $version;

    my $mc = $metacpan->get_by(distribution => $name);
    next unless $mc;
    next unless $mc->newer_than($version);

    # Risk bucket by dependency delta (same notion as `compare --report`).
    my $delta = eval { $app->dep_delta($drv, $mc) };
    if ($@) {
      push @skipped, { attr => $attr, reason => "dependency resolution failed (needs errata/missing)" };
      next;
    }
    if ($risk eq "safe") { next unless $delta == 0; }
    elsif ($risk eq "moderate") { next unless $delta <= 6; }

    last if $app->max && (@updated + @failed) >= $app->max;

    # Compute the bump in memory.
    my $d = eval { $app->update_attr($metacpan, $pp, $attr) };
    if ($@) { push @skipped, { attr => $attr, reason => "update_attr: $@" }; next; }
    next unless $d && $d->dirty;

    my $old = $d->get_attr("version", $d->orig_part);
    my $new = $d->version;

    # v1: only candidates whose deps are all already present (no new packages).
    eval { $app->validate_drv_dependency_attrs($d, \%known, {}) };
    if ($@) {
      push @skipped, { attr => $attr, old => $old, new => $new,
                       reason => "needs missing dependency packages (run generate_missing)" };
      next;
    }

    # Apply (unformatted but valid), then build-gate. No need to re-parse here:
    # verify_build shells out to nix-build on disk, and each outcome re-parses
    # anyway (revert_nix_file / format_nix_file), so parse_after => 0 avoids a
    # wasted full-file parse per candidate.
    $pp->update_inplace($d, parse_after => 0);
    my ($ok, $reason) = $app->verify_build($attr);

    if (!$ok) {
      $app->revert_nix_file($pp);
      push @failed, { attr => $attr, old => $old, new => $new, reason => $reason };
      WARN("FAIL  $attr $old -> $new: $reason");
      next;
    }

    if ($app->commit) {
      $app->format_nix_file($pp);
      if ($app->git_file_dirty) {
        $app->git_cmd("commit", "--no-gpg-sign", "-m", $d->git_message);
        push @updated, { attr => $attr, old => $old, new => $new, committed => 1, reason => $reason };
        INFO("OK    $attr $old -> $new (committed)");
      } else {
        $app->revert_nix_file($pp);
        push @skipped, { attr => $attr, reason => "no net change after format" };
      }
    } else {
      # dry-run: revert so the tree stays clean for the next candidate.
      $app->revert_nix_file($pp);
      push @updated, { attr => $attr, old => $old, new => $new, committed => 0, reason => $reason };
      INFO("OK    $attr $old -> $new (verified, dry-run)");
    }
  }

  my $report = {
    risk      => $risk,
    committed => ($app->commit ? 1 : 0),
    fast      => ($app->fast ? 1 : 0),
    updated   => \@updated,
    failed    => \@failed,
    skipped   => \@skipped,
  };

  printf("auto (risk=%s, %s%s): %d verified, %d failed, %d skipped\n",
         $risk, ($app->commit ? "commit" : "dry-run"), ($app->fast ? ", fast" : ""),
         scalar(@updated), scalar(@failed), scalar(@skipped));
  for my $u (@updated) {
    printf("  OK    %-32s %s -> %s%s\n", $u->{attr}, $u->{old} // "?", $u->{new} // "?",
           $u->{committed} ? " (committed)" : "");
  }
  for my $f (@failed) {
    printf("  FAIL  %-32s %s -> %s : %s\n", $f->{attr}, $f->{old} // "?", $f->{new} // "?", $f->{reason});
  }
  for my $s (@skipped) {
    printf("  SKIP  %-32s %s\n", $s->{attr}, $s->{reason});
  }

  if (defined $app->report_file) {
    # YAML (not JSON) so the report diffs cleanly in review and can be read/edited
    # by hand, consistent with Errata.yaml.
    CPAN::Meta::YAML->new($report)->write($app->report_file);
    say "Wrote YAML report to ".$app->report_file;
  }

  return (@failed ? 1 : 0);
}

sub command_update ($app, @attrs) {
  $app->init_logging;
  my $metacpan = Nix::MetaCPANCache->new;
  die "MetaCPAN cache does not exist, download it with:\n    $0 refresh\n\n"
    unless $metacpan->db_file_exists;
  if ($app->commit) {
    $app->git_sanity;
  }

  my $pp = Nix::PerlPackages->new( nix_file => $app->nix_file );
  my %known_attrs = map { $_ => 1 } $pp->all_attrnames;
  my %scanned_attrs = $app->scan_top_level_attrnames;
  @known_attrs{keys %scanned_attrs} = values %scanned_attrs;

  unless (@attrs) {
    @attrs = map { $_->attrname } $pp->drvs;
  }

  my $missing_to_add = {};
  if ($app->missing) {
    $missing_to_add = $app->collect_missing_dependencies($metacpan, $pp, @attrs);
    INFO("Missing dependency stanzas to add: ".scalar(keys %$missing_to_add));
  }

  my (@updated, @ok, @fail);
  foreach my $a (@attrs) {
    try {
      my $d = $app->update_attr($metacpan, $pp, $a);
      if ($d && $d->dirty) {
        $app->validate_drv_dependency_attrs($d, \%known_attrs, $missing_to_add);
        push @updated, $d;
      } else {
        push @ok, [$a];
      }
    } catch ($e) {
      warn $e;
      push @fail, [$a, $e];
    }
  }

  INFO("Updates for ".scalar(@updated)." packages, ok ".scalar(@ok).", failed ".scalar(@fail));

  if ($app->diff) {
    foreach my $d (@updated) {
      say "diff -- perlPackages.".$d->attrname;
      my $old = $d->orig_part;
      my $new = $d->part;
      my $patch = Text::Diff::diff(\$old, \$new, { STYLE => "Unified" });
      print $patch;
    }
  }

  my %missing_added;
  foreach my $d (@updated) {
    my @missing_for_update = ();
    if ($app->missing) {
      foreach my $attr (sort keys %$missing_to_add) {
        next if $missing_added{$attr};
        next unless $missing_to_add->{$attr}->{required_by}->{ $d->attrname };
        push @missing_for_update, $attr;
      }
    }

    if ($app->diff && @missing_for_update) {
      foreach my $attr (@missing_for_update) {
        my $release = $missing_to_add->{$attr}->{release};
        my $stanza = $app->render_generated_drv($release);
        say "diff -- perlPackages.$attr";
        my $empty = q{};
        my $patch = Text::Diff::diff(\$empty, \$stanza, { STYLE => "Unified" });
        print $patch;
      }
    }

    if ($app->inplace || $app->commit) {
      $pp->update_inplace($d, parse_after => 0);
      if (@missing_for_update) {
        my @stanzas = map { $app->render_generated_drv($missing_to_add->{$_}->{release}) } @missing_for_update;
        my $block = $app->format_stanza_block(@stanzas);
        $app->append_generated_stanzas_inplace($block);
        $pp->parse_nix_file;
        $missing_added{$_} = 1 for @missing_for_update;
      }
      if ($app->commit) {
        $app->format_nix_file($pp);
      }
      if ($app->commit) {
        my $msg = $app->deps_only_enabled
          ? "perlPackages.".$d->attrname.": fix deps"
          : $d->git_message;
        if ($app->git_file_dirty) {
          my $body = $app->missing_commit_body($missing_to_add, @missing_for_update);
          if ($body) {
            $app->git_cmd("commit","--no-gpg-sign","-m", $msg, "-m", $body);
          } else {
            $app->git_cmd("commit","--no-gpg-sign","-m", $msg);
          }
        } else {
          INFO("No net changes for ".$d->attrname.", skipping commit");
        }
      }
    }

  }

  if ($app->missing) {
    my @remaining = grep { !$missing_added{$_} } sort keys %$missing_to_add;
    if ($app->diff && @remaining) {
      foreach my $attr (@remaining) {
        my $stanza = $app->render_generated_drv($missing_to_add->{$attr}->{release});
        say "diff -- perlPackages.$attr";
        my $empty = q{};
        my $patch = Text::Diff::diff(\$empty, \$stanza, { STYLE => "Unified" });
        print $patch;
      }
    }
    if (($app->inplace || $app->commit) && @remaining) {
      my @stanzas = map { $app->render_generated_drv($missing_to_add->{$_}->{release}) } @remaining;
      my $block = $app->format_stanza_block(@stanzas);
      $app->append_generated_stanzas_inplace($block);
      $pp->parse_nix_file;
      if ($app->commit) {
        $app->format_nix_file($pp);
      }
      if ($app->commit) {
        # Fallback: if there are missing-only additions, keep them in one commit.
        if ($app->git_file_dirty) {
          my $body = $app->missing_commit_body($missing_to_add, @remaining);
          my $msg = "perlPackages: add remaining missing deps";
          if ($body) {
            $app->git_cmd("commit", "--no-gpg-sign", "-m", $msg, "-m", $body);
          } else {
            $app->git_cmd("commit", "--no-gpg-sign", "-m", $msg);
          }
        } else {
          INFO("No net changes for remaining missing deps, skipping commit");
        }
      }
    }
  }

  if ($app->inplace && !$app->commit) {
    $app->format_nix_file($pp);
  }

  return 0;
}

 sub git_cmd ($app, @args) {
   my $file = $app->nix_file;
   die "git_cmd: Invalid nix_file $file" unless $file && -f $file;
   my $dir = dirname($file);
   my $rel_file = basename($file);

   my ($ok, $err, $buf) = run( command => ["git", "-C", $dir, @args, $rel_file] );
   die "$err: ".join ("", @$buf) unless $ok;
   return join "", $buf->@*;
}

sub git_sanity ($app) {
    my @err;
    my $nix_file = $app->nix_file;
    my $dir = dirname($nix_file);
    my $rel_file = basename($nix_file);
    my ($ok_branch, $err_branch, $buf_branch) =
      run( command => ["git", "-C", $dir, qw(rev-parse --abbrev-ref HEAD)] );
    die "$err_branch: ".join("", @$buf_branch) unless $ok_branch;
    my $pwd_branch = join "", $buf_branch->@*;
    push @err, "* pwd is in '$pwd_branch' branch, this is probably not what you want\n"
      if $pwd_branch=~/(master|main)/;

    my ($ok_status, $err_status, $buf_status) =
      run( command => ["git", "-C", $dir, qw(status --porcelain), $rel_file] );
    die "$err_status: ".join("", @$buf_status) unless $ok_status;
    my $file_status = join "", $buf_status->@*;
    push @err, "* $nix_file is not clean, maybe it has uncommitted changes?\n"
      if $file_status;

    die "git_sanity error:\n".join("", @err) if @err;
}

sub git_file_dirty ($app) {
   my $file = $app->nix_file;
   die "git_file_dirty: Invalid nix_file $file" unless $file && -f $file;
   my $dir = dirname($file);
   my $rel_file = basename($file);
   my ($ok, $err, $buf) =
     run( command => ["git", "-C", $dir, "status", "--porcelain", $rel_file] );
   die "$err: ".join("", @$buf) unless $ok;
   return join("", @$buf) ne q{};
}

sub deps_only_enabled ($app) {
  return 0 unless $app->can("deps_only");
  return $app->deps_only ? 1 : 0;
}

sub validate_drv_dependency_attrs ($app, $drv, $known_attrs, $missing_to_add = {}) {
  my %unknown;
  foreach my $attr ($drv->build_inputs, $drv->propagated_build_inputs) {
    next unless defined $attr && length $attr;
    next if $attr =~ /^pkgs\./;
    next if $known_attrs->{$attr};
    next if $missing_to_add->{$attr};
    $unknown{$attr} = 1;
  }
  if (%unknown) {
    my @list = sort keys %unknown;
    die "Unknown dependency attrs for " . $drv->attrname . ": " . join(", ", @list)
      . ". Add a valid module/distribution mapping in errata or enable --missing if appropriate.";
  }
}



sub update_attr ($app, $metacpan, $pp, $attrname) {
  my $drv = $pp->drv_by_attrname($attrname);
  unless ($drv) {
    die "Cannot find $attrname in perlPackages";
  }

  my $name = $drv->distribution_name;
  unless (defined $name && length $name) {
    WARN("Skipping $attrname: no name found");
    return;
  }

  my $mc = $metacpan->get_by(distribution => $name);
  unless ($mc) {
    die "Cannot find " . $name . " on MetaCPAN";
  }

  if ($app->deps_only_enabled) {
    $drv->update_deps_from_metacpan($mc);
    return $drv;
  }

  my $version = $drv->version;
  unless (defined $version && length $version) {
    WARN("Skipping $attrname: no version found");
    return;
  }

  # url/hash are scoped to the src fetcher block (a derivation may also have
  # url/hash inside a fetchpatch in `patches = [ ... ]`).
  my $url = $drv->src_url;
  my $hash_attr = $drv->src_hash_attr;
  unless (defined $url && defined $hash_attr) {
    WARN("Skipping $attrname: no updatable url/hash source");
    return;
  }

  unless ($mc->newer_than($version)) {
    return;
  }

  $drv->update_from_metacpan($mc);

  return $drv;
}


app {
    my $app = shift;
    $app->init_logging();
    $app->_script->print_help;

    return 1;
};
