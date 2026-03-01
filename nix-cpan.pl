#!/usr/bin/env perl


use v5.38;
use Applify;

use strict;
use warnings;
use Array::Diff;
use Log::Log4perl qw(:easy);
use Smart::Comments;
use File::Basename;
use Perl6::Junction qw(any);
use lib qw(lib);
use Cpanel::JSON::XS qw(encode_json);
use Nix::PerlPackages;
use Nix::MetaCPANCache;
use Nix::Util qw(sha256_hex_to_sri render_license);
use Text::Diff ();
use IPC::Cmd qw(run);

use experimental qw(signatures try);

our $VERSION = 0.2;

option bool    => "debug"          => "Output debug information" => 0;
option bool    => "verbose"        => "Show changes and determinations being made" => 0;
option file    => "nix_file"       => "Path to perl-packages.nix" => "pkgs/top-level/perl-packages.nix";

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



sub init_logging {
    my $app = shift;
    Log::Log4perl->easy_init({
            level =>  ($app->debug ? $DEBUG : ($app->verbose ? $INFO : undef)),
            layout => '%X{distro}%m%n'
          });
    Log::Log4perl::MDC->put('distro', q{});
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
    open my $fh, ">", $app->out or die "Cannot write ".$app->out.": $!";
    print {$fh} $text;
    close $fh;
    $app->format_path_with_nixfmt($app->out);
    say "Generated ".scalar(@attrs_sorted)." missing dependency stanzas into ".$app->out;
  }
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
  foreach my $d (@updated) { ### Updating inplace [===|    ] % done
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

  my $url = $drv->get_top_level_attr("url");
  my $hash = $drv->get_top_level_attr("hash");
  if (!defined $url) {
    my $tmp = eval { $drv->get_attr("url") };
    $url = $tmp if !$@;
  }
  if (!defined $hash) {
    my $tmp = eval { $drv->get_attr("hash") };
    $hash = $tmp if !$@;
  }
  unless (defined $url && defined $hash) {
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
