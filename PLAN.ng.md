# PLAN.ng — making nix-cpan a bulk perlPackages updater

> Living planning document for the `ng` branch. Append findings and decisions as
> we go; a future Claude/agent should be able to reconstruct *why* from this file
> alone. Keep entries dated (today is 2026-06-26).

## Mission / north star

A `nix-cpan` that can **automatically bump every package in nixpkgs'
`pkgs/top-level/perl-packages.nix`** — version, source, hash, dependencies,
license, description — correctly and without munging hand-written special-cases
(macOS/platform conditionals, `doCheck`, `broken`, patch phases). End state:
the tool is reliable enough to run unattended as an updater script / bot.

## Goals

- Bump version + `src.url` + `src.hash` for all updatable derivations.
- Keep dependency lists (`buildInputs` / `propagatedBuildInputs`) in sync with
  *actual* build/runtime needs — not blindly with what MetaCPAN/CPAN metadata
  claims (that's what errata exists to correct).
- Update `meta` (license, description, homepage) in the same commit as the bump.
- **One commit per package**, containing *all* of that package's own changes
  (version/src/hash + deps + meta). New dependency packages land as separate
  `perlPackages.X: init at <version>` commits.
- Verify with real `nix` evaluation and builds, not just self-tests.
- Manage errata as a living, build-driven dataset (add from failures, prune the
  obsolete where tests permit).
- Produce an updater-script entry point suitable for automation.

## Non-goals (for now)

- A general-purpose Nix parser/formatter. We rely on nixfmt-canonical input.
- Rewriting derivations that use complex/conditional input lists (`++
  lib.optionals …`) — these are detected and **skipped**, not mangled (tracked).
- Updating packages not sourced from CPAN, or with non-`fetchurl` sources.
- Touching `doCheck`/`broken`/patch logic — these are human decisions.

## Ratified decisions (ADR-style)

### D1 — Parser: harden the line-based locator + use `nix eval` for authoritative reads
**Decision:** Keep the existing line-based parser for *locating* and *editing*
derivation blocks. Use `nix eval` as the authoritative reader for verification
(computed version, resolved buildInputs after conditionals). Adopt a CST parser
(tree-sitter-nix / rnix) **only if** a concrete munging bug appears that the
line-based approach cannot handle safely.
**Rationale:** Spike on the real file (2026-06-26): **1911/1911** parsed blocks
match exactly once — no gaps/overlaps/bleed; no duplicate attrnames; version/src
edits preserved every `++ lib.optionals` suffix. Boundary detection is *not* the
weak point. A CST rewrite adds a non-Perl build dependency and large up-front
cost for a problem we have not yet hit.
**Recall verified (2026-06-26):** of all top-level `X = buildPerl(Package|Module)`
definitions, **0** are missed by the parser; it additionally catches the 2
hyphenated attrs (`constant-defer`, `libintl-perl`) that a `\w+`-only grep misses.
So recall — the killer failure mode for a "bulk update *all*" tool — is full.
**Alternatives rejected:** (a) Grammar/CST now — premature given the data.
(b) Eval-and-regenerate whole stanzas — reformats and destroys hand-written
conditionals/comments; unacceptable for the macOS special-cases.
**Risk owned:** read (eval) and write (text) are different problems; a passing
edit must still be validated by eval/build, never assumed from the text diff.

### D2 — nixfmt: pin the nixpkgs formatter, format the whole file
**Decision:** Add `pkgs.nixfmt` to `shell.nix`; the updater runs whole-file
`nixfmt` (as the tool already does) after edits. **Region-only formatting is NOT
needed** and is rejected.
**Rationale (resolved 2026-06-26):** Two facts settled this.
(1) `~/nixpkgs` pins **nixfmt 1.3.1**, identical to the version the dev
shell's channel provides — so the dev-shell nixfmt has exact CI parity; no need to
build nixfmt from the target tree.
(2) `nixfmt - < perl-packages.nix | diff - perl-packages.nix` = **0 lines** — the
file is already nixfmt-canonical (CI treefmt-enforced). So whole-file nixfmt is a
no-op on untouched lines and only the real edit appears in the diff. Whole-file is
therefore *simpler and lower-risk* than region-only (which carried a
byte-identical-reproduction risk, now moot).
**Note:** the tool invokes `nixfmt <file>` (file arg, formats in place) — the
non-deprecated form. Only bare-stdin `nixfmt` is deprecated in 1.3.1.
**Status:** Bug #1 fixed (nixfmt added to shell.nix; `nixfmt --version` → 1.3.1).

### D3 — Sequencing: curated safe batch first, then expand
**Phase 1** version+hash-only bumps (no dep changes) on a curated batch, verified
end-to-end with nix builds → **Phase 2** dependency + errata management →
**Phase 3** meta updates folded in → **Phase 4** bot/updater script.
**Rationale:** De-risks the write/commit/build loop before layering the hard
actual-vs-metadata dependency problem on top.

### D4 — New dependency derivations get their own `init at V` commits
**Decision:** A bump's own changes are one commit. Any *new* dependency package it
pulls in is a separate `perlPackages.X: init at <version>` commit.
**Rationale:** Matches nixpkgs convention; keeps per-package bump commits clean.
**Gap to fix:** current code emits a combined `perlPackages: add remaining
missing deps` commit (nix-cpan.pl ~600-622) — violates this; must change to
per-package init commits.

## Commit-shape requirement (from user, 2026-06-26)

One commit per package bump = **all** of that package's changes together:
version + src + hash + dependency-list changes + license + description. This
means the updater must apply meta (license/description/homepage) updates in the
same pass as the version bump — see Bug #4 (meta not currently updated).

## Verification methodology

Design around the loop's asymmetry — bake these into the tooling:

- **Cheap pre-gate:** `nix eval` the resolved `buildInputs`/`propagatedBuildInputs`
  + version before vs after, to catch unintended changes without building.
- **Build gate:** `nix-build -A perlPackages.<attr>` (in `~/nixpkgs`) for affected
  packages only — 1915 full builds is infeasible per-change.
- **Cheap hash gate (KEY for safe bumps):** `nix-build -A perlPackages.<attr>.src`
  fetches the tarball and verifies the fixed-output hash **without compiling**
  (~0.5–1s each vs minutes). For pure version+src+hash bumps the only failure mode
  is a wrong hash, so the `.src` sweep validates the whole safe batch quickly.
  Verified: all 196 safe bumps pass `.src` (0 hash mismatches).
- **Asymmetry — state it loudly:** a passing build (with `doCheck`) proves deps
  are *sufficient*, never *minimal*. We can detect **missing** deps from build
  failures; we **cannot** detect **obsolete** errata without removing it and
  rebuilding.
- **Blind spot:** `doCheck = false` packages have no test net; their runtime deps
  can't be validated by building. Flag such packages; treat their dep changes as
  unverified.
- **Regression definition:** eval diff shows unintended change, OR build/check
  fails that passed before, OR the runtime closure changes unexpectedly.

## Errata management (build-loop process)

`Errata.yaml` is "hopelessly outdated" (user). Treat it as a build-driven dataset:

- **Adding:** a build failure → identify the missing module → add the minimal
  `extra{Build,Runtime}Dependencies` / `moduleResolutionOverrides` entry → record
  symptom + repro + affected package in the Bug log below.
- **Pruning:** an errata entry is only safely removable by *removing it and
  rebuilding* with tests. Bounded by test coverage — `doCheck = false` packages
  can't have their errata safely pruned. Do not bulk-delete.
- Every applied errata already logs a WARN; consider a `--report-errata` mode to
  surface which entries actually fired during a run (dead-entry detection).

## Roadmap (phased)

- [ ] **P0 — Unblock the loop**
  - [x] Pin `nixfmt` in `shell.nix` (Bug #1) — 1.3.1, matches `~/nixpkgs`.
  - [x] nixfmt strategy (D2) — whole-file; file is already canonical.
  - [x] Confirm `~/nixpkgs` build works: `nix-build ~/nixpkgs -A
        perlPackages.TryTiny` → exit 0 (builds from source; perl 5.42.0).
- [x] **P1 — Safe bulk bumps** (version+src+hash only, deps untouched) — VERIFIED
  - [x] `compare --report`: **456 updates** (safe=196, moderate=220, high=40).
        No dep-resolution failures across all candidates.
  - [x] `update --diff`/`--inplace` on a 3-pkg batch: edits touch only
        version/url/hash; meta untouched; file stays nixfmt-canonical.
  - [x] `nix-build` of 3 full packages: exit 0 — MetaCPAN hashes correct, sources
        build with tests.
  - [x] `--commit` on a fresh reset: **one clean commit per package**, correct
        `perlPackages.X: old -> new` messages, each diff isolated to 1 pkg.
  - [x] Whole safe-196: applied inplace (586/586 line changes, file canonical);
        **hash sweep 196/196 OK, 0 failures** via cheap `.src` gate.
  - [x] Safe-196 version sanity via version.pm: 0 downgrades, 0 scheme-flip
        no-ops, 0 alpha/dev, 0 parse failures — all genuine forward bumps.
  - [x] Full safe-196 `--commit` scale run: **193 clean per-package commits**
        (each single-file, canonical, conforming `perlPackages.X: a -> b` msgs).
        3 not committed — all safe skips, not failures: AlgorithmBackoff (legacy
        `sha256=` form, Bug #9), EV + NetCUPS (`fetchpatch` multi-url, Bug #10).
        Final file nixfmt-canonical. nixpkgs reset to baseline after.
- [ ] **P2 — Dependency + errata management**
  - Scope (measured 2026-06-26): moderate=220, high=40 updates carry dep changes.
    Across moderate+high, **252 distinct added deps**, of which only **23 are not
    already present as attrs** (would need `--missing` stanza generation). So most
    dep work is wiring existing attrs; the genuinely-new surface is small.
    Caveat: some of the 23 may be attr-name-mapping mismatches
    (`distro_name_to_attr` vs nixpkgs casing), not truly missing — verify per case.
    List saved (session scratch): missing_deps.txt.
  - [x] Verify dep changes by build+test on a small moderate batch:
        **DateTimeTimeZone 2.60->2.68** (gains ModuleRuntime,TryTiny) → build+tests
        exit 0; **CGI 4.59->4.72** (gains URI, **drops obsolete TestDeep**) →
        build+tests exit 0 (MetaCPAN's dep removal was correct — strong signal that
        metadata-driven dep updates are buildable). **DBIxClassCandy 0.005003->
        0.005004 → exit 0 too. P2a result: 3/3 moderate dep-updates build + pass
        tests.**
  - [x] src-block-scoped editing (Bug #10) + legacy sha256 (Bug #9) — DONE, lets
        fetchpatch/legacy derivations bump (EV, NetCUPS, AlgorithmBackoff).
  - [ ] Eval-based actual-vs-metadata dep diffing.
  - [ ] Handle complex/conditional input lists (currently skipped — Bug #2, 7 drvs).
  - [x] Errata audit + gated prune — `nix-cpan errata` (+ `--prune`). DONE.
        Classifies extra{Build,Runtime}Dependencies vs the live cache:
        provably-redundant / load-bearing / findings. **28 redundant on the
        current cache = 18 prunable + 10 commented hedges.** `--prune` removes
        only redundant+uncommented (18 applied, hedges retained). Module
        `Errata/Audit.pm` + t/20.
  - [ ] Errata ADD-from-build-failure loop (separate session — needs build runs).
  - [ ] Audit the other 3 buckets: `moduleResolutionOverrides` (redundant if
        `resolve_module` finds it without the override), `buildFunctionOverrides`
        (redundant if `preferred_build_fun` agrees), `ignoreModule` (hardest —
        suppresses a die).
- [ ] **P3 — Meta updates** folded into the same commit (Bug #4).
- [ ] **P4 — Automation**
  - [ ] Updater-script entry point; idempotent, resumable, machine-readable report.
  - [ ] Per-package `init at V` commits for new deps (D4 gap).

## Bug / finding log

> Format: `#N (date) [status] symptom — repro — affected — notes`

- **#1 (2026-06-26) [FIXED] nixfmt missing from dev shell.** `nix-shell --run
  "nixfmt --version"` → `command not found`; tool died in `has_nixfmt` on any
  write/commit. Fixed by adding `pkgs.nixfmt` to `shell.nix` (1.3.1, matches
  `~/nixpkgs`). Verified: `nixfmt --version` → 1.3.1.
- **#2 (2026-06-26) [open, by-design] complex input lists silently skipped.**
  `set_or_add_attr_list` skips any input list that isn't a plain `[ … ]` (e.g. a
  `++ lib.optionals …` suffix). Census across the real file: `buildInputs`
  simple=781 / complex=3 / none; `propagatedBuildInputs` simple=1106 / complex=4 /
  none=801. **7 derivations** have ≥1 skipped input list (not 3). Safe (no
  munging) but their deps won't be auto-managed. Needs explicit handling or a
  reported skip-list in P2 — this is exactly the dependency-management surface the
  user cares about most.
- **#3 (2026-06-26) [open] combined missing-deps commit.** nix-cpan.pl ~600-622
  emits `perlPackages: add remaining missing deps` as one commit — violates D4
  per-package `init at V` commits.
- **#4 (2026-06-26) [open] meta not updated on bump.** `update_from_metacpan`
  updates version/url/hash + dep lists but not `meta` (license/description/
  homepage). User requires these in the same commit. Needs a meta-update path.
- **#5 (2026-06-26) [open] errata stale.** `Errata.yaml` inherited from cpan2nix,
  known outdated. To be managed via the build loop above. Note: `compare --report`
  across all 456 update candidates produced **no resolution failures**, so the
  staleness is likely *wrong/obsolete* entries (inject wrong deps, or no longer
  needed) rather than missing resolutions that crash. Pruning needs the build loop.
- **#6 (2026-06-26) [minor/cosmetic] `--diff` prints "Updating inplace" progress.**
  `update --diff` (no `--inplace`) still emits the Smart::Comments
  `### Updating inplace` progress bar (the loop is shared). Harmless but
  misleading. Low priority.
- **#7 (2026-06-26) [FIXED] version comparison mis-orders dev & scheme-changed
  versions.** `newer_than` used `Sort::Versions::versioncmp` (string-segment),
  giving false "updates": `CatalystPluginAuthentication 0.10_027 -> 0.10026`
  (downgrade), `ZonemasterCLI 8.0.1 -> 8.000001` (equal scheme flip). Fixed
  (commit 08b5dba): `newer_than` parses both with `version.pm`, refuses bumps when
  either side `is_alpha` (dev/trial), compares with Perl version ordering, falls
  back to versioncmp only when unparseable. Gotcha fixed: quote `'version'->parse`
  because the class has a `method version`. Test: t/18_version_compare.t (8 cases).
- **Verification cost note (2026-06-26):** the local store has no binary-cache hit
  for perl 5.42.0, so `nix-build` of a single leaf perl package compiles the perl
  toolchain + test deps from source (many minutes). This makes per-package full
  builds expensive at scale → P2/verification must lean on `nix eval` pre-gates and
  build only a sampled/affected subset, or arrange a substituter.

- **#8 (2026-06-26) [perf, for P4 bot] per-commit whole-file nixfmt dominates
  bulk runtime.** `--commit` runs `format_nix_file` (whole 40k-line nixfmt, ~1-2s)
  before *each* package commit, so a 196-package run takes ~10+ min mostly in
  nixfmt. But surgical version/url/hash edits preserve line structure, so the file
  stays nixfmt-canonical *without* reformatting (observed: inplace edits → file
  already CANONICAL). Likely optimization: skip nixfmt when the edit is a pure
  value substitution, or format once at the end of an inplace batch. Revisit for
  the bot (P4); not a correctness issue.

- **#9 (2026-06-26) [FIXED] legacy `sha256 = "<hex>"` not handled.** Only 2
  derivations (e.g. AlgorithmBackoff). Fixed (commit 0ff804d): src-scoped setter
  detects `sha256` vs `hash` and writes the hex checksum for the legacy form.
  Verified on AlgorithmBackoff (0.009 -> 0.010). Test: t/19.
- **#10 (2026-06-26) [FIXED] derivations with `fetchpatch` skipped.** `patches =
  [ (fetchpatch { url; hash }) ]` created multiple url/hash pairs → `update_attr`
  skipped (no munging) so EV/NetCUPS never bumped. Scope was 34 fetchpatch / 55
  `patches` blocks. Fixed (commit 0ff804d): url/hash edits are scoped to the
  `src = <fetcher> { … }` sub-block via `_src_span_lines`; the fetchpatch block is
  preserved verbatim. Falls back to top-level for src-less fixtures. Verified on
  EV (4.34 -> 4.37) and NetCUPS (0.64 -> 0.65). Test: t/19. Full suite 186 green.
- **#11 (2026-06-26) [open, P2/P3] version-specific patches may not apply after a
  bump.** EV pins `patches = [ EV-4.34-perl-5.42.patch ]`; bumping to 4.37 keeps
  the patch, which may fail to apply or be unnecessary. The mechanical bump is
  correct; patch validity is a separate, *build-detectable* concern. The updater
  should flag (not auto-edit) derivations whose `patches` reference the old
  version, and a build is required to confirm such bumps.

- **#12 (2026-06-26) [key insight] "redundant in cache" ≠ "safe to remove".**
  Some errata extra-deps are *deliberate hedges* against MetaCPAN snapshot
  unreliability — their comments say so ("MetaCPAN can miss module->distribution
  mapping ... in some snapshots"; libwww-perl: "pin distro names"). They look
  redundant against the current cache but protect against incomplete future
  snapshots. Therefore the audit *reports* redundancy but `--prune` only removes
  redundant entries whose dist block has **no comment** (comment = intent signal).
  A proper hedge-vs-stale classifier is out of scope (a comment is the proxy).
- **#13 (2026-06-26) [test fragility] t/05 is coupled to the real Errata.yaml.**
  t/05 asserts specific live errata entries (HTTP-Message:URI, HTML-Parser:*,
  libwww-perl:HTML-Parser) using a *mock cache that omits those deps* — i.e. it
  encodes the hedge behavior. This is why those entries must never be auto-pruned,
  and why "managed errata" makes t/05 brittle. Don't refactor now; if errata
  curation continues, give t/05 its own fixture errata instead of the real file.

## Open questions

- Region-only nixfmt: does it reproduce whole-file nixfmt byte-for-byte? (D2 risk)
- How to detect *obsolete* errata at scale given the removal+rebuild cost?
- `version_numified` vs `Sort::Versions` — are there packages where MetaCPAN's
  "latest" disagrees with what we'd pick? (filter_releases dedup logic)
- Packages with non-`fetchurl` / non-CPAN sources: enumerate and exclude cleanly.
- Updater-script output contract for the future bot (JSON report shape).
