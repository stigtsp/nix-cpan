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

## Status snapshot (2026-06-27)

Full updater lifecycle built, tested (**256 tests green**), and validated against
real `~/nixpkgs` builds. Subcommands: `compare`, `update` (bumps + deps incl.
conditional lists), `generate_missing`, `errata` (audit/prune all 5 buckets),
`diagnose` (errata add-from-failure), **`auto`** (build-gated bot updater with
JSON report). 23 commits on `ng`; nothing committed in `~/nixpkgs`.

Bugs found+fixed this run: #1 nixfmt missing; #7 version-compare (dev/scheme);
#9 legacy sha256; #10 fetchpatch src-scoping; #2 conditional input lists;
#16 generate_missing `--out` fragment; #17 compare/generate_missing exit codes.
Open: #15 (buildInputs==propagatedBuildInputs — likely metadata-real, confirm).
Deferred: failure quarantine, `init at V` commits for new deps, broad
moderate/high runs, license-on-generated-stanzas.

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
  - [x] Handle complex/conditional input lists (Bug #2) — `[ base ] ++ cond`
        base now updated, conditional preserved; other shapes WARN + skip.
  - [x] Errata audit + gated prune — `nix-cpan errata` (+ `--prune`). DONE.
        Classifies extra{Build,Runtime}Dependencies vs the live cache:
        provably-redundant / load-bearing / findings. **28 redundant on the
        current cache = 18 prunable + 10 commented hedges.** `--prune` removes
        only redundant+uncommented (18 applied, hedges retained). Module
        `Errata/Audit.pm` + t/20.
  - [x] Errata ADD-from-build-failure — `nix-cpan diagnose <attr>` (+ `--apply`,
        `--log`). DONE. Builds the derivation, parses "Can't locate Foo/Bar.pm in
        @INC (you may need to install the Foo::Bar module)", resolves each missing
        module to an attr, and classifies: **metadata-misses → suggest
        extraBuildDependencies errata** (`--apply` writes it surgically);
        **metadata-has-it → STALE, recommend `update --deps_only`** (not errata);
        core/unresolvable → findings. Module `Errata/Suggest.pm` + t/21.
  - [x] Audit the other 3 buckets — DONE (commit cd7f339). `errata` now reports:
        **buildFunctionOverrides** (redundant iff `build_fun_from_metadata` ==
        forced; Dist-Build is load-bearing — metadata undecided);
        **ignoreModule** (redundant iff core, since dependency() checks ignore
        before the core filter; all 9 load-bearing — each excludes a resolvable
        dep, shown with the excluded attr); **moduleResolutionOverrides** (none
        configured). Report-only — nothing prunable on current data (correct).
        Split `preferred_build_fun` -> `build_fun_from_metadata`. t/20 extended.
- [x] **Generate missing dependency packages** (`generate_missing`) — VERIFIED.
      Against the real file it generates **27 stanzas** (the 23 first-level missing
      deps + transitive ones found via BFS, e.g. GetoptYath, LogReportOptional,
      KeywordSimple). Stanzas are correct and **build**: Heap, XMLTiny (leaf),
      DateTimeFormatDateManip, Test2PluginIOEvents (with deps) → all exit 0.
      Payoff: with them appended, the previously-blocked **AppMusicChordPro**
      (6.050.7 → 6.101.0) now fully updates (HarfBuzzShaper/JavaScriptQuickJS
      resolve; the `++ lib.optionals (!isDarwin) [ Wx ]` conditional preserved).
      Fixed two bugs found en route (#16 --out fragment, #17 exit codes).
      Note: generated stanzas may lack `license` when MetaCPAN has none (e.g.
      Heap) — minor quality gap for nixpkgs review.
- [ ] **P3 — Meta updates** folded into the same commit (Bug #4).
- [x] **P4 — Automation** — `nix-cpan auto` DONE (commit bd6a0b3).
  - [x] Updater entry point: risk-filtered, **build-gated** (full build default;
        `.src` fail-fast pre-filter; `--fast` = src-only opt-in), revert-on-fail
        via `git checkout` (broken bumps never committed), per-package commits,
        dry-run default, machine-readable JSON report (failures carry
        {attr,old,new,reason} for future quarantine), exit-code aware.
        Idempotent via git (a landed bump is no longer a candidate next run).
        v1 scope: deps-all-present candidates only (no --missing) for atomic revert.
        Validated on real ~/nixpkgs (green→commit, forced-fail→revert) + t/23.
  - [ ] **Deferred** (future): failure quarantine (skip-list keyed by attr+version,
        from the JSON report) so the bot doesn't rebuild known-bad bumps each run;
        per-package `init at V` commits for new deps (D4 gap); moderate/high at
        scale once #15 (build==propagated deps) is confirmed metadata-real.

## Bug / finding log

> Format: `#N (date) [status] symptom — repro — affected — notes`

- **#1 (2026-06-26) [FIXED] nixfmt missing from dev shell.** `nix-shell --run
  "nixfmt --version"` → `command not found`; tool died in `has_nixfmt` on any
  write/commit. Fixed by adding `pkgs.nixfmt` to `shell.nix` (1.3.1, matches
  `~/nixpkgs`). Verified: `nixfmt --version` → 1.3.1.
- **#2 (2026-06-26) [FIXED for the common shape] complex input lists.**
  `set_or_add_attr_list` used to skip any non-flat list. Now it handles
  `[ base ] ++ <conditional rest>` (commit ea00867): updates the unconditional
  base list, preserves the `++ lib.optionals … / ++ (with pkgs; …)` suffix
  verbatim, excludes attrs already in the conditional (no duplicating a
  platform-only dep), keeps pkgs.* in base. Verified on XMLLibXML + PDL (real
  file) — conditionals preserved, edited drv still evaluates (`--dry-run` exit 0).
  Test: t/22. Remaining un-handled shapes (left untouched, now WARNed): `with
  perlPackages`/`with pkgs` exprs (CryptPassphraseArgon2, PDL native),
  `[ (pkgs.x.override {…}) … ]` (SVNSimple, libapreq2), leading-conditional
  pkgs-only (TextWrapI18N, IOInterface) — these have no flat perlPackages base to
  manage, so manual review is correct.
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

- **#14 (2026-06-27) [key insight] build failure ≠ errata-add.** A missing build
  dep falls into two cases, and only one is errata: (a) MetaCPAN metadata already
  declares the dep but the nix derivation's buildInputs is **stale** → fix is
  `update --deps_only` (regenerate), adding errata would just create a future
  "redundant" audit hit; (b) metadata genuinely **misses** the dep → errata. The
  `diagnose` command distinguishes these (mirror of the audit's redundancy check).
  Observed live: Array-Compare's `Test::NoWarnings` failure is case (a) — metadata
  has `Test::NoWarnings build/requires`, so it's STALE, not errata.
- **Limitation (2026-06-27):** the genuine errata-add path (metadata-misses) is
  covered by unit tests (t/21, mock cache, both branches) and the suggestion logic,
  but not yet by a *real* build of a metadata-misses package (hard to find on
  demand). Runtime-only missing deps are invisible at build time
  (sufficiency/minimality asymmetry), so `diagnose` only ever infers build-bucket
  errata. Add-then-rebuild-green on a real metadata-misses case is future work.

- **#15 (2026-06-27) [open, dep classification] buildInputs == propagatedBuildInputs
  after some updates.** Updating AppMusicChordPro produced identical build and
  propagated lists. Likely the distro's metadata lists the same modules across
  multiple phases, so `build_inputs()` (build/test/configure) and
  `propagated_build_inputs()` (runtime) overlap fully. Pre-existing behavior (not
  from the conditional-list or generate work). Worth a look: should a runtime dep
  be excluded from buildInputs when it's already propagated? Low priority.
- **#16 (2026-06-27) [FIXED] generate_missing --out wrote an unparseable
  fragment.** It ran nixfmt on a bare set of bindings (no enclosing `{}`) →
  nixfmt parse error, exit 255. Fixed (04f1629): --out skips nixfmt and emits an
  explanatory header; the stanzas are already canonical.
- **#17 (2026-06-27) [FIXED] compare/generate_missing exited 1 on success.** Both
  lacked `return 0`, so the final `say` (returns 1) became the exit code — would
  break a bot checking exit status. Fixed (04f1629).

## Code review (2026-06-27, high-effort workflow over 1412c00..HEAD)

22 findings survived verification. Triage:

**Fixed (commit df77ae4):**
- **CR-1 [CRITICAL] newer_than regression** — version.pm ranked "1.10" as 1.1 <
  1.9, silently skipping X.9→X.10 updates and risking downgrades when the local
  tree was ahead of the cache. Reverted to Sort::Versions ordering + explicit
  underscore/dev guard. (This supersedes the version.pm approach in Bug #7; the
  dev-guard still satisfies #7's real requirement.)
- **CR-0 [CRITICAL] auto dry-run data loss** — default (dry-run) auto reverted via
  `git checkout` but the dirty guard only ran with --commit → a preview on a file
  with uncommitted edits wiped them. auto now refuses on a dirty file always.
- **CR-8/11 src reader/writer asymmetry** — writer now mirrors the reader's
  src-block→top-level fallback (`_set_src_or_top_attr`); `_set_src_attr` returns 0
  instead of dying. Note: real nixpkgs is uniformly canonical (0 single-line src,
  0 top-level hash), so these never fired in practice — defensive hardening.
- **CR perf** — auto used `update_inplace(parse_after => 1)`; every path re-parses
  anyway, so → `parse_after => 0` (halves per-candidate parsing).

**Accepted by design (documented, not changed):**
- **CR-3 conditional base drops hand-added deps** — `[ base ] ++ cond` regenerates
  the base from metadata + pkgs.* (dropping manual non-pkgs base deps). This is
  IDENTICAL to how simple lists already behave: metadata is authoritative for deps;
  manual deps belong in errata (which IS preserved). `auto`'s build gate catches
  any resulting missing dep. Constraint, not a bug.
- **CR-4/6 dev-pinned never updated** — intended (README: don't update pre$
  versions); now enforced via the underscore guard.
- **CR-10 url/hash in exotic layouts WARN-skip** — the old whole-part scan could
  edit the WRONG url (a fetchpatch's); src-scoping is a safety improvement.
  Skipping an unrecognised layout is safer than mis-editing.
- **CR-9 the 18 errata prunes** — redundancy is computed from the real resolver
  (`dependency()`), so a pruned entry is provably output-identical on the current
  cache; commented hedges are retained; the prune commit is git-reversible.

**Deferred backlog — DONE (commit 2befc20):**
- CR verify_build double `nix-build` eval — fixed: default does one full build and
  mines the log for the hash-mismatch signature; `--fast` does `.src` only.
- DRY: `_mask_nix_line` + `brace_delta` moved to Nix::Util (single source of
  truth; both classes delegate). Dep-list merge factored into
  Drv::_merge_inputs_from_mc.

## Open questions

- Region-only nixfmt: does it reproduce whole-file nixfmt byte-for-byte? (D2 risk)
- How to detect *obsolete* errata at scale given the removal+rebuild cost?
- `version_numified` vs `Sort::Versions` — are there packages where MetaCPAN's
  "latest" disagrees with what we'd pick? (filter_releases dedup logic)
- Packages with non-`fetchurl` / non-CPAN sources: enumerate and exclude cleanly.
- Updater-script output contract for the future bot (JSON report shape).
