Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Gatecraft.Protocol.psm1') -Force

function Write-EnforceGateUsage {
    [Console]::Out.WriteLine(@'
Usage:
  enforce-gate.ps1 check-merge --repository-root <absolute-path> (--bead-id <id> | --receipt-file <path>) --artifact-sha <64-hex-uppercase> [--low-risk-no-review-required]
  enforce-gate.ps1 check-close --repository-root <absolute-path> (--bead-id <id> | --receipt-file <path>)
  enforce-gate.ps1 check-push --repository-root <absolute-path> --target <branch-name>

Blocking precondition gate for gatecraft's own critical invariants (gatecraft-i4j):
this exists so a merge/close/push cannot proceed just because an orchestrator
session forgot or misremembered a prose rule -- each check fails with a
non-zero exit and a code naming exactly which artifact is missing, rather than
silently letting the action through.

check-merge requires: the local cooperative guard (scripts/guard.ps1) is
currently held by a LIVE process (matched by PID + canonical process start
against <git-common-dir>/gatecraft-local-guard-v1/holder.json); a valid
VERIFY_PHASE phase=baseline result=observed receipt line exists for the bead;
and, by DEFAULT, a REVIEW_PASS line bound to the exact --artifact-sha. Review
is required unless the caller explicitly opts out with
--low-risk-no-review-required (deliberately long and hard to pass by accident
-- review round 1 finding, codex/lavoro: an opt-in `--require-review` flag
left the safe behavior dependent on the caller remembering to add it on every
sensitive-path call, the exact prose-discipline failure mode this bead exists
to close). This check is deliberately lighter than scripts/guard.ps1 itself:
it is a read-only informational precondition, not a lifecycle mutation, so it
does not pin native process handles the way guard.ps1 does -- a lock released
a moment after this check runs is a real (if narrow) gap the same class as
any TOCTOU check, accepted here because the alternative (no check at all) is
strictly worse.

check-close requires the full verification/v2 chain (baseline, integration/
premerge, optional review, postmerge VERIFIED) to validate with zero issues,
reusing Test-GatecraftVerificationChain from Gatecraft.Protocol.psm1 rather
than reimplementing its grammar/ordering rules.

check-push requires an explicit push-policy file at
<repository-root>/.beads/gatecraft-push-policy.json (protocol
gatecraft-push-policy/v1). mode=manual-only always fails closed (matches
"never auto-push" -- an automated push is never authorized under that
policy, no matter the target). mode=branch-only requires --target to exactly
match the configured authorized_branch.

--receipt-file is test-only wiring, gated behind
GATECRAFT_ENFORCE_GATE_TEST_CONTROLS=1 the same way scripts/guard.ps1 gates
its own test-only surfaces (review round 2 finding, codex/lavoro: an
ungated --receipt-file let any caller substitute a fabricated file for real
bd state, defeating the whole mechanism's anti-forgery purpose). Without
that variable set to exactly '1' it fails closed with
argument-receipt-file-test-only regardless of what path is given. When
enabled, it reads receipt lines from a plain UTF-8 file (one candidate line
per line) instead of fetching bd comments, so Test-EnforceGate.ps1 can
exercise this script deterministically without a live bd database.
Production callers never set that variable and always pass --bead-id.
'@)
}

function Complete-EnforceGate {
    param([Parameter(Mandatory)][string] $Code, [string] $Detail = '')
    $exitCode = 65
    if ($Code -ceq 'ok') { $exitCode = 0 }
    elseif ($Code -match '^argument-') { $exitCode = 64 }
    elseif ($Code -match '^lock-') { $exitCode = 73 }
    elseif ($Code -match '^baseline-') { $exitCode = 74 }
    elseif ($Code -match '^review-') { $exitCode = 75 }
    elseif ($Code -match '^verification-') { $exitCode = 76 }
    elseif ($Code -match '^push-') { $exitCode = 77 }

    if ($exitCode -eq 0) {
        [Console]::Out.WriteLine('ENFORCE_GATE_PASSED code=ok')
        exit 0
    }
    $line = "ENFORCE_GATE_FAILED code=$Code"
    if ($Detail) { $line += " detail=`"$($Detail -replace '"', '\"')`"" }
    [Console]::Error.WriteLine($line)
    exit $exitCode
}

function Get-GitCommonDirectory {
    param([Parameter(Mandatory)][string] $RepositoryRoot)
    $output = & git -C $RepositoryRoot rev-parse --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$output)) {
        return [pscustomobject]@{ Ok = $false; Code = 'lock-repository-invalid'; Detail = "'$RepositoryRoot' is not inside a git repository (git rev-parse --git-common-dir failed)."; Value = $null }
    }
    $common = [string]$output
    if (-not [IO.Path]::IsPathRooted($common)) { $common = Join-Path $RepositoryRoot $common }
    return [pscustomobject]@{ Ok = $true; Code = 'ok'; Detail = ''; Value = [IO.Path]::GetFullPath($common) }
}

function Get-CanonicalProcessStart {
    param([Parameter(Mandatory)][Diagnostics.Process] $Process)
    return $Process.StartTime.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function Get-CanonicalProcessStartForCurrentProcess {
    return Get-CanonicalProcessStart -Process ([Diagnostics.Process]::GetCurrentProcess())
}

function Test-LocalGuardHeldByLiveProcess {
    param([Parameter(Mandatory)][string] $GitCommonDir)
    $holderPath = Join-Path (Join-Path $GitCommonDir 'gatecraft-local-guard-v1') 'holder.json'
    if (-not (Test-Path -LiteralPath $holderPath -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Code = 'lock-not-held'; Detail = "No holder record at $holderPath. Acquire the local guard (scripts/guard.ps1 acquire) before merging." }
    }
    # System.Text.Json, deliberately not PowerShell's ConvertFrom-Json:
    # ConvertFrom-Json auto-coerces an ISO-8601-shaped string value into
    # [DateTime], silently truncating process_start's fractional-second
    # precision and reformatting it -- guard.ps1's own Read-LockRecord avoids
    # exactly this by parsing holder.json the same low-level way.
    try { $document = [Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($holderPath)) }
    catch { return [pscustomobject]@{ Ok = $false; Code = 'lock-record-unreadable'; Detail = "Holder record at $holderPath is not valid JSON." } }
    try {
        $root = $document.RootElement
        $pidElement = [Text.Json.JsonElement]::new()
        $startElement = [Text.Json.JsonElement]::new()
        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object -or
            -not $root.TryGetProperty('pid', [ref] $pidElement) -or $pidElement.ValueKind -ne [Text.Json.JsonValueKind]::Number -or
            -not $root.TryGetProperty('process_start', [ref] $startElement) -or $startElement.ValueKind -ne [Text.Json.JsonValueKind]::String) {
            return [pscustomobject]@{ Ok = $false; Code = 'lock-record-unreadable'; Detail = "Holder record at $holderPath is missing a numeric 'pid' or a string 'process_start'." }
        }
        $holderPid = 0
        if (-not $pidElement.TryGetInt32([ref] $holderPid) -or $holderPid -le 0) {
            return [pscustomobject]@{ Ok = $false; Code = 'lock-record-unreadable'; Detail = "Holder record at $holderPath has an invalid pid." }
        }
        $holderStart = $startElement.GetString()
        if ($holderStart -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') {
            return [pscustomobject]@{ Ok = $false; Code = 'lock-record-unreadable'; Detail = "Holder record at $holderPath has a non-canonical process_start." }
        }
        try { $holderProcess = [Diagnostics.Process]::GetProcessById($holderPid) }
        catch [ArgumentException] {
            return [pscustomobject]@{ Ok = $false; Code = 'lock-holder-process-dead'; Detail = "Holder pid=$holderPid is not live. Attended stale-lock recovery is required." }
        }
        try { $expectedStart = Get-CanonicalProcessStart -Process $holderProcess }
        catch {
            return [pscustomobject]@{ Ok = $false; Code = 'lock-holder-process-unreadable'; Detail = "Holder pid=$holderPid is live but its start time could not be read." }
        }
        finally { if ($null -ne $holderProcess) { $holderProcess.Dispose() } }
        if ($holderStart -cne $expectedStart) {
            return [pscustomobject]@{ Ok = $false; Code = 'lock-holder-process-mismatch'; Detail = "Holder process_start=$holderStart does not match live pid=$holderPid start ($expectedStart). Attended stale-lock recovery is required." }
        }
        return [pscustomobject]@{ Ok = $true; Code = 'ok'; Detail = '' }
    }
    finally { $document.Dispose() }
}

function Get-BeadReceiptLines {
    # `--directory` is bd's own `-C`-equivalent (review round 1 finding,
    # codex/lavoro): without it, `bd comments` resolved its database from
    # THIS PROCESS's current working directory, not the declared
    # --repository-root, so a caller invoking enforce-gate.ps1 from anywhere
    # else could silently read the wrong bd database or fail outright.
    param([Parameter(Mandatory)][string] $BeadId, [Parameter(Mandatory)][string] $RepositoryRoot)
    $json = & bd comments $BeadId --json --directory $RepositoryRoot 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$json)) {
        return [pscustomobject]@{ Ok = $false; Code = 'verification-bead-unreadable'; Detail = "'bd comments $BeadId --json --directory $RepositoryRoot' failed or returned nothing."; Value = @() }
    }
    try { $comments = $json | ConvertFrom-Json }
    catch { return [pscustomobject]@{ Ok = $false; Code = 'verification-bead-unreadable'; Detail = "'bd comments $BeadId --json' output is not valid JSON."; Value = @() } }
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($comment in @($comments)) {
        if ($null -eq $comment.text) { continue }
        foreach ($rawLine in ([string]$comment.text -split "`n")) {
            $trimmed = $rawLine.TrimEnd("`r")
            # Only prefixes supported by Gatecraft.Protocol are receipts.
            # A broad uppercase-token filter also captured ordinary historical
            # comments such as "AUDIT ..." and made an otherwise valid bead
            # permanently impossible to close.
            if (Test-GatecraftReceiptCandidateLine -Line $trimmed) {
                $lines.Add($trimmed)
            }
        }
    }
    return [pscustomobject]@{ Ok = $true; Code = 'ok'; Detail = ''; Value = $lines.ToArray() }
}

function Test-GatecraftReceiptCandidateLine {
    param([AllowEmptyString()][string] $Line)
    return $Line -match '^(?:VERIFY_PHASE|VERIFIED|RECOVERY|REVIEW_PASS|REVIEW_BLOCK|REVIEW_INCONCLUSIVE|REVIEW_CLARIFY)\s'
}

function Get-ReceiptLinesForCheck {
    param([string] $BeadId, [string] $ReceiptFile, [string] $RepositoryRoot)
    if ($ReceiptFile) {
        # Test-only surface, gated the same way guard.ps1 gates its own
        # test-only knobs (review round 2 finding, codex/lavoro): without this,
        # any production caller could pass a fabricated file instead of
        # --bead-id and satisfy check-merge/check-close against content that
        # was never actually recorded on the real bead -- a bypass of the
        # entire mechanism's anti-forgery purpose, not just a convenience.
        if ([Environment]::GetEnvironmentVariable('GATECRAFT_ENFORCE_GATE_TEST_CONTROLS', [EnvironmentVariableTarget]::Process) -cne '1') {
            return [pscustomobject]@{ Ok = $false; Code = 'argument-receipt-file-test-only'; Detail = '--receipt-file requires GATECRAFT_ENFORCE_GATE_TEST_CONTROLS=1; production callers must pass --bead-id and read real bd state.'; Value = @() }
        }
        if (-not (Test-Path -LiteralPath $ReceiptFile -PathType Leaf)) {
            return [pscustomobject]@{ Ok = $false; Code = 'argument-receipt-file-missing'; Detail = "--receipt-file '$ReceiptFile' does not exist."; Value = @() }
        }
        $lines = @(Get-Content -LiteralPath $ReceiptFile)
        return [pscustomobject]@{ Ok = $true; Code = 'ok'; Detail = ''; Value = $lines }
    }
    return Get-BeadReceiptLines -BeadId $BeadId -RepositoryRoot $RepositoryRoot
}

function Invoke-CheckMerge {
    # Review is required by DEFAULT (review round 1 finding, codex/lavoro): an
    # opt-in `--require-review` flag left the safe behavior dependent on the
    # caller remembering to add it, exactly the prose-discipline failure mode
    # this whole bead exists to close. `-LowRiskNoReviewRequired` is the only
    # way to skip it -- a long, deliberately hard-to-pass-by-accident name, so
    # skipping review is something a caller must consciously choose to type,
    # never the silent default of omitting a flag.
    param([string] $RepositoryRoot, [string] $BeadId, [string] $ReceiptFile, [switch] $LowRiskNoReviewRequired, [string] $ArtifactSha)

    if (-not $BeadId -and -not $ReceiptFile) { return [pscustomobject]@{ Ok = $false; Code = 'argument-bead-id-or-receipt-file-required' } }
    if (-not $LowRiskNoReviewRequired -and -not $ArtifactSha) { return [pscustomobject]@{ Ok = $false; Code = 'argument-artifact-sha-required'; Detail = 'Review is required by default; pass --artifact-sha to bind it to the exact merge candidate, or explicitly opt out with --low-risk-no-review-required.' } }
    if ($ArtifactSha -and $ArtifactSha -cnotmatch '^[0-9A-F]{64}$') { return [pscustomobject]@{ Ok = $false; Code = 'argument-artifact-sha-malformed'; Detail = '--artifact-sha must be exactly 64 uppercase hexadecimal characters.' } }

    $commonResult = Get-GitCommonDirectory -RepositoryRoot $RepositoryRoot
    if (-not $commonResult.Ok) { return $commonResult }
    $lockResult = Test-LocalGuardHeldByLiveProcess -GitCommonDir $commonResult.Value
    if (-not $lockResult.Ok) { return $lockResult }

    $linesResult = Get-ReceiptLinesForCheck -BeadId $BeadId -ReceiptFile $ReceiptFile -RepositoryRoot $RepositoryRoot
    if (-not $linesResult.Ok) { return $linesResult }

    $baselineFound = $false
    $reviewPassFound = $false
    $identityPattern = '^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$'
    foreach ($line in $linesResult.Value) {
        $parsed = ConvertFrom-GatecraftReceiptLine -Line $line
        if (-not $parsed.IsValid) { continue }
        if ($parsed.Type -ceq 'VERIFY_PHASE' -and $parsed.Fields['phase'] -ceq 'baseline' -and $parsed.Fields['result'] -ceq 'observed') { $baselineFound = $true }
        if ($LowRiskNoReviewRequired -or $parsed.Type -cne 'REVIEW_PASS' -or $parsed.Fields['artifact_sha'] -cne $ArtifactSha) { continue }
        # A REVIEW_PASS candidate must pass the SAME semantic checks
        # Test-GatecraftVerificationChain applies to every receipt (review
        # round 2 finding, codex/lavoro): ConvertFrom-GatecraftReceiptLine only
        # validates grammar and field presence, so a structurally well-formed
        # but forged line -- wrong protocol, garbage timestamp -- otherwise
        # parsed as IsValid=true and satisfied this check on artifact_sha
        # equality alone.
        if ($parsed.Fields['protocol'] -cne 'verification/v2') { continue }
        if (-not (Test-GatecraftIso8601 -Value $parsed.Fields['reviewed_at'])) { continue }
        if ($parsed.Fields['reviewer'] -notmatch $identityPattern -or $parsed.Fields['source_id'] -notmatch $identityPattern -or $parsed.Fields['review_id'] -notmatch $identityPattern) { continue }
        $reviewPassFound = $true
    }
    if (-not $baselineFound) {
        return [pscustomobject]@{ Ok = $false; Code = 'baseline-missing'; Detail = "No valid 'VERIFY_PHASE ... phase=baseline result=observed' receipt line found." }
    }
    if (-not $LowRiskNoReviewRequired -and -not $reviewPassFound) {
        return [pscustomobject]@{ Ok = $false; Code = 'review-missing-for-artifact'; Detail = "No 'REVIEW_PASS' receipt line bound to artifact_sha=$ArtifactSha found." }
    }
    return [pscustomobject]@{ Ok = $true; Code = 'ok'; Detail = '' }
}

function Invoke-CheckClose {
    param([string] $RepositoryRoot, [string] $BeadId, [string] $ReceiptFile)

    if (-not $BeadId -and -not $ReceiptFile) { return [pscustomobject]@{ Ok = $false; Code = 'argument-bead-id-or-receipt-file-required' } }

    $linesResult = Get-ReceiptLinesForCheck -BeadId $BeadId -ReceiptFile $ReceiptFile -RepositoryRoot $RepositoryRoot
    if (-not $linesResult.Ok) { return $linesResult }

    # Test-GatecraftVerificationChain returns one summary object (.Decision/.Reasons/
    # .Errors/.Receipts), not a bare list of issues -- reuse its own pass/block
    # decision rather than re-deriving it from a miscounted wrapper.
    $chain = Test-GatecraftVerificationChain -Receipt $linesResult.Value
    if ($chain.Decision -cne 'pass') {
        $codes = @($chain.Reasons) -join ', '
        return [pscustomobject]@{ Ok = $false; Code = 'verification-chain-invalid'; Detail = "Chain validation found $(@($chain.Errors).Count) issue(s): $codes" }
    }
    return [pscustomobject]@{ Ok = $true; Code = 'ok'; Detail = '' }
}

function Invoke-CheckPush {
    param([string] $RepositoryRoot, [string] $Target)

    if (-not $Target) { return [pscustomobject]@{ Ok = $false; Code = 'argument-target-required' } }

    $policyPath = Join-Path (Join-Path $RepositoryRoot '.beads') 'gatecraft-push-policy.json'
    if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Code = 'push-policy-missing'; Detail = "No push policy file at $policyPath. Push authorization (0.9) must be explicit and persisted there before any automated push." }
    }
    try { $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json }
    catch { return [pscustomobject]@{ Ok = $false; Code = 'push-policy-malformed'; Detail = "$policyPath is not valid JSON." } }

    if ($policy.protocol -cne 'gatecraft-push-policy/v1') {
        return [pscustomobject]@{ Ok = $false; Code = 'push-policy-malformed'; Detail = "$policyPath does not declare protocol 'gatecraft-push-policy/v1'." }
    }
    if ($policy.mode -ceq 'manual-only') {
        return [pscustomobject]@{ Ok = $false; Code = 'push-manual-only'; Detail = 'Standing policy (0.9) is manual-only: every push waits for the user, no automated target is ever authorized.' }
    }
    if ($policy.mode -ceq 'branch-only') {
        $authorizedBranch = [string]$policy.authorized_branch
        if ([string]::IsNullOrWhiteSpace($authorizedBranch)) {
            return [pscustomobject]@{ Ok = $false; Code = 'push-policy-malformed'; Detail = "$policyPath has mode=branch-only but no non-empty authorized_branch." }
        }
        if ($Target -cne $authorizedBranch) {
            return [pscustomobject]@{ Ok = $false; Code = 'push-target-not-authorized'; Detail = "Standing policy only authorizes pushing '$authorizedBranch'; '$Target' is not authorized." }
        }
        return [pscustomobject]@{ Ok = $true; Code = 'ok'; Detail = '' }
    }
    return [pscustomobject]@{ Ok = $false; Code = 'push-policy-malformed'; Detail = "$policyPath has unknown mode '$($policy.mode)'." }
}

