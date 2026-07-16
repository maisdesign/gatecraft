[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failures = [Collections.Generic.List[string]]::new()

function Add-Failure {
    param([Parameter(Mandatory)][string] $Message)
    $script:failures.Add($Message)
}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )
    if (-not $Condition) {
        Add-Failure $Message
    }
}

function Assert-Equal {
    param(
        [AllowNull()]
        [object] $Actual,

        [AllowNull()]
        [object] $Expected,

        [Parameter(Mandatory)]
        [string] $Message
    )
    if ($null -eq $Expected) {
        if ($null -ne $Actual) {
            Add-Failure "$Message Expected null; found '$Actual'."
        }
        return
    }
    if ($null -eq $Actual -or $Actual -ne $Expected) {
        Add-Failure "$Message Expected '$Expected'; found '$Actual'."
    }
}

function Assert-Match {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Pattern,
        [Parameter(Mandatory)][string] $Message
    )
    if (-not [regex]::IsMatch($Text, $Pattern)) {
        Add-Failure $Message
    }
}

function Assert-NotMatch {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $Pattern,
        [Parameter(Mandatory)][string] $Message
    )
    if ([regex]::IsMatch($Text, $Pattern)) {
        Add-Failure $Message
    }
}

function Read-RequiredText {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Label
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Failure "$Label is missing at $Path."
        return ''
    }
    return [IO.File]::ReadAllText($Path)
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$contractPath = Join-Path $repoRoot 'gatecraft/references/execution-contract.md'
$hygienePath = Join-Path $repoRoot 'gatecraft/references/evidence-hygiene.md'
$receiptProtocolPath = Join-Path $repoRoot 'gatecraft/references/receipt-protocol.md'
$recoveryProtocolPath = Join-Path $repoRoot 'gatecraft/references/recovery-protocol.md'
$cycleEndReferencePath = Join-Path $repoRoot 'gatecraft/references/cycle-end.md'
$localGuardReferencePath = Join-Path $repoRoot 'gatecraft/references/local-guard.md'
$protocolModulePath = Join-Path $repoRoot 'gatecraft/scripts/Gatecraft.Protocol.psm1'
$guardScriptPath = Join-Path $repoRoot 'gatecraft/scripts/guard.ps1'
$guardShellPath = Join-Path $repoRoot 'gatecraft/scripts/guard.sh'
$cycleEndScriptPath = Join-Path $repoRoot 'gatecraft/scripts/cycle-end.ps1'
$cycleEndShellPath = Join-Path $repoRoot 'gatecraft/scripts/cycle-end.sh'
$cycleEndTestPath = Join-Path $repoRoot 'gatecraft/tests/Test-CycleEnd.ps1'
$guardTestPath = Join-Path $repoRoot 'gatecraft/tests/Test-Guard.ps1'
$receiptTestPath = Join-Path $repoRoot 'gatecraft/tests/Test-ReceiptProtocol.ps1'
$recoveryTestPath = Join-Path $repoRoot 'gatecraft/tests/Test-RecoveryProtocol.ps1'
$skillPath = Join-Path $repoRoot 'gatecraft/SKILL.md'
$dispatchPath = Join-Path $repoRoot 'gatecraft/references/dispatch-template.md'
$quotaPath = Join-Path $repoRoot 'gatecraft/references/codex-quota.md'
$changelogPath = Join-Path $repoRoot 'gatecraft/references/changelog.md'
$readmePath = Join-Path $repoRoot 'README.md'
$gitignorePath = Join-Path $repoRoot '.gitignore'

$contract = Read-RequiredText -Path $contractPath -Label 'Normative execution contract'
$hygiene = Read-RequiredText -Path $hygienePath -Label 'Raw-log hygiene reference'
$receiptProtocol = Read-RequiredText -Path $receiptProtocolPath -Label 'Receipt protocol reference'
$recoveryProtocol = Read-RequiredText -Path $recoveryProtocolPath -Label 'Recovery protocol reference'
$cycleEndReference = Read-RequiredText -Path $cycleEndReferencePath -Label 'Cycle-end reference'
$localGuardReference = Read-RequiredText -Path $localGuardReferencePath -Label 'Local guard reference'
$protocolModule = Read-RequiredText -Path $protocolModulePath -Label 'Receipt protocol module'
$guardScript = Read-RequiredText -Path $guardScriptPath -Label 'Guard PowerShell entry point'
$guardShell = Read-RequiredText -Path $guardShellPath -Label 'Guard POSIX entry point'
$cycleEndScript = Read-RequiredText -Path $cycleEndScriptPath -Label 'Cycle-end PowerShell entry point'
$cycleEndShell = Read-RequiredText -Path $cycleEndShellPath -Label 'Cycle-end POSIX entry point'
$cycleEndTest = Read-RequiredText -Path $cycleEndTestPath -Label 'Cycle-end behavioral gate'
$guardTest = Read-RequiredText -Path $guardTestPath -Label 'Guard behavioral gate'
$receiptTest = Read-RequiredText -Path $receiptTestPath -Label 'Receipt protocol behavioral gate'
$recoveryTest = Read-RequiredText -Path $recoveryTestPath -Label 'Recovery protocol behavioral gate'
$skill = Read-RequiredText -Path $skillPath -Label 'Gatecraft core skill'
$dispatch = Read-RequiredText -Path $dispatchPath -Label 'Dispatch template'
$quota = Read-RequiredText -Path $quotaPath -Label 'Quota adapter reference'
$changelog = Read-RequiredText -Path $changelogPath -Label 'Changelog'
$readme = Read-RequiredText -Path $readmePath -Label 'README'
$gitignore = Read-RequiredText -Path $gitignorePath -Label '.gitignore'

# Contract IDs, fields, ordering, modes, and imperative form.
$expectedIds = [Collections.Generic.List[string]]::new()
$expectedIds.Add('GC-0.0')
foreach ($number in 1..12) {
    $expectedIds.Add("GC-0.$number")
}
foreach ($number in 1..12) {
    $expectedIds.Add("GC-1.$number")
}

$recordPattern = '(?ms)^### (?<id>GC-\d+\.\d+)\b[^\r\n]*\r?\n(?<body>.*?)(?=^### GC-|\z)'
$records = [regex]::Matches($contract, $recordPattern)
$actualIds = @($records | ForEach-Object { $_.Groups['id'].Value })

Assert-True -Condition ($records.Count -eq $expectedIds.Count) -Message "Contract must contain exactly $($expectedIds.Count) GC records; found $($records.Count)."
Assert-True -Condition (($actualIds -join '|') -ceq (@($expectedIds) -join '|')) -Message "Contract record IDs or order differ. Expected: $(@($expectedIds) -join ', '); found: $($actualIds -join ', ')."
Assert-Match -Text $contract -Pattern '(?m)^### GC-0\.0\b.*\bBLOCKING\b' -Message 'GC-0.0 must be visibly marked BLOCKING.'

$triggerVerbs = 'Begin|Continue|Complete|Prepare|Enter|Select|Launch|Verify|Evaluate|Record|Finish'
$actionVerbs = 'Create|Check|Enumerate|Detect|Persist|Declare|Obtain|Designate|Compare|Select|Fill|Match|Set|Inspect|Pause|Apply|Lead|Append|Ask|Verify|Validate'
foreach ($record in $records) {
    $id = $record.Groups['id'].Value
    $body = $record.Groups['body'].Value
    foreach ($field in @('Trigger', 'Action', 'Evidence', 'Stop')) {
        $fieldPattern = '(?m)^- \*\*' + [regex]::Escape($field) + ':\*\*[ \t]+(?<value>\S.*)$'
        $fieldMatches = [regex]::Matches($body, $fieldPattern)
        Assert-True -Condition ($fieldMatches.Count -eq 1) -Message "$id must contain exactly one non-empty $field field; found $($fieldMatches.Count)."
        if ($fieldMatches.Count -eq 1) {
            $value = $fieldMatches[0].Groups['value'].Value
            switch ($field) {
                'Trigger' {
                    Assert-Match -Text $value -Pattern "^(?:$triggerVerbs)\b" -Message "$id Trigger must begin in imperative/infinitive form; found: $value"
                }
                'Action' {
                    Assert-Match -Text $value -Pattern "^(?:$actionVerbs)\b" -Message "$id Action must begin in imperative/infinitive form; found: $value"
                }
                'Evidence' {
                    Assert-Match -Text $value -Pattern '^Record\b' -Message "$id Evidence must begin with the imperative Record; found: $value"
                }
                'Stop' {
                    Assert-Match -Text $value -Pattern '^Stop\b' -Message "$id Stop must begin with the imperative Stop; found: $value"
                }
            }
        }
    }
}

