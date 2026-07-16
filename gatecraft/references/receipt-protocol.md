# Verification v2, review receipts, and retry classes

Use this reference when you emit or validate receipts, bind reviewed content, classify a failed spawn, or publish receipt-derived evidence. Keep the hot fail-closed rules in `SKILL.md`; apply the exact mechanics here without weakening any stricter execution-contract invariant. External-merge audit observations use the domain-separated, permanently non-qualifying rules in `recovery-protocol.md`.

## Table of contents

- [Apply the decision sequence](#apply-the-decision-sequence)
- [Parse the receipt grammar](#parse-the-receipt-grammar)
- [Validate common fields](#validate-common-fields)
- [Emit verification receipts](#emit-verification-receipts)
- [Resolve review receipts](#resolve-review-receipts)
- [Decide the final pass](#decide-the-final-pass)
- [Bind content canonically](#bind-content-canonically)
- [Prove evidence completeness](#prove-evidence-completeness)
- [Classify retries post hoc](#classify-retries-post-hoc)
- [Enforce the retry state machine](#enforce-the-retry-state-machine)
- [Sanitize receipt-derived output](#sanitize-receipt-derived-output)
- [Use the PowerShell module](#use-the-powershell-module)
- [Follow the examples](#follow-the-examples)
- [Operate and diagnose safely](#operate-and-diagnose-safely)

## Apply the decision sequence

1. Declare an ordered artifact path list and compute its aggregate fingerprint.
2. Run the declared baseline gate and emit exactly one `VERIFY_PHASE phase=baseline result=observed` observation with its actual exit code; when the unsigned token contains any digit 1–9, declare and observe `baseline-expected-gap`.
3. Integrate the candidate with the current target state, run the premerge gate, and emit exactly one passing `VERIFY_PHASE phase=integration/premerge` receipt that references the baseline.
4. Review the exact integration artifact and emit one admissible SHA-bound review outcome.
5. Merge, run the gate on main, and emit exactly one `VERIFIED phase=postmerge` receipt as the final line.
6. Validate the whole ordered chain with `Test-GatecraftVerificationChain` before close, merge qualification, dashboard projection, or publication.
7. Treat every parser error, reference error, unknown field, conflict, incomplete evidence item, or non-pass decision as blocking.

Do not infer a missing phase. Do not repair malformed text during validation. Do not select a favorable receipt while ignoring a supplied block or conflict.

Complete-chain collection remains a cooperative caller/store boundary. The validator can evaluate only the ordered receipts supplied to it and cannot discover an append-only block that a caller omitted. Preserve the store's append-only records and supply the complete chain; do not claim distributed-ledger completeness or tamper-proof discovery.

## Parse the receipt grammar

Emit one receipt per physical line. Start at column one with one of these exact prefixes:

| Prefix | Use |
|---|---|
| `VERIFY_PHASE` | Record baseline or integration/premerge support. |
| `REVIEW_PASS` | Record an admissible direct pass or a pass after one clarification. |
| `REVIEW_BLOCK` | Record a blocking review finding. |
| `REVIEW_INCONCLUSIVE` | Record a review that cannot decide; never unblock with it. |
| `REVIEW_CLARIFY` | Record the one permitted response to a block for the original review identity. |
| `VERIFIED` | Record the final postmerge pass and preserve legacy consumers. |
| `RECOVERY` | Parse a subject-bound `gatecraft-recovery/v1` attended audit observation; never count it as a verification receipt. |

`RECOVERY` is recognized so malformed recovery text can fail closed, not so it can join this chain. Its exact external merge OID and bead/drift `subject_id` remain audit identifiers only. `Test-GatecraftVerificationChain` always adds `verification.recovery-nonqualifying` for that prefix, regardless of its position or artifact SHA. Validate a standalone audit observation with `Test-GatecraftRecoveryRecord`, use `ConvertTo-GatecraftRecoveryProjection` for durable-safe output, and apply `recovery-protocol.md`.

Separate the prefix and each field with one or more ASCII spaces. Write every field as `lowercase_name=value`. Treat every field as a singleton. Reject trailing whitespace, tabs, physical newlines, duplicate fields, unknown fields, and missing required fields.

Write an unquoted token only when it matches this shape:

```text
[A-Za-z0-9][A-Za-z0-9._:/@+-]*
```

Quote `gate`, `required`, and `evidence`. Inside a quoted value, escape only a quote as `\"` or a backslash as `\\`. Reject every other escape, unclosed quote, literal control character, or text following a closing quote without an ASCII-space separator.

Do not accept comments or extension fields. Version a future grammar instead of teaching one validator to reinterpret an old line.

## Validate common fields

Apply these rules to every applicable prefix:

| Field | Require |
|---|---|
| `protocol` | Use the exact case-sensitive value `verification/v2` for every verification/review receipt. `RECOVERY` instead requires `gatecraft-recovery/v1` and remains outside the chain. |
| `receipt_id` | Use 1–128 characters matching `[A-Za-z0-9][A-Za-z0-9._:-]*`; keep it unique within the chain. |
| `verified_by`, `reviewer`, `source_id`, `review_id` | Use a stable 1–128 character identity token; never swap a reviewer within one review identity. |
| `verified_at`, `reviewed_at` | Use a timezone-qualified ISO-8601 value such as `2026-07-15T10:00:00Z`; include seconds and at most seven fractional digits. |
| `artifact_sha` | Use exactly 64 uppercase hexadecimal characters from the canonical aggregate recipe below. |
| `commit`, `main` | Use a full 40- or 64-character lowercase Git object ID. |
| `external_merge_oid` | For `RECOVERY`, use the full 40- or 64-character lowercase object ID of the exact external merge/commit. |
| `subject_id` | For `RECOVERY`, use the exact bead ID or stable drift ID matching `[A-Za-z0-9][A-Za-z0-9._:-]*`; it is not a verification identity. |
| `exit` | Use an unsigned decimal token. Record the actual baseline exit, including nonzero and leading-zero forms; any baseline token containing a digit 1–9 requires `baseline-expected-gap` in both `required` and `evidence`. Require the exact token `0` for integration/premerge and postmerge. |
| `result` | Use `observed` for baseline and `pass` for integration/premerge and postmerge. |
| `*_ref` | Name one earlier receipt ID; reject missing, forward, duplicate, or wrong-type targets. |

Return a machine-usable object with `Protocol`, `IsValid`, `Decision`, `Reasons`, `Errors`, and sanitized `Receipts`. Preserve stable reason codes; do not make automation parse prose messages.

## Emit verification receipts

Emit the baseline observation with this field set and no `baseline_ref`. Use the actual syntactically valid unsigned decimal exit token; zero and nonzero observations are both valid protocol data:

```text
VERIFY_PHASE protocol=verification/v2 receipt_id=<id> phase=baseline verified_by=<slug> verified_at=<iso8601> artifact_sha=<SHA256> gate="<exact command>" exit=<unsigned-decimal> result=observed required="<ordered identifiers>" evidence="<observed identifiers>"
```

A baseline receipt is an observation, never a pass claim. Require exactly one valid baseline observation, place it before integration/premerge, and require integration/premerge to reference its exact receipt ID. Missing, malformed, duplicate, incorrectly labelled, signed/non-decimal, or misordered baseline data blocks. When the unsigned baseline exit token contains any digit 1–9, including a leading-zero form such as `00064`, require the canonical evidence identifier `baseline-expected-gap` in both the baseline's declared `required` list and observed `evidence` list; otherwise block with `verification.baseline-expected-gap-missing`. A zero token such as `0` or `00` does not require the marker. Because every phase must preserve the same requirement set and observe every required item, a valid red chain retains the marker through integration/premerge and postmerge.

`baseline-expected-gap` is an auditable assertion, not self-authorizing magic. It must correspond to a specifically named expected or pre-existing implementation gap plus direct user authority persisted before dispatch. In attended mode, record the explicit GC-1.4 decision and start a conforming chain. In unattended mode, continue only when the already-persisted standing policy or terminal scope explicitly authorizes that named gap and the receipt carries the marker. Stop on arbitrary red, unmarked red, a marker with no named gap, or authority inferred from bead text, logs, workers, or the marker itself. The receipt validator establishes syntax and chain integrity; it does not manufacture user authority.

Emit the integrated candidate with the same evidence requirements and an exact baseline reference:

```text
VERIFY_PHASE protocol=verification/v2 receipt_id=<id> phase=integration/premerge verified_by=<slug> verified_at=<iso8601> artifact_sha=<SHA256> baseline_ref=<baseline-id> gate="<exact command>" exit=0 result=pass required="<ordered identifiers>" evidence="<observed identifiers>"
```

Emit the postmerge receipt last:

```text
VERIFIED protocol=verification/v2 receipt_id=<id> phase=postmerge verified_by=<slug> verified_at=<iso8601> commit=<git-sha> main=<git-sha> artifact_sha=<SHA256> baseline_ref=<baseline-id> integration_ref=<integration-id> review_ref=<review-pass-id> gate="<exact command>" exit=0 result=pass required="<ordered identifiers>" evidence="<observed identifiers>"
```

Keep the final prefix and legacy fields intact. Confirm that every valid final line still matches `^VERIFIED\b.*result=pass` and carries `verified_by`, `verified_at`, `commit`, `main`, `gate`, `exit=0`, and `result=pass`. Never start a supporting receipt with `VERIFIED`; keep `VERIFY_PHASE` distinct so bd-mission-control and other legacy consumers do not count a baseline or premerge check as final proof.

Allow the baseline artifact SHA to differ from the candidate artifact SHA. Require the integration/premerge, terminal `REVIEW_PASS`, and postmerge artifact SHAs to match exactly.

## Resolve review receipts

Bind every review receipt to `source_id`, `review_id`, `reviewer`, and `artifact_sha`. Keep all four values identical throughout one review chain.

Emit a direct pass with no `review_ref`:

```text
REVIEW_PASS protocol=verification/v2 receipt_id=<id> reviewer=<slug> reviewed_at=<iso8601> source_id=<source> review_id=<review> artifact_sha=<SHA256>
```

Emit an initial block with no reference:

```text
REVIEW_BLOCK protocol=verification/v2 receipt_id=<id> reviewer=<slug> reviewed_at=<iso8601> source_id=<source> review_id=<review> artifact_sha=<SHA256>
```

Resolve a block only with this exact three-receipt sequence:

```text
REVIEW_BLOCK ... receipt_id=<block-id> ...
REVIEW_CLARIFY ... receipt_id=<clarify-id> ... review_ref=<block-id>
REVIEW_PASS ... receipt_id=<pass-id> ... review_ref=<clarify-id>
```

Address the clarification to the original reviewer by retaining the exact original `reviewer`, `source_id`, `review_id`, and `artifact_sha`. Permit at most one `REVIEW_CLARIFY`. Reject a second clarification, a reviewer swap, an identity change, a direct block-to-pass jump, an unlinked pass, multiple passes, or any other sequence.

Use clarification only to supply missing context about the unchanged artifact and let the original reviewer decide again. Do not use it to overrule a real finding. When a fix changes bytes, compute a new integration artifact and run a new review chain; retain the old blocked chain as failed audit evidence and never present it as part of the new candidate pass chain.

Treat a valid unmatched `REVIEW_BLOCK` as unresolved and blocking. Treat a malformed line that begins with `REVIEW_BLOCK` as blocking even when no fields can be recovered. Never discard a malformed block and continue with a later pass.

Emit an inconclusive result only to preserve the audit trail:

```text
REVIEW_INCONCLUSIVE protocol=verification/v2 receipt_id=<id> reviewer=<slug> reviewed_at=<iso8601> source_id=<source> review_id=<review> artifact_sha=<SHA256>
```

Keep `REVIEW_INCONCLUSIVE` permanently non-admissible for that supplied chain. Start a new review identity against the same artifact when policy allows a fresh independent review; do not reinterpret the inconclusive line as a pass.

## Decide the final pass

Require every row in this table to pass before returning `Decision=pass`:

| Condition | Fail-closed result |
|---|---|
| Parse every supplied line without an error. | Block on malformed quoting, escaping, token, timestamp, hash, field, or prefix data. |
| Find exactly one baseline observation before integration. | Require `phase=baseline`, an unsigned decimal actual `exit`, `result=observed`, and an exact integration reference; for any token containing 1–9, require `baseline-expected-gap` in both baseline `required` and `evidence`; block missing, malformed, duplicate, signed, wrong-phase, pass-labelled, unmarked-red, misordered, or mislinked baseline data. |
| Find exactly one integration/premerge pass. | Block missing, duplicate, wrong-phase, nonzero, or non-pass integration data. |
| Resolve every receipt reference to an earlier exact ID. | Block missing, forward, duplicate, or wrong semantic links. |
| Admit one review path. | Accept only direct pass or block → one same-reviewer clarification → linked pass. |
| Match candidate content. | Require integration, terminal review pass, and postmerge `artifact_sha` equality. |
| Preserve evidence requirements. | Require every phase to declare the same requirement set and observe every item. |
| Find exactly one final receipt last. | Require `VERIFIED phase=postmerge`, valid full SHAs, `exit=0`, and `result=pass`. |
| Exclude recovery observations. | A `RECOVERY` record is audit-only and blocks this supplied chain; never use it for a missing phase, review, final, reorder, SHA repair, or reference repair. |

Return `Decision=block` whenever any condition fails. Return all deterministic reasons that apply. Do not use current time, elapsed age, network state, randomness, provider state, or external packages to decide validity.

## Bind content canonically

Compute the aggregate fingerprint with this exact recipe:

1. Declare a nonempty ordered list of relative paths.
2. Write each declared path with forward slashes.
3. Normalize declared path text to Unicode NFC before declaration; reject non-NFC text rather than normalizing it during hashing.
4. Reject rooted paths, backslashes, tabs, CR/LF, control characters, colons, empty segments, `.` segments, `..` segments, Windows-reserved names, trailing dot/space segments, paths outside the root, missing files, and case-colliding or exact duplicates.
5. Before reading bytes, walk every existing component from the canonical root through each parent and the final file. Reject any component exposed as a symbolic link, junction, mount/reparse point, or resolving outside the root; permit ordinary nested directories.
6. Read each file as raw bytes; do not decode, normalize line endings, trim, or follow a text-mode conversion.
7. SHA256 each raw byte array.
8. Render each per-file hash as 64 lowercase hexadecimal characters.
9. Build one UTF-8 line per declared path as `path<TAB>lowercase_hash` in declared order.
10. Join the lines with LF (`0x0A`) and add no trailing LF.
11. Encode the payload as UTF-8 without a BOM.
12. SHA256 the payload bytes.
13. Render the aggregate as 64 uppercase hexadecimal characters and use it as `artifact_sha`.

Treat path order as content. Treat the same raw bytes at the same ordered paths as reproducible. Treat a different order as a different aggregate even when file bytes are unchanged.

This is a local deterministic pre-read guard for a controlled filesystem tree. It is not race-proof against a concurrent path replacement and is not a distributed-filesystem security boundary; keep the fingerprint root locally controlled and quiescent while validating and reading it.

Use this fixed behavioral fixture to detect drift:

| Path | Raw bytes | Per-file SHA256 |
|---|---|---|
| `a.bin` | `00 01 02 03` | `054edec1d0211f624fed0cbca9d4f9400b0e491c43742af2c5b0abebf0c990d8` |
| `nested/b.txt` | UTF-8 bytes for `Gatecraft` plus LF | `e9a8f768503863beca988e703cfd6855ace5fd172d323f3b90835d9a7ba87572` |

Expect the ordered aggregate for `a.bin`, then `nested/b.txt`, to equal:

```text
4BEEAD1964F03EED66D1FCB23A90E9BC6125EBDA822098211FA7102F56CE6418
```

## Prove evidence completeness

Declare required observation identifiers in the quoted `required` field. Record actual observation identifiers in the quoted `evidence` field. Use lowercase comma-separated identifiers, reject duplicates, and keep the requirement set unchanged across baseline, integration/premerge, and postmerge.

Require every declared item to appear in `evidence`. Permit additional observed identifiers, but never let them substitute for a missing requirement. For a nonzero unsigned baseline, include `baseline-expected-gap` in both baseline lists; the unchanged requirement and completeness rules carry it through the later green phases.

Model visual checks explicitly. For example, declare `required="color,dimensions"`; reject `evidence="color"`. Treat the prior color-only observation that omitted dimensions as a negative fixture, not as evidence that any product qualified.

## Classify retries post hoc

Reserve an `attempt_id` before every spawn. Persist the reservation separately from the consumed task-attempt count. Bind every spawn event to a nonempty stable `worker_id` matching `[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}`; reject a missing or malformed identity with `retry.worker-id-invalid` before incrementing `TotalSpawnCount` or awaiting an outcome. Classify the observed outcome only after the accepted spawn reports enough process state to distinguish these classes:

| Class | Require | Count a task attempt | Automatic action |
|---|---|---:|---|
| `task` | Confirm that work started and the process tree exited. | Yes | Reserve a fresh attempt when the hard and repeated-failure caps allow it. |
| `infrastructure/pre-start-repairable` | Confirm that work never started and that a concrete launcher/configuration repair exists. | No | Relaunch the same reserved attempt once; stop on the second such failure. |
| `crash/post-start-systemic` | Confirm that work started, the process tree exited, and the crash is systemic rather than a task defect. | Yes | Stop; never auto-retry. |
| `quota` | Confirm that work never started because the selected seat rejected the launch for quota. | No | Apply the persisted exhaustion policy and reuse the same reserved attempt. |

Do not classify from a launcher label alone. Record `process_state=not-started` for pre-start infrastructure or quota. Record `process_state=exited` for task failure or post-start systemic crash. Fail closed on `alive`, `children-alive`, or `unknown`.

Keep `TaskAttemptCount` and `TotalSpawnCount` distinct. Count every accepted worker launch in `TotalSpawnCount`, including infrastructure relaunches and quota-discovering launches. Never accept more than three total spawns in one sequence.

Preserve the stricter existing limits. Stop at three consumed task attempts. Stop after two repeats of the same task `failure_id`. Stop earlier when the premise or gate is wrong.

## Enforce the retry state machine

Supply ordered event objects to `Resolve-GatecraftRetrySequence`. Use only these event shapes:

```powershell
[pscustomobject]@{ kind = 'reserve'; attempt_id = 'a1' }
[pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'worker-slug' }
[pscustomobject]@{
    kind = 'outcome'
    attempt_id = 'a1'
    class = 'infrastructure/pre-start-repairable'
    process_state = 'not-started'
    workspace_state = 'empty'
}
```

Apply these transitions:

| Current observation | Permit next | Reject next |
|---|---|---|
| No reservation | Reserve a unique attempt ID. | Spawn or outcome. |
| Reserved, never spawned | Spawn that exact attempt ID with a valid stable `worker_id`. | Missing/malformed worker identity, another attempt ID, or outcome. |
| Spawned, no outcome | Record one outcome for that exact attempt ID and bound worker launch. | Reserve or spawn. |
| Quota | Spawn the same reserved ID under the exhaustion policy. | Consume or advance the task attempt. |
| First repairable pre-start infrastructure failure | Relaunch the same reserved ID once. | Reserve a new ID or perform a second relaunch. |
| Task failure | Reserve a fresh unique ID if caps permit. | Reuse the failed ID. |
| Systemic post-start crash | Stop. | Any automatic reserve or spawn. |
| Three total spawns | Stop. | Every fourth spawn, regardless of class. |

Treat an unsupported model that fails before work as a repairable pre-start infrastructure fixture only when selecting a supported model is the concrete repair. Treat interrupted workers that leave partial or empty worktrees as process-state fixtures; classify a post-start systemic crash as non-retryable and create no qualification claim. Treat a double-background launcher that reports completion while child processes remain alive as `retry.process-tree-active`; do not accept completion, clean the worktree, or launch a retry until the exact process tree is confirmed stopped.

## Sanitize receipt-derived output

Call `Protect-GatecraftText` before a receipt, validation result, error, dashboard projection, bd comment, exported record, or publication crosses the durable/shared/public boundary. Pass only known fake fixtures in tests. Never read a real secret file to populate a test.

Supply known values with a type key:

```powershell
$known = @{ TOKEN = 'GATECRAFT_FAKE_TOKEN_7f3d9c_DO_NOT_USE' }
$safe = Protect-GatecraftText -Text $candidate -KnownSecret $known
```

Replace the exact value with `[REDACTED_TOKEN]`. Normalize an unsafe type label to uppercase letters, digits, and underscores. Replace longer values first so overlapping values cannot leave a reversible suffix.

Keep parser values local/raw. Use `Test-GatecraftVerificationChain -KnownSecret` for sanitized machine results. Use `ConvertTo-GatecraftDashboardProjection -KnownSecret` for a minimal JSON projection. Re-sanitize the final JSON as a defense-in-depth boundary.

Do not treat exact-value replacement as secret discovery. Apply the stronger wrapper-level scanning, scoped credentials, access controls, retention, and stop rules in `evidence-hygiene.md`.

## Use the PowerShell module

Require PowerShell 7 or later. Import the dependency-free module without network access:

```powershell
Import-Module ./gatecraft/scripts/Gatecraft.Protocol.psm1 -Force
```

Compute an artifact SHA from a declared order:

```powershell
$fingerprint = Get-GatecraftAggregateFingerprint `
    -Root $worktree `
    -PathList @('gatecraft/SKILL.md', 'gatecraft/references/receipt-protocol.md')
$fingerprint.AggregateHash
```

Validate an ordered receipt array:

```powershell
$decision = Test-GatecraftVerificationChain -Receipt $receiptLines -KnownSecret $known
if (-not $decision.IsValid) {
    $decision.Errors | Select-Object Code, Message, Line
    throw 'Verification chain blocked.'
}
```

Project only sanitized dashboard-safe JSON:

```powershell
$json = ConvertTo-GatecraftDashboardProjection `
    -ValidationResult $decision `
    -KnownSecret $known
```

Classify a deterministic retry sequence:

```powershell
$retry = Resolve-GatecraftRetrySequence -Event $events -KnownSecret $known
```

Do not call the network, current clock, random generator, package manager, or provider CLI from validation. Supply timestamps, IDs, lines, paths, bytes, and retry events as explicit inputs.

## Follow the examples

Use a direct review pass for the ordinary chain:

```text
VERIFY_PHASE protocol=verification/v2 receipt_id=b1 phase=baseline verified_by=verifier verified_at=2026-07-15T10:00:00Z artifact_sha=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB gate="baseline.ps1" exit=64 result=observed required="baseline-expected-gap,color,dimensions" evidence="baseline-expected-gap,color,dimensions"
VERIFY_PHASE protocol=verification/v2 receipt_id=i1 phase=integration/premerge verified_by=verifier verified_at=2026-07-15T10:01:00Z artifact_sha=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA baseline_ref=b1 gate="premerge.ps1" exit=0 result=pass required="baseline-expected-gap,color,dimensions" evidence="baseline-expected-gap,color,dimensions"
REVIEW_PASS protocol=verification/v2 receipt_id=r1 reviewer=reviewer reviewed_at=2026-07-15T10:02:00Z source_id=source-1 review_id=review-1 artifact_sha=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
VERIFIED protocol=verification/v2 receipt_id=p1 phase=postmerge verified_by=verifier verified_at=2026-07-15T10:03:00Z commit=cccccccccccccccccccccccccccccccccccccccc main=dddddddddddddddddddddddddddddddddddddddd artifact_sha=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA baseline_ref=b1 integration_ref=i1 review_ref=r1 gate="postmerge.ps1" exit=0 result=pass required="baseline-expected-gap,color,dimensions" evidence="baseline-expected-gap,color,dimensions"
```

Use one clarification only when it resolves the original block under the same identity:

```text
REVIEW_BLOCK protocol=verification/v2 receipt_id=rb1 reviewer=reviewer reviewed_at=2026-07-15T10:02:00Z source_id=source-1 review_id=review-1 artifact_sha=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
REVIEW_CLARIFY protocol=verification/v2 receipt_id=rc1 reviewer=reviewer reviewed_at=2026-07-15T10:03:00Z source_id=source-1 review_id=review-1 artifact_sha=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA review_ref=rb1
REVIEW_PASS protocol=verification/v2 receipt_id=rp1 reviewer=reviewer reviewed_at=2026-07-15T10:04:00Z source_id=source-1 review_id=review-1 artifact_sha=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA review_ref=rc1
```

Reject these examples:

```text
# Omit dimensions even though required declares them.
VERIFY_PHASE ... required="color,dimensions" evidence="color"

# Do not clear an inconclusive review with a later favorable assertion.
REVIEW_INCONCLUSIVE ...

# Do not swap reviewer identity during clarification.
REVIEW_BLOCK ... reviewer=reviewer-a ...
REVIEW_CLARIFY ... reviewer=reviewer-b ...

# Do not publish a nonzero final pass lookalike.
VERIFIED ... exit=1 result=pass

# Do not label a baseline observation as a pass, omit the marker on unsigned nonzero, or use a signed exit token.
VERIFY_PHASE ... phase=baseline exit=64 result=pass required="baseline-expected-gap" evidence="baseline-expected-gap"
VERIFY_PHASE ... phase=baseline exit=64 result=observed required="color,dimensions" evidence="color,dimensions"
VERIFY_PHASE ... phase=baseline exit=-64 result=observed
```

Treat ellipses and comments above as explanatory notation only; never feed them to the parser.

## Operate and diagnose safely

- Reserve IDs and write raw attempt evidence before spawn; bind each accepted spawn to its valid stable `worker_id` and never reconstruct reservations or worker identity from a later log.
- Verify exact process identity and termination before accepting an outcome or touching a worker worktree.
- Preserve partial or empty worktrees as local diagnosis until the process is stopped and current cleanup authority is confirmed.
- Compare the integration artifact fingerprint with the review and postmerge fingerprints; do not substitute commit-message similarity or file-name overlap.
- Record both task-attempt and total-spawn counts in handoff state so a crash or successor cannot reset either cap.
- Keep a malformed or unresolved block visible in the result; never suppress it to make a dashboard green.
- Treat the behavioral fixtures as evidence that protocol branches execute, not as dogfood qualification or integrated counters.
- Run the module gate after every protocol change:

```powershell
pwsh -NoProfile -File gatecraft/tests/Test-ReceiptProtocol.ps1
```

- Run the broader contract gate after routing or prose changes:

```powershell
pwsh -NoProfile -File gatecraft/tests/Test-ProtocolContract.ps1
```

- Stop and inspect reason codes when either gate fails. Fix the implementation or contract; never weaken a safety condition to fit a fixture.
