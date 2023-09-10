use v5.38;
use strict;
use experimental qw(class);

class Nix::MetaCPANCache::Release {
  use Cpanel::JSON::XS qw(decode_json);
  use Sort::Versions qw(versioncmp);
  field $name :param;
  field $distribution :param;
  field $main_module :param;
  field $data :param;

  ADJUST {
    unless (!ref($data) && $data =~ /^{/) {
      die "data is expected to be a JSON encoded string";
    }
    $data = decode_json($data);
  };

  method name         { return $name }
  method distribution { return $distribution }
  method main_module  { return $main_module }
  method data         { return $data }


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

  method dependency {
    return $data->{dependency} // [];
  }

  method newer_than ($ver) {
    return versioncmp($self->version, $ver) > 0;
  }

}
