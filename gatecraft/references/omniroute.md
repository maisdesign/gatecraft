# Optional OmniRoute session gateway

OmniRoute is an optional optimization layer. Gatecraft must remain fully usable when OmniRoute is absent, declined, stopped, or broken. Resolve this onboarding at the start of every orchestration session as part of GC-0.2, before any worker launch. Installation and use are separate decisions: consent to install never implies consent to route a session through it.

The runtime entry point is `scripts/omniroute-session.ps1`; it provides JSON commands for status, preferences, project policy, bounded discovery, preflight, adapter registration/start, separately confirmed source build planning/execution, and pinned install planning/execution. GC-0.2 must invoke its `status` command every session:

```powershell
pwsh -NoLogo -NoProfile -File <gatecraft-root>/scripts/omniroute-session.ps1 status
pwsh -NoLogo -NoProfile -File <gatecraft-root>/scripts/omniroute-session.ps1 resolve-policy -RepositoryRoot <target-repo>
```

`scripts/OmniRoute.psm1` owns the deterministic primitives behind that entry point. Import the module directly only for in-process policy resolution that the entry point does not expose.

## State is observed; intent is persisted

Never persist `installed=true` or `installed=false`. Recompute one of these states on every session:

| State | Meaning |
| --- | --- |
| `missing` | No valid endpoint and no supported local start adapter was discovered. |
| `installed-stopped` | A native CLI, existing Docker container, registered adapter, or supported unregistered source/desktop/service installation was discovered, but the endpoint is unreachable. |
| `ready` | `<endpoint>/v1/models` returned a valid, non-empty model list. This is sufficient even when `omniroute` is not on `PATH`. |
| `broken` | The endpoint returned an invalid catalog, or a supposedly running container was unreachable. |

Use the session entry point's `status` command (backed by `Get-GatecraftOmniRouteStatus`). Its default endpoint is `http://localhost:20128`; an endpoint must be a bare HTTP(S) origin and must not contain user information, a non-root path, a query, or a fragment. Auto-start is loopback-only.

`status` also returns `runtime_protocol` plus SHA-256 identities for the loaded module, entry point, and process host. Record these in local incident evidence whenever observed behavior disagrees with the current contract; differing hashes prove a stale/duplicate Gatecraft copy without exposing its filesystem path. When developing Gatecraft itself, update the installed/project-scoped copy before retesting rather than assuming the canonical checkout is the code being executed.

Persist only user intent at three levels:

1. Session choice (`use`, `skip`, or `none`) exists only in orchestrator memory.
2. Project policy (`ask`, `always`, `never`, or absent/inherit) lives only in the target repository's local Git config as `gatecraft.omniroute.policy`. It is not committed and does not travel through Beads.
3. Global preferences live in `%LOCALAPPDATA%\Gatecraft\preferences.json` on Windows or the XDG user-config location on Unix. They contain only `install_prompt=ask|never`, `global_use_policy=ask|always`, and the endpoint.

A separately confirmed startup adapter may be stored beside that file as `omniroute-startup.json`. It is a closed typed record, not a command: native CLI, existing Docker container, official source checkout plus the allowlisted `start`/`dev` mode, platform-compatible desktop application, or user-level systemd service. The record binds a SHA-256 executable/runner or unit hash, immutable container/image IDs, or a clean Git commit plus fixed runner hash and is revalidated immediately before every start. Source checkout validation requires a clean worktree, `package.json` name `omniroute`, the selected allowlisted mode, the exact official GitHub origin, and a fixed `scripts/dev/run-next.mjs` invocation; Gatecraft never executes the mutable npm script text. Any update, dirty checkout, replaced executable/container/unit, or identity drift invalidates standing startup authority and requires direct re-registration. A dirty but otherwise valid official checkout remains discoverable as `installed-stopped`: it may be used once only after a new direct session confirmation of its path, mode, and current runner hash, but that authority is never persisted. No arguments, environment, shell fragments, credentials, or provider configuration can be persisted in this record.

Resolution order is session choice, project policy, global policy, then the default `ask`. A malformed preference record is not silently repaired or trusted: report it and fall back to asking. Never store credentials, API keys, raw prompts, provider responses, or observed installation state in either preference location.

## Missing installation

When the observed state is `missing`, call `Resolve-GatecraftOmniRouteInstallDecision`:

