package Nix::Util;

use v5.38;
use feature qw(signatures);
use Exporter qw(import);
use Math::BigInt;
use Smart::Comments -ENV;
use MIME::Base64;
use Log::Log4perl qw(:easy);

our @EXPORT_OK = qw(sha256_hex_to_sri distro_name_to_attr license_map render_license attr_is_reserved);

sub sha256_hex_to_sri ($hex) {
    my $num = Math::BigInt->new("0x$hex")->to_bytes();
    return "sha256-" . encode_base64( $num, "" );
}

sub distro_name_to_attr ($distro) {
    # Converts perl ditribution or module names to nix attribute
    die "no \$distro_name" unless $distro;
    $distro=~ s/[:-]//g;
    return $distro;
}



sub license_map ($cpan_license) {
    my %LICENSE_MAP = (

        # The Perl 5 License (Artistic 1 & GPL 1 or later).
        perl_5 => {
            licenses => [qw( artistic1 gpl1Plus )]
        },

        # GNU Affero General Public License, Version 3.
        agpl_3 => {
            licenses => [qw( agpl3Plus )],
            amb      => 1
        },

        # Apache Software License, Version 1.1.
        apache_1_1 => {
            licenses => ["Apache License 1.1"],
            in_set   => 0
        },

        # Apache License, Version 2.0.
        apache_2_0 => {
            licenses => [qw( asl20 )]
        },

        # Artistic License, (Version 1).
        artistic_1 => {
            licenses => [qw( artistic1 )]
        },

        # Artistic License, Version 2.0.
        artistic_2 => {
            licenses => [qw( artistic2 )]
        },

        # BSD License (three-clause).
        bsd => {
            licenses => [qw( bsd3 )],
            amb      => 1
        },

        # FreeBSD License (two-clause).
        freebsd => {
            licenses => [qw( bsd2 )]
        },

        # GNU Free Documentation License, Version 1.2.
        gfdl_1_2 => {
            licenses => [qw( fdl12 )]
        },

        # GNU Free Documentation License, Version 1.3.
        gfdl_1_3 => {
            licenses => [qw( fdl13 )]
        },

        # GNU General Public License, Version 1.
        gpl_1 => {
            licenses => [qw( gpl1Plus )],
            amb      => 1
        },

        # GNU General Public License, Version 2. Note, we will interpret
        # "gpl" alone as GPL v2+.
        gpl_2 => {
            licenses => [qw( gpl2Plus )],
            amb      => 1
        },

        # GNU General Public License, Version 3.
        gpl_3 => {
            licenses => [qw( gpl3Plus )],
            amb      => 1
        },

        # GNU Lesser General Public License, Version 2.1. Note, we will
        # interpret "gpl" alone as LGPL v2.1+.
        lgpl_2_1 => {
            licenses => [qw( lgpl21Plus )],
            amb      => 1
        },

        # GNU Lesser General Public License, Version 3.0.
        lgpl_3_0 => {
            licenses => [qw( lgpl3Plus )],
            amb      => 1
        },

        # MIT (aka X11) License.
        mit => {
            licenses => [qw( mit )]
        },

        # Mozilla Public License, Version 1.0.
        mozilla_1_0 => {
            licenses => [qw( mpl10 )]
        },

        # Mozilla Public License, Version 1.1.
        mozilla_1_1 => {
            licenses => [qw( mpl11 )]
        },

        # OpenSSL License.
        openssl => {
            licenses => [qw( openssl )]
        },

        # Q Public License, Version 1.0.
        qpl_1_0 => {
            licenses => [qw( qpl )]
        },

        # Original SSLeay License.
        ssleay => {
            licenses => ["Original SSLeay License"],
            in_set   => 0
        },

        # Sun Internet Standards Source License (SISSL).
        sun => {
            licenses => ["Sun Industry Standards Source License v1.1"],
            in_set   => 0
        },

        # zlib License.
        zlib => {
            licenses => [qw( zlib )]
        },

        # Other Open Source Initiative (OSI) approved license.
        open_source => {
            licenses => [qw( free )],
            amb      => 1
        },

        # Requires special permission from copyright holder.
        restricted => {
            licenses => [qw( unfree )],
            amb      => 1
        },

        # Not an OSI approved license, but not restricted. Note, we
        # currently map this to unfreeRedistributable, which is a
        # conservative choice.
        unrestricted => {
            licenses => [qw( unfreeRedistributable )],
            amb      => 1
        },

        # License not provided in metadata.
        unknown => {
            licenses => [],
            amb      => 1
        }
    );
    return $LICENSE_MAP{$cpan_license};
}

sub render_license {
    my ($cpan_license) = @_;

    return if !defined $cpan_license;

    my $licenses;

    # If the license is ambiguous then we'll print an extra warning.
    # For example, "gpl_2" is ambiguous since it may refer to exactly
    # "GPL v2" or to "GPL v2 or later".
    my $amb = 0;

    # Whether the license is available inside `lib.licenses`.
    my $in_set = 1;

    ### lookup: $cpan_license

    my $nix_license = license_map($cpan_license);
    if ( !$nix_license ) {
        WARN("Unknown license: $cpan_license");
        $licenses = [$cpan_license];
        $in_set   = 0;
    }
    else {
        $licenses = $nix_license->{licenses};
        $amb      = $nix_license->{amb};
        $in_set   = !$nix_license->{in_set};
    }

    my $license_line;

    if ( @$licenses == 0 ) {
        # Avoid defining the license line.
    }
    elsif ($in_set) {
        my $lic = 'lib.licenses';
        if ( @$licenses == 1 ) {
            $license_line = "$lic.$licenses->[0]";
        }
        else {
            $license_line = "with $lic; [ " . join( ' ', @$licenses ) . " ]";
        }
    }
    else {
        if ( @$licenses == 1 ) {
            $license_line = $licenses->[0];
        }
        else {
            $license_line = '[ ' . join( ' ', @$licenses ) . ' ]';
        }
    }

    INFO("license: $cpan_license");
    WARN("License '$cpan_license' is ambiguous, please verify") if $amb;
    return $license_line;
}

sub attr_is_reserved {
    my ($pkg) = @_;

    return $pkg =~ /^(?: assert    |
                         else      |
                         if        |
                         import    |
                         in        |
                         inherit   |
                         let       |
                         rec       |
                         then      |
                         while     |
                         with      )$/x;
}



1;
