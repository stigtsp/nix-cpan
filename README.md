# nix-cpan

A mechanical updater for the Perl package set in nixpkgs
(`pkgs/top-level/perl-packages.nix`). It compares each derivation against a local
MetaCPAN mirror and rewrites version / source / hash / dependencies / description,
build-gating each change and committing one package per commit.

No AI/LLM at runtime — it's deterministic Perl.

## Setup

Build the local MetaCPAN cache once (slow; downloads CPAN release data):

```sh
nix run github:stigtsp/nix-cpan -- refresh
```

Re-run `refresh` whenever you want fresher data.

## Examples

`--nix-file` points at a nixpkgs checkout (default:
`pkgs/top-level/perl-packages.nix`). The examples use a shell variable for it:

```sh
NF=~/nixpkgs/pkgs/top-level/perl-packages.nix
alias nix-cpan='nix run github:stigtsp/nix-cpan --'
```

```sh
# What's outdated, bucketed by risk (safe / moderate / high)
nix-cpan compare --report --nix-file $NF

# Preview one bump without touching anything
nix-cpan update --diff Mojolicious --nix-file $NF

# Bump every package with no dependency changes, build each, commit the ones
# that pass (skips/reverts the rest):
nix-cpan auto --risk safe --commit --nix-file $NF

# Include packages with small dependency changes too:
nix-cpan auto --risk moderate --commit --nix-file $NF

# Dry run (verify, don't commit) and write a YAML report:
nix-cpan auto --risk safe --report-file report.yaml --nix-file $NF

# Generate stanzas for dependencies nixpkgs doesn't have yet:
nix-cpan generate_missing --inplace --nix-file $NF

# Audit the errata file against the cache; --prune removes the provably-redundant
# (uncommented) entries:
nix-cpan errata
nix-cpan errata --prune

# A build failed — see which missing module to add to errata:
nix-cpan diagnose SomePackage --nix-file $NF
```

`auto` is build-gated: it never commits a bump that fails to build, never leaves
the tree dirty, refuses to run on `main`/`master` or with uncommitted changes, and
makes one `perlPackages.X: old -> new` commit per package.

## Development

```sh
nix-shell --run "prove -lv t/"        # tests
nix-shell --run "perlcritic nix-cpan.pl"
```

Requires Perl 5.42. See `CLAUDE.md` for architecture and `PLAN.ng.md` for design
notes.
