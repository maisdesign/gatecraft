# Dispatch prompt template (Step 1.5)

Fill every field — an empty or vague field is exactly what produces an unverifiable "looks done" outcome.

```
You are: <profile-slug>                     (the worker's canonical bd identity from Step 0.2 —
                                             a worker cannot discover this; the prompt is the only channel)
Bead: <bead-id> — <one-line title>          (use the project tracker's own prefix, whatever it is)
Worktree: ../repo-wt-<id>-a<n> on branch work/<id>-a<n>   (attempt-scoped; orchestrator fills the actual <n>)

Task: <what to do, concretely — reference actual file paths/components, not "the login stuff">
Do NOT touch: <files/areas explicitly out of scope, even if tempting to "fix while you're in there">

Definition of done (run this yourself before reporting done):
<exact command(s), e.g. `wp-cli eval-file test.php` or `npm test -- --grep "cart"` — from Step 2>

Tool invocation pattern for this project (from Step 0.3): <exact path/flags, e.g. LocalWP php/wp-cli paths>

Constraints:
- Do not read or output the contents of .env, credentials, API keys, or any secret/credential file.
- If you repoint any shared-runtime indirection (symlink/mount/dev-env link) to test this, restore it
  to its original target before reporting done — this is part of done, not optional cleanup.
- Stay inside this worktree; do not push, merge, or touch other worktrees/branches.
- Do not leave scratch or debug files (sandbox workarounds, temp configs such as a stray
  vitest.node.config.*, throwaway test scripts) in the tree — they are not part of done; remove them
  before reporting.
- bd: you may claim this bead and comment on it. Do not close or modify any other bead, and do not
  touch orchestration-level bd remember keys (locks, policies, snapshots).
- bd identity: all your bd writes must be recorded as <profile-slug>. Your environment should already
  set BEADS_ACTOR=<profile-slug>; if a bd write would run without it, pass --actor <profile-slug>
  explicitly. Never write to bd under any other name.
- If your sandbox cannot commit or write to bd (a worktree's .git and bd's data live under the main
  repo's .git, often outside a worktree-scoped sandbox's writable root) — do not treat that as a
  failure. Leave your work uncommitted in the worktree and report what you did, what you observed,
  and any follow-ups in your final output; the orchestrator will commit and record it on your behalf
  after independent verification, attributed to you.

When done: <ONE concrete completion instruction, chosen once at bootstrap per the bd write-roles
note — either `bd close <id>` or "mark it awaiting_verification"; never put both in a real prompt>
with a closing comment covering: what you ran, what you observed (not just "tests pass"), suggested
tests/checks the verifier should run, and any follow-up work worth its own bead — flag out-of-scope
findings there instead of fixing them silently. If you cannot write to bd, put this same content in
your final message/output instead.
Your completion mark is a signal: independent verification and merge happen after it, not by you.
```
