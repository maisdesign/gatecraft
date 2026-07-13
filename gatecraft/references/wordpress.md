# WordPress environment checks (Step 0.3 detail)

Applies when project detection finds `wp-config.php` / `wp-content`.

- **Locate the local PHP binary, `wp-cli`, and the local site path** (LocalWP or equivalent). Confirm the exact invocation pattern once and reuse it verbatim in every dispatch prompt — do not make agents rediscover it each time.
- **Run a write-capability smoke test before any real work**: dispatch a trivial file-write task (e.g. create a throwaway file with one line) to a scratch git worktree using whichever tool will do file-editing work, and confirm it actually lands. This catches a sandbox-vs-filesystem mismatch *before* it derails real work — seen concretely on Windows: a sandboxed agent's file-write layer can silently refuse writes outside narrow allow-listed roots, and the agent's own retry logic may hang indefinitely instead of failing fast. If the smoke test fails, prefer a different tool for write-heavy tasks and reserve the failing one for read-only/audit work or for tasks that only need shell/DB access, not file edits.
- **Confirm whether `git` write/push access to the target repo is actually available** (e.g. `git remote -v` plus a harmless non-destructive check) before assuming any agent can commit.
