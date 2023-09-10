use v5.38;
use strict;
use experimental qw(class multidimensional);

class Nix::PerlDrv {
  use Log::Log4perl qw(:easy);
  use Regexp::Common;
  use Smart::Comments -ENV;

  field $prepart   :param;
  field $attrname  :param;
  field $orig_build_fun :param(build_fun);
  field $orig_part      :param(part);

  field $build_fun;
  field $part;

  ADJUST {
    $build_fun = $orig_build_fun;
    $part      = $orig_part;
  };

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
    $part =~ s/($attr\s*=\s*)$RE{quoted}{-keep};/$1"$val";/g;
  }

  method get_attr ($attr) {
    my $cnt = $part =~ m/$attr\s*=\s*$RE{quoted}{-keep};/;
    my $val = $1;
    return unless defined $val;
    die "get_attr $attr found more than 1 in part: $part" if $cnt>1;
    $val =~ s/^(['"])(.*)\1/$2/;
    return $val;
  }

  method get_attr_list ($attr) {
    ### get_attr_list text: $text
    my ($val) = $part =~ m/ $attr\s*=\s*
                            $RE{balanced}{-parens=>'[]'}
                          /gx;

    return unless $val;

    my @ret = grep { !/^[\[\]]$/ } split(/\s+/, $val);
    ### get_attr_list: @ret
    @ret = sort @ret;
    return @ret;
  }


  method attrname {
    return $attrname;
  }

}