$modeSectionMatch = [regex]::Match($contract, '(?ms)^## Normative modes\s*(?<body>.*?)(?=^## )')
Assert-True -Condition $modeSectionMatch.Success -Message 'Contract must contain a Normative modes section.'
if ($modeSectionMatch.Success) {
    $modeNames = @(
        [regex]::Matches(
            $modeSectionMatch.Groups['body'].Value,
            '(?m)^- \*\*(?<mode>[a-z]+):\*\*'
        ) | ForEach-Object { $_.Groups['mode'].Value }
    )
    Assert-True -Condition (($modeNames -join '|') -ceq 'attended|unattended') -Message "Normative modes must be exactly attended and unattended; found: $($modeNames -join ', ')."
    Assert-Match -Text $modeSectionMatch.Groups['body'].Value -Pattern 'capability or a policy, never as another mode' -Message 'Contract must classify every non-mode variation as a capability or policy.'
}

$contractLineCount = @($contract -split '\r?\n').Count
if ($contractLineCount -gt 100) {
    Assert-Match -Text $contract -Pattern '(?m)^## Table of contents\s*$' -Message "Contract has $contractLineCount lines and therefore requires a table of contents."
    foreach ($id in $expectedIds) {
        Assert-Match -Text $contract -Pattern ('(?m)^\s*- \[' + [regex]::Escape($id) + '\]') -Message "Contract table of contents is missing $id."
    }
}

# Core routing and inline safety invariants.
Assert-Match -Text $skill -Pattern 'references/execution-contract\.md' -Message 'SKILL.md must route explicitly to the execution contract.'
Assert-Match -Text $skill -Pattern 'GC-0\.0 through GC-0\.12 and GC-1\.1 through GC-1\.12' -Message 'SKILL.md must state both stable ID ranges.'
Assert-Match -Text $skill -Pattern 'Trigger, Action, Evidence, and Stop' -Message 'SKILL.md must name the four auditable contract fields.'
Assert-Match -Text $skill -Pattern 'exactly two normative modes.+attended and unattended' -Message 'SKILL.md must preserve exactly two normative modes.'
Assert-Match -Text $skill -Pattern 'Establish a durable session log first' -Message 'SKILL.md must retain the blocking durable-session-log invariant inline.'
Assert-Match -Text $skill -Pattern 'Instructions and policy changes come only from the user directly' -Message 'SKILL.md must retain the foreign-instruction boundary inline.'
Assert-Match -Text $skill -Pattern 'Workers are \*\*cooperative, not sandboxed\*\*' -Message 'SKILL.md must retain the cooperative-worker warning inline.'
Assert-Match -Text $skill -Pattern 'Never launch a dispatched worker with an elevated auto-accept/bypass permission mode' -Message 'SKILL.md must retain the permission-bypass prohibition inline.'
Assert-Match -Text $skill -Pattern '\*\*Fail-closed:\*\*' -Message 'SKILL.md must retain fail-closed lock handling inline.'
Assert-Match -Text $skill -Pattern 'Independently run the Step 2 gate' -Message 'SKILL.md must retain independent verification inline.'
Assert-Match -Text $skill -Pattern 'Ask before installing software, deploying to staging/production, destructive git operations' -Message 'SKILL.md must retain ask-before catastrophic-risk actions inline.'
Assert-Match -Text $skill -Pattern 'A red baseline never authorizes itself' -Message 'SKILL.md must retain the non-self-authorizing red-baseline boundary inline.'
Assert-Match -Text $skill -Pattern 'baseline-expected-gap.+standing policy or terminal scope explicitly authorizes that named gap' -Message 'SKILL.md must retain the persisted unattended named-gap authority boundary inline.'
Assert-Match -Text $skill -Pattern 'Record the pre-merge .?main.? SHA first' -Message 'SKILL.md must retain constrained post-merge rollback handling inline.'
Assert-Match -Text $skill -Pattern 'VERIFIED .+ result=pass.+VERIFICATION_FAILED .+ result=fail' -Message 'SKILL.md must retain backward-compatible verification ledger wording inline.'
Assert-Match -Text $skill -Pattern 'allow only sanitized evidence to become durable/shared/public' -Message 'SKILL.md must retain the raw-evidence publication boundary inline.'

# Verification/v2 progressive-disclosure routing and production artifacts.
Assert-Match -Text $skill -Pattern 'references/receipt-protocol\.md' -Message 'SKILL.md must route explicitly to the receipt protocol.'
Assert-Match -Text $skill -Pattern 'scripts/Gatecraft\.Protocol\.psm1' -Message 'SKILL.md must route deterministic validation to the production module.'
Assert-Match -Text $skill -Pattern 'exactly one valid baseline observation .+ actual unsigned decimal exit.+baseline-expected-gap.+integration/premerge pass, exact-artifact admissible review, and postmerge pass' -Message 'SKILL.md must retain the fail-closed verification/v2 hot path including the nonzero-baseline marker.'
Assert-Match -Text $skill -Pattern 'never exceed three total spawns' -Message 'SKILL.md must retain the global worker-spawn cap.'
Assert-Match -Text $contract -Pattern 'separate task-attempt and total-spawn counts' -Message 'Execution contract must keep retry counters distinct.'
Assert-Match -Text $contract -Pattern 'emit exactly one valid verification/v2 .?phase=baseline result=observed.? receipt with the actual unsigned decimal exit code' -Message 'GC-1.4 must emit the baseline observation with its actual unsigned exit.'
Assert-Match -Text $contract -Pattern 'direct user authority persisted before dispatch' -Message 'GC-1.4 must bind the nonzero-baseline marker to prior direct user authority.'
Assert-Match -Text $contract -Pattern 'standing policy or terminal scope explicitly authorizes the named gap' -Message 'GC-1.4 must permit unattended red only for the persisted named gap.'
Assert-Match -Text $contract -Pattern 'mandatory stable worker identity on every spawn' -Message 'GC-0.5 must declare identity binding for every spawn.'
Assert-Match -Text $contract -Pattern 'increment total-spawn state only after accepting that identity-bound spawn' -Message 'GC-1.7 must account only accepted identity-bound spawns.'
Assert-Match -Text $contract -Pattern 'emit one integration/premerge receipt' -Message 'GC-1.10 must emit the integration receipt before review.'
Assert-Match -Text $contract -Pattern 'Validate the ordered verification/v2 chain with Gatecraft\.Protocol\.psm1' -Message 'GC-1.11 must validate the real receipt chain.'
Assert-Match -Text $contract -Pattern 'Append exactly one `cycle-end` event.+stable event ID.+strictly monotonic positive sequence' -Message 'GC-1.12 must invoke one stable, monotonic cycle-end event.'
Assert-Match -Text $contract -Pattern 'append-only canonical receipt first.+derive the session-log, heartbeat, snapshot, and dashboard projections only from the validated receipt sequence' -Message 'GC-1.12 must make the receipt authoritative over every projection.'
Assert-Match -Text $contract -Pattern 'unattended mode fails closed.+attended mode may expose only the documented `automatic_completion=false` manual checklist' -Message 'GC-1.12 must preserve visible mode-specific projection failure behavior.'

