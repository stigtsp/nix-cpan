package Nix::PerlPackages::Errata;

use v5.42;
use Exporter 'import';
use File::Basename qw(dirname);
use CPAN::Meta::YAML;

our @EXPORT_OK = qw(errata errata_file set_errata_file);
our $errata;
our $errata_file_override;

# Point the loader at a different Errata.yaml (e.g. a writable copy when the
# bundled one is read-only in the nix store). Clears the cached singleton so the
# next errata() reads the new path. The CLI's --errata-file calls this; the
# NIX_CPAN_ERRATA_FILE env var is also honoured.
sub set_errata_file {
    $errata_file_override = shift;
    undef $errata;
    return $errata_file_override;
}

sub errata_file {
    return $errata_file_override
      if defined $errata_file_override && length $errata_file_override;
    return $ENV{NIX_CPAN_ERRATA_FILE}
      if defined $ENV{NIX_CPAN_ERRATA_FILE} && length $ENV{NIX_CPAN_ERRATA_FILE};
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