- `install_prompt=never`: skip silently except for the sanitized Step 0 summary.
- `install_prompt=ask`: in attended mode ask **Install now / Ask next session / Never ask again**.
- In unattended mode, absence of an answer means skip for this session. Never install from silence or from a general unattended-operation policy.

`Ask next session` writes nothing. `Never ask again` changes only the global `install_prompt` preference. For `Install now`:

1. Obtain the current exact stable version from the official npm registry, not from a search snippet or an unpinned `latest` install.
2. Call `New-GatecraftOmniRouteInstallPlan -Version <exact-semver>` and show the user its official source, pinned version, destination scope, and exact display command.
3. After direct confirmation of that exact plan, call `Install-GatecraftOmniRoute -Version <same-semver> -UserConfirmed $true -Confirm:$false` so the already-recorded confirmation is not replaced by an interactive shell prompt.
4. Re-run status discovery. Installation success is not readiness: provider setup may still require attended work in the OmniRoute dashboard.

The helper uses the official npm package and includes optional native dependencies. It rejects an unpinned or command-shaped version. On Windows it resolves the application shims explicitly as `npm.cmd` and `omniroute.exe|omniroute.cmd`; it never passes a `.ps1` wrapper to process launch or to the OS file-association handler. Do not auto-update OmniRoute during orchestration, install a Docker image, modify a service, or select a different installer without a separate direct user decision.

## Completing the installation

`npm install --global` is not the whole installation on npm 11.16 and later. npm defers every install script it has not been told to allow, exits 0 anyway, and prints only a warning; for OmniRoute that silently skips its own postinstall plus roughly a dozen native dependencies. Neither documented remedy applies to the scope Gatecraft uses: `npm approve-scripts` refuses global installs with `EGLOBAL`, and `--allow-scripts=<pkg>` is not a valid `install` flag. Treating npm's exit code as success therefore reports a half-installed package as installed (lived, on the first real install this contract was exercised).

`Install-GatecraftOmniRoute` closes that gap inside the single install confirmation the user already gave — a confirmation to install means a confirmation to install something that works, not to stop halfway. After npm exits it resolves the global package root from `npm root --global`, runs `Invoke-GatecraftOmniRoutePostinstall`, and then requires `Test-GatecraftOmniRouteInstallHealth` to pass before returning. An unhealthy result throws `omniroute-install-health-failed:<reason>` instead of returning `Installed=$true`. Do not add a second prompt for the postinstall: it only copies already-downloaded platform-native binaries into the standalone bundle, needs no build toolchain, and is idempotent.

Never trust the postinstall's own narrative. On Windows its `wreq-js` branch prints a false-negative warning that OAuth-based providers may not work, and recommends a `cd dist && npm install wreq-js --no-save` that fails with `ERESOLVE`, when the `win32-x64-msvc` binary is in fact present and loads. Its output also embeds user-home paths. Gatecraft records only the runner's exit code and a fixed reason code, and decides health separately.

Health means all of: the resolved `omniroute.exe|omniroute.cmd` shim reports the exact installed version, and each native module (`better-sqlite3` for local state, `wreq-js` for the TLS client the OAuth providers use) loads **from both the package root and the standalone `dist/` tree**. The bundle resolves its own `node_modules`, so a module that loads from the root proves nothing about the runtime that actually serves `/v1/models`. Only the parsed semver is projected — the CLI also prints its resolved `.env` path, which is user-home-shaped. `install-health` is available as a standalone entry-point command so a later session can re-check an existing installation without reinstalling it.

## Provider onboarding is the user's own, always

The point of the gateway is a larger pool of workers: free-tier provider tokens alongside whatever paid or local accounts multi-CLI already discovered. Gatecraft takes that pool exactly as far as it can honestly go, and stops at a fixed line.

Gatecraft may: install and health-check OmniRoute, start it under the normal consent rules, open or name the local dashboard, read `/v1/models` to observe which providers actually answer, and report the gap between the models the catalog expects and the models the endpoint offers.

Gatecraft must never, on the user's behalf: create an account with any provider, complete a signup or OAuth consent screen, enter a password, solve a bot check, accept provider terms, or handle, transcribe, or store an API key. This is not a limitation of the current implementation and must not be "fixed" later. Automated signup violates essentially every provider's terms and would put the user's identity behind a credential they never saw; an OAuth consent screen is the one place the user, not an agent, authorizes access.

