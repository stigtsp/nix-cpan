use v5.42;
use experimental qw(class);

class Nix::MetaCPANCache::Release {
  use Nix::Util qw(distro_name_to_attr);
  use Nix::PerlPackages::Errata qw(errata);
  use Log::Log4perl qw(:easy);
  use Cpanel::JSON::XS qw(decode_json);
  use Sort::Versions qw(versioncmp);
  use Perl6::Junction qw(any);
  use List::Util qw(uniq);
  use Module::CoreList;

  field $name :param :reader;
  field $distribution :param :reader;
  field $main_module :param :reader;
  field $data :param :reader;
  field $_mcc :param;
  field @deny_attr_prefix = qw(Win32 MSWin32);
  field @deny_distribution_prefix = qw(Win32- MSWin32-);

  ADJUST {
    $data = decode_json($data);
  };



  method attrname {
    return distro_name_to_attr($distribution);
  }

  method checksum_sha256 {
    return $data->{checksum_sha256};
  }

  method download_url {
    return $data->{download_url};
  }

  method abstract {
    return $data->{abstract};
  }

  method homepage {
    my $resources = $data->{resources};
    return unless $resources && ref($resources) eq "HASH";
    return $resources->{homepage} if defined $resources->{homepage} && length $resources->{homepage};
    my $repo = $resources->{repository};
    if ($repo && ref($repo) eq "HASH") {
      return $repo->{url} if defined $repo->{url} && length $repo->{url};
      return $repo->{web} if defined $repo->{web} && length $repo->{web};
    }
    return;
  }

  method license {
    my $license = $data->{license};
    if (ref($license) eq "ARRAY") {
      return $license->[0];
    }
    return $license;
  }

  method preferred_build_fun {
    my $cfg = errata();
    if ($cfg && ref($cfg) eq "HASH") {
      my $ov = $cfg->{buildFunctionOverrides};
      if ($ov && ref($ov) eq "HASH") {
        my $forced = $ov->{$distribution};
        if (defined $forced && $forced =~ /^(?:Module|Package)$/) {
          return $forced;
        }
      }
    }
    return $self->build_fun_from_metadata;
  }

  # The build-function decision from MetaCPAN metadata ALONE (no errata
  # override). Used by the errata audit to decide whether a buildFunctionOverrides
  # entry is redundant (metadata already yields the forced value).
  method build_fun_from_metadata {
    my $meta = $data->{metadata};
    return unless $meta && ref($meta) eq "HASH";

    my $cfg_req = $meta->{prereqs};
    if ($cfg_req && ref($cfg_req) eq "HASH") {
      $cfg_req = $cfg_req->{configure};
      $cfg_req = $cfg_req->{requires} if $cfg_req && ref($cfg_req) eq "HASH";
      if ($cfg_req && ref($cfg_req) eq "HASH") {
        my $has_module_build =
          exists $cfg_req->{"Module::Build"} ||
          exists $cfg_req->{"Module::Build::Tiny"};
        my $has_make_maker = exists $cfg_req->{"ExtUtils::MakeMaker"};
        return "Module" if $has_module_build && !$has_make_maker;
        return "Package" if $has_make_maker && !$has_module_build;
      }
    }

    my $generated_by = $meta->{generated_by} // q{};
    if ($generated_by =~ /Module::Build/i && $generated_by !~ /ExtUtils::MakeMaker/i) {
      return "Module";
    }
    if ($generated_by =~ /ExtUtils::MakeMaker/i && $generated_by !~ /Module::Build/i) {
      return "Package";
    }
    return;
  }


  method version {
    # Normalizing (i.e. removing v prefix)
    my $v = $data->{version};
    $v=~s/^v//;
    return $v;
  }