# Attended-only external-merge recovery remains an audit observation, never proof.
Assert-Match -Text $skill -Pattern 'references/recovery-protocol\.md' -Message 'SKILL.md must route explicitly to the recovery protocol.'
Assert-Match -Text $skill -Pattern 'permanently non-qualifying.+never count or relabel it as integration/premerge.+VERIFIED result=pass.+REVIEW_PASS.+replacement phase.+ordered verification/v2 chain repair' -Message 'SKILL.md must retain the complete recovery non-qualification boundary inline.'
Assert-Match -Text $skill -Pattern 'exact external merge OID.+bead/drift subject ID.+current artifact.+observation time' -Message 'SKILL.md must bind recovery to both audit subject identifiers.'
Assert-Match -Text $skill -Pattern 'persist only `ConvertTo-GatecraftRecoveryProjection` output.+omits those free-text fields by default' -Message 'SKILL.md must route durable recovery output through the safe projection.'
Assert-Match -Text $contract -Pattern 'Only in attended mode and after a direct answer.+gatecraft-recovery/v1.+exact external merge OID.+bead ID or stable drift ID.+current artifact SHA.+observation time.+missing-evidence reason.+direct-user decision' -Message 'GC-0.12 must restrict recovery to a direct attended decision and bind both audit subject identifiers.'
Assert-Match -Text $contract -Pattern 'persist only the durable-safe projection.+external merge OID.+bead/drift subject ID.+omitted-field markers.+missing-evidence and direct-user free text remains local by default' -Message 'GC-0.12 durable evidence must omit recovery narrative text by default.'
Assert-Match -Text $contract -Pattern 'Never emit recovery in unattended mode.+never count it as integration/premerge.+postmerge `VERIFIED result=pass`.+`REVIEW_PASS`.+replacement phase.+ordered verification/v2 chain repair' -Message 'GC-0.12 must prohibit every recovery qualification substitute.'
Assert-Match -Text $recoveryProtocol -Pattern '(?m)^# External-merge recovery \(`gatecraft-recovery/v1`\)' -Message 'Recovery reference must declare its versioned protocol.'
Assert-Match -Text $recoveryProtocol -Pattern 'RECOVERY protocol=gatecraft-recovery/v1 receipt_id=<id> mode=attended observed_at=<iso8601> external_merge_oid=<git-oid> subject_id=<bead-or-drift-id> artifact_sha=<SHA256> missing_evidence=' -Message 'Recovery reference must define the complete subject-bound record grammar.'
foreach ($field in @('external_merge_oid', 'subject_id', 'artifact_sha', 'observed_at', 'missing_evidence', 'user_decision')) {
    Assert-Match -Text $recoveryProtocol -Pattern ([regex]::Escape('| `' + $field + '` |')) -Message "Recovery reference must define field $field."
}
Assert-Match -Text $recoveryProtocol -Pattern 'Artifact equality is not subject identity.+same `artifact_sha`.+`external_merge_oid` values differ' -Message 'Recovery reference must distinguish same-artifact external merges.'
Assert-Match -Text $recoveryProtocol -Pattern 'U\+2028 LINE SEPARATOR.+U\+2029 PARAGRAPH SEPARATOR.+Unicode `Format` \(`Cf`\)' -Message 'Recovery reference must reject separator and format controls in quoted text.'
Assert-Match -Text $recoveryProtocol -Pattern 'Decision = audit-only' -Message 'Valid recovery validation must return audit-only.'
Assert-Match -Text $recoveryProtocol -Pattern 'Qualifies = false' -Message 'Valid recovery validation must remain non-qualifying.'
Assert-Match -Text $recoveryProtocol -Pattern 'verification\.recovery-nonqualifying' -Message 'Recovery reference must expose the stable chain-block reason.'
Assert-Match -Text $recoveryProtocol -Pattern 'fresh prospective Gatecraft cycle' -Message 'Recovery reference must require fresh prospective proof instead of backfill.'
Assert-Match -Text $recoveryProtocol -Pattern '(?m)^## Durable-safe projection(?:\r?\n|\z)' -Message 'Recovery reference must define a dedicated durable-safe projection boundary.'
Assert-Match -Text $recoveryProtocol -Pattern '(?s)ConvertTo-GatecraftRecoveryProjection.+allowlists only.+external_merge_oid.+subject_id.+omits `missing_evidence` and `user_decision` completely' -Message 'Recovery projection contract must allowlist subject metadata and omit free text.'
Assert-Match -Text $protocolModule -Pattern '(?m)^function Test-GatecraftRecoveryRecord\s*\{' -Message 'Production validation must implement Test-GatecraftRecoveryRecord.'
Assert-Match -Text $protocolModule -Pattern '(?m)^function ConvertTo-GatecraftRecoveryProjection\s*\{' -Message 'Production validation must implement the durable-safe recovery projection.'
Assert-Match -Text $protocolModule -Pattern 'verification\.recovery-nonqualifying' -Message 'Production verification must block every recovery member.'
Assert-Match -Text $recoveryTest -Pattern 'Import-Module \$modulePath -Force' -Message 'Recovery gate must import the real production module.'
Assert-Match -Text $recoveryTest -Pattern 'valid recovery audit observation remains non-qualifying' -Message 'Recovery gate must prove a valid audit observation remains non-qualifying.'
Assert-Match -Text $recoveryTest -Pattern 'Recovery text used as integration/postmerge substitute' -Message 'Recovery gate must cover phase substitution.'
Assert-Match -Text $recoveryTest -Pattern 'Reordered/SHA-mismatched recovery variant' -Message 'Recovery gate must cover reordered and SHA-mismatched variants.'
Assert-Match -Text $recoveryTest -Pattern 'same artifact/different external merge remained distinctly bound' -Message 'Recovery gate must distinguish equal artifacts attached to different external merges.'
foreach ($separator in @('U\+2028', 'U\+2029')) {
    foreach ($field in @('missing_evidence', 'user_decision')) {
        Assert-Match -Text $recoveryTest -Pattern ($separator + ' in ' + $field) -Message "Recovery gate must reject $separator in $field."
    }
}
Assert-Match -Text $recoveryTest -Pattern '(?s)U\+202E format control.+U\+2066 format control' -Message 'Recovery gate must reject representative Unicode format controls.'
Assert-Match -Text $recoveryTest -Pattern 'durable-safe recovery projection omitted sensitive and path-like free text' -Message 'Recovery gate must prove sensitive and path-like narrative text cannot persist.'
Assert-NotMatch -Text $recoveryTest -Pattern '(?m)^function (?:Test-GatecraftRecoveryRecord|Test-GatecraftVerificationChain)\s*\{' -Message 'Recovery gate must not duplicate production validation logic.'

# Receipt-first cycle-end implementation, entry points, and recovery gate.
Assert-Match -Text $skill -Pattern 'references/cycle-end\.md' -Message 'SKILL.md must route cycle-end behavior to the focused reference.'
Assert-Match -Text $skill -Pattern 'append-only canonical receipt as the only source of truth.+session-log, heartbeat, snapshot, and dashboard files only as rebuildable projections' -Message 'SKILL.md must retain the cycle-end authority boundary inline.'
Assert-Match -Text $skill -Pattern 'Only exit 0 with `projections=complete` completes the boundary' -Message 'SKILL.md must retain the visible cycle completion condition.'
Assert-Match -Text $cycleEndReference -Pattern '(?m)^# Cycle-end event \(`gatecraft-cycle/v1`\)' -Message 'Cycle-end reference must declare the versioned event.'
Assert-Match -Text $cycleEndReference -Pattern 'same ID with different canonical fields, a sequence already owned by another ID, every gap' -Message 'Cycle-end reference must define all three identity/sequence conflicts.'
Assert-Match -Text $cycleEndReference -Pattern 'not a cooperative lock and are not race-proof against concurrent path replacement' -Message 'Cycle-end reference must state its honest no-lock filesystem boundary.'
Assert-Match -Text $cycleEndReference -Pattern 'GATECRAFT_CYCLE_END_TEST_CONTROLS.+exact value.+1.+before state-root initialization or persistence' -Message 'Cycle-end reference must document the exact test-control environment gate and pre-write rejection.'
Assert-Match -Text $cycleEndReference -Pattern 'Only exit 0 plus `CYCLE_END_COMPLETE \.\.\. projections=complete` means automatic completion' -Message 'Cycle-end reference must distinguish completion from fallback.'
Assert-Match -Text $cycleEndScript -Pattern '\[IO\.File\]::Move\(\$temporary, \$Path, \$false\)' -Message 'Canonical receipt installation must be create-only.'
Assert-Match -Text $cycleEndScript -Pattern "receiptDisposition = 'replayed'" -Message 'Cycle-end implementation must expose idempotent replay.'
Assert-Match -Text $cycleEndScript -Pattern "(?s)GATECRAFT_CYCLE_END_TEST_CONTROLS.+-cne '1'.+test-controls-disabled:.+Initialize-StateRoot" -Message 'Cycle-end implementation must reject test controls unless the exact environment opt-in is present before state initialization.'
foreach ($boundary in @('receipt', 'session-log', 'heartbeat', 'snapshot', 'dashboard')) {
    Assert-Match -Text $cycleEndScript -Pattern ([regex]::Escape("after-$boundary")) -Message "Cycle-end implementation is missing failpoint after-$boundary."
    Assert-Match -Text $cycleEndTest -Pattern ([regex]::Escape("after-$boundary")) -Message "Cycle-end behavioral gate is missing kill/replay coverage after-$boundary."
}
Assert-Match -Text $cycleEndScript -Pattern 'CYCLE_END_MANUAL_FALLBACK.+automatic_completion=false' -Message 'Attended projection failure must remain visibly incomplete.'
Assert-Match -Text $cycleEndScript -Pattern 'Unattended mode fails closed' -Message 'Unattended projection failure must fail closed.'
Assert-Match -Text $cycleEndShell -Pattern '(?m)^#!/bin/sh\s*$' -Message 'Cycle-end shell entry point must use a POSIX shell.'
Assert-Match -Text $cycleEndShell -Pattern 'exec pwsh -NoLogo -NoProfile -File "\$script_dir/cycle-end\.ps1" "\$@"' -Message 'Cycle-end shell entry point must preserve arguments and the real exit code.'
Assert-Match -Text $cycleEndTest -Pattern '\$IsWindows' -Message 'Cycle-end gate must branch explicitly by platform.'
Assert-Match -Text $cycleEndTest -Pattern 'C:\\Program Files\\Git\\bin\\bash\.exe' -Message 'Cycle-end gate must require the exact Git for Windows Bash binary on Windows.'
Assert-Match -Text $cycleEndTest -Pattern 'Get-Command -Name bash -CommandType Application' -Message 'Cycle-end gate must resolve bash as an Application from PATH on non-Windows platforms.'
Assert-Match -Text $cycleEndTest -Pattern '\$bash = \$bashCommand\.Source' -Message 'Cycle-end gate must invoke the exact non-Windows Bash executable resolved from PATH.'
Assert-Match -Text $cycleEndTest -Pattern 'GATECRAFT_CYCLE_END_TEST_CONTROLS' -Message 'Cycle-end behavioral gate must name the test-control environment opt-in.'
Assert-Match -Text $cycleEndTest -Pattern '(?s)GetEnvironmentVariable\(\$testControlsEnvironmentVariable.+finally\s*\{.+SetEnvironmentVariable\(\$testControlsEnvironmentVariable, \$previousValue' -Message 'Cycle-end behavioral gate must restore any pre-existing test-control environment value in finally.'
Assert-Match -Text $cycleEndTest -Pattern 'Invoke-WithTestControlsEnvironment -Enabled \$false' -Message 'Cycle-end behavioral gate must exercise production rejection with the test-control opt-in absent.'
Assert-Match -Text $cycleEndTest -Pattern 'WaitForExit\(\$TimeoutMilliseconds\)' -Message 'Cycle-end production-rejection fixture must enforce a hard timeout.'
Assert-Match -Text $cycleEndTest -Pattern 'ProcessStartInfo' -Message 'Cycle-end gate must use real child processes for interruption fixtures.'
Assert-Match -Text $cycleEndTest -Pattern 'Kill\(\$true\)' -Message 'Cycle-end gate must kill the exact failpoint child process tree.'
Assert-Match -Text $cycleEndTest -Pattern 'Refuse fixture cleanup outside the exact unique temp root' -Message 'Cycle-end gate must verify cleanup targets before deletion.'

