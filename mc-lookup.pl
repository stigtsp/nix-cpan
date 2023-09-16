#!/usr/bin/env perl

use v5.38;
use lib qw(lib);
use Nix::MetaCPANCache;
use Cpanel::JSON::XS qw(encode_json);

my $distro = $ARGV[0] || die "$0 <distribution>\n";


my $mc = Nix::MetaCPANCache->new();
say encode_json( $mc->get_by_distribution($distro)->data );