Provider credentials therefore never enter a Gatecraft repository, a bead, a receipt, a dashboard, a dispatch prompt, or a process command line. **A Gatecraft checkout is published; a key committed to it is a key disclosed.** OmniRoute keeps provider credentials in its own local store beside its `.env`, outside any repository Gatecraft orchestrates, and Gatecraft neither reads nor copies them. If a user asks Gatecraft to save keys "in the project", refuse and explain where they actually belong.

The supported onboarding is therefore: Gatecraft reaches a `ready` endpoint, tells the user the dashboard origin, and the user connects providers there themselves. OmniRoute ships a default `INITIAL_PASSWORD=CHANGEME`; surface that as the non-secret `default-initial-password` warning and have the user change it during that same attended pass. Afterwards Gatecraft re-reads `/v1/models` and reports the resulting worker pool as availability evidence — never as catalog authority, per the routing rules below.

## Guided onboarding

Installing and starting OmniRoute does not make it usable: a fresh instance has no provider
connected, so `/v1/models` answers with an empty catalog and every route fails. The entry point's
`onboarding` command turns that gap into an ordered, sanitized instruction list for the user
instead of a readiness failure the operator has to interpret:

```powershell
pwsh -NoLogo -NoProfile -File <gatecraft-root>/scripts/omniroute-session.ps1 onboarding
pwsh -NoLogo -NoProfile -File <gatecraft-root>/scripts/omniroute-session.ps1 onboarding -Target <omniroute-checkout>
```

It reuses `status`, adds source preflight evidence when a source checkout is known (an explicit
`-Target`, otherwise the registered adapter), and projects one `stage` plus the ordered
`next_actions` for that stage. It never connects a provider, opens a consent screen, changes a
password, or reads a credential: `configuration_owner` is always `user`, and the projection carries
no secret.

| `stage` | Meaning | `next_actions` |
| --- | --- | --- |
| `not-installed` | No endpoint and no start adapter | `install-omniroute`, or `respect-never-install` when the preference says so |
| `installed-not-running` | Discovered or registered but unreachable | `start-omniroute` |
| `running-unconfigured` | Answers on a verified loopback listener with `catalog-empty` or `authentication-required` | `change-initial-password` (when warned), `open-dashboard`, `connect-provider`, `create-api-key`, `retry-readiness` |
| `usable` | Ready with a non-empty catalog | `none` |
| `broken` | Responding but the catalog is malformed | `inspect-endpoint` |

`running-unconfigured` requires concordant evidence through `Test-GatecraftOmniRouteInstanceUnconfigured`:
the default initial-password warning, a bootstrap state that is not `configured`, a verified
loopback-only listener, and a responding-but-unusable catalog. Any single signal alone stays an
ordinary failure, so a genuinely broken instance is never presented to the user as "just needs
setup". `dashboard_url` is projected only for a loopback origin — a remote origin is never turned
into a clickable link Gatecraft has not validated.

`next_actions` name the steps; they are not authority to perform them. `none` is a sentinel and
never coexists with a real action. Which providers to connect is the user's decision: prefer
pointing them at the dashboard's own provider list over naming providers here, because that list
changes and OmniRoute's own free-tier documentation has been observed to disagree with its
provider registry.

`adapter_authority` reports the stored startup adapter independently of the stage: `valid`, `stale`,
or `none`. It matters because managed source startup runs `scripts/dev/run-next.mjs`, which
regenerates tracked files under `.source/`; a `source-checkout` registration can therefore be
invalidated by the very start it authorized, and the next session would otherwise find an
unexplained loss of standing authority. When `stale`, `re-register-adapter` is added and the user
must reconfirm path, mode, and current runner hash.

### Readiness that stops at a setup gap

A freshly installed instance listens and answers, but has no provider connected, so
`/v1/models` stays empty and readiness never arrives. Left alone, the bounded wait expires and
reports a generic `readiness-timeout` — an operator then has to guess whether the gateway is
broken or merely unconfigured. Managed source startup therefore classifies that case explicitly.

`Get-GatecraftOmniRouteSourcePreflight` reads `OMNIROUTE_BOOTSTRAPPED` alongside
`INITIAL_PASSWORD` and projects `SetupState` as `configured`, `unconfigured`, or `unknown`. Only an
explicit `true` counts as configured: an absent or unparsable marker stays `unknown` and never
authorises treating an instance as already set up. The marker's value is read but never projected,
exactly like the password.

