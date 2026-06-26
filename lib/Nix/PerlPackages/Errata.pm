package Nix::PerlPackages::Errata;

use v5.38;
use strict;
use warnings;
use Exporter 'import';
use File::Basename qw(dirname);
use CPAN::Meta::YAML;

our @EXPORT_OK = qw(errata errata_file);
our $errata;

sub errata_file {
    return dirname(__FILE__) . "/Errata.yaml";
}

sub _load_errata {
    my $yaml_file = errata_file();
    my $docs = CPAN::Meta::YAML->read($yaml_file)
      or die "Unable to read errata YAML from $yaml_file";
    my $first = eval { $docs->[0] };
    die "Errata YAML did not contain a document: $yaml_file"
      unless $first && ref($first) eq "HASH";
    return $first;
}

sub errata {
    $errata //= _load_errata();
    return $errata;
}

1;
