use v5.38;
use strict;
use experimental qw(class);

class Nix::MetaCPANCache::Release {
  use Nix::Util qw(distro_name_to_attr);
  use Cpanel::JSON::XS qw(decode_json);
  use Sort::Versions qw(versioncmp);
  use Perl6::Junction qw(any);
  use List::Util qw(uniq);
  use Module::CoreList;

  field $name :param;
  field $distribution :param;
  field $main_module :param;
  field $data :param;
  field $_mcc :param;
  field @deny_attr_prefix = qw(Win32 MSWin32);
  field @deny_distribution_prefix = qw(Win32- MSWin32-);

  ADJUST {
    $data = decode_json($data);
  };

  method name         { return $name }
  method distribution { return $distribution }
  method main_module  { return $main_module }
  method data         { return $data }



  method attrname {
    return distro_name_to_attr($distribution);
  }

  method checksum_sha256 {
    return $data->{checksum_sha256};
  }

  method download_url {
    return $data->{download_url};
  }


  method version {
    # Normalizing (i.e. removing v prefix)
    my $v = $data->{version};
    $v=~s/^v//;
    return $v;
  }

  method dependency ($phases=undef, $relationships=["requires"]) {
    my (@deps) = $data->{dependency}->@*;
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
      next if $seen_module{$module}++;
      next if Module::CoreList::is_core($module);

      my $release = $_mcc->resolve_module($module);
      next unless $release;
      next if $self->is_denied_dependency_release($release);
      next if $seen_distribution{ $release->distribution }++;
      push @resolved, $release;
    }

    @resolved = sort { $a->name cmp $b->name } @resolved;
    return [ @resolved ];
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
    return versioncmp($self->version, $ver) > 0;
  }

  method build_inputs {
    my @ret = map { $_->attrname } $self->dependency([qw(build test configure)])->@*;
    return @ret;
  }

  method propagated_build_inputs {
    my @ret = map { $_->attrname } $self->dependency([qw(runtime)])->@*;
    return @ret;
  }

  method generate_drv { # XXX: This should return a PerlPackages::Drv object instead?
    my $template = ';
  <%= $attrname %> = <%= $build_fun %> {
  }
';

  }

}