# Cooperative local guard, foreign-change sweep, and exact call sites.
Assert-Match -Text $skill -Pattern 'references/local-guard\.md' -Message 'SKILL.md must route to the focused local guard reference.'
Assert-Match -Text $skill -Pattern 'cooperative and same-host/same-common-directory only.+neither replaces the durable best-effort handoff state nor joins verification/v2 or the canonical cycle-end ledger' -Message 'SKILL.md must retain the honest local guard authority boundary.'
Assert-Match -Text $contract -Pattern 'Before the first conforming orchestration action, acquire the cooperative local guard' -Message 'Execution contract must acquire before orchestration.'
Assert-Match -Text $contract -Pattern 'immediately before dispatch create the separate create-only foreign-change baseline' -Message 'GC-1.4 must create the foreign baseline before dispatch.'
Assert-Match -Text $contract -Pattern 'run the read-only dispatch-baseline foreign-change sweep immediately before commit/merge' -Message 'GC-1.10 must sweep immediately before commit/merge.'
Assert-Match -Text $contract -Pattern 'create a second create-only postmerge foreign baseline under a fresh ID' -Message 'GC-1.10 must rebaseline only after verified authorized main movement.'
Assert-Match -Text $contract -Pattern 'only after the read-only sweep of GC-1\.10.s fresh postmerge foreign baseline immediately before cycle-end exits zero' -Message 'GC-1.12 must sweep the postmerge baseline before cycle-end.'
Assert-Match -Text $contract -Pattern 'release the cooperative local guard only by its exact owner after a terminal/local boundary' -Message 'GC-1.12 must restrict release to the exact owner after the boundary.'
Assert-Match -Text $localGuardReference -Pattern '(?m)^# Cooperative local guard \(`gatecraft-local-lock/v1`\)' -Message 'Local guard reference must declare the lock protocol.'
Assert-Match -Text $localGuardReference -Pattern 'exclusive `CreateNew` open' -Message 'Local guard reference must define exclusive creation.'
Assert-Match -Text $localGuardReference -Pattern 'no automatic steal or stale recovery' -Message 'Local guard reference must prohibit stale auto-recovery.'
Assert-Match -Text $localGuardReference -Pattern 'complete raw bytes and SHA-256 of `git status --porcelain=v1 -z --untracked-files=all`' -Message 'Local guard reference must define the complete raw status baseline.'
Assert-Match -Text $localGuardReference -Pattern 'owned paths, expected-process worker IDs, parsed Git dirty paths, and recursive directory entries.+`StringComparer\.Ordinal`.+independent of `CurrentCulture` and `CurrentUICulture`' -Message 'Local guard reference must define explicit ordinal canonical and hash ordering.'
Assert-Match -Text $localGuardReference -Pattern 'A finding is observation only' -Message 'Local guard reference must preserve foreign paths.'
Assert-Match -Text $localGuardReference -Pattern 'no distributed compare-and-swap, fencing token, cross-host claim.+daemon, timer.+non-conforming writer' -Message 'Local guard reference must state the honest cooperative boundary.'
Assert-Match -Text $cycleEndReference -Pattern 'separate `local-guard\.md` sweep of GC-1\.10.s fresh verified-postmerge baseline exits zero' -Message 'Cycle-end must document its explicit preceding guard sweep.'
Assert-Match -Text $cycleEndReference -Pattern 'Cycle-end never acquires, releases, reads, or becomes authoritative over that guard' -Message 'Cycle-end must remain separate from the guard.'
Assert-Match -Text $guardScript -Pattern "rev-parse', '--path-format=absolute', '--git-common-dir'" -Message 'Guard must root the lock at Git common-dir.'
Assert-Match -Text $guardScript -Pattern '\[IO\.FileMode\]::CreateNew' -Message 'Guard must use exclusive create for lock/baseline writes.'
Assert-Match -Text $guardScript -Pattern "protocol = 'gatecraft-local-lock/v1'" -Message 'Guard must persist the versioned lock record.'
Assert-Match -Text $guardScript -Pattern "@\('status', '--porcelain=v1', '-z', '--untracked-files=all'\)" -Message 'Guard must capture exact complete porcelain state.'
Assert-Match -Text $guardScript -Pattern '@\(''--literal-pathspecs'', ''ls-files'', ''--stage'', ''-z'', ''--'', \$RelativePath\)' -Message 'Guard must fingerprint exact dirty-path index entries.'
Assert-Match -Text $guardScript -Pattern "GIT_OPTIONAL_LOCKS.*= '0'" -Message 'Guard Git reads must disable optional locks.'
Assert-Match -Text $guardScript -Pattern 'state-root-repository-overlap' -Message 'Guard must reject local evidence roots inside the checkout/common-dir.'
Assert-Match -Text $guardScript -Pattern 'sweep-repository-raced' -Message 'Guard sweep must fail closed when its observation races.'
Assert-Match -Text $guardScript -Pattern 'lock-stale-attended-recovery-required' -Message 'Guard must surface stale state without stealing.'
Assert-Match -Text $guardScript -Pattern 'GUARD_FAILED code=\$Code' -Message 'Guard must emit stable machine failure markers.'
Assert-NotMatch -Text $guardScript -Pattern "(?i)'(?:add|checkout|reset|restore|stash|clean|revert|mv|rm|commit|merge)'" -Message 'Production guard must not invoke forbidden Git mutations.'
Assert-Match -Text $guardShell -Pattern '(?m)^#!/bin/sh\s*$' -Message 'Guard shell entry point must use a POSIX shell.'
Assert-Match -Text $guardShell -Pattern 'exec pwsh -NoLogo -NoProfile -File "\$script_dir/guard\.ps1" "\$@"' -Message 'Guard shell entry point must preserve arguments and exit status.'
Assert-Match -Text $guardTest -Pattern 'C:\\Program Files\\Git\\bin\\bash\.exe' -Message 'Guard test must select exact Git for Windows Bash.'
Assert-Match -Text $guardTest -Pattern '\$bashCommand = Get-Command bash -CommandType Application' -Message 'Guard test must resolve Bash from PATH on POSIX.'
Assert-Match -Text $guardTest -Pattern 'GATECRAFT_GUARD_TEST_CONTROLS' -Message 'Guard test must exercise the exact test-control opt-in.'
Assert-Match -Text $guardTest -Pattern '(?s)acquire-barrier.+ready-one.+ready-two' -Message 'Guard test must release two real acquisitions from one barrier.'
Assert-Match -Text $guardTest -Pattern 'Wrong-token release must leave the record byte-identical' -Message 'Guard test must prove wrong-token byte preservation.'
Assert-Match -Text $guardTest -Pattern 'Invoke-ThirdShellWrite' -Message 'Guard test must edit the foreign path from a third shell.'
Assert-Match -Text $guardTest -Pattern 'Blocked sweep must leave foreign bytes exact' -Message 'Guard test must hash the foreign path across a blocked sweep.'
Assert-Match -Text $guardTest -Pattern 'Further byte changes under identical status must block' -Message 'Guard test must detect dirty worktree bytes under stable status.'
Assert-Match -Text $guardTest -Pattern 'Changed index bytes under identical status/worktree bytes must block' -Message 'Guard test must detect dirty index bytes under stable status and worktree content.'
Assert-Match -Text $guardTest -Pattern "CultureName 'de-DE'" -Message 'Guard test must baseline under an explicit de-DE child culture.'
Assert-Match -Text $guardTest -Pattern "CultureName 'sv-SE'" -Message 'Guard test must baseline under an explicit sv-SE child culture.'
Assert-Match -Text $guardTest -Pattern 'canonical baseline records must be byte-identical' -Message 'Guard test must prove exact cross-culture canonical byte equality.'
Assert-Match -Text $guardTest -Pattern 'process-start-mismatch' -Message 'Guard test must reject a live PID with the wrong start.'
Assert-Match -Text $guardTest -Pattern 'New-Item -ItemType Junction' -Message 'Guard test must reject a Windows junction guard path.'
Assert-Match -Text $guardTest -Pattern 'New-Item -ItemType SymbolicLink' -Message 'Guard test must reject the POSIX symlink equivalent.'
Assert-Match -Text $guardTest -Pattern 'Kill\(\$true\)' -Message 'Guard test must reap real child process trees.'
Assert-Match -Text $guardTest -Pattern 'Refuse fixture cleanup outside the exact unique temp root' -Message 'Guard test must constrain cleanup to its fixture root.'

