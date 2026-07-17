# ADR: Optional DebateGUI distribution and multi-instance contract (`gatecraft-debategui/v1`)

## Status and ownership

Accepted for the optional DebateGUI beads. Gatecraft owns instance publication, the local registry, the sanitized event feeds, and the optional installer/launcher. DebateGUI owns the user interface, its local bridge process, and read-only presentation of registered instances. Neither repository may mutate the other's checkout, tracker, orchestration state, or event feed.

Gatecraft remains fully functional when DebateGUI is absent, stopped, incompatible, or removed. A UI failure is never a Gatecraft failure and never blocks a bead, receipt, cycle-end event, or local guard.

## Acquisition and consent

`gatecraft-debategui/v1` uses a Gatecraft-maintained release manifest containing an HTTPS release URL, immutable archive SHA-256, DebateGUI semantic version, and this protocol version range. A clean Gatecraft clone obtains DebateGUI only through an explicit interactive `install-debategui` action. It must display the exact version, URL host, archive hash, target directory, required dependency/runtime commands, and requested network access before any download or install.

No startup check, orchestration, registry publication, or CLI command may download, install, upgrade, launch, remove, or check remotely for DebateGUI without that action. Upgrade is a separate explicit action against a newly displayed manifest. Removal is a separate explicit action and deletes only the installer-created DebateGUI directory after displaying it; it never deletes Gatecraft state, another checkout, or a user-supplied directory.

The installer verifies the manifest signature/trust source before download and the archive SHA-256 before extraction. It extracts under the user-selected local UI root, never inside the Gatecraft checkout or worktree. A failed verification leaves no trusted installed release and must not execute archive content. Network/package-manager access is opt-in per install or upgrade, never inherited from an earlier run.

## Registry and descriptor

The per-user, access-restricted registry is `<local-state>/debategui/v1/instances.json`. It is canonical UTF-8 without BOM, atomically replaced, and never committed. It has exactly `protocol`, `generated_at`, and ordinal-sorted `instances`. Each instance descriptor has only:

```json
{
  "instance_id": "opaque-base64url-id",
  "label": "safe human label",
  "protocol": "gatecraft-debategui/v1",
  "endpoint": "http://127.0.0.1:<port>/v1/instances/<id>",
  "feed": "local opaque feed reference",
  "cursor": "opaque cursor or null",
  "freshness": "UTC RFC3339",
  "lifecycle": "running|stopped|stale|incompatible",
  "capabilities": ["events.read"],
  "gatecraft_version": "semver",
  "debategui_range": "semver range"
}
```

`instance_id` is random, stable for one local Gatecraft instance, and never derived from paths, user names, repository names, ports, or feeds. `label` is supplied or generated from a fixed privacy-safe vocabulary and rejects paths, controls, URLs, credentials, tokens, and `@` identifiers. Descriptors never contain absolute paths, raw process details, environment values, repository status, credentials, or raw event payloads.

Only Gatecraft writes its own descriptor and feed. DebateGUI may read registry entries and cursor state, but does not write Gatecraft descriptors, feeds, or lifecycle status. Registry readers reject unknown fields, duplicate IDs, untrusted non-loopback endpoints, malformed protocol/version data, path traversal, and stale/malformed records.

## Multiplexed bridge, ports, and lifecycle

One installed DebateGUI process exposes one loopback-only multiplexed bridge. It reads many registered descriptors and offers one selector plus an aggregate read-only view. Per-instance UI processes are not the default and are permitted only as a future protocol version with a distinct registry namespace.

The bridge binds `127.0.0.1` only. The launcher requests an OS-assigned ephemeral port (`0`), receives the actual bound port from the bridge's machine-readable readiness record, and publishes it only after endpoint health succeeds. It never scans a port range, assumes a fixed port, exposes LAN interfaces, or overwrites an existing instance. Restart creates a new bridge endpoint when necessary, republishes it atomically, and preserves each Gatecraft instance ID and cursor.

Gatecraft updates lifecycle to `stopped` on an intentional local stop and `stale` only after a bounded failed loopback health check plus freshness expiry. Cleanup removes only stale entries owned by the current local Gatecraft instance after recording a sanitized reason; it never probes or kills an unknown process and never removes a currently compatible descriptor merely because DebateGUI is absent.

## Feed, cursor, compatibility, and migration

Each instance has a distinct append-only sanitized feed and an opaque monotonic cursor. The bridge reads by instance ID and cursor; it must never combine feeds before identity validation. Missing/corrupt cursor or feed results in per-instance `stale`/error display, not fallback to another instance or cursor reset that loses data.

Compatibility requires exact major protocol compatibility plus Gatecraft/DebateGUI ranges declared in the descriptor. An incompatible descriptor is visible as `incompatible` but is never consumed, rewritten, or auto-upgraded. `v1` migration is additive: older single-instance live bridge consumers continue using their existing endpoint/feed until explicit re-registration; new clients ignore unknown future descriptors and fail closed on malformed `v1` descriptors.

## Rejected alternatives

- Vendoring a copied DebateGUI tree in Gatecraft: ownership and release drift.
- Automatic latest-branch clone/install: executes moving remote code without consent.
- Requiring a manual DebateGUI clone: fails the clean-clone optional distribution goal.
- One UI per Gatecraft instance: cannot provide selector/aggregate default.
- One shared manually appended JSONL: loses identity, lifecycle, and cursor isolation.
- Fixed ports or non-loopback binding: collision and unnecessary network exposure.
- Copying a real `.env`: leaks credentials and couples instances to mutable external state.