function Read-EnforceGateArguments {
    param([Parameter(Mandatory)][object[]] $Tokens)
    if ($Tokens.Count -eq 1 -and [string]$Tokens[0] -ceq '--help') { Write-EnforceGateUsage; exit 0 }
    if ($Tokens.Count -lt 1) { Complete-EnforceGate -Code 'argument-command-required' }
    $command = [string]$Tokens[0]
    if ($command -cnotin @('check-merge', 'check-close', 'check-push')) { Complete-EnforceGate -Code 'argument-command-invalid' -Detail "'$command' is not check-merge, check-close, or check-push." }

    $allowedByCommand = @{
        'check-merge' = @('--repository-root', '--bead-id', '--receipt-file', '--low-risk-no-review-required', '--artifact-sha')
        'check-close' = @('--repository-root', '--bead-id', '--receipt-file')
        'check-push' = @('--repository-root', '--target')
    }
    $allowed = $allowedByCommand[$command]
    $values = @{}
    $index = 1
    while ($index -lt $Tokens.Count) {
        $token = [string]$Tokens[$index]
        if ($token -cnotin $allowed) { Complete-EnforceGate -Code 'argument-flag-unknown' -Detail "'$token' is not valid for $command." }
        if ($token -ceq '--low-risk-no-review-required') { $values[$token] = 'true'; $index++; continue }
        if ($index + 1 -ge $Tokens.Count) { Complete-EnforceGate -Code 'argument-value-missing' -Detail "'$token' requires a value." }
        $values[$token] = [string]$Tokens[$index + 1]
        $index += 2
    }
    return [pscustomobject]@{ Command = $command; Values = $values }
}

