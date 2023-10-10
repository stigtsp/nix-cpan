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

    my %seen;
    @deps =
      sort { $a->name cmp $b->name }
      map { $_mcc->get_by(main_module =>  $_->{module}) }
      grep { !$seen{$_->{module}}++ }
      grep { !Module::CoreList::is_core($_->{module}) }
      @deps;
    return [ @deps ];
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

}