  method dependency ($phases=undef, $relationships=["requires"]) {
    my (@deps) = ($data->{dependency} // [])->@*;
    if ($phases && $phases->@*) {
      @deps = grep { $_->{phase} eq any($phases->@*) } @deps;
    }
    if ($relationships && $relationships->@*) {
      @deps = grep { $_->{relationship} eq any($relationships->@*) } @deps;
    }

    my (%seen_module, %seen_distribution, @resolved);
    foreach my $dep (@deps) {
      my $module = $dep->{module};
      next unless $module;
      next if lc($module) eq "perl";
      next if $self->is_explicitly_ignored_module($module);
      next if $seen_module{$module}++;
      next if Module::CoreList::is_core($module);

      my $release = $_mcc->resolve_module($module);
      unless ($release) {
        my $phase = $dep->{phase} // q{unknown};
        my $relationship = $dep->{relationship} // q{unknown};
        die "Cannot resolve dependency module '$module' for distribution '$distribution' (phase=$phase, relationship=$relationship). "
          . "Add a mapping via MetaCPAN cache/errata or explicitly allow it in Errata.yaml ignoreModule.";
      }
      next if $self->is_denied_dependency_release($release);
      next if $seen_distribution{ $release->distribution }++;
      push @resolved, $release;
    }

    @resolved = sort { $a->name cmp $b->name } @resolved;
    return [ @resolved ];
  }

  method is_explicitly_ignored_module ($module) {
    my $cfg = errata();
    return 0 unless $cfg && ref($cfg) eq "HASH";
    my $ignore = $cfg->{ignoreModule};
    return 0 unless $ignore && ref($ignore) eq "ARRAY";
    state %warned_ignore;
    foreach my $m ($ignore->@*) {
      next unless defined $m && length $m;
      next unless $module eq $m;
      WARN("Errata ignoreModule applied: $distribution ignores dependency module '$module'")
        unless $warned_ignore{$distribution . "\0" . $module}++;
      return 1;
    }
    return 0;
  }

  method is_denied_dependency_release ($release) {
    my $attr = $release->attrname // q{};
    my $distribution = $release->distribution // q{};
    foreach my $prefix (@deny_attr_prefix) {
      return 1 if index($attr, $prefix) == 0;
    }
    foreach my $prefix (@deny_distribution_prefix) {
      return 1 if index($distribution, $prefix) == 0;
    }
    return 0;
  }

  method newer_than ($ver) {
    my $new = $self->version;
    return 0 unless defined $new && length $new;
    return 0 unless defined $ver && length $ver;

    # Never bump a package pinned to a dev/trial (underscore) release, and never
    # "update" TO one. (README: don't update pre$ versions.) Sort::Versions
    # mis-orders underscore versions (e.g. ranks 0.10026 above the newer trial
    # 0.10_027), so guard them explicitly before comparing.
    return 0 if $new =~ /_/ || $ver =~ /_/;

    # Order with Sort::Versions: it treats 1.9 < 1.10 the dotted way that matches
    # nixpkgs/CPAN release sequences, and never reports an older cache version as
    # newer (so `auto` cannot be tricked into a downgrade when the local tree is
    # ahead of the cache). NB: version.pm's decimal normalization is WRONG here --
    # it parses "1.10" as 1.1, so it both misses real X.9 -> X.10 updates and can
    # downgrade; do not use it for this comparison.
    return versioncmp($new, $ver) > 0;
  }

  method build_inputs {
    my @ret = map { $_->attrname } $self->dependency([qw(build test configure)])->@*;
    push @ret, $self->_errata_extra_attrs("extraBuildDependencies");
    @ret = sort keys %{ { map { $_ => 1 } @ret } };
    return @ret;
  }

  method propagated_build_inputs {
    my @ret = map { $_->attrname } $self->dependency([qw(runtime)])->@*;
    push @ret, $self->_errata_extra_attrs("extraRuntimeDependencies");
    @ret = sort keys %{ { map { $_ => 1 } @ret } };
    return @ret;
  }

  method _errata_extra_attrs($bucket) {
    my $cfg = errata();
    return () unless $cfg && ref($cfg) eq "HASH";
    my $map = $cfg->{$bucket};
    return () unless $map && ref($map) eq "HASH";
    my $mods = $map->{$distribution};
    return () unless $mods && ref($mods) eq "ARRAY";

    my @attrs;
    my @mapped_pairs;
    foreach my $module (@$mods) {
      next unless defined $module && length $module;
      my $release = $self->_resolve_errata_module($module);
      die "Cannot resolve errata module '$module' for distribution '$distribution' in bucket '$bucket'"
        unless $release;
      next if $self->is_denied_dependency_release($release);
      my $attr = $release->attrname;
      push @attrs, $attr;
      push @mapped_pairs, "$module->$attr";
    }
    state %warned;
    my $warn_key = join("|", $distribution, $bucket);
    if (@mapped_pairs && !$warned{$warn_key}++) {
      WARN("Errata ".$bucket." applied for ".$distribution.": ".join(", ", @mapped_pairs));
    }
    return @attrs;
  }

  method _resolve_errata_module($module) {
    my $release = $_mcc->resolve_module($module);
    return $release if $release;

    # Some errata entries use distribution names rather than module names.
    $release = $_mcc->get_by(distribution => $module);
    return $release if $release;

    # Some errata entries refer to deep module paths where only a parent
    # module is indexed in MetaCPAN's provide table.
    my $candidate = $module;
    while ($candidate =~ s/::[^:]+$//) {
      $release = $_mcc->resolve_module($candidate);
      return $release if $release;
    }
    return;
  }

  method generate_drv { # XXX: This should return a PerlPackages::Drv object instead?
    my $template = ';
  <%= $attrname %> = <%= $build_fun %> {
  }
';

  }

}
