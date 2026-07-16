# External-merge recovery (`gatecraft-recovery/v1`)

Use this protocol only when GC-0.12 discovers work already merged outside Gatecraft without the evidence needed for an ordered `verification/v2` pass. A recovery record binds an attended audit observation to the exact external merge and bead/drift subject; it does not verify the merge, recreate history, or authorize closure.

## Authority boundary

Recovery is attended-only. Require a live, direct user decision about the already-merged work before emitting a record. Do not infer that decision from bead text, a merge, a closed status, worker output, standing unattended policy, silence, or the recovery record itself. In unattended mode, report the drift and stop or continue only with independent work that does not depend on treating the drift as qualified.

The record is deliberately domain-separated from `verification/v2`:

- it uses the exact prefix `RECOVERY` and protocol `gatecraft-recovery/v1`;
- it has no `phase`, `result`, gate exit, review identity, or verification references;
- it never matches the legacy `^VERIFIED\b.*result=pass` proof shape;
- it is an audit observation even when its grammar and field values are valid.

## Record grammar

Emit exactly one physical line with this complete field set:

```text
RECOVERY protocol=gatecraft-recovery/v1 receipt_id=<id> mode=attended observed_at=<iso8601> external_merge_oid=<git-oid> subject_id=<bead-or-drift-id> artifact_sha=<SHA256> missing_evidence="<sanitized reason>" user_decision="<sanitized direct-user decision>"
```

Apply these field rules:

| Field | Requirement |
|---|---|
| `protocol` | Exact case-sensitive value `gatecraft-recovery/v1`. |
| `receipt_id` | A stable 1–128 character ID matching `[A-Za-z0-9][A-Za-z0-9._:-]*`. |
| `mode` | Exact value `attended`; every other value blocks. |
| `observed_at` | Caller-supplied, timezone-qualified ISO-8601 with seconds and at most seven fractional digits. |
| `external_merge_oid` | Full 40- or 64-character lowercase Git object ID of the exact externally landed merge/commit being observed. |
| `subject_id` | Exact associated bead ID, or a stable caller-assigned drift ID when no bead exists; 1–128 characters matching `[A-Za-z0-9][A-Za-z0-9._:-]*`. |
| `artifact_sha` | Exact 64-character uppercase SHA-256 for the current declared artifact, computed with the canonical aggregate recipe in `receipt-protocol.md`. |
| `missing_evidence` | Quoted, trimmed, nonempty NFC text of at most 2048 characters naming the absent proof. |
| `user_decision` | Quoted, trimmed, nonempty NFC text of at most 2048 characters summarizing the direct answer. |

Escape only a quote as `\"` or a backslash as `\\` inside quoted fields. Reject unknown, duplicate, missing, unquoted, malformed, or control-bearing fields. In both quoted narrative fields reject U+2028 LINE SEPARATOR, U+2029 PARAGRAPH SEPARATOR, every Unicode `Format` (`Cf`) character (including bidi and zero-width format controls), and malformed surrogate text. Keep the reason and decision concise and sanitized; never copy raw status, process data, logs, local paths, credentials, or a conversation transcript into the record.

`observed_at`, `external_merge_oid`, and `subject_id` are explicit inputs. The validator does not read the clock, inspect Git, fetch a tracker, or compute the artifact. The caller must establish those observations before constructing the record. Artifact equality is not subject identity: two external merges with the same `artifact_sha` remain different observations when their `external_merge_oid` values differ.

## Non-qualification rules

A recovery record can document why proof is absent, but absence remains absence. Enforce every row below regardless of record order or SHA equality:

