# Cycle-end event (`gatecraft-cycle/v1`)

`cycle-end` is the only event in the MVP. Invoke it once at GC-1.12 after the verification ledger and bead status are current. The caller supplies sanitized, stable values; the command does not read a raw worker log, tracker, repository, clock, or network.

## Entry points

PowerShell 7 owns validation and persistence:

```powershell
pwsh -NoProfile -File gatecraft/scripts/cycle-end.ps1 `
  --state-root C:\absolute\temporary-or-local-runtime-root `
  --event-id cycle-20260715-001 `
  --cycle-sequence 1 `
  --mode attended `
  --occurred-at 2026-07-15T10:15:30Z `
  --outcome continue `
  --summary "Sanitized cycle outcome."
```

The POSIX-compatible entry point delegates without re-parsing arguments and returns the real PowerShell exit code. From Windows PowerShell at the repository root, invoke it through the exact Git for Windows Bash:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' gatecraft/scripts/cycle-end.sh `
  --state-root 'C:\absolute\temporary-or-local-runtime-root' `
  --event-id cycle-20260715-001 `
  --cycle-sequence 1 `
  --mode attended `
  --occurred-at 2026-07-15T10:15:30Z `
  --outcome continue `
  --summary 'Sanitized cycle outcome.'
```

From a normal POSIX shell at the repository root, invoke the same entry point through the `bash` selected from `PATH`; keep each caller-controlled value as one quoted argument:

```sh
bash gatecraft/scripts/cycle-end.sh \
  --state-root '/absolute/temporary-or-local-runtime-root' \
  --event-id 'cycle-20260715-001' \
  --cycle-sequence '1' \
  --mode 'attended' \
  --occurred-at '2026-07-15T10:15:30Z' \
  --outcome 'continue' \
  --summary 'Sanitized cycle outcome.'
```

Options are exact, long-form, case-sensitive pairs. Unknown, abbreviated, duplicate, or missing options fail closed. `event-id` matches `[A-Za-z0-9][A-Za-z0-9._-]{0,127}`. `cycle-sequence` is a canonical positive decimal Int64 with no sign or leading zero. Mode is exactly `attended` or `unattended`; these remain Gatecraft's only two normative modes. Outcome is exactly `continue`, `completed`, `failed`, `quiescent`, or `waiting-external`. The timestamp is timezone-qualified RFC3339 and is normalized to seven fractional UTC digits. Summary is one-line, nonempty NFC text without leading/trailing whitespace or controls, at most 2048 characters.

## Source of truth and projections

All artifacts remain below the caller-supplied absolute state root:

```text
cycle-end/
├─ receipts/
│  └─ 0000000000000000001--<event-id>.json
├─ session-log.jsonl
├─ heartbeat.json
├─ snapshot.json
└─ dashboard.json
```

The filename above is illustrative; the implementation uses a 19-digit sequence field. Each receipt is deterministic UTF-8 without BOM or trailing newline and is installed create-only after a write-through temporary file. Receipt files are append-only: never rewrite or delete one to repair a projection. The receipt directory is the sole authority. `session-log.jsonl`, `heartbeat.json`, `snapshot.json`, and `dashboard.json` are replaceable projections rebuilt from the complete validated receipt sequence by same-directory write-through temporary files and atomic replacement.

The first receipt must have sequence 1. Every new receipt must be exactly the preceding sequence plus one. A byte/semantic-identical retry of the same event ID is idempotent: it keeps one receipt and rebuilds every projection, which repairs an interruption after receipt persistence or any later projection. Reject the same ID with different canonical fields, a sequence already owned by another ID, every gap, every nonpositive/noncanonical sequence, and any malformed existing receipt ledger.

State-root input must be absolute and may not contain dot segments, wildcards, controls, or ambiguous trailing dot/space components; Windows UNC/device roots are non-local and rejected. Existing path components and internal outputs are rejected when they are symbolic links, junctions, mounts, or other reparse points, and every component is checked again after directory creation. Internal names are fixed and event IDs cannot contain separators, so derived paths cannot escape the state root. These checks reduce caller-controlled indirection on the local runtime but are not a cooperative lock and are not race-proof against concurrent path replacement. GC-0.6 and `handoff-protocol.md` retain their existing lock semantics.

## Completion and fallback

Only exit 0 plus `CYCLE_END_COMPLETE ... projections=complete` means automatic completion. Validation/state failures are nonzero. Projection failure is exit 74 after retaining any already-created canonical receipt so an exact replay can repair it.

In `unattended` mode projection failure always fails closed and prints no manual fallback. In `attended` mode it is still nonzero and explicitly reports `automatic_completion=false`, followed by this checklist: resolve the local projection write problem without editing the receipt; rerun the exact same event; require a zero exit with `projections=complete`. The checklist is a visible recovery route, never success.

Do not claim the next bead until the exact event has completed. An attended operator who cannot repair automatically may manually reconstruct the four projections only from the canonical receipts, must record that the automatic command remains incomplete, and must not emit the automatic completion marker.

## Deterministic test controls

These controls exist only for dependency-free acceptance fixtures:

- `--failpoint after-receipt|after-session-log|after-heartbeat|after-snapshot|after-dashboard`
- `--failpoint-action exit|pause` (default `exit`; `pause` prints and flushes the boundary marker so a parent can kill the exact child)
- `--fail-projection session-log|heartbeat|snapshot|dashboard`

The process environment variable `GATECRAFT_CYCLE_END_TEST_CONTROLS` must have the exact value `1` whenever any test control is supplied. An absent variable or any other value rejects the invocation nonzero before state-root initialization or persistence. Setting the variable without a test-control option does not change normal behavior. Acceptance fixtures must scope the value to the exact child invocation and restore or remove it afterward; routine orchestration must never set it.

Each failpoint runs immediately after the named durable file replacement. Restart with the exact event and without the control; it must idempotently finish all projections or return a visible nonzero failure. Never use a failpoint for routine orchestration.
