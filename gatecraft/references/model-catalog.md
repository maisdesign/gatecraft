# Model catalog contract (`gatecraft-model-catalog/v1`)

This contract selects explicit worker and reviewer launch settings; it never changes the human-selected orchestrator model or thinking level.

## Local record

Persist a canonical UTF-8-without-BOM JSON record outside the repository at `<local-state>/model-catalog-v1/catalog.json`. It contains only `protocol`, `generated_at`, `source`, and a sorted `models` array. Every model has a stable `id`, `provider`, `roles`, `thinking_levels`, `cost_tier`, and `quality_tier`. Reject unknown fields, duplicate IDs, unsupported thinking levels, missing provenance, non-UTC timestamps, and credentials, prompts, tokens, PIDs, or raw provider responses.

`source` is one explicit trusted local capability probe or a user-approved static catalog. Network data is never trusted directly: a refresh command must sanitize and validate it before replacing the local record.

## Freshness and startup decision

The stale threshold is exactly 72 hours from `generated_at`. Evaluate it once when Gatecraft starts and once per resumed orchestration session; do not run a background timer.

| Catalog state | Startup action | Launch decision |
| --- | --- | --- |
| Fresh and valid | Use it. | Select an explicit model and thinking level matching role, complexity, risk, availability, and cost tier. |
| Stale and refresh authority exists | Offer one startup-only refresh; run it only after the persisted authority allows that named source. | Use the refreshed valid record, otherwise follow failure row. |
| Stale without authority or offline | Keep the stale record marked `stale`. | Require per-launch availability verification; do not silently treat it as fresh. |
| Refresh fails or result is malformed/conflicting | Preserve the last valid record and record sanitized reason code only. | No automatic fallback to another provider/model/thinking level. Ask or stop the affected launch. |
| No valid catalog | Record `catalog-unavailable`. | Stop automatic worker/reviewer selection. Human may explicitly choose a launch setting. |

Per-launch availability is separate from catalog freshness. Before a launch, verify that the named profile can actually start with the selected model and thinking level. An unsupported or rejected setting is a launch failure, not permission to substitute defaults.

## Selection and evidence

The orchestrator chooses worker/reviewer settings, not the human's own orchestrator settings. It must record only sanitized fields: catalog protocol/version, freshness state, source kind, selected model ID, selected thinking level, role, decision reason codes, and availability outcome. Retain the local catalog under the normal restricted local-state policy; never commit it or publish raw provider data.

The human may opt in to a source, a refresh authority, or an explicit one-off fallback. Silence, stale data, network availability, or a provider error is never opt-in.
