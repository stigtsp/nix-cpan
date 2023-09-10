use v5.38;
use strict;
use experimental qw(class);


class Nix::PerlPackages {
  use Log::Log4perl qw(:easy);
  use Nix::PerlDrv;
  field $nix_file :param;
  field @drvs;

  ADJUST {
    die "$nix_file does not exist" unless -f $nix_file;
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

    while (my $l = <$fh>) {
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
        push @drvs, Nix::PerlDrv->new(
          prepart   => $h->{prepart},
          attrname  => $h->{attrname},
          build_fun => $h->{build_fun},
          part      => $h->{part});
    }
    return @drvs;
  }



}
