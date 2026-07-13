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

## Verify

- `/gatecraft` appears among the commands → skill loaded
- First invocation on a project: Step 0 (bootstrap discovery) runs; it assumes nothing from a
  previous machine — profiles, paths, and roles are rediscovered and reconfirmed.

## Prerequisites on the new machine

git, at least one CLI coding agent, a real shell. `bd` (beads) and the multi-profile tooling are
NOT needed in advance: Step 0 detects them and asks permission before installing.
