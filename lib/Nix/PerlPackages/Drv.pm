use v5.38;
use strict;
use experimental qw(class multidimensional);

class Nix::PerlPackages::Drv {
  use Log::Log4perl qw(:easy);
  use Nix::Util qw(sha256_hex_to_sri distro_name_to_attr);
  use Regexp::Common;
  use Perl6::Junction qw(any);
  use Smart::Comments -ENV;

  field $prepart        :param;
  field $attrname       :param;
  field $orig_build_fun :param(build_fun);
  field $orig_part      :param(part);

  field $build_fun;
  field $part;

  ADJUST {
    $build_fun = $orig_build_fun;
    $part      = $orig_part;
  };

  method orig_part {
    return $orig_part;
  }

  method dirty {
    return !($orig_build_fun eq $build_fun &&
             $orig_part eq $part);
  }

  method set_attrs(%attrs) {
    foreach my $k (keys %attrs) {
        $self->set_attr($k, $attrs{$k});
    }
    return $part;
  }

  method set_attr($attr, $val) {
    my $old_val = $self->get_attr($attr);
    unless (defined $old_val) {
        die "$attr wasn't defined previously";
    }
    $part =~ s{(^\s*\Q$attr\E\s*=\s*)"\Q$old_val\E";}{$1"$val";}m
      or die "Unable to update $attr";
  }

