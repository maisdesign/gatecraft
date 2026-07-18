# Handoff, lock, and verification-ledger mechanics (Step 3 detail)

`SKILL.md` Step 3 states the **invariants** — when to hand off, that the durable `bd remember` lock is best-effort not mutual exclusion, that ACK is the successor taking that durable lock, fail-closed on conflict, snapshot persisted and versioned. The separate cooperative same-host guard in `local-guard.md` prevents two conforming local processes sharing one Git common directory from reaching that durable protocol concurrently. This file holds the **exact mechanics**: commands, formats, numeric bounds, and field lists you consult while actually performing a handoff. Nothing here overrides an invariant in `SKILL.md`; it operationalizes it.

## Usage introspection

Obtain the orchestrator's own session (~5h) and week (~7d) usage percentages and reset times by feeding `/usage` as **stdin into an interactive `claude` session** — not `--print`, which echoes `/usage` back as literal text. `/exit` and any `sleep` are unnecessary: the session exits on stdin EOF in ~2 s. The robust form polls for the target line with a hard timeout:

```sh
LOG=<logfile>
echo "/usage" | CLAUDE_CONFIG_DIR="<profile-config-dir>" claude > "$LOG" 2>&1 &
BGPID=$!; SECS=0
until grep -q "Current session:" "$LOG" 2>/dev/null || [ "$SECS" -ge 20 ]; do sleep 0.5; SECS=$((SECS+1)); done
wait "$BGPID" 2>/dev/null
grep -E "Current (session|week)" "$LOG"     # EMPTY ⇒ no reading this time (best-effort miss), NOT 0%
```

Either `claude` with `CLAUDE_CONFIG_DIR` set (confirmed — no wrapper needed) or the multi-cli launcher works; `--print` does not.

**Best-effort, not guaranteed (lived, verified by repeated testing).** The `Current session:` / `Current week:` percentage lines render on the first calls but **intermittently vanish on rapid repeated invocations** (suspected server-side throttling on the summary fetch) — independent of sleep length, pipe-vs-file, or profile — while the "What's contributing to your limits usage?" section always prints. So query **at most once per bead cycle** (the required cadence; never poll tightly — that is exactly what triggers the vanishing), and treat a **missing percentage line as "no reading this cycle," not as 0% and not as a stop** — retry next cycle or use the non-blocking fallback below. Codex has a *structured* channel that is cleaner than this scrape — JSON-RPC `account/rateLimits/read` over `codex app-server --stdio` (see `codex-quota.md`).

Exact lines to parse:

- `Current session: {N}% used · resets {Mon} {DD}, {h}[:{mm}]{am|pm} ({TZ})`
- `Current week (all models): {N}% used · resets {Mon} {DD}, {h}[:{mm}]{am|pm} ({TZ})`

The separator is the middot `·` (U+00B7) with surrounding spaces; `resets` is lowercase; the hour sometimes omits minutes (`8pm` vs `3:49am`). Ignore any `Shell cwd was reset to …` line — that is the outer Bash harness, not `/usage`.

**Unofficial options that do work** go around the CLI and are a deliberate user choice only (they read local auth/usage data and can change without notice): for Claude Code, `ccusage` reads the usage JSONL under `~/.claude`; for codex, `codex-status-json` and `pi-codex-status` (see `codex-quota.md`).

Identify the current profile from `CLAUDE_CONFIG_DIR` (Claude Code) or the vendor equivalent, match it to 0.2, and run introspection under that same account so the number is the orchestrator's, not an estimate; if no identity mechanism exists, ask the user once. **If even the scripted-stdin method above does not work here (a truly headless environment with no launchable interactive session), do not infer quota indirectly, and do not block.** A check-in with the user (e.g. every 2–3 beads) is an **attended-only** fallback — with no human watching it halts the run indefinitely. For **unattended** runs, make reaching the limit non-catastrophic rather than trying to predict it:

