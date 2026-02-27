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
    $part =~ s/($attr\s*=\s*)"\Q$old_val\E";/$1"$val";/g;
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

  method has_attr_assignment($attr, $str=$part) {
    return $str =~ /$attr\s*=/ ? 1 : 0;
  }

  method attr_list_is_simple($attr, $str=$part) {
    my ($expr) = $str =~ m/$attr\s*=\s*(.*?);/s;
    return 0 unless defined $expr;
    return $expr =~ /^\s*\[[^\]]*\]\s*$/s ? 1 : 0;
  }

  method set_or_add_attr_list($attr, @vals) {
    my @sorted = sort @vals;

    if ($self->attr_list_is_simple($attr)) {
      if (@sorted) {
        $self->set_attr_list($attr, @sorted);
      }
      return;
    }
    return if $self->has_attr_assignment($attr); # keep complex expressions untouched
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

    my @build_inputs = $mc->build_inputs();
    my @existing_build_inputs = $self->build_inputs();
    push @build_inputs,
      grep { /^pkgs\./ } @existing_build_inputs;
    $self->set_or_add_attr_list("buildInputs", @build_inputs);

    my @propagated_build_inputs = $mc->propagated_build_inputs();
    my @existing_propagated_build_inputs = $self->propagated_build_inputs();
    push @propagated_build_inputs,
      grep { /^pkgs\./ } @existing_propagated_build_inputs;
    $self->set_or_add_attr_list("propagatedBuildInputs", @propagated_build_inputs);
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