$receiptLineCount = @($receiptProtocol -split '\r?\n').Count
Assert-True -Condition ($receiptLineCount -gt 100) -Message 'Receipt protocol must use the requested detailed progressive-disclosure reference.'
Assert-Match -Text $receiptProtocol -Pattern '(?m)^## Table of contents\s*$' -Message 'Receipt protocol exceeds 100 lines and must contain a table of contents.'
foreach ($heading in @(
    'Parse the receipt grammar', 'Resolve review receipts', 'Decide the final pass',
    'Bind content canonically', 'Classify retries post hoc', 'Enforce the retry state machine',
    'Sanitize receipt-derived output', 'Follow the examples', 'Operate and diagnose safely'
)) {
    Assert-Match -Text $receiptProtocol -Pattern ('(?m)^## ' + [regex]::Escape($heading) + '\s*$') -Message "Receipt protocol is missing detailed section '$heading'."
}
Assert-Match -Text $receiptProtocol -Pattern '\^VERIFIED\\b\.\*result=pass' -Message 'Receipt protocol must preserve the historic bd-mission-control regex.'
Assert-Match -Text $receiptProtocol -Pattern 'phase=baseline.+exit=<unsigned-decimal> result=observed' -Message 'Receipt protocol must define baseline as an observation with the actual unsigned exit.'
Assert-Match -Text $receiptProtocol -Pattern 'verification\.baseline-expected-gap-missing' -Message 'Receipt protocol must define the stable missing-marker reason.'
Assert-Match -Text $receiptProtocol -Pattern '\[A-Za-z0-9\]\[A-Za-z0-9\._:/@\+-\]\{0,127\}' -Message 'Receipt protocol must define the mandatory stable worker identity token.'
Assert-Match -Text $receiptProtocol -Pattern 'retry\.worker-id-invalid.+before incrementing `TotalSpawnCount` or awaiting an outcome' -Message 'Receipt protocol must reject invalid worker identity before spawn acceptance.'
Assert-Match -Text $protocolModule -Pattern 'verification\.baseline-expected-gap-missing' -Message 'Production validation must expose the stable missing expected-gap reason.'
Assert-Match -Text $protocolModule -Pattern 'retry\.worker-id-invalid' -Message 'Production retry validation must expose the stable invalid-worker reason.'
Assert-Match -Text $receiptTest -Pattern 'nonzero baseline without expected-gap marker' -Message 'Behavioral fixtures must reject an unmarked nonzero baseline.'
Assert-Match -Text $receiptTest -Pattern 'zero baseline token with no expected-gap marker must pass' -Message 'Behavioral fixtures must admit a marker-free zero baseline.'
Assert-Match -Text $receiptTest -Pattern 'spawn missing worker identity fails closed before acceptance' -Message 'Behavioral fixtures must reject a missing worker identity before acceptance.'
Assert-Match -Text $receiptTest -Pattern 'spawn malformed worker identity fails closed before acceptance' -Message 'Behavioral fixtures must reject a malformed worker identity before acceptance.'
Assert-Match -Text $receiptProtocol -Pattern 'cannot discover an append-only block that a caller omitted' -Message 'Receipt protocol must state the cooperative complete-chain collection limit.'
Assert-Match -Text $receiptProtocol -Pattern 'not race-proof against a concurrent path replacement' -Message 'Receipt protocol must state the honest local filesystem race boundary.'
Assert-Match -Text $receiptProtocol -Pattern 'path<TAB>lowercase_hash' -Message 'Receipt protocol must state the canonical aggregate payload line.'
Assert-Match -Text $receiptProtocol -Pattern 'add no trailing LF' -Message 'Receipt protocol must state the no-trailing-LF rule.'
Assert-Match -Text $receiptProtocol -Pattern '4BEEAD1964F03EED66D1FCB23A90E9BC6125EBDA822098211FA7102F56CE6418' -Message 'Receipt protocol must carry the fixed aggregate fixture.'

foreach ($functionName in @(
    'Protect-GatecraftText', 'ConvertFrom-GatecraftReceiptLine',
    'Test-GatecraftVerificationChain', 'ConvertTo-GatecraftDashboardProjection',
    'Get-GatecraftAggregateFingerprint', 'Resolve-GatecraftRetrySequence'
)) {
    Assert-Match -Text $protocolModule -Pattern ('(?m)^function ' + [regex]::Escape($functionName) + '\s*\{') -Message "Protocol module is missing $functionName."
    Assert-Match -Text $receiptTest -Pattern ([regex]::Escape($functionName)) -Message "Behavioral gate must exercise $functionName."
}
Assert-Match -Text $receiptTest -Pattern 'Import-Module \$modulePath -Force' -Message 'Receipt gate must import the real production module.'
Assert-NotMatch -Text $receiptTest -Pattern '(?m)^function (?:Test-GatecraftVerificationChain|Get-GatecraftAggregateFingerprint|Resolve-GatecraftRetrySequence)\s*\{' -Message 'Receipt gate must not duplicate production parser/hash/retry logic.'
Assert-NotMatch -Text $protocolModule -Pattern '(?i)\b(?:Get-Date|New-Guid|Invoke-WebRequest|Invoke-RestMethod|Start-BitsTransfer)\b|DateTime(?:Offset)?\]::(?:Now|UtcNow)' -Message 'Protocol validation module must not use time, randomness, or network access.'
Assert-Match -Text $receiptTest -Pattern "New-Item -ItemType Junction" -Message 'Behavioral gate must exercise an intermediate Windows junction.'
Assert-Match -Text $receiptTest -Pattern "New-Item -ItemType SymbolicLink" -Message 'Behavioral gate must exercise the POSIX symbolic-link equivalent where supported.'

foreach ($powerShellSource in @(
    [pscustomobject]@{ Label = 'Gatecraft.Protocol.psm1'; Text = $protocolModule },
    [pscustomobject]@{ Label = 'guard.ps1'; Text = $guardScript },
    [pscustomobject]@{ Label = 'cycle-end.ps1'; Text = $cycleEndScript },
    [pscustomobject]@{ Label = 'Test-Guard.ps1'; Text = $guardTest },
    [pscustomobject]@{ Label = 'Test-CycleEnd.ps1'; Text = $cycleEndTest },
    [pscustomobject]@{ Label = 'Test-ReceiptProtocol.ps1'; Text = $receiptTest },
    [pscustomobject]@{ Label = 'Test-RecoveryProtocol.ps1'; Text = $recoveryTest }
)) {
    $tokens = $null
    $parseErrors = $null
    [void] [Management.Automation.Language.Parser]::ParseInput(
        $powerShellSource.Text,
        [ref] $tokens,
        [ref] $parseErrors
    )
    foreach ($parseError in @($parseErrors)) {
        Add-Failure "$($powerShellSource.Label) has a syntax error at '$($parseError.Extent.Text)': $($parseError.Message)"
    }
}

# Absolute worktree template with both platform rules.
Assert-Match -Text $dispatch -Pattern '(?m)^Worktree: <absolute-worktree-path> on branch work/<id>-a<n>' -Message 'Dispatch template Worktree field must use <absolute-worktree-path>.'
Assert-Match -Text $dispatch -Pattern '(?m)^Worktree platform rule \(bootstrap-filled from GC-0\.3\):' -Message 'Dispatch template must include a bootstrap-filled platform rule.'
Assert-Match -Text $dispatch -Pattern 'Codex/Windows example: C:\\Users\\<user>\\codex-worktrees\\<repo>-<id>-a<n> \(under the user''s home\)' -Message "Dispatch template must show a Codex/Windows absolute worktree under the user's home."
Assert-Match -Text $dispatch -Pattern 'Unix example for /home/<user>/src/<repo>: /home/<user>/src/<repo>-wt-<id>-a<n> \(sibling of the repo\)' -Message 'Dispatch template must show an absolute Unix sibling worktree.'
Assert-NotMatch -Text $dispatch -Pattern '(?m)^Worktree: \.\./repo-wt-' -Message 'Dispatch template must not retain the relative worktree field.'