- refresh the handoff snapshot and session log after **every** bead, so an abrupt rate-limit stop mid-run is fully recoverable (the in-flight bead is recorded and re-verified by the successor);
- schedule the successor spawn / reclaim wake-up on a timer **independent of usage** (per the scheduler smoke-test above), so continuity does not depend on the dying orchestrator handing off gracefully;
- optionally hand off automatically at a conservative bootstrap-set bead-count or wall-clock budget — a crude but non-blocking proxy;
- optionally poll `ccusage` (reads token counts from the local `~/.claude/projects/*.jsonl` transcripts; gives token burn and an approximate active 5-hour block, **not** the subscription rate-limit % that `/usage` shows) for a rough non-blocking signal.

Running to the limit is then acceptable: the scheduled successor picks up from the fresh snapshot. Never gate an unattended run on a question no one is awake to answer.

Check after each complete bead cycle and before claiming another; do not poll on a timer.

Before the next claim, persist exactly one sanitized, machine-greppable record in the durable session log and current handoff snapshot:

```
USAGE_CHECK cycle=<completed-cycle-id> adapter=<claude-usage|codex-rate-limits|none> status=<ok|no-data|skip> short_session=<0-100|unavailable> weekly=<0-100|unavailable> reason=<sanitized-reason-code> checked_at=<UTC-RFC3339>
```

`status=skip` is allowed only when no applicable adapter was discovered or the persisted policy disables it; state that sanitized reason. `status=no-data` is the required result for an attempted adapter without a trustworthy short-session value. Never omit the line, infer a percentage, include raw provider output, or run another adapter in the same cycle to replace it. A no-data or skip record preserves unattended continuity, but its absence blocks the next bead claim.

## The two tiers

The two tiers below apply only when a trustworthy short-session value is available. They never apply to weekly usage: a weekly-only reading remains valid while the short-session capability is unavailable, and it must not trigger either tier.

- **Below 95%, but with the next full bead cycle genuinely at risk:** judgment based on estimated bead size, not another fixed percentage. Check 0.6 candidates' headroom with the same introspection, write the snapshot even if none is confirmed, report current usage/reset and candidates with room, and ask whether to hand off or continue.
- **At or above 95%:** treat this as an overwhelming margin, not a judgment call. Without waiting for a live answer, select the first 0.6 candidate with confirmed headroom, write the snapshot, and hand off. If 0.6 says stop, write the snapshot and stop.

Both tiers follow succession list → confirm headroom → snapshot; only the live-answer wait differs.

## Temporary regency (`reclaim_at`)

Put the outgoing profile's known `resets_at` into the snapshot as `reclaim_at`. At `reclaim_at`, before acting on it, call `Test-GatecraftReclaimBoundary -StateRoot <the cycle-end state root>` from `scripts/Gatecraft.Protocol.psm1`. It determines whether "now" is a genuine cycle boundary rather than a moment mid-merge: it reads the same canonical `cycle-end` receipt ledger and `dashboard.json` projection that `cycle-end.md`/`cycle-end.ps1` already produce and test, plus the lightweight GC-1.10 cycle-begin marker (`New-GatecraftCycleBeginMarker`) that the orchestrator creates immediately before merge begins and that `cycle-end.ps1` deletes only as its very last action, strictly after the final dashboard write. It returns `Allowed=$true, Reason=ok` only when no cycle-begin marker exists at all (its target sequence is never consulted — presence alone, checked last, is what proves the sequence has not fully finished, including the crash window between writing the final dashboard and deleting the marker), the latest ledger entry's every field (event ID, sequence, mode, timestamp, outcome, and summary) is fully and exactly reflected in the rebuilt dashboard, and a second receipt-list read taken inside the same check still agrees with the first on every one of those fields — a durable-state cross-check that fails closed on any disagreement, not proof by itself that the cycle finished cleanly (the receipt/dashboard agreement alone cannot distinguish a clean boundary from a merge that is currently in flight but has not yet written its next receipt; the cycle-begin marker is what closes that gap). It fails closed with `Allowed=$false` and a reason (`blocked-no-ledger` when no completed cycle-end has ever run, `blocked-mid-merge` when a receipt exists but the projection rebuild that follows it did not finish, a live cycle-begin marker is present regardless of its target, or a receipt-list field disagrees on rescan, `blocked-malformed-ledger` when the receipt ledger, the cycle-begin marker, or the dashboard projection itself is corrupt or unreadable) whenever the boundary is not clean or the state cannot be trusted. If it returns not-ok, do not reclaim immediately: wait and recheck at the next cycle-end boundary instead. Only when it returns `ok` does the successor treat the event like reaching its own 95% threshold: write its own snapshot, rerun succession, and give the original profile first priority because it should now have headroom. Chain this across any number of hops; each orchestrator carries inherited `reclaim_at`, or sets its own when it triggered the current handoff, so the eventual return path is not silently discarded.

