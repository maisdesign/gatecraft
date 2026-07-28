# Model catalog contract (`gatecraft-model-catalog/v1`)

This contract selects explicit worker and reviewer launch settings; it never changes the human-selected orchestrator model or thinking level.

## Local record

Persist a canonical UTF-8-without-BOM JSON record outside the repository at `<local-state>/model-catalog-v1/catalog.json`. It contains only `protocol`, `generated_at`, `source`, and a sorted `models` array. Every model has a stable `id`, `provider`, `roles`, `thinking_levels`, `cost_tier`, `quality_tier`, and `deprecation_state`. Reject unknown fields, duplicate IDs, unsupported thinking levels, missing provenance, non-UTC timestamps, and credentials, prompts, tokens, PIDs, or raw provider responses.

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

When the optional OmniRoute session gateway is active, its validated live `/v1/models` IDs are only another per-launch availability source. They do not supply trusted role eligibility, cost/quality tiers, thinking support, deprecation state, or sensitive-review suitability and therefore never replace this record. An automatic OmniRoute route is selectable only when its exact route ID is represented in this validated catalog for the ordinary implementer role; reviewers and sensitive reviewers require an explicit approved effective model as specified in `omniroute.md`.

## Selection and evidence

The orchestrator chooses worker/reviewer settings, not the human's own orchestrator settings. It must record only sanitized fields: catalog protocol/version, freshness state, source kind, selected model ID, selected thinking level, role, decision reason codes, and availability outcome. Retain the local catalog under the normal restricted local-state policy; never commit it or publish raw provider data.

For an active, available model with the requested supported thinking level, select the lowest `cost_tier` for `implementer` and ordinary `reviewer`; break ties by higher `quality_tier`, then ordinal model ID. `sensitive-reviewer` filters to `quality_tier=high` before applying the same tie-break. Construct the launch with explicit `--model <id>` and `--config model_reasoning_effort="<level>"`; accept it only when the launched session reports the same effective model and thinking level. A mismatch is `launch-setting-drift`, never an implicit retry with defaults.

The human may opt in to a source, a refresh authority, or an explicit one-off fallback. Silence, stale data, network availability, or a provider error is never opt-in.

## Populating the catalog from an OmniRoute gateway

A ready gateway exposes its routes at `<endpoint>/v1/models`. Those IDs are availability evidence
only: they carry no role, cost, quality, or sensitive-review eligibility, so the catalog cannot be
generated from them mechanically. Deriving `cost_tier` or `quality_tier` from a model name would be
fabrication — Gatecraft ships no auto-generator for this on purpose. Build the record by hand (or
with a reviewed one-off script) and keep two rules:

1. **Every catalogued ID must exist in the live catalog at build time.** Validate against
   `/v1/models` while writing the record, so an absent route fails there instead of failing a
   dispatch later.
2. **`cost_tier` ranks scarcity, not price.** For free routes a defensible ranking is: unlimited and
   account-free lowest, then a free tier on the user's own account, then an unofficial relay, then a
   small monthly credit allowance highest. Selection prefers the lowest tier, so the ranking decides
   which free lane absorbs ordinary work and which is held back.

Availability is not usability. A route that answers a one-line request can still be
unusable as a worker lane, and two rejections only appear at realistic size and shape: a free
tier that caps the per-request payload (HTTP 413 `Request too large`), and a model that refuses
the reasoning parameter the `anthropic` launch adapter always sends (HTTP 400
`reasoning_effort is not enabled/supported`). Both were observed on lanes that passed a small
ping — so a small ping is not evidence.

`omniroute-session.ps1 probe-models -ModelIds <id> [<id> ...]` measures this. Each probe sends a
worker-shaped request — reasoning enabled, a long system prompt, a realistic set of tool
definitions — and classifies the outcome:

| `verdict` | Meaning | Use |
| --- | --- | --- |
| `permanent` + `usable=true` | The lane accepted a worker-sized request | Catalogue it |
| `permanent` + `lane-rejected` | Rejected on its own terms (413, 400, …) | Leave it out |
| `transient` | Rate limit, cooldown, upstream fault, timeout | Unknown — never exclude on this |
| `blocked` | `probe-unauthorized` / `probe-key-missing` | The credential, not the model; the run stops |

The `transient`/`permanent` split is the point. A `429 all credentials are cooling down` was
observed on a lane that worked minutes later: treating it as a rejection would permanently
blacklist a good lane over a temporary limit. Only `permanent` verdicts are evidence.

**Warn the user before starting: this is slow.** The probes run serially and paced on purpose —
each one is a full-size request, and on a free tier a single probe can take minutes. Running them
in parallel is the fastest way to trip the very rate limits being measured. Budget minutes per
model, not seconds, and re-probe anything `transient` later rather than deciding from one run.

The probe reads the OmniRoute key from `OMNIROUTE_API_KEY` (or `ANTHROPIC_AUTH_TOKEN`) in the
inherited environment. It is never persisted, logged, or projected, and a `401`/`403` is reported
as a credential problem rather than attributed to the model.

Keep `implementer` and `reviewer` on different models. Selection would otherwise route both roles to
the same lowest-cost lane, and a review produced by the model that wrote the code shares its blind
spots — the independence the reviewer role exists for is lost silently, with every gate still green.

Gateway routes reach a Claude-Code-shaped worker through the `anthropic` adapter
(`--model <id> --effort <level>`) and a Codex-shaped worker through the `openai` adapter. Verify the
installed CLI actually accepts those flags for the version in use before accepting a launch manifest;
`Get-GatecraftProviderLaunchArguments` returns `$null` for any other provider, which blocks the
dispatch as `unsupported-provider-adapter` rather than guessing.
