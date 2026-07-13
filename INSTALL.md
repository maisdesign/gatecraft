# Installation — Gatecraft

Contents of the archive:

- `gatecraft/` — the skill itself (SKILL.md + references/). The copyable unit is the **whole folder**, not SKILL.md alone. The slash command is always the folder name — `/gatecraft` needs nothing else installed.

## Single-profile machine (no CLAUDE_CONFIG_DIR / multi-CLI wrapper)

1. Copy `gatecraft/` into `~/.claude/skills/`
2. Restart any open Claude Code sessions (skills load at startup)

## Multi-profile machine (wrapper with a per-profile CLAUDE_CONFIG_DIR)

Each profile loads skills from its OWN `<config-dir>/skills` — a per-profile copy diverges
silently (lived lesson: one profile ran a stale 14k-word version for days).

1. Install the canonical copy as above in `~/.claude/skills/`
2. For EACH profile, create a junction instead of copying (no admin rights needed):

   ```powershell
   New-Item -ItemType Junction -Path "<config-dir>\skills\gatecraft" -Target "$HOME\.claude\skills\gatecraft"
   ```

3. If a profile already holds an old real copy of the skill, DELETE it before creating the junction.

## Developing the skill itself (editing in a separate git checkout)

If you're editing this skill's own source in a git clone that lives somewhere other than
`~/.claude/skills/gatecraft` (e.g. `c:\Progetti\Skill\gatecraft\gatecraft`), step 1 above — "copy
into `~/.claude/skills/`" — creates a **second, silently divergent copy**: every edit lands in the
git checkout, but every session loads the plain copy, which never updates (lived: a full session
ran against a copy missing several same-day commits, discovered only when a diff was checked by
hand). Make `~/.claude/skills/gatecraft` itself a junction straight to the git checkout instead of
a real directory:

```powershell
Remove-Item -Recurse -Force "$HOME\.claude\skills\gatecraft"   # only if it's a real copy, not already a junction
New-Item -ItemType Junction -Path "$HOME\.claude\skills\gatecraft" -Target "<path-to-git-checkout>\gatecraft"
```

Per-profile junctions (step 2 above) then resolve straight through to the git checkout with no
extra step — a junction chain works the same as a direct one. Verify with
`Get-Item ~/.claude/skills/gatecraft | Select-Object LinkType,Target` before trusting that a
session is running current instructions, especially right after cloning fresh or moving the repo.

## Verify

- `/gatecraft` appears among the commands → skill loaded
- First invocation on a project: Step 0 (bootstrap discovery) runs; it assumes nothing from a
  previous machine — profiles, paths, and roles are rediscovered and reconfirmed.

## Prerequisites on the new machine

git, at least one CLI coding agent, a real shell. `bd` (beads) and the multi-profile tooling are
NOT needed in advance: Step 0 detects them and asks permission before installing.
