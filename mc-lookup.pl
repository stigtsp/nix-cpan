#!/usr/bin/env perl

use v5.38;
use lib qw(lib);
use Nix::MetaCPANCache;
use Cpanel::JSON::XS qw(encode_json);


my $mc = Nix::MetaCPANCache->new();
say encode_json( $mc->get_by_distribution("Moose")->data );
