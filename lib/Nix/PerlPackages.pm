use v5.38;
use strict;
use experimental qw(class);


class Nix::PerlPackages {
  use Log::Log4perl qw(:easy);
  use Nix::PerlPackages::Drv;
  field $nix_file          :param;
  field $nix_file_contents = undef;
  field @drvs;

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
    # TODO: Make parsing more proper
    @drvs = ();

    open(my $fh, "<", $nix_file) || die $!;

    my $attr = {};
    my %in;
    my $i = 0;

    my $start = time();
    $nix_file_contents="";
    while (my $l = <$fh>) {
      $nix_file_contents .= $l;
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

  method update_inplace($drv) {
    my $buf = $nix_file_contents;

    my $old = $drv->orig_part;
    my $new = $drv->part;

    # use Data::Dumper;
    # die Dumper($old, $new);

    $buf =~ s/\Q$old\E/$new/gs;

    open my $wh, ">", $nix_file;
    print $wh $buf;
    close $wh;

    $self->parse_nix_file;

  }

}