  method get_attr ($attr, $str=$part) {
    my @vals;
    foreach my $line (split /\n/, $str, -1) {
      if ($line =~ /^\s*\Q$attr\E\s*=\s*(["'])(.*)\1;\s*$/) {
        push @vals, $2;
      }
    }
    return undef unless @vals;
    die "get_attr $attr found more than 1 in part: $part" if @vals > 1;
    return $vals[0];
  }

  method get_attr_list ($attr, $str=$part) {
    ### get_attr_list text: $text
    # Grab the first balanced `[ ... ]` after `attr =`. Do NOT require a `;`
    # immediately after it: for the conditional form `[ base ] ++ lib.optionals
    # ... [ extra ];` that would fail and (wrongly) return an empty list, which
    # made dep_delta/compare see every conditional-list package as a full set of
    # spurious additions. We return the unconditional base list, mirroring what
    # the writer (set_or_add_attr_list) edits.
    my ($val) = $str =~ m/^\s*\Q$attr\E\s*=\s*
                           $RE{balanced}{-parens=>'[]'}
                         /gmx;

    return unless $val;

    my @ret = grep { !/^[\[\]]$/ } split(/\s+/, $val);
    ### get_attr_list: @ret
    @ret = sort @ret;
    return @ret;
  }

  method set_attr_list ($attr, @vals) {
    # my @has = $self->get_attr_list($attr, $str);
    my $attr_str = "[ ". join(" ", sort @vals)." ]";
    $part=~s/^(\s*)\Q$attr\E\s*=\s*$RE{balanced}{-parens=>'[]'}/$1$attr = $attr_str/m;
  }

  method has_attr_assignment($attr, $str=$part) {
    return $str =~ /^\s*\Q$attr\E\s*=/m ? 1 : 0;
  }

  method attr_list_is_simple($attr, $str=$part) {
    my ($expr) = $str =~ m/^\s*\Q$attr\E\s*=\s*(.*?);/ms;
    return 0 unless defined $expr;
    return $expr =~ /^\s*\[[^\]]*\]\s*$/s ? 1 : 0;
  }

  # For `attr = [ ... ] ++ <rest>;` where the leading list is FLAT (no nested
  # brackets), return (base_list_text, rest_text); rest begins with `++` and is
  # preserved verbatim (it carries platform conditionals like
  # `++ lib.optionals stdenv.hostPlatform.isDarwin [ ... ]`). Returns () for any
  # other shape (with-expr, override list, leading-conditional with no base).
  method attr_list_base_plus_rest($attr, $str=$part) {
    my ($expr) = $str =~ m/^\s*\Q$attr\E\s*=\s*(.*?);/ms;
    return unless defined $expr;
    if ($expr =~ /^\s*(\[[^\[\]]*\])\s*(\+\+.*\S)\s*$/s) {
      return ($1, $2);
    }
    return;
  }

  # Attrs referenced inside bracket lists within the conditional `rest`, so we
  # never duplicate a platform-conditional dep into the unconditional base.
  method _attrs_in_rest($rest) {
    my %in;
    # Plural form: deps live in bracket lists, e.g. `++ lib.optionals cond [ X Y ]`.
    while ($rest =~ /\[([^\[\]]*)\]/g) {
      for my $tok (split /\s+/, $1) {
        $in{$tok} = 1 if length $tok;
      }
    }
    # Singular form: a bare dep with no brackets, e.g.
    # `++ lib.optional (!stdenv.hostPlatform.isDarwin) Wx`. Capture the dep token
    # after the condition so it is not also promoted into the unconditional base.
    while ($rest =~ /\blib\.optional\s+(?:\([^()]*\)|\S+)\s+([A-Za-z_][\w]*)/g) {
      $in{$1} = 1;
    }
    return %in;
  }

  method set_or_add_attr_list($attr, @vals) {
    my @sorted = sort @vals;

    if ($self->attr_list_is_simple($attr)) {
      if (@sorted) {
        $self->set_attr_list($attr, @sorted);
      }
      return;
    }

    # `[ base ] ++ <conditional rest>`: update the unconditional base list only,
    # preserving the conditional suffix verbatim (do NOT munge macOS/platform
    # conditionals). Exclude any attr already present in the conditional so a
    # platform-only dep (e.g. Wx under !isDarwin) is not duplicated into base.
    if (my ($base, $rest) = $self->attr_list_base_plus_rest($attr)) {
      my %in_rest = $self->_attrs_in_rest($rest);
      my @old_base = grep { length && !/^[\[\]]$/ } split /\s+/, $base;
      my @new = grep { !$in_rest{$_} } @sorted;
      push @new, grep { /^pkgs\./ } @old_base;  # keep pkgs.* already in base
      @new = sort keys %{ { map { $_ => 1 } @new } };
      my $new_base = "[ " . join(" ", @new) . " ]";
      my $ok = ($part =~ s/(^\s*\Q$attr\E\s*=\s*)\[[^\[\]]*\](\s*\+\+)/$1$new_base$2/ms);
      die "set_or_add_attr_list: failed to update base list for $attr" unless $ok;
      return;
    }

    if ($self->has_attr_assignment($attr)) {
      # Other complex expressions (with-exprs, override lists, leading
      # conditionals) are left untouched — too risky to edit mechanically.
      WARN("Keeping complex $attr expression untouched for "
           . $self->attrname . " (manual review may be needed)");
      return;
    }
    return unless @sorted; # do not add empty attr lists

    my $attr_str = "[ ". join(" ", @sorted)." ]";
    my $indent = "    ";
    if ($part =~ /^(\s+)\w+\s*=/m) {
      $indent = $1;
    }
    my $line = $indent.$attr." = ".$attr_str.";\n";
    if ($part =~ s/^(\s*meta\s*=)/$line$1/m) {
      return;
    }
    $part .= $line;
  }

  method version {
    return $self->_get_top_level_attr("version");
  }

  method name {
    return $self->_get_top_level_attr("name");
  }

  method pname {
    return $self->_get_top_level_attr("pname");
  }

  method get_top_level_attr($attr) {
    return $self->_get_top_level_attr($attr);
  }

  method distribution_name {
    my $pname = $self->pname;
    return $pname if defined $pname && length $pname;

    my $name = $self->name;
    return unless defined $name && length $name;

    my $version = $self->version;
    if (defined $version && length $version) {
      my $suffix = "-" . $version;
      if (substr($name, -length($suffix)) eq $suffix) {
        return substr($name, 0, length($name) - length($suffix));
      }
    }
    return $name;
  }

  method set_build_inputs (@attrs) {
    $self->set_attr_list("buildInputs", @attrs);
  }

  method set_propagated_build_inputs (@attrs) {
    $self->set_attr_list("propagatedBuildInputs", @attrs);
  }

  method check_inputs {
    return $self->get_attr_list('checkInputs');
  }

  method build_inputs {
    return $self->get_attr_list('buildInputs');
  }

  method propagated_build_inputs {
    return $self->get_attr_list('propagatedBuildInputs');
  }

  method attrname {
    return $attrname;
  }

  method prepart {
    return $prepart;
  }

  method build_fun {
    return $build_fun;
  }

  method build_fun_changed {
    return $build_fun ne $orig_build_fun ? 1 : 0;
  }

  method set_build_fun($new_build_fun) {
    return unless defined $new_build_fun;
    return unless $new_build_fun eq any(qw(Package Module));
    $build_fun = $new_build_fun;
  }

  method prepart_for_current_build_fun {
    my $new = $prepart;
    $new =~ s/buildPerl(?:Package|Module)/buildPerl$build_fun/;
    return $new;
  }

  method part {
    return $part;
  }

  method update_from_metacpan ($mc) {
    my $version  = $mc->version;
    my $checksum = $mc->checksum_sha256;
    my $url      = $mc->download_url;

    die "update_from_metacpan: missing checksum_sha256 for " . $mc->distribution
      unless defined $checksum && length $checksum;
    die "update_from_metacpan: missing download_url for " . $mc->distribution
      unless defined $url && length $url;

    my $hash = sha256_hex_to_sri($checksum);
    $url =~ s|^https://cpan.metacpan.org/|mirror://cpan/|;

    if ($mc->can("preferred_build_fun")) {
      my $preferred = $mc->preferred_build_fun;
      $self->set_build_fun($preferred) if defined $preferred;
    }

    $self->_set_attr_prefer_top_level("version", $version);
    # url/hash live inside the src fetcher block; edit them there so we never
    # touch a url/hash belonging to a fetchpatch in `patches = [ ... ]`. The
    # setter mirrors the src_url/src_hash_attr read fallback (src block, then
    # top-level) so reader and writer can never disagree.
    my $hash_attr = $self->src_hash_attr // "hash";
    $self->_set_src_or_top_attr("url", $url);
    $self->_set_src_or_top_attr($hash_attr, $hash_attr eq "sha256" ? $checksum : $hash);

    $self->_merge_inputs_from_mc($mc);
  }

  method update_deps_from_metacpan ($mc) {
    $self->_merge_inputs_from_mc($mc);
  }

  # Sync buildInputs/propagatedBuildInputs to MetaCPAN's resolved deps, keeping
  # any pkgs.* entries already present in the derivation (those come from nixpkgs,
  # not CPAN metadata, so MetaCPAN can't know about them).
  method _merge_inputs_from_mc ($mc) {
    for my $spec (["buildInputs", "build_inputs"],
                  ["propagatedBuildInputs", "propagated_build_inputs"]) {
      my ($nix_attr, $method) = @$spec;
      my @inputs = $mc->$method();
      push @inputs, grep { /^pkgs\./ } $self->$method();
      $self->set_or_add_attr_list($nix_attr, @inputs);
    }
  }

  method git_message {
    if ($self->dirty) {
      my $prev_ver = $self->get_attr("version", $orig_part);
      my $new_ver  = $self->get_attr("version");
      return "perlPackages." . $self->attrname . ": $prev_ver -> $new_ver";
    }
    return;
  }

  method _top_level_target_depth($str) {
    my @lines = split /\n/, $str, -1;
    my %state = (
      in_block_comment => 0,
      in_dquote        => 0,
      in_squote        => 0,
    );
    my $depth = 0;
    foreach my $line (@lines) {
      my $masked = $self->_mask_nix_line($line, \%state);
      next if $masked =~ /^\s*$/;
      my $depth_before = $depth;
      if ($masked =~ /^\s*\{\s*$/) {
        return $depth_before + 1;
      }
      return $depth_before;
    }
    return 0;
  }

  method _set_attr_prefer_top_level($attr, $val) {
    my $top = $self->_get_top_level_attr($attr);
    if (defined $top) {
      return $self->_set_top_level_attr($attr, $top, $val);
    }
    return $self->set_attr($attr, $val);
  }

  method _set_top_level_attr($attr, $old_val, $val) {
    my @lines = split /\n/, $part, -1;
    my %state = (
      in_block_comment => 0,
      in_dquote        => 0,
      in_squote        => 0,
    );
    my $depth = 0;
    my $target_depth = $self->_top_level_target_depth($part);
    my $target_indent = $self->_top_level_target_indent($part, $target_depth);
    $target_indent //= q{};
    my $updated = 0;

    for (my $i = 0; $i < @lines; $i++) {
      my $line = $lines[$i];
      my $masked = $self->_mask_nix_line($line, \%state);
      my $depth_before = $depth;

      if (!$updated && $depth_before == $target_depth) {
        if ($line =~ /^(\Q$target_indent\E\Q$attr\E\s*=\s*)(["'])(.*)\2;(\s*)$/) {
          my $line_old_val = $3;
          if (defined $line_old_val && $line_old_val eq $old_val) {
            $lines[$i] = $1 . "\"$val\";" . $4;
            $updated = 1;
          }
        }
      }
      $depth += $self->_brace_delta($masked);
    }

    die "Unable to update top-level $attr" unless $updated;
    $part = join("\n", @lines);
  }

  method _get_top_level_attr($attr, $str=$part) {
    my @vals;
    my @lines = split /\n/, $str, -1;
    my %state = (
      in_block_comment => 0,
      in_dquote        => 0,
      in_squote        => 0,
    );
    my $depth = 0;
    my $target_depth = $self->_top_level_target_depth($str);
    my $target_indent = $self->_top_level_target_indent($str, $target_depth);
    $target_indent //= q{};

    foreach my $line (@lines) {
      my $masked = $self->_mask_nix_line($line, \%state);
      my $depth_before = $depth;

      if ($depth_before == $target_depth &&
          $line =~ /^\Q$target_indent\E\Q$attr\E\s*=\s*(["'])(.*)\1;\s*$/) {
        push @vals, $2;
      }

      $depth += $self->_brace_delta($masked);
    }
    return undef unless @vals;
    die "_get_top_level_attr $attr found more than 1 in part: $part" if @vals > 1;
    return $vals[0];
  }

  method _top_level_target_indent($str, $target_depth=undef) {
    $target_depth //= $self->_top_level_target_depth($str);
    my @lines = split /\n/, $str, -1;
    my %state = (
      in_block_comment => 0,
      in_dquote        => 0,
      in_squote        => 0,
    );
    my $depth = 0;

    foreach my $line (@lines) {
      my $masked = $self->_mask_nix_line($line, \%state);
      my $depth_before = $depth;
      if ($depth_before == $target_depth &&
          $masked =~ /^(\s+)[\w.-]+\s*=/) {
        return $1;
      }
      $depth += $self->_brace_delta($masked);
    }
    return undef;
  }

  # --- src-block-scoped accessors -------------------------------------------
  # url/hash live inside `src = <fetcher> { ... }`. A derivation may also carry
  # `patches = [ (fetchpatch { url=...; hash=...; }) ]`, so editing url/hash on
  # the whole derivation part is ambiguous. These helpers restrict reads/writes
  # to the src fetcher block only.

  method _src_span_lines($lines) {
    my %state = (in_block_comment => 0, in_dquote => 0, in_squote => 0);
    my $depth = 0;
    my $start;
    my $base_depth;
    for (my $i = 0; $i < @$lines; $i++) {
      my $masked = $self->_mask_nix_line($lines->[$i], \%state);
      if (!defined $start && $masked =~ /^\s*src\s*=\s*\S/) {
        $start = $i;
        $base_depth = $depth;
      }
      $depth += $self->_brace_delta($masked);
      if (defined $start && $i >= $start && $depth <= $base_depth) {
        return ($start, $i);
      }
    }
    return;
  }

  method _get_src_attr($attr) {
    my @lines = split /\n/, $part, -1;
    my ($s, $e) = $self->_src_span_lines(\@lines);
    return undef unless defined $s;
    for my $i ($s .. $e) {
      if ($lines[$i] =~ /^\s*\Q$attr\E\s*=\s*(["'])(.*)\1;\s*$/) {
        return $2;
      }
    }
    return undef;
  }

  # Set $attr within the src fetcher block. Returns 1 if it edited a line, 0 if
  # the src block (or the attr within it) was not found — the caller decides
  # whether to fall back. Never dies, so a graceful fallback is possible.
  method _set_src_attr($attr, $val) {
    my @lines = split /\n/, $part, -1;
    my ($s, $e) = $self->_src_span_lines(\@lines);
    return 0 unless defined $s;
    my $updated = 0;
    for my $i ($s .. $e) {
      if (!$updated && $lines[$i] =~ /^(\s*\Q$attr\E\s*=\s*)(["'])(.*)\2;(\s*)$/) {
        $lines[$i] = $1 . "\"$val\";" . $4;
        $updated = 1;
      }
    }
    return 0 unless $updated;
    $part = join("\n", @lines);
    return 1;
  }

  # Set url/hash preferring the src fetcher block, falling back to a top-level
  # attribute. This mirrors the read fallback in src_url/src_hash_attr so the
  # reader and writer always agree on where the value lives. Dies only if the
  # attribute is present in neither place.
  method _set_src_or_top_attr($attr, $val) {
    return if $self->_set_src_attr($attr, $val);
    my $top = $self->_get_top_level_attr($attr);
    if (defined $top) {
      $self->_set_top_level_attr($attr, $top, $val);
      return;
    }
    die "Unable to update $attr: not found in src block or at top level";
  }

  method _has_src_block {
    my @lines = split /\n/, $part, -1;
    my ($s, $e) = $self->_src_span_lines(\@lines);
    return defined $s ? 1 : 0;
  }

  # Which hash attribute the src uses: 'hash' (modern SRI) or 'sha256' (legacy
  # hex), or undef if neither is present. Falls back to a top-level attribute
  # for derivations/fixtures that put url/hash directly on the derivation
  # instead of inside a src fetcher block.
  method src_hash_attr {
    return "hash"
      if defined $self->_get_src_attr("hash")
      || defined $self->_get_top_level_attr("hash");
    return "sha256"
      if defined $self->_get_src_attr("sha256")
      || defined $self->_get_top_level_attr("sha256");
    return undef;
  }

  method src_url {
    my $v = $self->_get_src_attr("url");
    return $v if defined $v;
    return $self->_get_top_level_attr("url");
  }

  method _brace_delta($line) { return Nix::Util::brace_delta($line); }

  method _mask_nix_line($line, $st) { return Nix::Util::mask_nix_line($line, $st); }


}