# Dot-sourcing this file (". enforce-gate.ps1") loads only the functions above,
# for in-process unit testing (Test-EnforceGate.ps1) without a subprocess and
# without this script's own `exit` calls tearing down the caller's session.
# Normal execution (`pwsh -File enforce-gate.ps1 ...`) runs the dispatcher below.
if ($MyInvocation.InvocationName -ne '.') {
    $parsed = Read-EnforceGateArguments -Tokens $args
    $repositoryRoot = $parsed.Values['--repository-root']
    if (-not $repositoryRoot) { Complete-EnforceGate -Code 'argument-repository-root-required' }
    $repositoryRoot = [IO.Path]::GetFullPath($repositoryRoot)

    $result = switch ($parsed.Command) {
        'check-merge' {
            Invoke-CheckMerge -RepositoryRoot $repositoryRoot -BeadId $parsed.Values['--bead-id'] -ReceiptFile $parsed.Values['--receipt-file'] `
                -LowRiskNoReviewRequired:($parsed.Values.ContainsKey('--low-risk-no-review-required')) -ArtifactSha $parsed.Values['--artifact-sha']
        }
        'check-close' {
            Invoke-CheckClose -RepositoryRoot $repositoryRoot -BeadId $parsed.Values['--bead-id'] -ReceiptFile $parsed.Values['--receipt-file']
        }
        'check-push' {
            Invoke-CheckPush -RepositoryRoot $repositoryRoot -Target $parsed.Values['--target']
        }
    }

    Complete-EnforceGate -Code $result.Code -Detail $result.Detail
}
