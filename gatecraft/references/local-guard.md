# Cooperative local guard (`gatecraft-local-lock/v1`)

The guard is a dependency-free local safety layer for conforming Gatecraft orchestration. It has two independent jobs: serialize a conforming local orchestrator with an exclusive lock, and detect foreign checkout changes or lost worker processes against a create-only baseline. PowerShell 7 owns every validation and byte format. `scripts/guard.sh` only resolves its own directory, verifies that `pwsh` exists, and `exec`s the PowerShell entry point with `"$@"`.

This guard is deliberately separate from verification/v2 receipts and the `gatecraft-cycle/v1` cycle-end ledger. It precedes or follows those protocols at the documented call sites; it creates no event type, orchestration ledger, daemon, timer, hook, or recovery actor.

## Lock entry points

Generate one opaque, non-secret owner token and bind it to the actual long-lived orchestrator process. Reuse exactly that token, PID, and process start for release. The canonical start string is the live process start converted to UTC as `yyyy-MM-ddTHH:mm:ss.fffffffZ`.

```powershell
$ownerToken = [Guid]::NewGuid().ToString('N')
$ownerPid = $PID
$ownerStart = (Get-Process -Id $ownerPid).StartTime.ToUniversalTime().ToString(
  "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
  [Globalization.CultureInfo]::InvariantCulture
)

pwsh -NoProfile -File gatecraft/scripts/guard.ps1 acquire `
  --repository-root C:\absolute\target-checkout `
  --owner-token $ownerToken --pid $ownerPid --process-start $ownerStart
```

On Windows, test or invoke the POSIX surface through the exact Git for Windows executable. In a normal POSIX environment, resolve `bash` from `PATH`. Values remain distinct quoted arguments.

```powershell
& 'C:\Program Files\Git\bin\bash.exe' gatecraft/scripts/guard.sh acquire `
  --repository-root 'C:\absolute\target-checkout' `
  --owner-token $ownerToken --pid $ownerPid --process-start $ownerStart
```

```sh
bash gatecraft/scripts/guard.sh acquire \
  --repository-root '/absolute/target-checkout' \
  --owner-token "$owner_token" --pid "$owner_pid" --process-start "$owner_start"
```

Release only after the terminal/local boundary described below:

```powershell
pwsh -NoProfile -File gatecraft/scripts/guard.ps1 release `
  --repository-root C:\absolute\target-checkout `
  --owner-token $ownerToken --pid $ownerPid --process-start $ownerStart
```

The command requires the caller-supplied path to be the exact Git top level, resolves `git rev-parse --path-format=absolute --git-common-dir`, rejects non-local roots and reparse/symlink path components, and uses only this fixed location:

```text
<absolute-git-common-dir>/gatecraft-local-guard-v1/holder.json
```

The holder is installed directly with an exclusive `CreateNew` open. Its deterministic UTF-8-without-BOM/no-newline bytes are:

```json
{"owner_token":"<32-128 base64url-safe characters>","pid":123,"process_start":"2026-07-15T10:15:30.1234567Z","protocol":"gatecraft-local-lock/v1"}
```

The PID must be positive and the supplied PID/start pair must match the actual live local process before and after acquisition. A contender never opens the existing file for write. An existing valid dead or start-mismatched holder reports `lock-stale-attended-recovery-required` and remains untouched; there is no automatic steal or stale recovery. Empty, partial, noncanonical, unknown-field, reparse, or unexpected-entry state fails closed.

## Headless identity boundary

If a headless harness cannot prove the long-lived orchestrator's exact live PID and canonical start binding, it must not invoke `acquire` or `release` with a shell, launcher, worker, inherited, guessed, or recycled PID. Persist only the sanitized local evidence `GUARD_IDENTITY status=unavailable reason=owner-binding-unprovable`, then stop before any claim, dispatch, tracker mutation, merge, close, release, or guard recovery. It must not delete or alter `holder.json`, retry against a substitute process, bypass the guard, or steal an existing holder. Resume only when the same orchestrator can supply a freshly proven live PID/start pair, or when an attended human performs the documented recovery; a harness limitation is never stale-holder evidence.

Release opens and strictly validates the persisted record again, compares all three owner fields exactly, re-proves that the persisted PID/start is live, rechecks the fixed directory, and deletes only `holder.json`. A wrong token, PID, or start reports `lock-owner-mismatch` and leaves the holder byte-identical. The empty fixed guard directory is retained.

## Foreign-change baseline and sweep

The caller supplies the exact checkout top level, an absolute local state root, a stable baseline ID, a nonempty JSON array of owned repository-relative paths, and a nonempty expected-process JSON manifest. Paths must already use normalized forward-slash repository-relative form. Backslashes, absolute paths, dot/traversal segments, `.git`, controls, wildcards, empty segments, duplicates, case collisions, and symlink/reparse escapes are rejected. Worker IDs use `[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}`; each positive PID/start binding must be unique and live.

```powershell
$owned = '["gatecraft/scripts/guard.ps1","gatecraft/tests/Test-Guard.ps1"]'
$processes = ConvertTo-Json @(
  [ordered]@{
    worker_id = 'codex/personale'
    pid = $worker.Id
    process_start = $worker.StartTime.ToUniversalTime().ToString(
      "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
      [Globalization.CultureInfo]::InvariantCulture
    )
  }
) -Compress

pwsh -NoProfile -File gatecraft/scripts/guard.ps1 baseline `
  --repository-root C:\absolute\target-checkout `
  --state-root C:\absolute\local-gatecraft-state `
  --baseline-id bead-attempt-1 `
  --owned-paths-json $owned `
  --process-manifest-json $processes
