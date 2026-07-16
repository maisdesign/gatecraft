# Raw-log and evidence hygiene

Apply this boundary to the GC-0.0 session log, GC-1.7 attempt logs, native agent transcripts, local Gatecraft runtime state, verifier captures, bd, dashboards, commits, and publications.

## Boundary

- Treat raw session logs, attempt logs, native transcripts, crash dumps, and .gatecraft/ state as local operational data.
- Keep raw operational data outside git and outside every dashboard, bd record, artifact upload, and publication.
- Treat tracked repository content, bd, dashboard/export data, shared storage, and external messages as durable/shared/public evidence.
- Allow only sanitized evidence across the durable/shared/public boundary.
- Keep the GC-0.0 append-only narrative durable against local session loss while keeping its raw form local, access-restricted, gitignored, and retention-bound.

## Restrictive local access

- Create raw-log and runtime directories under a user-controlled project location, never a web root or broadly shared temporary directory.
- Restrict access to the current user and explicitly authorized local operators by using the platform ACL or permission mechanism.
- Verify the effective access after creating the directory and record only the result, never sensitive ACL identities, in shared evidence.
- When effective access is broader than policy, prefer relocating the raw directory to an already-restricted current-user location. If no suitable location exists, ask the user before disabling inheritance or narrowing access to the current user plus explicitly authorized operators; never add principals as a remediation.
- Refuse to write raw logs through an unverified symlink, mount, network share, or directory with broader access than the selected policy.
- Preserve append-only intent for the session narrative and separate each attempt log by bead and attempt ID.

## Sanitize before crossing the boundary

- Read only the new log span needed for the current evidence item.
- Extract the minimum command, exit code, commit, observation, and timestamp needed to prove the result.
- Redact credentials, tokens, cookies, authorization headers, secret values, personal data, sensitive absolute paths, and unrelated prompt or source content.
- Replace each removed value with a typed marker such as [REDACTED_TOKEN] instead of a reversible partial value.
- Re-scan the sanitized text before writing it to bd, refreshing a dashboard/export, committing it, or publishing it.
- Record an explicit sanitization check beside the durable evidence.
- Treat a missing or uncertain redaction result as a stop condition and keep the evidence local.

## Apply the deterministic protocol boundary

- Import `scripts/Gatecraft.Protocol.psm1` under PowerShell 7 or later before emitting receipt-derived or dashboard-safe output.
- Pass already-known values to `Protect-GatecraftText` with a non-secret type label and replace exact values with typed markers such as `[REDACTED_TOKEN]`; never read a secret file merely to populate the replacement table.
- Pass the same known-value table to `Test-GatecraftVerificationChain` so its machine result and validation errors contain sanitized receipt fields.
- Pass that table to `Test-GatecraftRecoveryRecord` as well; keep the raw recovery line, both narrative fields, and the detailed audit result local. Persist only `ConvertTo-GatecraftRecoveryProjection` output, whose default allowlist retains the external merge/bead-or-drift identifiers while omitting the missing-evidence and direct-user free text so sensitive or path-like narrative content cannot cross the boundary.
- Build dashboard JSON only with `ConvertTo-GatecraftDashboardProjection`, then re-sanitize that projection before writing it.
- Keep `ConvertFrom-GatecraftReceiptLine` output local/raw; never publish parser fields directly.
- Treat deterministic exact-value replacement as one boundary control, not secret discovery; retain the broader scanning, access, retention, and wrapper-level controls above.
- Exercise only an obviously fake known value in `tests/Test-ReceiptProtocol.ps1` and prove that the exact value appears nowhere in sanitized text, validation results, or dashboard-safe projections.

## Append-only correction

- If a sensitive value is already present in an append-only bd/comment store and no supported edit exists, do not repeat the value in any follow-up.
- Append a correction that uses a typed marker such as [REDACTED_TOKEN] to identify the tainted field or record without reproducing it.
- Do not perform direct database surgery to rewrite an append-only store.
- Block every dashboard refresh, export, commit, and publication that could include the tainted record until a sanitized projection can exclude it or replace it with the typed-marker correction.
- This section defines the lived safe path; mechanical pattern enforcement remains assigned to Gatecraft bead 2.

## Retention

- Set a project retention period during GC-0.0 and record it without embedding raw content.
- Default the retention expiry for raw session and attempt logs to 30 days after the bead or orchestration stretch closes when the user sets no shorter policy and no legal or incident hold applies.
- Retain raw data only for active verification, retry diagnosis, handoff recovery, or an explicit hold.
- Retention expiry is not deletion authority: mark expired data for disposition, but never silently delete or move pre-existing material or anything whose user or project policy requires confirmation.
- A run may clean only evidence created during its own session when current authorization permits; otherwise ask the user before deleting or moving it.
- Review retained raw data at each handoff and final summary, record the disposition, and use the platform's normal local deletion mechanism only when deletion is currently authorized.
- State when storage media or backups prevent guaranteed secure erasure and avoid claiming secure deletion without evidence.
- Retain sanitized ledger lines and minimal sanitized evidence according to the project's normal durable-record policy.

## Publication rule

- Publish only sanitized evidence.
- Never publish or commit a raw session log, attempt log, native transcript, local runtime state, or unreviewed dashboard export.
- Stop publication and rotate or revoke exposed credentials immediately when raw sensitive data crosses the boundary; report the incident without repeating the exposed value.
