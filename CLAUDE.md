# CLAUDE.md

You are a Perl and Nix/NixOS expert.

## What this is

`nix-cpan` is a Perl CLI that **automates maintaining the Perl package set in
nixpkgs** (`pkgs/top-level/perl-packages.nix`). It compares each
`buildPerlPackage`/`buildPerlModule` derivation in that file against a local
mirror of MetaCPAN release data, then surgically rewrites version / url / hash /
dependency stanzas in place and produces nixpkgs-style commits
(`perlPackages.Foo: 1.0 -> 1.1`). It is the spiritual successor to `cpan2nix`,
and inherits that tool's hand-curated errata.

The intended end product is commits/PRs against a nixpkgs checkout, so the tool
deliberately refuses to run `--commit` on a `main`/`master` branch and on a
dirty target file (see `git_sanity`).

## Big picture / data flow

```
                  refresh                          compare / update / generate_missing
  MetaCPAN API ─────────────┐                ┌──────────────────────────────────────┐
  (release{status:latest})  │                │                                       │
  CPAN 02packages index ────┤                ▼                                       ▼
                            ▼          perl-packages.nix ──parse──> Drv objects   Errata.yaml
                     SQLite cache  ◄──get_by/resolve_module──┐         │           (fixups for
                     (~/.cache/nix-cpan/                     │         │            MetaCPAN gaps)
                       metacpan-cache.db)                Release ◄─────┘
                       releases / provide / dependency   objects
                                                            │
                                          surgical in-place text rewrite of the
                                          matched derivation block, then nixfmt
```

Two worlds meet in the comparison: a **`Drv`** (parsed *out of* the existing nix
file) and a **`Release`** (the latest data *from* MetaCPAN). `update_from_metacpan`
copies fields from the Release onto the Drv's raw text.

## Module map

- **`nix-cpan.pl`** — the `Applify`-based CLI and all command logic. Subcommands:
  - `refresh` — rebuild the local SQLite cache from the MetaCPAN API + CPAN 02packages.
  - `compare [attrs...]` — report outdated derivations. `--report` buckets by risk
    (safe / moderate / high, by count of dependency changes); `--report_missing`
    lists deps not yet in the file; `--all` shows no-ops too.
  - `update [attrs...]` — bump derivations. `--inplace` writes, `--commit` commits
    (one commit per attr), `--diff` previews, `--missing` also appends stanzas for
    absent deps, `--deps_only` refreshes only dependency lists.
  - `generate_missing [attrs...]` — emit `buildPerl*` stanzas for missing deps
    (`--inplace` appends to nix_file, else writes `--out`).
  - Also holds the git helpers (`git_sanity`, `git_cmd`, `git_file_dirty`), the
    `render_generated_drv` stanza renderer, and `nixfmt` invocation.

- **`lib/Nix/PerlPackages.pm`** — parses `perl-packages.nix` into `Drv` objects and
  performs in-place file writes. Has a **proper parser** (`_mask_nix_line` blanks
  out strings/comments so braces are counted correctly) and a legacy
  brace-counting parser kept for comparison (`NIX_CPAN_LEGACY_PARSER=1`).