## Handoff mechanism

Spawn the chosen profile non-interactively in the background with a resume prompt pointing to `bd prime`/`bd memories`, Step 1, Step 3, and `reclaim_at`. Since one invocation may stop early, schedule fallback check-ins shortly after spawn and around `reclaim_at`.

Each check-in is a watchdog, not an actor with standing authority. Attach a dedupe key and the attempt's `handoff_id`; when it fires, inspect before acting. Do nothing if the lock has a live holder or a fresh heartbeat (staleness below). If the snapshot's current id differs from the carried id, the chain moved on: remove the check-in and stop. Only a stale lock with no live holder permits retriggering succession. A completed handoff cleans or replaces inherited check-ins so an older hop cannot fire into the current chain. Verify a successor actually starts before relying on unattended handoff. Also smoke-test the scheduler with one harmless near-term wake-up, confirm it fires, and clean it up. If no scheduler survives the needed session-close/sleep/reboot conditions, state that continuity lasts only while a session remains alive and scope the plan accordingly; never promise durable unattended continuity without a durable wake-up.

## ACK — spawn is not completion

The predecessor stops new dispatches, writes the pending snapshot/marker while it still owns both locks, and reaches a terminal/local handoff boundary. Only then does that exact owner release the cooperative local guard. The successor must acquire the local guard against the same Git common directory before reading/accepting the pending state; it then acquires the durable orchestrator lock under its own identity citing the current `handoff_id`, and that durable acquisition alone is ACK. A comment, unrelated `bd` write, process launch, or local-guard acquisition is not ACK. Only after ACK is the handoff complete and the predecessor's authority over. Use the 0.6 ACK window (default **10 minutes**) recorded beside the pending marker so any observer can calculate expiry. If it expires, the spawn failed and the predecessor remains the intended orchestrator but may not mutate orchestration state until it reacquires the local guard. After reacquisition it rewrites the pending marker with a fresh `handoff_id` naming the next candidate **before spawning that candidate**, thereby voiding the prior attempt; a conflicting local holder stops the predecessor rather than authorizing takeover.

## Lock mechanics

**Two distinct layers.** Before initial bootstrap, acquire `scripts/guard.ps1 acquire` (or `guard.sh`) exactly as `local-guard.md` specifies, before any conforming orchestration mutation. At handoff pickup, acquire it after the predecessor's pending-marker terminal/local release and before reading/accepting the handoff. Its exclusive create is cooperative mutual exclusion only for conforming processes on one host resolving the same local Git common directory; it has no distributed CAS/fencing or cross-host claim.

The `bd remember` lock remains **best-effort durable conflict detection, not guaranteed mutual exclusion**. Read it at initial bootstrap or handoff pickup to identify holder/profile/session and last confirmation. It is plain, non-atomic read-then-write: it carries durable/cross-session succession evidence but cannot mathematically prevent two sessions that both read "free" from acquiring simultaneously, especially across hosts. Treat it as conflict evidence, never proof of exclusion. The local guard complements this durable record; neither replaces the other's scope.

**Heartbeat and staleness — the operational definition of a "live holder."** The holder refreshes the lock's `last confirmation` timestamp at every bead-cycle boundary (claim, merge, close); that write *is* the heartbeat — there is no separate timer thread to rely on. A lock is **stale** only when *both* hold: its `last confirmation` is older than the larger of the declared 0.6 ACK window and one worst-case bead cycle (project-configurable; **default: treat older than 30 minutes as stale**), **and** no live process is holding it. Tie staleness to this field, never to wall-clock alone — a long-running e2e gate is not a dead orchestrator, and declaring a live holder stale is exactly what mints the simultaneous orchestrators listed among 0.5's catastrophic risks. When in doubt between "slow" and "dead," treat it as slow and resolve with the user rather than seizing the lock.

