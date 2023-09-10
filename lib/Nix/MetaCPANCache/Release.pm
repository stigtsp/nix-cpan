use v5.38;
use strict;
use experimental qw(class);

class Nix::MetaCPANCache::Release {
  use Cpanel::JSON::XS qw(decode_json);
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

  method dependency {
    return $data->{dependency} // [];
  }


}
