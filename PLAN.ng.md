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
- [ ] **P1 — Safe bulk bumps** (version+src+hash only, deps untouched)
  - [x] `compare --report` against real file: **456 updates** (safe=196,
        moderate=220, high=40). No dep-resolution failures across all candidates.
  - [x] `update --diff` (no write) on CaptureTiny/ClassDataInheritable/BKeywords:
        diffs touch only version/url/hash; meta untouched; file not written.
  - [x] `update --inplace`: git diff = only the 9 intended lines; file stays
        nixfmt-canonical (verified by empty `nixfmt` diff + equal line count).
  - [ ] `nix-build` the batch (in progress) — confirms MetaCPAN hashes are correct.
  - [ ] Per-package `--commit` run on a fresh reset; verify one commit per pkg.
  - [ ] Scale to the full safe batch (196).
- [ ] **P2 — Dependency + errata management**
  - [ ] Eval-based actual-vs-metadata dep diffing.
  - [ ] Handle complex/conditional input lists (currently skipped — Bug #2).
  - [ ] Errata add/prune loop.
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
- **#7 (2026-06-26) [open, correctness] version comparison mis-orders dev &
  scheme-changed versions.** `newer_than` uses `Sort::Versions::versioncmp`.
  Observed false "updates": `CatalystPluginAuthentication 0.10_027 -> 0.10026`
  (a **downgrade** — existing is an underscore/dev release; README TODO already
  flagged "don't update pre$ versions"); scheme changes like `ZonemasterCLI
  8.0.1 -> 8.000001` and `AuthenOATH 2.0.1 -> 3.000001` (v-string vs float forms)
  need scrutiny. Need: (a) skip when the *existing* version is a dev/underscore
  release, (b) detect version-scheme changes and treat as suspect, not auto-safe.
  Note: none of these are in the safe-196 batch (verified: no `_` versions there).
- **Verification cost note (2026-06-26):** the local store has no binary-cache hit
  for perl 5.42.0, so `nix-build` of a single leaf perl package compiles the perl
  toolchain + test deps from source (many minutes). This makes per-package full
  builds expensive at scale → P2/verification must lean on `nix eval` pre-gates and
  build only a sampled/affected subset, or arrange a substituter.

## Open questions

- Region-only nixfmt: does it reproduce whole-file nixfmt byte-for-byte? (D2 risk)
- How to detect *obsolete* errata at scale given the removal+rebuild cost?
- `version_numified` vs `Sort::Versions` — are there packages where MetaCPAN's
  "latest" disagrees with what we'd pick? (filter_releases dedup logic)
- Packages with non-`fetchurl` / non-CPAN sources: enumerate and exclude cleanly.
- Updater-script output contract for the future bot (JSON report shape).