# PowerShell quota adapters, hard timeouts, at-most-once behavior, and no-data.
Assert-Match -Text $quota -Pattern 'function Get-ClaudeQuotaSnapshot' -Message 'Quota reference must include a copyable Claude PowerShell adapter.'
Assert-Match -Text $quota -Pattern 'function Get-CodexQuotaSnapshot' -Message 'Quota reference must include a copyable Codex PowerShell adapter.'
Assert-Match -Text $quota -Pattern 'function ConvertTo-GatecraftCodexQuotaSnapshot' -Message 'Quota reference must include a pure Codex window normalizer.'
Assert-Match -Text $quota -Pattern 'require PowerShell 7 or later and must be run with `pwsh`' -Message 'Quota reference must declare the PowerShell 7+ runtime requirement.'
Assert-True -Condition (([regex]::Matches($quota, "reason\s*=\s*'powershell-version-unsupported'")).Count -ge 2) -Message 'Both adapters must distinguish unsupported PowerShell from provider no-data.'
Assert-Match -Text $quota -Pattern 'Get-Command \$Command -CommandType Application, ExternalScript' -Message 'CLI resolution must exclude aliases and functions.'
Assert-Match -Text $quota -Pattern 'function New-GatecraftCmdPayload' -Message 'Quota helper must define a testable cmd/bat payload builder.'
Assert-Match -Text $quota -Pattern '\$psi\.Arguments = ''/d /s /c ''' -Message 'cmd/bat shims must use one raw pre-quoted ComSpec payload rather than ArgumentList re-quoting.'
Assert-Match -Text $quota -Pattern 'official-experimental Codex app-server' -Message 'Quota reference must identify the Codex adapter as official-experimental.'
Assert-Match -Text $quota -Pattern 'account/rateLimits/read' -Message 'Quota reference must call the structured Codex rate-limit method.'
Assert-Match -Text $quota -Pattern 'at most once after a complete bead cycle' -Message 'Quota guidance must limit adapters to at most once per cycle.'
Assert-Match -Text $quota -Pattern 'Never poll, tightly repeat, or retry an adapter in the same cycle' -Message 'Quota guidance must prohibit same-cycle retries.'
Assert-Match -Text $quota -Pattern 'hard timeout of at least 15 seconds' -Message 'Quota guidance must require a hard timeout.'
Assert-True -Condition (([regex]::Matches($quota, '\[ValidateRange\(15, 300\)\]')).Count -ge 2) -Message 'Both PowerShell adapters must enforce a timeout of at least 15 seconds.'
Assert-Match -Text $quota -Pattern '\.WaitForExit\(\$TimeoutSeconds \* 1000\)' -Message 'Claude adapter must implement its hard timeout.'
Assert-Match -Text $quota -Pattern 'AddSeconds\(\$TimeoutSeconds\)' -Message 'Codex adapter must implement a total hard deadline.'
Assert-Match -Text $quota -Pattern '\.Kill\(\$true\)' -Message 'Quota adapters must reap the process tree on timeout or completion.'
Assert-Match -Text $quota -Pattern "status\s*=\s*'no-data'" -Message 'Quota adapters must return an explicit no-data status.'
Assert-Match -Text $quota -Pattern 'usedPercent\s*=\s*\$null' -Message 'Quota adapters must represent missing percentages as null.'
Assert-Match -Text $quota -Pattern 'Never convert a missing or transient response into 0%' -Message 'Quota guidance must explicitly forbid converting missing/transient data to zero.'
Assert-Match -Text $quota -Pattern 'Do not retry in that cycle and do not synthesize a zero' -Message 'Codex transient responses must remain no-data for the cycle.'

$powerShellBlocks = [regex]::Matches($quota, '(?ms)^~~~powershell\r?\n(?<code>.*?)^~~~\s*$')
Assert-True -Condition ($powerShellBlocks.Count -ge 3) -Message "Quota reference must contain copyable PowerShell helper, Claude, and Codex blocks; found $($powerShellBlocks.Count)."
foreach ($block in $powerShellBlocks) {
    $tokens = $null
    $parseErrors = $null
    [void] [Management.Automation.Language.Parser]::ParseInput(
        $block.Groups['code'].Value,
        [ref] $tokens,
        [ref] $parseErrors
    )
    foreach ($parseError in @($parseErrors)) {
        Add-Failure "PowerShell quota example has a syntax error at '$($parseError.Extent.Text)': $($parseError.Message)"
    }
}