```

The create-only record is `<state-root>/guard-baselines-v1/<baseline-id>.json`; the state root must not equal or sit below the checkout or Git common directory, so creating evidence cannot become a repository change. It is canonical UTF-8 without BOM or newline and records: the exact `refs/heads/main` commit; the complete raw bytes and SHA-256 of `git status --porcelain=v1 -z --untracked-files=all --ignore-submodules=none`, so repository config cannot hide dirty submodules; raw-byte-derived worktree/directory and exact index-entry fingerprints for every already dirty, deleted, renamed, staged, or untracked path; normalized sorted owned paths; exact sorted expected-process bindings; and canonical repository/common-directory identity. All ordering that enters canonical record arrays or fingerprint hash payloads—owned paths, expected-process worker IDs, parsed Git dirty paths, and recursive directory entries—uses .NET `StringComparer.Ordinal`, independent of `CurrentCulture` and `CurrentUICulture`. Status bytes are base64 because POSIX filenames need not be line-safe; ambiguous or non-UTF-8 path identities fail closed during ownership classification. A second creation for the same ID returns `baseline-exists` and never rewrites the record. The command captures main/status twice and rechecks processes before persistence; sweep likewise repeats status, dirty/index fingerprints, main, and process checks and fails if the observed repository races.

Sweep is read-only with respect to both the checkout and local state:

```powershell
pwsh -NoProfile -File gatecraft/scripts/guard.ps1 sweep `
  --repository-root C:\absolute\target-checkout `
  --state-root C:\absolute\local-gatecraft-state `
  --baseline-id bead-attempt-1
```

It strictly revalidates the canonical baseline, repository/common-directory identity, every expected live process, `refs/heads/main`, current complete porcelain state, and every baseline-dirty path fingerprint. After binding repository identity and parsing the persisted raw status, sweep requires its ordinal-sorted path list to match `dirty_paths.path` exactly one-for-one; an omission, addition, duplicate, case mismatch, or ordering inconsistency is `baseline-record-invalid`. `main-moved`, `process-dead`, `process-start-mismatch`, or `foreign-change` is nonzero. Status/fingerprint differences are allowed only when every affected path is equal to or below an owned path; success reports only the count as `owned_changes=<n>`.

A finding is observation only. Neither baseline nor sweep stages, includes, checks out, resets, restores, stashes, cleans, reverts, deletes, moves, renames, or writes a repository path. `GIT_OPTIONAL_LOCKS=0` is set for all Git reads. Keep baseline files local, access-restricted, ignored, and retention-bound. Never publish or commit their raw status bytes, repository paths, owner tokens, PIDs, or process start values; durable/shared evidence carries only sanitized success markers and reason codes.

## Exact orchestration call sites

1. Acquire before any conforming orchestration action, including a fresh session and handoff pickup. A nonzero acquisition stops the local session before claim, dispatch, merge, tracker mutation, or cycle-end.
2. After worktree/scope validation, create the foreign-change baseline immediately before dispatch, using the complete owned-path list and the exact processes that are expected to remain live.
3. Sweep the dispatch baseline before commit/merge. Any nonzero finding stops the boundary for attended handling; it never authorizes absorbing or reverting the finding.
4. A successful authorized merge necessarily moves `refs/heads/main`, so never reuse the pre-dispatch baseline as if main had not moved. After postmerge verification has bound the exact expected merged SHA, status, and reaped-worker state, create a second create-only postmerge baseline under a fresh ID and with the processes still expected to be live. This is boundary evidence, not a reset or recovery of the first baseline. Sweep that postmerge baseline immediately before GC-1.12 cycle-end.
5. Keep the lock through verification, local merge/close, the pre-cycle-end sweep, and the cycle-end command. Release only by the exact owner after cycle-end has reached its terminal/local boundary and no further local orchestration mutation is pending. For handoff, the predecessor first stops local mutation and durably writes the pending snapshot/marker, making that its terminal/local handoff boundary; it then releases. The named successor acquires locally before validating/accepting the pending handoff and writing durable ACK. If ACK expires, the predecessor must reacquire locally before it resumes or rewrites the attempt; a conflicting holder stops it.

These calls do not replace the best-effort durable `bd remember` handoff marker/heartbeat or the canonical cycle-end receipts. The local lock answers only “which conforming process currently owns this local Git common directory”; the handoff state answers succession and ACK questions; the cycle-end ledger remains the only authority for its projections.

## Stable markers and test control

Success begins with exactly one of `GUARD_LOCK_ACQUIRED`, `GUARD_LOCK_RELEASED`, `GUARD_BASELINE_CREATED`, or `GUARD_SWEEP_OK`, each with a stable `code=` field. Every failure is nonzero and emits `GUARD_FAILED code=<reason>` without raw status or process data.

The acceptance-only acquire barrier requires all of `--test-acquire-barrier`, `--test-participant`, and a bounded `--test-timeout-ms` from 100 through 30000. Before any barrier or guard write, the process environment must contain `GATECRAFT_GUARD_TEST_CONTROLS=1` exactly. Without the options, production never pauses; even with the exact opt-in the barrier has a hard timeout.

## Honest boundary

This is cooperative mutual exclusion among conforming processes on one host that resolve the same local Git common directory. It provides no distributed compare-and-swap, fencing token, cross-host claim, network-filesystem guarantee, per-tool-call enforcement, daemon, timer, automatic recovery, or protection from a non-conforming writer that deletes/replaces files or mutates the checkout directly. Filesystem component checks reduce indirection risk but cannot make a hostile concurrent path replacement race-proof. Treat stale or malformed state as an attended stop, not permission to steal.