**Takeover rules.** During handoff, the predecessor does not pre-assign the lock. It writes a pending marker naming the successor and unique attempt `handoff_id` while retaining its live lock. The named successor may acquire under its identity only by citing that current id; this overwrite is the ACK and the **only legitimate takeover of another holder's live lock**. A late prior candidate finding a different id must stop and report rather than acquire. Any other session finding another live lock without a current marker naming itself must treat it as a real conflict, resolve it with the user or confirm the holder is inactive, and must not proceed regardless.

## Handoff snapshot

Persist through both `bd remember` and a relevant epic/tracking-bead comment:

- active worktrees and branch names;
- the bead tied to each and its status (canonical bead-status vocabulary — defined once in `SKILL.md` Step 1);
- each in-flight Step 2 gate;
- each reserved attempt ID, consumed task-attempt count, and total-spawn count;
- each baseline, integration/premerge, and review receipt ID already emitted for the active artifact;
- each current foreign-baseline ID and sanitized owned/process counts, without raw status or process data;
- pending user decisions;
- `reclaim_at`;
- intended successor;
- current `handoff_id`;
- declared ACK window;
- a monotonic `snapshot_seq`.

A cold successor under any profile loads it through `bd prime`/`bd memories` rather than re-deriving work. The `bd remember` copy is **authoritative**; the comment is a human-readable mirror that never overrides it. `snapshot_seq` is a divergence *detector*, not a conflict *resolver* — because the two writes are not atomic and concurrent writers can mint the same seq or leave a mirror ahead of the authoritative copy, a reader that finds them disagreeing does **not** silently take the higher seq: it treats the disagreement as a real conflict and fail-closes (stop, involve a human), and never auto-takes over across hosts on an ambiguous snapshot.

## Cycle-end call site and fallback

After the GC-1.11 ledger/status update, run the `local-guard.md` read-only sweep of GC-1.10's fresh verified-postmerge baseline, then invoke the single `cycle-end` event described in `cycle-end.md`. Its local canonical receipt is authoritative only for rebuilding the local session-log, heartbeat, snapshot, and dashboard projections; it does **not** replace the foreign baseline, cooperative local guard, `bd remember` handoff snapshot, comment mirror, or durable lock heartbeat/acquisition semantics above. Pass the next event sequence and a stable ID, and replay that exact payload after interruption. Do not claim another bead until the command exits zero with `projections=complete`. If the run is terminating locally, only the exact owner releases the cooperative guard after that boundary; a continuing owner may retain it into the next bead.

If projection cannot complete, unattended mode stops nonzero. Attended mode may print the documented `automatic_completion=false` manual checklist, but that checklist is recovery guidance rather than ACK, lock acquisition, or cycle completion. Manual reconstruction must read only the canonical cycle-end receipts and must remain visibly incomplete until the exact replay succeeds or the operator explicitly records the manual state.

## Verification ledger format (Step 1.11)

Lead the verification comment with one machine-greppable line. Apply the exact verification/v2 grammar, review state rules, canonical fingerprint, and decision procedure in `receipt-protocol.md`; validate it with `scripts/Gatecraft.Protocol.psm1` before close or publication.

Preserve the legacy boundary. Start only the final postmerge pass with `VERIFIED`, keep `verified_by`, `verified_at`, `commit`, `main`, `gate`, `exit=0`, and `result=pass`, and confirm it matches `^VERIFIED\b.*result=pass`. Start baseline and integration/premerge support with `VERIFY_PHASE` so legacy consumers cannot count them as final proof.

Record a failed final check with the distinct legacy failure prefix `VERIFICATION_FAILED … result=fail`; do not feed that failure ledger line into a candidate pass chain. Treat it as an audit record of the failed decision. Never rename it to `VERIFIED`, and never let closure substitute for a validated final pass.

Sanitize the full validator result before copying its minimal reason codes or receipt projection into `bd`, a handoff snapshot mirror, or a dashboard. Carry the referenced baseline, integration, and terminal review receipt IDs in handoff evidence so a cold successor can reconstruct the exact chain rather than grepping for an unlinked favorable line.