# Load only documented pure function bodies; never execute either live adapter.
function Get-DocumentedFunctionScriptBlock {
    param(
        [Parameter(Mandatory)]
        [Text.RegularExpressions.Match] $Block,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput(
        $Block.Groups['code'].Value,
        [ref] $tokens,
        [ref] $parseErrors
    )
    $functionAst = $ast.Find(
        {
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
        },
        $true
    )
    Assert-True -Condition ($null -ne $functionAst) -Message "Could not extract $Name from its documented block."
    if ($null -eq $functionAst) {
        return $null
    }
    $body = $functionAst.Body.Extent.Text
    return [scriptblock]::Create($body.Substring(1, $body.Length - 2))
}

$helperBlock = @(
    $powerShellBlocks | Where-Object {
        $_.Groups['code'].Value -match 'function New-GatecraftCmdPayload'
    }
) | Select-Object -First 1
$claudeBlock = @(
    $powerShellBlocks | Where-Object {
        $_.Groups['code'].Value -match 'function ConvertFrom-GatecraftClaudeUsageText'
    }
) | Select-Object -First 1
$codexBlock = @(
    $powerShellBlocks | Where-Object {
        $_.Groups['code'].Value -match 'function ConvertTo-GatecraftCodexQuotaSnapshot'
    }
) | Select-Object -First 1
Assert-True -Condition ($null -ne $helperBlock) -Message 'Could not find the documented process-helper block for fixture tests.'
Assert-True -Condition ($null -ne $claudeBlock) -Message 'Could not find the documented Claude parser block for fixture tests.'
Assert-True -Condition ($null -ne $codexBlock) -Message 'Could not find the documented Codex normalizer block for fixture tests.'

$buildCmdPayload = if ($null -ne $helperBlock) {
    Get-DocumentedFunctionScriptBlock -Block $helperBlock -Name 'New-GatecraftCmdPayload'
}
$parseClaudeUsage = if ($null -ne $claudeBlock) {
    Get-DocumentedFunctionScriptBlock -Block $claudeBlock -Name 'ConvertFrom-GatecraftClaudeUsageText'
}
$normalizeCodexQuota = $null
if ($null -ne $codexBlock) {
    $normalizeCodexQuota = Get-DocumentedFunctionScriptBlock -Block $codexBlock -Name 'ConvertTo-GatecraftCodexQuotaSnapshot'
}

if ($null -ne $buildCmdPayload) {
    $payload = & $buildCmdPayload -FilePath 'C:\Program Files\tool.cmd' -ArgumentList @('alpha', 'two words')
    Assert-Equal $payload '""C:\Program Files\tool.cmd" "alpha" "two words""' 'cmd/bat payload must preserve paths and arguments containing spaces.'
    $metacharacterRejected = $false
    try {
        [void] (& $buildCmdPayload -FilePath 'C:\tool.cmd' -ArgumentList @('unsafe&value'))
    }
    catch {
        $metacharacterRejected = $true
    }
    Assert-True -Condition $metacharacterRejected -Message 'cmd/bat payload builder must reject shell metacharacters.'
}

if ($null -ne $parseClaudeUsage) {
    $claudeNormal = & $parseClaudeUsage -Text "Current session: 42.5% used · resets 3pm"
    Assert-Equal $claudeNormal.status 'ok' 'Claude parser positive fixture status.'
    Assert-Equal $claudeNormal.usedPercent 42.5 'Claude parser positive fixture percentage.'

    $claudeMisleading = & $parseClaudeUsage -Text "Current week: 99% used`nA sentence mentions Current session: 12% used inline."
    Assert-Equal $claudeMisleading.status 'no-data' 'Claude parser must reject weekly or inline prose lookalikes.'
    Assert-Equal $claudeMisleading.usedPercent $null 'Claude misleading fixture must remain null.'
}

if ($null -ne $normalizeCodexQuota) {
    $normal = & $normalizeCodexQuota -RateLimits ([pscustomobject]@{
        primary = [pscustomobject]@{ usedPercent = 23; windowDurationMins = 300; resetsAt = 1750000300 }
        secondary = [pscustomobject]@{ usedPercent = 61; windowDurationMins = 10080; resetsAt = 1750604800 }
        planType = 'plus'
    })
    Assert-Equal $normal.status 'ok' 'Normal payload status.'
    Assert-Equal $normal.sessionAvailable $true 'Normal payload session availability.'
    Assert-Equal $normal.weeklyAvailable $true 'Normal payload weekly availability.'
    Assert-Equal $normal.sessionUsedPercent 23 'Normal payload session percentage.'
    Assert-Equal $normal.weeklyUsedPercent 61 'Normal payload weekly percentage.'
    Assert-Equal $normal.usedPercent 23 'Normal payload backward-compatible percentage.'
    Assert-Equal $normal.primaryWindowDurationMins 300 'Normal payload raw primary duration.'
    Assert-Equal $normal.secondaryResetsAt 1750604800 'Normal payload raw secondary reset.'

    $weeklyOnly = & $normalizeCodexQuota -RateLimits ([pscustomobject]@{
        primary = [pscustomobject]@{ usedPercent = 64; windowDurationMins = 10080; resetsAt = 1750604800 }
        planType = 'plus'
    })
    Assert-Equal $weeklyOnly.status 'ok' 'Weekly-only payload status.'
    Assert-Equal $weeklyOnly.sessionAvailable $false 'Weekly-only session availability.'
    Assert-Equal $weeklyOnly.weeklyAvailable $true 'Weekly-only weekly availability.'
    Assert-Equal $weeklyOnly.sessionUsedPercent $null 'Weekly-only session percentage.'
    Assert-Equal $weeklyOnly.weeklyUsedPercent 64 'Weekly-only weekly percentage.'
    Assert-Equal $weeklyOnly.usedPercent $null 'Weekly-only backward-compatible percentage.'
    Assert-Equal $weeklyOnly.primaryUsedPercent 64 'Weekly-only raw primary percentage.'

    $reversed = & $normalizeCodexQuota -RateLimits ([pscustomobject]@{
        primary = [pscustomobject]@{ usedPercent = 72; windowDurationMins = 10080; resetsAt = 1750604800 }
        secondary = [pscustomobject]@{ usedPercent = 87; windowDurationMins = 300; resetsAt = 1750000300 }
    })
    Assert-Equal $reversed.status 'ok' 'Reversed payload status.'
    Assert-Equal $reversed.sessionUsedPercent 87 'Reversed payload session percentage.'
    Assert-Equal $reversed.weeklyUsedPercent 72 'Reversed payload weekly percentage.'
    Assert-Equal $reversed.usedPercent 87 'Reversed payload backward-compatible percentage.'
    Assert-Equal $reversed.primaryWindowDurationMins 10080 'Reversed payload raw primary duration.'
    Assert-Equal $reversed.secondaryWindowDurationMins 300 'Reversed payload raw secondary duration.'

    $noWindows = & $normalizeCodexQuota -RateLimits ([pscustomobject]@{ planType = 'plus' })
    Assert-Equal $noWindows.status 'no-data' 'No-window payload status.'
    Assert-Equal $noWindows.sessionAvailable $false 'No-window session availability.'
    Assert-Equal $noWindows.weeklyAvailable $false 'No-window weekly availability.'
    Assert-Equal $noWindows.sessionUsedPercent $null 'No-window session percentage.'
    Assert-Equal $noWindows.weeklyUsedPercent $null 'No-window weekly percentage.'
    Assert-Equal $noWindows.usedPercent $null 'No-window backward-compatible percentage.'

    $unrecognized = & $normalizeCodexQuota -RateLimits ([pscustomobject]@{
        primary = [pscustomobject]@{ usedPercent = 95; windowDurationMins = 1440; resetsAt = 1750000300 }
    })
    Assert-Equal $unrecognized.status 'no-data' 'Unrecognized-duration payload status.'
    Assert-Equal $unrecognized.sessionAvailable $false 'Unrecognized-duration session availability.'
    Assert-Equal $unrecognized.weeklyAvailable $false 'Unrecognized-duration weekly availability.'
    Assert-Equal $unrecognized.usedPercent $null 'Unrecognized-duration backward-compatible percentage.'
    Assert-Equal $unrecognized.primaryUsedPercent 95 'Unrecognized-duration raw primary percentage.'
    Assert-Equal $unrecognized.primaryWindowDurationMins 1440 'Unrecognized-duration raw primary duration.'

    $outOfRangeSession = & $normalizeCodexQuota -RateLimits ([pscustomobject]@{
        primary = [pscustomobject]@{ usedPercent = 101; windowDurationMins = 300; resetsAt = 1750000300 }
        secondary = [pscustomobject]@{ usedPercent = 79; windowDurationMins = 10080; resetsAt = 1750604800 }
    })
    Assert-Equal $outOfRangeSession.status 'ok' 'Out-of-range session with valid weekly payload status.'
    Assert-Equal $outOfRangeSession.sessionAvailable $false 'Out-of-range session availability.'
    Assert-Equal $outOfRangeSession.weeklyUsedPercent 79 'Out-of-range session weekly percentage.'
    Assert-Equal $outOfRangeSession.usedPercent $null 'Out-of-range session must not drive the handoff percentage.'

    $malformedSession = & $normalizeCodexQuota -RateLimits ([pscustomobject]@{
        primary = [pscustomobject]@{ usedPercent = '42'; windowDurationMins = 300; resetsAt = 1750000300 }
    })
    Assert-Equal $malformedSession.status 'no-data' 'Malformed session payload status.'
    Assert-Equal $malformedSession.sessionAvailable $false 'Malformed session availability.'
    Assert-Equal $malformedSession.sessionUsedPercent $null 'Malformed session percentage.'
    Assert-Equal $malformedSession.usedPercent $null 'Malformed session must not drive the handoff percentage.'
    Assert-Equal $malformedSession.primaryUsedPercent '42' 'Malformed session raw primary percentage.'

    $duplicateSession = & $normalizeCodexQuota -RateLimits ([pscustomobject]@{
        primary = [pscustomobject]@{ usedPercent = 41; windowDurationMins = 300; resetsAt = 1750000300 }
        secondary = [pscustomobject]@{ usedPercent = 42; windowDurationMins = 300; resetsAt = 1750000400 }
    })
    Assert-Equal $duplicateSession.status 'no-data' 'Duplicate-session payload status.'
    Assert-Equal $duplicateSession.sessionAvailable $false 'Duplicate-session payload must be ambiguous and unavailable.'
    Assert-Equal $duplicateSession.usedPercent $null 'Duplicate-session payload must not drive handoff.'

    foreach ($invalidReset in @(
        [pscustomobject]@{ Label = 'Missing reset'; Value = $null; Include = $false },
        [pscustomobject]@{ Label = 'Fractional reset'; Value = 1750000300.5; Include = $true },
        [pscustomobject]@{ Label = 'Negative reset'; Value = -1; Include = $true }
    )) {
        $window = [ordered]@{ usedPercent = 43; windowDurationMins = 300 }
        if ($invalidReset.Include) {
            $window.resetsAt = $invalidReset.Value
        }
        $snapshot = & $normalizeCodexQuota -RateLimits ([pscustomobject]@{
            primary = [pscustomobject] $window
        })
        Assert-Equal $snapshot.status 'no-data' "$($invalidReset.Label) payload status."
        Assert-Equal $snapshot.sessionAvailable $false "$($invalidReset.Label) session availability."
        Assert-Equal $snapshot.usedPercent $null "$($invalidReset.Label) must not drive handoff."
    }
}

# Monotonic changelog and preserved historical anchors.
$dateMatches = [regex]::Matches($changelog, '(?m)^- \*\*(?<date>2026-\d{2}-\d{2})[^\r\n]*\*\*:')
Assert-True -Condition ($dateMatches.Count -ge 1) -Message 'Changelog must contain dated section headings.'
$previousDate = $null
foreach ($dateMatch in $dateMatches) {
    $dateText = $dateMatch.Groups['date'].Value
    $dateValue = [datetime]::ParseExact(
        $dateText,
        'yyyy-MM-dd',
        [Globalization.CultureInfo]::InvariantCulture
    )
    if ($null -ne $previousDate -and $dateValue -lt $previousDate) {
        Add-Failure "Changelog dates are not monotonic ascending at $dateText after $($previousDate.ToString('yyyy-MM-dd'))."
    }
    $previousDate = $dateValue
}
$position13 = $changelog.IndexOf('- **2026-07-13**:')
$position14 = $changelog.IndexOf('- **2026-07-14**:')
$position15 = $changelog.IndexOf('- **2026-07-15**:')
Assert-True -Condition ($position13 -ge 0 -and $position13 -lt $position14) -Message 'The 2026-07-13 section must precede every 2026-07-14 section.'
Assert-True -Condition ($position14 -ge 0 -and $position14 -lt $position15) -Message 'The 2026-07-15 section must follow all 2026-07-14 sections.'
Assert-Match -Text $changelog -Pattern 'Harvest from Menu-Nomade session 7''s log' -Message 'Historical 2026-07-15 wording anchor is missing.'
Assert-Match -Text $changelog -Pattern 'Five findings folded in from two orchestration sessions on OrizzonteDiploma' -Message 'Historical 2026-07-14 wording anchor is missing.'
Assert-Match -Text $changelog -Pattern 'Renamed .+ to Gatecraft, published under a fresh public repository' -Message 'Historical 2026-07-13 wording anchor is missing.'
Assert-Match -Text $changelog -Pattern 'Contract-first foundation and five approved tweaks' -Message 'The substantive contract-first change must be appended to 2026-07-15.'
Assert-Match -Text $changelog -Pattern 'Verification v2, review receipts, and retry classes' -Message 'The verification/v2 revision must amend the current 2026-07-15 entry.'
Assert-Match -Text $changelog -Pattern 'Receipt-first cycle-end MVP' -Message 'The cycle-end MVP revision must amend the current 2026-07-15 entry.'
Assert-Match -Text $changelog -Pattern 'Cooperative local guard and foreign-change sweep' -Message 'The local guard revision must amend the current 2026-07-15 entry.'
Assert-Match -Text $changelog -Pattern 'Attended external-merge recovery audit' -Message 'The recovery protocol revision must be recorded in the changelog.'

# Raw-log ignore boundary and documentation.
foreach ($pattern in @('log/', '/logs/', '/.llm/runtime/', '/.gatecraft/', '*.attempt-*.log', '*.raw-session.*')) {
    $escaped = [regex]::Escape($pattern)
    Assert-Match -Text $gitignore -Pattern ("(?m)^$escaped\s*$") -Message ".gitignore is missing Gatecraft raw/runtime pattern: $pattern"
}
Assert-Match -Text $hygiene -Pattern 'Restrict access to the current user and explicitly authorized local operators' -Message 'Evidence hygiene must require restrictive local access.'
Assert-Match -Text $hygiene -Pattern 'Redact credentials, tokens, cookies, authorization headers' -Message 'Evidence hygiene must require redaction.'
Assert-Match -Text $hygiene -Pattern 'before writing it to bd, refreshing a dashboard/export, committing it, or publishing it' -Message 'Evidence hygiene must enforce redaction at bd/dashboard/publication boundaries.'
Assert-Match -Text $hygiene -Pattern 'Default the retention expiry for raw session and attempt logs to 30 days' -Message 'Evidence hygiene must define a retention default without granting deletion authority.'
Assert-Match -Text $hygiene -Pattern 'ask the user before disabling inheritance or narrowing access' -Message 'Evidence hygiene must make ACL remediation ask-before.'
Assert-Match -Text $hygiene -Pattern 'never add principals as a remediation' -Message 'Evidence hygiene must forbid broadening ACLs as remediation.'
Assert-Match -Text $hygiene -Pattern 'Retention expiry is not deletion authority' -Message 'Evidence expiry must not silently authorize deletion.'
Assert-Match -Text $hygiene -Pattern 'Do not perform direct database surgery' -Message 'Append-only correction must forbid unsupported database surgery.'
Assert-Match -Text $hygiene -Pattern 'sanitized projection can exclude it or replace it with the typed-marker correction' -Message 'Tainted durable evidence must block unsanitized projection.'
Assert-Match -Text $hygiene -Pattern 'Allow only sanitized evidence across the durable/shared/public boundary' -Message 'Evidence hygiene must allow only sanitized durable/shared/public evidence.'
Assert-Match -Text $hygiene -Pattern 'Never publish or commit a raw session log, attempt log, native transcript, local runtime state' -Message 'Evidence hygiene must forbid durable/public raw logs and runtime state.'
Assert-Match -Text $hygiene -Pattern 'Pass the same known-value table to `Test-GatecraftVerificationChain`' -Message 'Evidence hygiene must route sanitized validation through the production module.'
Assert-Match -Text $hygiene -Pattern 'Test-GatecraftRecoveryRecord.+raw recovery line.+narrative fields.+detailed audit result local.+ConvertTo-GatecraftRecoveryProjection.+sensitive or path-like narrative content cannot cross the boundary' -Message 'Evidence hygiene must route only the safe recovery projection across the durable boundary.'
Assert-Match -Text $hygiene -Pattern 'Keep `ConvertFrom-GatecraftReceiptLine` output local/raw' -Message 'Evidence hygiene must keep raw parser output behind the boundary.'
Assert-Match -Text $contract -Pattern 'user-approved project \.gitignore rule.+local \.git/info/exclude.+outside the repository' -Message 'GC-0.0 must define a non-silent target-repository ignore mechanism.'
Assert-Match -Text $skill -Pattern 'without silently editing the user''s tracked `\.gitignore`' -Message 'SKILL.md must retain the target-repository ignore boundary inline.'
Assert-Match -Text (Read-RequiredText -Path (Join-Path $repoRoot 'gatecraft/references/handoff-protocol.md') -Label 'Handoff protocol') -Pattern 'tiers below apply only when a trustworthy short-session value is available' -Message 'Handoff tiers must never use weekly-only usage.'

# README truth in both languages and repository layout.
$englishMatch = [regex]::Match($readme, '(?s)### Orchestrator seat compatibility(?<body>.*?)(?=### Repository layout)')
$italianMatch = [regex]::Match($readme, '(?s)### Compatibilità della sedia dell''orchestratore(?<body>.*?)(?=### Struttura del repository)')
Assert-True -Condition $englishMatch.Success -Message 'README English orchestrator compatibility section is missing.'
Assert-True -Condition $italianMatch.Success -Message 'README Italian orchestrator compatibility section is missing.'
if ($englishMatch.Success) {
    $english = $englishMatch.Groups['body'].Value
    Assert-Match -Text $english -Pattern 'Claude Code is the most field-tested orchestrator seat, not a categorical requirement' -Message 'README English must state the narrower Claude field-tested truth.'
    Assert-Match -Text $english -Pattern 'Codex also has a verified official-experimental structured quota adapter' -Message 'README English must state the verified Codex structured adapter.'
    foreach ($capability in @('self-identification', 'usage introspection', 'non-interactive launch', 'ACK/lock acquisition', 'process-tree reap')) {
        Assert-Match -Text $english -Pattern ([regex]::Escape($capability)) -Message "README English is missing orchestrator smoke-test capability: $capability"
    }
}
if ($italianMatch.Success) {
    $italian = $italianMatch.Groups['body'].Value
    Assert-Match -Text $italian -Pattern 'Claude Code è la sedia di orchestrazione più collaudata sul campo, non un requisito categorico' -Message 'README Italian must state the narrower Claude field-tested truth.'
    Assert-Match -Text $italian -Pattern 'Codex dispone di un adapter strutturato verificato e ufficiale-sperimentale' -Message 'README Italian must state the verified Codex structured adapter.'
    foreach ($capability in @('auto-identificazione', 'lettura dell''uso', 'avvio non interattivo', 'ACK/acquisizione del lock', 'reap dell''albero dei processi')) {
        Assert-Match -Text $italian -Pattern ([regex]::Escape($capability)) -Message "README Italian is missing orchestrator smoke-test capability: $capability"
    }
}
Assert-NotMatch -Text $readme -Pattern 'orchestrator role is Claude Code.specific' -Message 'README must not claim that the orchestrator role is Claude-only.'
Assert-NotMatch -Text $readme -Pattern 'ruolo di orchestratore è specifico di Claude Code' -Message 'README Italian must not claim that the orchestrator role is Claude-only.'
foreach ($newFile in @(
    'execution-contract.md', 'local-guard.md', 'cycle-end.md', 'evidence-hygiene.md', 'receipt-protocol.md', 'recovery-protocol.md',
    'Gatecraft.Protocol.psm1', 'guard.ps1', 'guard.sh', 'cycle-end.ps1', 'cycle-end.sh',
    'Test-Guard.ps1', 'Test-CycleEnd.ps1', 'Test-ReceiptProtocol.ps1', 'Test-RecoveryProtocol.ps1', 'Test-ProtocolContract.ps1'
)) {
    $count = [regex]::Matches($readme, [regex]::Escape($newFile)).Count
    Assert-True -Condition ($count -ge 2) -Message "README repository layouts must list $newFile in both languages; found $count occurrence(s)."
}
Assert-True -Condition (([regex]::Matches($readme, 'pwsh -NoProfile -File gatecraft/tests/Test-ProtocolContract\.ps1')).Count -ge 2) -Message 'README must give the exact maintainer gate command in both languages.'
Assert-True -Condition (([regex]::Matches($readme, 'pwsh -NoProfile -File gatecraft/tests/Test-ReceiptProtocol\.ps1')).Count -ge 2) -Message 'README must give the exact receipt gate command in both languages.'
Assert-True -Condition (([regex]::Matches($readme, 'pwsh -NoProfile -File gatecraft/tests/Test-RecoveryProtocol\.ps1')).Count -ge 2) -Message 'README must give the exact recovery gate command in both languages.'
Assert-True -Condition (([regex]::Matches($readme, 'pwsh -NoProfile -File gatecraft/tests/Test-CycleEnd\.ps1')).Count -ge 2) -Message 'README must give the exact cycle-end gate command in both languages.'
Assert-True -Condition (([regex]::Matches($readme, 'pwsh -NoProfile -File gatecraft/tests/Test-Guard\.ps1')).Count -ge 2) -Message 'README must give the exact guard gate command in both languages.'

if ($failures.Count -gt 0) {
    [Console]::Error.WriteLine("Protocol contract gate failed with $($failures.Count) issue(s):")
    foreach ($failure in $failures) {
        [Console]::Error.WriteLine(" - $failure")
    }
    exit 1
}

Write-Host "Protocol contract gate passed: $($records.Count) records, exactly two modes, all requested acceptance checks green."
exit 0
