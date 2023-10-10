use v5.38;
use strict;
use experimental qw(class multidimensional);

class Nix::PerlPackages::Drv {
  use Log::Log4perl qw(:easy);
  use Nix::Util qw(sha256_hex_to_sri distro_name_to_attr);
  use Regexp::Common;
  use Perl6::Junction qw(any);
  use Smart::Comments -ENV;
  use Text::Diff;

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
    $part =~ s/($attr\s*=\s*)"$old_val";/$1"$val";/g;
  }

  method get_attr ($attr, $str=$part) {
    my $cnt = $str =~ m/$attr\s*=\s*$RE{quoted}{-keep};/;
    my $val = $1;
    return unless defined $val;
    die "get_attr $attr found more than 1 in part: $part" if $cnt>1;
    $val =~ s/^(['"])(.*)\1/$2/;
    return $val;
  }

  method get_attr_list ($attr, $str=$part) {
    ### get_attr_list text: $text
    my ($val) = $str =~ m/ $attr\s*=\s*
                           $RE{balanced}{-parens=>'[]'};
                         /gx;

    return unless $val;

    my @ret = grep { !/^[\[\]]$/ } split(/\s+/, $val);
    ### get_attr_list: @ret
    @ret = sort @ret;
    return @ret;
  }

  method set_attr_list ($attr, @vals) {
    # my @has = $self->get_attr_list($attr, $str);
    my $attr_str = "[ ". join(" ", sort @vals)." ]";
    $part=~s/$attr\s*=\s*$RE{balanced}{-parens=>'[]'}/$attr = $attr_str/;
  }

  method version {
    return $self->get_attr("version");
  }

  method name {
    return $self->get_attr("name");
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

  method part {
    return $part;
  }

  method update_from_metacpan ($mc) {
    my $version = $mc->version;
    my $hash    = sha256_hex_to_sri($mc->checksum_sha256);
    my $url     = $mc->download_url;

    $url =~ s|^https://cpan.metacpan.org/|mirror://cpan/|;

    $self->set_attrs(
      version => $version,
      url     => $url,
      hash    => $hash,
    );

    my $buildInputs           = $mc->dependency(qw(build configure test));
    my $propatatedBuildInputs = $mc->dependency(qw(runtime));


    warn diff \$orig_part, \$part;
  }

  method git_message {
    if ($self->dirty) {
      my $prev_ver = $self->get_attr("version", $orig_part);
      my $new_ver  = $self->get_attr("version");
      return "perlPackages." . $self->attrname . ": $prev_ver -> $new_ver";
    }
    return;
  }


}