While waiting for readiness, a managed `source-checkout` launch returns `State=needs-action` with
`ReasonCode=instance-unconfigured` when `Test-GatecraftOmniRouteInstanceUnconfigured` agrees on all
of its signals: the default initial-password warning, a `SetupState` that is not `configured`, a
verified loopback-only listener, and a probe that responded with `catalog-empty` or
`authentication-required`. Any single signal alone stays an ordinary readiness failure, so a
genuinely broken instance is never presented as "just needs setup". A verified non-loopback listener
still fails closed and reaps the tree before any of this is considered.

The `needs-action` result carries the local `DashboardUrl` (loopback origins only),
`RequiredActions` = `login`, `change-initial-password`, `configure-provider`, `retry-readiness`,
`AvailableActions` = `open-dashboard`, `use-direct-profiles`, `stop-omniroute`, the PID and start
identity, and `KeptRunningForSetup=true`. The already-authorised loopback process stays alive for
the attended setup pass and must remain in the session's process/reap manifest. Gatecraft must not
open the dashboard, change the password, add a provider, read a credential, or treat this state as
ready: it names the steps and stops. Continue orchestration on direct profiles until the human pass
is done.

A genuine `readiness-timeout` now also projects `ProbeReasonCode`, `SecurityWarnings`, and
`SetupState`, so the failure says whether nothing answered or something answered unusably — two
different problems that were previously the same message.

## Use decision

When OmniRoute is present, or immediately after verified installation, offer these attended choices whenever the resolved policy is `ask`:

| Choice | Persisted effect |
| --- | --- |
| Use this session | Session choice `use`; ask again next session. |
| Always in this project | Set local Git policy to `always`. |
| Always with Gatecraft | Set global use policy to `always`; a project override can still win. |
| Not this session | Session choice `skip`; ask again next session. |
| Never in this project | Set local Git policy to `never`. |

Use `Resolve-GatecraftOmniRouteUsePolicy` for precedence. In unattended mode, `Decision=ask` becomes a sanitized session skip; it never becomes implicit consent. A persisted `always` policy is standing authority to start and use an already installed adapter, not authority to install, update, reconfigure providers, expose a remote endpoint, or write CLI profiles.

## Start and readiness

For `Decision=use`:

1. If state is `ready`, continue.
2. If state is `installed-stopped`, run `preflight` for a discovered or registered source checkout before asking to start it. `dev` needs no production build. `start` is ready only when `.build/next/BUILD_ID` exists and is non-empty; otherwise return `Decision=needs-action`, `ReasonCode=production-build-missing`, recommend `dev`, and offer only `use-dev`, `build-with-confirmation`, or `use-direct-profiles`. Never launch first and discover this precondition from a crash, and never silently change an explicit `start` selection to `dev`.
3. A source build is a distinct mutation and permission boundary. Show `build-plan`, including the fixed `node scripts/build/build-next-isolated.mjs` command and exact Node/runner SHA-256 values, then call `build` only after direct confirmation of those same hashes. Never implement this as `npm run build`, never infer build consent from use/install/project policy, and never build in unattended mode. Re-run preflight after a successful build; a zero exit without a valid build marker is `build-output-missing`.
4. Use the entry point's `start` command with the selected typed adapter. It may start only the validated native CLI, immutable registered Docker ID, official source checkout through the fixed Node runner and explicit `start|dev` mode, platform-validated Windows/Linux/macOS desktop executable, or user-level `omniroute.service`; it never executes a persisted free-form command. Managed source startup goes through `omniroute-process-host.ps1`, forces `HOST=127.0.0.1` plus the endpoint port, and verifies the actual listener addresses after `/v1/models` becomes ready. A wildcard/non-loopback listener or unavailable listener verification fails closed and reaps the launched tree. This remains required even when the configured endpoint origin says `localhost`, because endpoint reachability does not prove bind scope.
5. Wait for a valid `/v1/models` response under the bounded readiness timeout. Directly launched processes return PID/start identity and a readiness timeout must kill and verify the observed process tree; an unavailable observation or unverifiable reap is a blocking error, not a successful fallback. The source process host resolves one existing `pwsh` application, uses the OmniRoute checkout as its explicit working directory, and drains stdout/stderr into access-restricted rotating local files capped at 64 KiB current plus 64 KiB previous per stream. A failure before the host process is created returns `process-host-launch-failed` rather than a raw PowerShell/.NET exception. On early child exit or timeout return the real child exit code, a stable diagnostic code, at most 20 sanitized lines/4,000 characters, and the local raw-log directory. Passwords, tokens, keys, user-home paths, and default `INITIAL_PASSWORD=CHANGEME` output are never projected raw; the latter becomes the non-secret `default-initial-password` warning during preflight.
6. If state is `broken`, stop gateway activation and show the reason. Do not repair, restart a running service, or rewrite configuration automatically.
7. If preflight/start/readiness fails, attended mode presents only the returned actions; unattended mode falls back to direct profiles and records the sanitized reason.

