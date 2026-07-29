[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    [Console]::Error.WriteLine('Test-EnforceGate requires PowerShell 7 or newer.')
    exit 1
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$enforceGateScript = Join-Path $repoRoot 'gatecraft/scripts/enforce-gate.ps1'
$pwshPath = @(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('gatecraft-enforce-gate-tests-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)

$failures = [Collections.Generic.List[string]]::new()
function Add-Failure { param([Parameter(Mandatory)][string] $Message) $script:failures.Add($Message) }
function Assert-True { param([bool] $Condition, [string] $Message) if (-not $Condition) { Add-Failure $Message } }
function Assert-Equal {
    param([AllowNull()][object] $Actual, [AllowNull()][object] $Expected, [string] $Message)
    if ($null -eq $Actual -and $null -eq $Expected) { return }
    if ($null -eq $Actual -or $null -eq $Expected -or [string]$Actual -cne [string]$Expected) {
        Add-Failure "$Message Expected '$Expected'; found '$Actual'."
    }
}

# Dot-source for in-process function-level testing: this loads every function
# above the dispatcher guard without running the CLI dispatcher itself (the
# script checks $MyInvocation.InvocationName -ne '.' before dispatching), so
# `exit` calls in the dispatcher never fire here and this test process is safe.
. $enforceGateScript

function New-TestRepository {
    param([string] $Name)
    $path = Join-Path $testRoot $Name
    [void][IO.Directory]::CreateDirectory($path)
    & git -C $path init --quiet | Out-Null
    & git -C $path config user.email 'test@example.com' | Out-Null
    & git -C $path config user.name 'Test' | Out-Null
    [IO.File]::WriteAllText((Join-Path $path 'README.md'), "seed`n")
    & git -C $path add -A | Out-Null
    & git -C $path commit -m seed --quiet | Out-Null
    return $path
}

function Write-HolderJson {
    param([string] $GitDir, [object] $ProcessId, [string] $ProcessStart)
    $dir = Join-Path $GitDir 'gatecraft-local-guard-v1'
    [void][IO.Directory]::CreateDirectory($dir)
    $record = [ordered]@{ owner_token = ('t' * 32); pid = $ProcessId; process_start = $ProcessStart; protocol = 'gatecraft-local-lock/v1' }
    ($record | ConvertTo-Json -Compress) | Set-Content -LiteralPath (Join-Path $dir 'holder.json') -Encoding utf8 -NoNewline
}

function Write-ReceiptFile {
    param([string[]] $Lines)
    $path = Join-Path $testRoot ('receipt-' + [Guid]::NewGuid().ToString('N') + '.txt')
    ($Lines -join "`n") | Set-Content -LiteralPath $path -Encoding utf8 -NoNewline
    return $path
}

function Invoke-EnforceGateProcess {
    param([string[]] $Arguments, [int] $TimeoutMilliseconds = 30000)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwshPath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.ArgumentList.Add('-NoLogo')
    $info.ArgumentList.Add('-NoProfile')
    $info.ArgumentList.Add('-File')
    $info.ArgumentList.Add($enforceGateScript)
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Could not start enforce-gate child.' }
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'enforce-gate child exceeded its hard timeout.'
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $outTask.GetAwaiter().GetResult(); Error = $errorTask.GetAwaiter().GetResult() }
    }
    finally { $process.Dispose() }
}

# --- Test-LocalGuardHeldByCurrentProcess: no holder file at all ---
$noLockRepo = New-TestRepository 'no-lock-repo'
$noLockCommon = (Get-GitCommonDirectory -RepositoryRoot $noLockRepo).Value
$noLock = Test-LocalGuardHeldByCurrentProcess -GitCommonDir $noLockCommon
Assert-True (-not $noLock.Ok) 'Missing holder.json must fail the lock check.'
Assert-Equal $noLock.Code 'lock-not-held' 'Missing holder.json must report lock-not-held.'

# --- holder.json exists but names a different PID ---
$wrongPidRepo = New-TestRepository 'wrong-pid-repo'
$wrongPidCommon = (Get-GitCommonDirectory -RepositoryRoot $wrongPidRepo).Value
Write-HolderJson -GitDir $wrongPidCommon -ProcessId 999999999 -ProcessStart '2026-01-01T00:00:00.0000000Z'
$wrongPid = Test-LocalGuardHeldByCurrentProcess -GitCommonDir $wrongPidCommon
Assert-True (-not $wrongPid.Ok) 'A holder naming a different PID must fail.'
Assert-Equal $wrongPid.Code 'lock-not-held-by-current-process' 'Wrong-PID holder must report lock-not-held-by-current-process.'

# --- holder.json names this exact process's PID but the wrong start time ---
$wrongStartRepo = New-TestRepository 'wrong-start-repo'
$wrongStartCommon = (Get-GitCommonDirectory -RepositoryRoot $wrongStartRepo).Value
Write-HolderJson -GitDir $wrongStartCommon -ProcessId $PID -ProcessStart '2026-01-01T00:00:00.0000000Z'
$wrongStart = Test-LocalGuardHeldByCurrentProcess -GitCommonDir $wrongStartCommon
Assert-True (-not $wrongStart.Ok) 'A holder with this PID but the wrong start time must fail (PID-reuse discipline).'
Assert-Equal $wrongStart.Code 'lock-not-held-by-current-process' 'Wrong-start holder must report lock-not-held-by-current-process.'

# --- holder.json genuinely matches this process (PID + canonical start) ---
$heldRepo = New-TestRepository 'held-repo'
$heldCommon = (Get-GitCommonDirectory -RepositoryRoot $heldRepo).Value
$ownStart = Get-CanonicalProcessStartForCurrentProcess
Write-HolderJson -GitDir $heldCommon -ProcessId $PID -ProcessStart $ownStart
$held = Test-LocalGuardHeldByCurrentProcess -GitCommonDir $heldCommon
Assert-True $held.Ok 'A holder matching this exact process must pass.'

# --- malformed holder.json ---
$malformedDir = Join-Path $heldCommon 'gatecraft-local-guard-v1'
[IO.File]::WriteAllText((Join-Path $malformedDir 'holder.json'), '{not json')
$malformed = Test-LocalGuardHeldByCurrentProcess -GitCommonDir $heldCommon
Assert-True (-not $malformed.Ok) 'Malformed holder.json must fail.'
Assert-Equal $malformed.Code 'lock-record-unreadable' 'Malformed holder.json must report lock-record-unreadable.'
Write-HolderJson -GitDir $heldCommon -ProcessId $PID -ProcessStart $ownStart

# --- Invoke-CheckMerge: lock held, no baseline in receipt file (opted out of review to isolate the baseline check) ---
$noBaselineFile = Write-ReceiptFile -Lines @('VERIFIED protocol=verification/v2 receipt_id=x phase=postmerge verified_by=v verified_at=2026-07-15T10:00:00Z commit=' + ('c' * 40) + ' main=' + ('d' * 40) + ' artifact_sha=' + ('a' * 64) + ' baseline_ref=b integration_ref=i review_ref=r gate="g" exit=0 result=pass required="" evidence=""')
$mergeNoBaseline = Invoke-CheckMerge -RepositoryRoot $heldRepo -ReceiptFile $noBaselineFile -LowRiskNoReviewRequired
Assert-True (-not $mergeNoBaseline.Ok) 'check-merge must fail without a valid baseline receipt line.'
Assert-Equal $mergeNoBaseline.Code 'baseline-missing' 'Missing baseline must report baseline-missing.'

# --- Invoke-CheckMerge: lock held, valid baseline present, review explicitly opted out ---
$baselineLine = 'VERIFY_PHASE protocol=verification/v2 receipt_id=baseline-1 phase=baseline verified_by=v verified_at=2026-07-15T10:00:00Z artifact_sha=' + ('a' * 64) + ' gate="g" exit=0 result=observed required="" evidence=""'
$withBaselineFile = Write-ReceiptFile -Lines @($baselineLine)
$mergeOk = Invoke-CheckMerge -RepositoryRoot $heldRepo -ReceiptFile $withBaselineFile -LowRiskNoReviewRequired
Assert-True $mergeOk.Ok 'check-merge must pass with lock held, a valid baseline, and review explicitly opted out.'

# --- Invoke-CheckMerge: review is required by DEFAULT -- no flags at all must demand --artifact-sha ---
$mergeMissingArtifact = Invoke-CheckMerge -RepositoryRoot $heldRepo -ReceiptFile $withBaselineFile
Assert-True (-not $mergeMissingArtifact.Ok) 'check-merge must require review by default (no opt-out, no artifact-sha).'
Assert-Equal $mergeMissingArtifact.Code 'argument-artifact-sha-required' 'Missing artifact-sha under the default-required-review path must report argument-artifact-sha-required.'

# --- Invoke-CheckMerge: artifact-sha given (review required by default) but no matching REVIEW_PASS ---
$artifactSha = 'F' * 64
$mergeNoReview = Invoke-CheckMerge -RepositoryRoot $heldRepo -ReceiptFile $withBaselineFile -ArtifactSha $artifactSha
Assert-True (-not $mergeNoReview.Ok) 'check-merge must fail without a matching REVIEW_PASS when review is required (the default).'
Assert-Equal $mergeNoReview.Code 'review-missing-for-artifact' 'Missing review must report review-missing-for-artifact.'

# --- Invoke-CheckMerge: matching REVIEW_PASS present ---
$reviewLine = "REVIEW_PASS protocol=verification/v2 receipt_id=review-1 reviewer=r reviewed_at=2026-07-15T10:00:00Z source_id=s review_id=rv artifact_sha=$artifactSha"
$withReviewFile = Write-ReceiptFile -Lines @($baselineLine, $reviewLine)
$mergeWithReview = Invoke-CheckMerge -RepositoryRoot $heldRepo -ReceiptFile $withReviewFile -ArtifactSha $artifactSha
Assert-True $mergeWithReview.Ok 'check-merge must pass once a REVIEW_PASS bound to the exact artifact_sha exists.'

# --- Invoke-CheckClose: full valid verification/v2 chain ---
$artifact = 'B' * 64
$commit = 'c' * 40
$main = 'd' * 40
$validChainLines = @(
    "VERIFY_PHASE protocol=verification/v2 receipt_id=baseline-1 phase=baseline verified_by=v verified_at=2026-07-15T10:00:00Z artifact_sha=$artifact gate=`"g`" exit=0 result=observed required=`"gate-check`" evidence=`"gate-check`""
    "VERIFY_PHASE protocol=verification/v2 receipt_id=integration-1 phase=integration/premerge verified_by=v verified_at=2026-07-15T10:00:00Z artifact_sha=$artifact baseline_ref=baseline-1 gate=`"g`" exit=0 result=pass required=`"gate-check`" evidence=`"gate-check`""
    "REVIEW_PASS protocol=verification/v2 receipt_id=review-1 reviewer=r reviewed_at=2026-07-15T10:00:00Z source_id=s review_id=rv artifact_sha=$artifact"
    "VERIFIED protocol=verification/v2 receipt_id=postmerge-1 phase=postmerge verified_by=v verified_at=2026-07-15T10:00:00Z commit=$commit main=$main artifact_sha=$artifact baseline_ref=baseline-1 integration_ref=integration-1 review_ref=review-1 gate=`"g`" exit=0 result=pass required=`"gate-check`" evidence=`"gate-check`""
)
$validChainFile = Write-ReceiptFile -Lines $validChainLines
$closeOk = Invoke-CheckClose -RepositoryRoot $heldRepo -ReceiptFile $validChainFile
Assert-True $closeOk.Ok "check-close must pass a genuinely complete chain. Detail=$($closeOk.Detail)"

# --- Invoke-CheckClose: missing the postmerge VERIFIED line ---
$incompleteChainFile = Write-ReceiptFile -Lines $validChainLines[0..2]
$closeIncomplete = Invoke-CheckClose -RepositoryRoot $heldRepo -ReceiptFile $incompleteChainFile
Assert-True (-not $closeIncomplete.Ok) 'check-close must fail without a postmerge VERIFIED line.'
Assert-Equal $closeIncomplete.Code 'verification-chain-invalid' 'Incomplete chain must report verification-chain-invalid.'

# --- Invoke-CheckClose: --repository-root is actually threaded into the bd lookup, not ignored (review round 1 finding, codex/lavoro) ---
$distinctRepoRoot = Join-Path $testRoot 'distinct-repo-root-marker'
$closeWithBeadId = Invoke-CheckClose -RepositoryRoot $distinctRepoRoot -BeadId 'no-such-bead-id'
Assert-True (-not $closeWithBeadId.Ok) 'check-close with a --bead-id path (no --receipt-file) must attempt a real bd lookup.'
Assert-Equal $closeWithBeadId.Code 'verification-bead-unreadable' 'A bd lookup against a bogus bead must report verification-bead-unreadable.'
Assert-True ($closeWithBeadId.Detail -like "*--directory $distinctRepoRoot*") "The bd invocation must be scoped to the declared --repository-root, not the test process's own CWD. Detail=$($closeWithBeadId.Detail)"

# --- Invoke-CheckPush: no policy file ---
$noPolicyRepo = New-TestRepository 'no-policy-repo'
$pushNoPolicy = Invoke-CheckPush -RepositoryRoot $noPolicyRepo -Target 'main'
Assert-True (-not $pushNoPolicy.Ok) 'check-push must fail without a policy file.'
Assert-Equal $pushNoPolicy.Code 'push-policy-missing' 'Missing policy file must report push-policy-missing.'

# --- Invoke-CheckPush: mode=manual-only always fails closed ---
$manualOnlyRepo = New-TestRepository 'manual-only-repo'
[void][IO.Directory]::CreateDirectory((Join-Path $manualOnlyRepo '.beads'))
(@{ protocol = 'gatecraft-push-policy/v1'; mode = 'manual-only'; authorized_branch = $null } | ConvertTo-Json) |
    Set-Content -LiteralPath (Join-Path $manualOnlyRepo '.beads/gatecraft-push-policy.json') -Encoding utf8
$pushManualOnly = Invoke-CheckPush -RepositoryRoot $manualOnlyRepo -Target 'main'
Assert-True (-not $pushManualOnly.Ok) 'mode=manual-only must always fail closed.'
Assert-Equal $pushManualOnly.Code 'push-manual-only' 'manual-only policy must report push-manual-only.'

# --- Invoke-CheckPush: mode=branch-only, matching target ---
$branchOnlyRepo = New-TestRepository 'branch-only-repo'
[void][IO.Directory]::CreateDirectory((Join-Path $branchOnlyRepo '.beads'))
(@{ protocol = 'gatecraft-push-policy/v1'; mode = 'branch-only'; authorized_branch = 'orchestration/overnight' } | ConvertTo-Json) |
    Set-Content -LiteralPath (Join-Path $branchOnlyRepo '.beads/gatecraft-push-policy.json') -Encoding utf8
$pushMatching = Invoke-CheckPush -RepositoryRoot $branchOnlyRepo -Target 'orchestration/overnight'
Assert-True $pushMatching.Ok 'A push target matching the authorized branch must pass.'
$pushMismatch = Invoke-CheckPush -RepositoryRoot $branchOnlyRepo -Target 'main'
Assert-True (-not $pushMismatch.Ok) 'A push target other than the authorized branch must fail.'
Assert-Equal $pushMismatch.Code 'push-target-not-authorized' 'Mismatched target must report push-target-not-authorized.'

# --- Invoke-CheckPush: malformed policy JSON ---
$malformedPolicyRepo = New-TestRepository 'malformed-policy-repo'
[void][IO.Directory]::CreateDirectory((Join-Path $malformedPolicyRepo '.beads'))
[IO.File]::WriteAllText((Join-Path $malformedPolicyRepo '.beads/gatecraft-push-policy.json'), '{not json')
$pushMalformed = Invoke-CheckPush -RepositoryRoot $malformedPolicyRepo -Target 'main'
Assert-True (-not $pushMalformed.Ok) 'Malformed policy JSON must fail.'
Assert-Equal $pushMalformed.Code 'push-policy-malformed' 'Malformed policy must report push-policy-malformed.'

# --- End-to-end CLI/subprocess sanity: exit codes for a few race-free cases ---
$helpResult = Invoke-EnforceGateProcess -Arguments @('--help')
Assert-Equal $helpResult.ExitCode 0 '--help must exit 0.'
Assert-True ($helpResult.Output -match 'Usage:') '--help must print usage.'

$missingRepoRootResult = Invoke-EnforceGateProcess -Arguments @('check-push', '--target', 'main')
Assert-Equal $missingRepoRootResult.ExitCode 64 'Missing --repository-root must exit 64.'
Assert-True ($missingRepoRootResult.Error -match 'code=argument-repository-root-required') 'Missing --repository-root must name its exact code.'

$badCommandResult = Invoke-EnforceGateProcess -Arguments @('bogus-command', '--repository-root', $noLockRepo)
Assert-Equal $badCommandResult.ExitCode 64 'Unknown command must exit 64.'
Assert-True ($badCommandResult.Error -match 'code=argument-command-invalid') 'Unknown command must name its exact code.'

$realLockNotHeldResult = Invoke-EnforceGateProcess -Arguments @('check-merge', '--repository-root', $noLockRepo, '--receipt-file', $withBaselineFile, '--low-risk-no-review-required')
Assert-Equal $realLockNotHeldResult.ExitCode 73 'A real subprocess with no held lock must exit 73.'
Assert-True ($realLockNotHeldResult.Error -match 'code=lock-not-held') 'A real subprocess with no held lock must name lock-not-held.'

$realPushManualOnlyResult = Invoke-EnforceGateProcess -Arguments @('check-push', '--repository-root', $manualOnlyRepo, '--target', 'main')
Assert-Equal $realPushManualOnlyResult.ExitCode 77 'A real subprocess under manual-only policy must exit 77.'
Assert-True ($realPushManualOnlyResult.Error -match 'code=push-manual-only') 'A real subprocess under manual-only policy must name push-manual-only.'

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { [Console]::Error.WriteLine("ASSERTION FAILED: $failure") }
    exit 1
}

[Console]::Out.WriteLine('Enforce-gate gate passed: local-guard binding (missing/wrong-pid/wrong-start/malformed/held), check-merge baseline and bound-review requirements, check-close full verification/v2 chain reuse, check-push manual-only/branch-only/malformed policy, and end-to-end CLI exit codes are green.')
