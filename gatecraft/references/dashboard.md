# Dashboard: recommended tool and multi-layer data sources (Step 0.11 detail)

## Recommended: `bd-mission-control`

When 0.11 finds no existing dashboard, propose **[bd-mission-control](https://github.com/maisdesign/bd-mission-control)** before generating anything from scratch — a purpose-built, zero-dependency, single-file HTML panel for `bd`, not a generic template. It is an **external tool, checked and offered for install like `bd` itself, never vendored into this skill** — copying its generated HTML in here would just recreate the stale-duplicate drift this skill's own anti-patterns warn about, and it is independently maintained upstream.

**Verified compatible with this skill's ledger out of the box.** The panel's `deriveVerification()` reads each bead's `.beads/issues.jsonl` comments and matches `/^VERIFIED\b.*result=pass/m` and `/^VERIFICATION_FAILED\b/m` — exactly the ledger lines Step 1.11 already writes (`VERIFIED verified_by=… result=pass` / `VERIFICATION_FAILED …`). No adapter, no extra field, no reformatting needed; a closed-but-unverified bead shows as drift on the panel the same way Step 0.12 already treats it.

**Install** (real behavior, per its own README, itself verified against `scripts/install.ps1`/`scripts/install.sh`):

```powershell
git clone https://github.com/maisdesign/bd-mission-control.git
powershell -NoProfile -File bd-mission-control/scripts/install.ps1 -Target C:\path\to\project
```
```sh
git clone https://github.com/maisdesign/bd-mission-control.git
sh bd-mission-control/scripts/install.sh -Target /path/to/project
```

`-Target` is required; `-Dir` (default `docs`) picks the vendored subdirectory; `-Update` refreshes the panel/refresh scripts without touching `orchestration.config.js` once it exists; `-Force` also overwrites locally-modified vendored files (loud warning). This is also the correct path for `-Update` when 0.11 finds the panel **already installed** — refresh the vendored files rather than hand-editing generated HTML.

**Operationally important:** the panel's data-source chain is live fetch of `../.beads/issues.jsonl` → snapshot (`window.BMC_SNAPSHOT` from a generated `orchestration-data.js`) → built-in demo, in that order. Over plain HTTP hosting, live fetch just works. Opened via `file://` (common for a local-only project dashboard), browsers block that fetch — run `scripts/refresh.ps1`/`refresh.sh` to generate `orchestration-data.js` after each bead cycle (or wire it into the same Step 1.12 dashboard-refresh point already used for a project's existing dashboard), or the panel will silently show stale/demo data and look broken.

**Curation** uses an optional `orchestration.meta.json` overlay (wave titles, bead labels/notes, flags) that the panel deep-merges over the raw tracker data — enriches, never required, and never overwritten by a refresh, which is the same curation-optional design this file's own lived incident (below) argues for.

**Dashboard title defaults silently to the local folder name — ask the user instead, on first install.** Read directly from the installer source (`scripts/install.ps1`'s `Write-ConfigStub`): on a fresh install it writes `orchestration.config.js` with `title: "<TargetBaseName> mission control"`, where `TargetBaseName` is the local `-Target` folder's basename — not the git remote's repo name, and not anything the user was asked about. The function also only writes the file when none exists yet; a config already present (including on `-Update`) is left untouched. So Step 0.11 asks a second question at first-time install only: repo folder name, or a different title? State the actual folder name in the question, since it can diverge from the git repo name (e.g. a clone into a renamed directory). If the user wants something else, edit the single `title:` line of the already-generated `orchestration.config.js` after install completes — do not pre-seed a custom config ahead of the installer; that would mean re-deriving the exact stub format (currently just `title` and `dataPath`, with several commented-out example fields) by hand, which drifts the moment the tool's own stub changes upstream. Never re-ask on a project where the panel is already installed, even if its title is still the folder-name default — that default is the existing project's standing state, not a fresh bootstrap decision to revisit.

## Multi-layer data sources and the optional-curation design — general lesson

Lived incident behind the core rule: an auto-refresh script updated its generated data layer while a separate hand-curated layer — the one the renderer actually read — left 21 real beads invisible on screen, and re-running the refresh script kept giving false confidence that the dashboard was current.

**If a dashboard already exists, check whether it has more than one data source before trusting a refresh script alone.** A dashboard can end up with an auto-generated layer (regenerated from `bd` by a script, always current) *and* a separately hand-curated layer (a human-maintained grouping/description layer that a rendering script reads from, which does not update itself). Re-running the auto-refresh script only fixes the first layer — if the visible rendering actually depends on the hand-curated one, newly created beads can be completely present in the underlying data yet invisible on the page. Confirm what actually renders on screen — not just what's in the regenerated data file — before telling the user a dashboard update is done.

**Prefer making the hand-curated layer optional rather than required, if you're building or extending the refresh script anyway.** A required-but-manual step is exactly what gets forgotten under time or usage pressure — not a flaw unique to any one project. Most fields a hand-curated layer holds are usually derivable from `bd` directly and don't need a human at all: priority is already native, a short label is often already embedded in the bead's own title by convention, and grouping can default to "one group per parent epic" (with a shared catch-all group for parentless standalone beads, rather than minting one new group per bead) since that's usually how a human would have grouped it anyway. Have the refresh script synthesize a default entry for anything missing, so a bead is never invisible even if nobody remembered the manual step — and leave already-curated entries completely untouched, so a human can still refine the grouping/description later without that refinement being overwritten by the next auto-run.

The one thing that doesn't automate is the *narrative* a human adds when deliberately grouping several small, unrelated items under one thematic heading — that's a genuine judgment call, not just missing wiring, and a fully mechanical one-epic-per-group default will be noisier than what a human would have chosen. Treat the auto-generated entry as a safety net, not a replacement for that judgment.