- **`lib/Nix/PerlPackages/Drv.pm`** — one derivation as *raw text plus accessors*.
  All setters edit the text via regex. Distinguishes **top-level attrs**
  (depth-tracked, so a nested `version =` inside an override isn't touched) from
  naive ones. Handles `buildPerlPackage` ↔ `buildPerlModule` switching.

- **`lib/Nix/MetaCPANCache.pm`** — the SQLite cache. Tables: `releases`,
  `provide` (module→distribution), `dependency`. `resolve_module` is the heart of
  dependency resolution: errata override → `main_module` → `provide` table →
  derived distribution guess.

- **`lib/Nix/MetaCPANCache/Release.pm`** — one cached release. `dependency()`
  filters by phase/relationship, drops core modules (`Module::CoreList`), applies
  ignore/deny lists (e.g. Win32), and resolves each dep to a Release.
  `build_inputs`/`propagated_build_inputs` map deps to nix attrnames and merge in
  errata extras. `preferred_build_fun` decides Package vs Module.

- **`lib/Nix/PerlPackages/Errata.yaml`** (+ `Errata.pm` loader) — hand-curated
  fixups for things MetaCPAN metadata gets wrong or omits:
  `extraBuildDependencies`, `extraRuntimeDependencies`, `buildFunctionOverrides`,
  `moduleResolutionOverrides`, `ignoreModule`. Keep it human-editable; comments
  are intentional.

- **`lib/Nix/Util.pm`** — pure helpers: `sha256_hex_to_sri`,
  `distro_name_to_attr` (`Foo-Bar` → `FooBar`), CPAN→nix `render_license`,
  `attr_is_reserved`.

- **`mc-download.pl` / `mc-lookup.pl`** — tiny scripts to refresh the cache and
  dump a single distribution's cached JSON.

## Running things — always via nix-shell

Dependencies (Log::Log4perl, Applify, DBD::SQLite, MetaCPAN::Client, etc.) live
only inside the nix-shell defined by `shell.nix`. Running bare on the host fails
with `Can't locate ...`. `.envrc` (`use nix`) makes direnv load the same shell.

```sh
# Test suite (this is what CI runs)
nix-shell --run "prove -lv t/"

# Lint (CI runs perlcritic on the CLI)
nix-shell --run "perlcritic nix-cpan.pl"

# The tool itself (point --nix_file at a nixpkgs checkout)
nix-shell --run "perl nix-cpan.pl refresh"
nix-shell --run "perl nix-cpan.pl --nix_file /path/to/nixpkgs/pkgs/top-level/perl-packages.nix compare --report"
nix-shell --run "perl nix-cpan.pl --nix_file ... update --diff Mojolicious"
```

`nixfmt` is **required** for any write/commit path; the tool dies if it's
missing. The test fixture `t/bin/nixfmt` stubs it for tests.

### Running the packaged tool via the flake

`flake.nix` packages the tool (script + `lib/` + Perl deps + `nixfmt`/`git`
wrapped in) so it runs with no dev shell:

```sh
nix run .# -- compare --report --nix-file /path/to/nixpkgs/pkgs/top-level/perl-packages.nix
nix run github:stigtsp/nix-cpan -- auto --risk safe --commit --nix-file ...
```

`packages.default`/`apps.default` = the tool; `devShells.default` = `shell.nix`.
The Perl dep set is shared via `perl-deps.nix` (imported by both `package.nix`
and `shell.nix`) so they can't drift. `nix-build` is taken from the ambient PATH
(you're already running via nix); `nixfmt` is pinned by the flake for treefmt
parity. The bundled `Errata.yaml` is read-only in the store, so the
errata-*mutation* subcommands (`errata --prune`, `diagnose --apply`) need a
**writable copy**: pass `--errata-file /path/to/copy.yaml` (or set
`NIX_CPAN_ERRATA_FILE`). Read-only use (`compare`/`update`/`auto`/`errata` audit)
works against the bundled errata with no extra flags. `--errata-file` /
`NIX_CPAN_ERRATA_FILE` also let you maintain your own errata anywhere; both feed
`Nix::PerlPackages::Errata::set_errata_file`, which the lazily-loaded errata
singleton honours.

## Conventions, invariants & gotchas

- **Perl 5.42 (`use v5.42;`)** — the version baseline. `use v5.42` already turns
  on `strict`, `warnings`, signatures, `say`, postfix deref, `try`/`catch`,
  for-list, and chained comparisons, so files don't repeat those pragmas. It also
  enables `source::encoding "ascii"`, so **keep source ASCII** (no Unicode in
  comments/strings — use `--`, `->`, etc.). The native `class` feature
  (`field`/`method`/`ADJUST`, `:param`, `:reader`) still needs
  `use experimental qw(class)`; Drv also needs `multidimensional` for
  Regexp::Common's `$RE{balanced}{-parens=>'[]'}`. Trivial field accessors use
  `field $x :param :reader;` rather than hand-written methods. Not Moose/Moo.
- **In-place edits must match exactly once.** `update_inplace` substitutes the
  old derivation block for the new one and *dies if the match count isn't 1*.
  This is a safety invariant — don't loosen it.
- **The parser is line-oriented and hand-rolled** on purpose (no real Nix
  grammar). The string/comment masker and brace counter live in `Nix::Util`
  (`mask_nix_line`, `brace_delta`) as the single source of truth; `PerlPackages`
  and `Drv` delegate to them. Test parser behavior in `t/15_parser_modes.t`.
- **Tests use mocked release data**, never the network — they build a temp
  SQLite cache via `write_releases` (see `t/05_dependency_resolution.t`) and run
  the CLI through `t/lib/Test/CommandUtil.pm` (`run_nix_cpan`) with an isolated
  `XDG_CACHE_HOME` and `t/bin` on PATH. Follow this pattern for new tests; do not
  add tests that hit MetaCPAN.
- **Dependency resolution dies loudly** on an unresolvable module — the fix is
  usually a `moduleResolutionOverrides`/extra-dep entry in `Errata.yaml`, not a
  silent skip.
- **Cache location**: `~/.cache/nix-cpan/` (via `File::XDG`) — `metacpan-cache.db`,
  `metacpan-download-cache.jsonl.gz`, `cpan-02packages.details.txt.gz`.
- The `ng` branch is where significant improvements are developed; `README.md` is
  a stale TODO list and not a reliable description of current behavior.