When an endpoint is ready but no restart adapter is known, gateway use still proceeds. In attended mode Gatecraft may run the bounded `discover-adapters` entry-point command; it checks native CLI, the known Docker container, conventional platform desktop locations, user systemd, and a depth/directory-capped search over conventional source roots. Show every validated candidate, including whether its current clean identity is eligible for persistence. Registering any candidate requires a separate direct confirmation of its type, absolute target, fixed mode, and identity binding; detection alone never grants future execution. After that confirmation use the entry point's `register-adapter ... -UserConfirmed` command. This lets source, desktop, package, container, and service installations converge on one startup contract without guessing a working directory or saving an arbitrary launch command. If no adapter validates, record `ready-no-restart-adapter`; future stopped sessions fall back to direct profiles until the user registers or installs a supported adapter. A directly selected but unregistered native/container candidate also requires `-UserConfirmed` for that session's `start` command; a prior global `always` use policy is not registration authority for a newly discovered executable.

The identity recheck is an honest same-user local safety boundary, not protection against a privileged or same-user process racing replacement in the final instant before execution. If the host is suspected compromised or another local process is mutating the adapter target, do not auto-start it; use direct profiles and involve the user.

Never place an API key on a process command line or in a receipt. Use only an already configured OmniRoute local context or inherited secret environment supplied by the user. Raw startup and provider logs remain local, access-restricted, size-bounded, and excluded from Beads/receipts under evidence hygiene; only their sanitized bounded projection may cross that boundary.

## Worker launch and model integrity

When gateway mode is active, rebuild and smoke-test each affected profile's launch manifest during GC-0.2. Prefer OmniRoute's config-free launchers (`omniroute launch` for Claude Code and `omniroute launch-codex` for Codex) because they inject endpoint configuration without rewriting the user's ordinary CLI configuration. Verify the exact installed-version `--help` syntax before accepting the manifest; close stdin, bind PID/process tree, preserve `BEADS_ACTOR` and profile identity, and retain Gatecraft's normal worktree and reap rules.

Do not run `setup-claude`, `setup-codex`, or another config-writing setup command as part of session activation. If the user explicitly chooses persistent OmniRoute CLI profiles, treat that as a separate configuration change outside this policy.

The live `/v1/models` IDs are availability evidence, not a trusted replacement for `gatecraft-model-catalog/v1` role, cost, quality, or sensitive-review eligibility. Routing rules are:

- ordinary implementers may use an approved automatic/cheap/fast OmniRoute route when its exact ID exists in both the valid Gatecraft catalog and the live endpoint;
- reviewers use an explicit approved model ID;
- sensitive reviewers use an explicit approved model ID and a different Gatecraft profile; automatic routing is not admissible when the effective provider/model cannot be proven;
- after launch, effective model/thinking drift remains a launch failure under `Test-GatecraftDispatchDrift`; a gateway is not permission to accept an unknown substitute.

Compression may transform ordinary worker context only. Never compress or rewrite the dispatch contract fields, secrets boundary, exact gate commands, required evidence IDs, receipt lines, review records, test output used as evidence, or cycle-end data. If fidelity cannot be bounded for those fields, disable compression for the request or use the direct profile.

Record only a sanitized session projection such as:

```text
OMNIROUTE_SESSION decision=use source=project state=ready adapter=endpoint endpoint_origin=http://localhost:20128 catalog_models=42 compression=ordinary-context-only
```

Do not record full model catalogs, keys, prompts, raw responses, headers, provider account names, or token-bearing URLs.