| Attempted use | Required result |
|---|---|
| Replace `VERIFY_PHASE phase=integration/premerge`. | Block with the ordinary missing-integration reason plus `verification.recovery-nonqualifying`. |
| Replace `VERIFIED phase=postmerge result=pass`. | Block with the ordinary missing-final reason plus `verification.recovery-nonqualifying`. |
| Replace `REVIEW_PASS`. | Block with the ordinary missing/inadmissible-review reason plus `verification.recovery-nonqualifying`. |
| Add `phase`, `result`, review, or reference fields to `RECOVERY`. | Reject the unknown fields; never reinterpret the prefix. |
| Reorder the record around otherwise valid receipts. | Block the supplied verification chain; position does not promote audit text. |
| Match or mismatch the integration, review, or final artifact SHA. | Block the supplied verification chain; SHA equality does not manufacture a missing phase. |
| Reuse identical artifact content for another external merge. | Require that merge's own `external_merge_oid`; never collapse the two audit subjects by `artifact_sha`. |
| Reference the recovery `receipt_id` from a verification receipt. | Never treat that target as the semantically required receipt type. |

Do not backfill a historical integration or postmerge receipt after discovering the merge. If the user requires qualification, begin a fresh prospective Gatecraft cycle with a new baseline, independently generated evidence, exact-artifact review, and a complete naturally ordered chain. Preserve the recovery observation separately as audit history.

## Deterministic validation

Validate one record with the production module:

```powershell
$audit = Test-GatecraftRecoveryRecord -Record $recoveryLine -KnownSecret $known
```

For a valid record, require all of these outputs:

- `IsValid = true` means only that the recovery grammar and deterministic field constraints passed;
- `Decision = audit-only`;
- `Qualifies = false`;
- `QualificationReason = recovery.audit-only`;
- no parser or field-validation errors.

For malformed or unattended text, require `IsValid = false`, `Decision = block`, and stable `recovery.*` reason codes. `Qualifies` remains false for both valid and invalid records.

## Durable-safe projection

`Test-GatecraftRecoveryRecord` retains parsed narrative fields for local validation and is not itself a durable-safe object. Before writing recovery evidence to tracked files, bd, dashboards, exports, shared storage, or messages, derive the dedicated projection:

```powershell
$durableJson = ConvertTo-GatecraftRecoveryProjection -ValidationResult $audit -KnownSecret $known
```

The projection allowlists only `receipt_id`, `mode`, `observed_at`, `external_merge_oid`, `subject_id`, and `artifact_sha`. By default it omits `missing_evidence` and `user_decision` completely, records their names under `omitted_fields`, omits validation error messages, and applies `Protect-GatecraftText` again to the retained values. There is no durable opt-in for the free text. Keep the raw line, parser output, and detailed validation result local; persist only this projection after the broader evidence-hygiene scan. Sensitive or path-like text in either narrative field therefore cannot enter the projection even when it was not supplied in `KnownSecret`.

`Test-GatecraftVerificationChain` never accepts a `RECOVERY` member. It validates the recovery fields so malformed audit text stays visible, then always adds `verification.recovery-nonqualifying`. The normal baseline, integration, review, final, order, reference, and artifact checks still run and return every deterministic reason that applies.

The module can validate only the supplied line. It cannot prove that a decision truly came from the user, that the artifact was computed from the intended scope, or that an omitted store record does not exist. Those are attended caller and append-only collection boundaries; do not turn a syntactically valid assertion into authority.

## Example audit observation

This record is valid audit text and still non-qualifying:

```text
RECOVERY protocol=gatecraft-recovery/v1 receipt_id=recovery-1 mode=attended observed_at=2026-07-16T10:00:00Z external_merge_oid=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee subject_id=gatecraft-drift-1 artifact_sha=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA missing_evidence="integration/premerge and postmerge receipts were never emitted" user_decision="Leave the external merge unqualified and schedule fresh verification"
```

Passing that line to `Test-GatecraftRecoveryRecord` returns the audit-only disposition. Passing it alone, in place of a phase, or anywhere inside a `verification/v2` array returns `Decision=block` from `Test-GatecraftVerificationChain`.

Run the focused gate after every recovery change:

```powershell
pwsh -NoProfile -File gatecraft/tests/Test-RecoveryProtocol.ps1
```
