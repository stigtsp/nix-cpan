use v5.42;
use experimental qw(class);


class Nix::PerlPackages {
  use Log::Log4perl qw(:easy);
  use Nix::PerlPackages::Drv;
  use Nix::Util ();
  field $nix_file          :param;
  field $nix_file_contents = undef;
  field @drvs;
  field %all_attrnames;

  ADJUST {
    die "$nix_file does not exist" unless -f $nix_file;
    $self->parse_nix_file();
  };

  method drvs() {
    return @drvs;
  }

  method drv_by_attrname($attr) {
    my ($first) = grep { $_->attrname eq $attr } @drvs;
    return $first;
  }

  method parse_nix_file() {
    if ($ENV{NIX_CPAN_LEGACY_PARSER}) {
      return $self->parse_nix_file_legacy();
    }
    return $self->parse_nix_file_proper();
  }

  method parse_nix_file_proper() {
    @drvs = ();
    %all_attrnames = ();

    open(my $fh, "<", $nix_file) || die $!;

    my $attr = {};
    my %in;
    my $i = 0;
    my %scan_state = (
      in_block_comment => 0,
      in_dquote        => 0,
      in_squote        => 0,
    );

    $nix_file_contents = "";
    while (my $l = <$fh>) {
      $nix_file_contents .= $l;

      my $masked = $self->_mask_nix_line($l, \%scan_state);

      if ($l =~ /^  ([\w-]+)\s*=/) {
        $all_attrnames{$1} = 1;
      }
      if ($l =~ m/(\s+)(([\w-]+)\s+=\s+buildPerl(Package|Module)\s+(?:rec)?\s*)\{/) {
        %in = (
          ws          => $1,
          prepart     => $2,
          attrname    => $3,
          build_fun   => $4,
        );
        DEBUG("parse_nix_file_proper: Found $in{attrname}");
      } elsif (%in && $l =~ m/^$in{ws}\};/) {
        DEBUG("parse_nix_file_proper: Found end of $in{attrname}");
        %in = ();
      } elsif (%in) {
        DEBUG("parse_nix_file_proper: Line $i to $in{attrname} ## $l");
        my $h = $attr->{ $in{attrname} } //= { %in };
        push @{$h->{lines}}, [$i, $l];
        $h->{part} .= $l;
      }
      $i++;
    }
    close $fh;

    foreach my $k (sort keys %$attr) {
      my $h = $attr->{$k};
      push @drvs, Nix::PerlPackages::Drv->new(
        prepart   => $h->{prepart},
        attrname  => $h->{attrname},
        build_fun => $h->{build_fun},
        part      => $h->{part});
    }
    return @drvs;
  }

  method parse_nix_file_legacy() {
    # TODO: Make parsing more proper
    @drvs = ();
    %all_attrnames = ();

    open(my $fh, "<", $nix_file) || die $!;

    my $attr = {};
    my %in;
    my $i = 0;
    my $depth = 0;

    $nix_file_contents = "";
    while (my $l = <$fh>) {
      $nix_file_contents .= $l;
      if ($depth == 1 && $l =~ /^\s{2}([\w-]+)\s*=/) {
        $all_attrnames{$1} = 1;
      }
      if ($l=~m/(\s+)(([\w-]+)\s+=\s+buildPerl(Package|Module)\s+(?:rec)?\s*)\{/) {
        %in = (
          ws          => $1,
          prepart     => $2,
          attrname    => $3,
          build_fun   => $4,
      );
        DEBUG("parse_nix_file: Found $in{attrname}");
      } elsif ( %in && $l =~ m/^$in{ws}\};/ ) {
        DEBUG("parse_nix_file: Found end of $in{attrname}");
        %in = ();
      } elsif ( %in ) {
        DEBUG("parse_nix_file: Line $i to $in{attrname} ## $l");
        my $h = $attr->{ $in{attrname} } //= { %in };
        push @{$h->{lines}}, [$i, $l];
        $h->{part} .= $l;
      }
      my $open_cnt = () = ($l =~ /\{/g);
      my $close_cnt = () = ($l =~ /\}/g);
      $depth += $open_cnt - $close_cnt;
      $i++;
    }
    close $fh;

    foreach my $k (sort keys %$attr) {
        my $h = $attr->{$k};
        push @drvs, Nix::PerlPackages::Drv->new(
          prepart   => $h->{prepart},
          attrname  => $h->{attrname},
          build_fun => $h->{build_fun},
          part      => $h->{part});
    }
    return @drvs;
  }

  method _mask_nix_line($line, $st) { return Nix::Util::mask_nix_line($line, $st); }

  method all_attrnames() {
    return keys %all_attrnames;
  }

  method update_inplace($drv, %opt) {
    my $buf = $nix_file_contents;
    my $parse_after = exists $opt{parse_after} ? $opt{parse_after} : 1;

    if ($drv->build_fun_changed) {
      my $old_pre = $drv->prepart;
      my $new_pre = $drv->prepart_for_current_build_fun;
      my $count_pre = () = ($buf =~ /\Q$old_pre\E\{/gs);
      if ($count_pre != 1) {
        die "update_inplace expected exactly one build-fun match for ".$drv->attrname.", got $count_pre";
      }
      $buf =~ s/\Q$old_pre\E\{/$new_pre\{/s;
    }

    my $old = $drv->orig_part;
    my $new = $drv->part;

    # use Data::Dumper;
    # die Dumper($old, $new);

    my $count = () = ($buf =~ /\Q$old\E/gs);
    if ($count != 1) {
      die "update_inplace expected exactly one match for ".$drv->attrname.", got $count";
    }
    $buf =~ s/\Q$old\E/$new/s;

    open my $wh, ">", $nix_file;
    print $wh $buf;
    close $wh;

    $nix_file_contents = $buf;
    $self->parse_nix_file if $parse_after;

  }

}
