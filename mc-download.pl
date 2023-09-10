#!/usr/bin/env perl

use v5.38;
use lib qw(lib);
use Nix::MetaCPANCache;
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init({
  level => $INFO
});


my $mc = Nix::MetaCPANCache->new();

$mc->update;
