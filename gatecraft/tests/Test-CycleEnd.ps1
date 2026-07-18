[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$entryPoint = Join-Path $repoRoot 'gatecraft/scripts/cycle-end.ps1'
$shellEntryPoint = Join-Path $repoRoot 'gatecraft/scripts/cycle-end.sh'
$windowsGitBash = 'C:\Program Files\Git\bin\bash.exe'
$bash = $null
if ($IsWindows) {
    $bash = $windowsGitBash
}
else {
    $bashCommand = Get-Command -Name bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $bashCommand) {
        $bash = $bashCommand.Source
    }
}
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$protocolModulePath = Join-Path $repoRoot 'gatecraft/scripts/Gatecraft.Protocol.psm1'
Import-Module $protocolModulePath -Force -ErrorAction Stop
$testControlsEnvironmentVariable = 'GATECRAFT_CYCLE_END_TEST_CONTROLS'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$fixturePrefix = "gatecraft-cycle-end-$PID-"
$fixtureRoots = [Collections.Generic.List[string]]::new()
$failures = [Collections.Generic.List[string]]::new()

function Assert-True {
    param([Parameter(Mandatory)][bool] $Condition, [Parameter(Mandatory)][string] $Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param([AllowNull()][object] $Actual, [AllowNull()][object] $Expected, [Parameter(Mandatory)][string] $Message)
    if ($null -eq $Expected) {
        if ($null -ne $Actual) { throw "$Message Expected null; found '$Actual'." }
        return
    }
    if ($null -eq $Actual -or $Actual -ne $Expected) {
        throw "$Message Expected '$Expected'; found '$Actual'."
    }
}

function New-FixtureRoot {
    $path = [IO.Path]::Combine($tempRoot, $fixturePrefix + [Guid]::NewGuid().ToString('N'))
    [void] [IO.Directory]::CreateDirectory($path)
    $fixtureRoots.Add($path)
    return $path
}

function Get-EventArguments {
    param(
        [Parameter(Mandatory)][string] $StateRoot,
        [string] $EventId = 'cycle-1',
        [string] $Sequence = '1',
        [string] $Mode = 'attended',
        [string] $OccurredAt = '2026-07-15T10:15:30Z',
        [string] $Outcome = 'continue',
        [string] $Summary = 'Cycle completed with sanitized evidence.',
        [string[]] $Extra = @()
    )

    return @(
        '--state-root', $StateRoot,
        '--event-id', $EventId,
        '--cycle-sequence', $Sequence,
        '--mode', $Mode,
        '--occurred-at', $OccurredAt,
        '--outcome', $Outcome,
        '--summary', $Summary
    ) + $Extra
}

function Invoke-CycleEnd {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $output = @(& $pwsh -NoLogo -NoProfile -File $entryPoint @Arguments 2>&1 | ForEach-Object { [string] $_ })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output; Text = $output -join "`n" }
}

function Invoke-WithTestControlsEnvironment {
    param(
        [Parameter(Mandatory)][bool] $Enabled,
        [Parameter(Mandatory)][scriptblock] $Action
    )

    $previousValue = [Environment]::GetEnvironmentVariable($testControlsEnvironmentVariable, [EnvironmentVariableTarget]::Process)
    try {
        $scopedValue = if ($Enabled) { '1' } else { $null }
        [Environment]::SetEnvironmentVariable($testControlsEnvironmentVariable, $scopedValue, [EnvironmentVariableTarget]::Process)
        return & $Action
    }
    finally {
        [Environment]::SetEnvironmentVariable($testControlsEnvironmentVariable, $previousValue, [EnvironmentVariableTarget]::Process)
    }
}

function Invoke-CycleEndWithTimeout {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][int] $TimeoutMilliseconds
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwsh
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $entryPoint) + $Arguments) {
        [void] $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    try {
        $started = $process.Start()
        Assert-True $started 'Could not start timed cycle-end child.'
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutMilliseconds)
        if ($timedOut) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        else {
            $process.WaitForExit()
        }
        $text = @($stdoutTask.Result, $stderrTask.Result) -join "`n"
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            TimedOut = $timedOut
            Text = $text.Trim()
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

function Invoke-ShellCycleEnd {
    param([Parameter(Mandatory)][string[]] $Arguments)

    Push-Location $repoRoot
    try {
        $output = @(& $bash 'gatecraft/scripts/cycle-end.sh' @Arguments 2>&1 | ForEach-Object { [string] $_ })
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output; Text = $output -join "`n" }
    }
    finally {
        Pop-Location
    }
}

function Read-JsonSemantic {
    param([Parameter(Mandatory)][string] $Path)
    return (([IO.File]::ReadAllText($Path) | ConvertFrom-Json -Depth 30) | ConvertTo-Json -Depth 30 -Compress)
}

function Read-StateSemantic {
    param([Parameter(Mandatory)][string] $StateRoot)

    $cycleRoot = Join-Path $StateRoot 'cycle-end'
    $receipts = @(
        Get-ChildItem -LiteralPath (Join-Path $cycleRoot 'receipts') -File |
            Sort-Object -Property Name |
            ForEach-Object { Read-JsonSemantic -Path $_.FullName }
    )
    $session = @(
        [IO.File]::ReadAllLines((Join-Path $cycleRoot 'session-log.jsonl')) |
            Where-Object { $_.Length -gt 0 } |
            ForEach-Object { ($_ | ConvertFrom-Json -Depth 30) | ConvertTo-Json -Depth 30 -Compress }
    )
    return [pscustomobject][ordered]@{
        Receipts = $receipts
        SessionLog = $session
        Heartbeat = Read-JsonSemantic -Path (Join-Path $cycleRoot 'heartbeat.json')
        Snapshot = Read-JsonSemantic -Path (Join-Path $cycleRoot 'snapshot.json')
        Dashboard = Read-JsonSemantic -Path (Join-Path $cycleRoot 'dashboard.json')
    }
}

function Assert-CompleteState {
    param(
        [Parameter(Mandatory)][string] $StateRoot,
        [Parameter(Mandatory)][int] $ExpectedCount
    )

    $cycleRoot = Join-Path $StateRoot 'cycle-end'
    $receiptFiles = @(Get-ChildItem -LiteralPath (Join-Path $cycleRoot 'receipts') -File)
    Assert-Equal $receiptFiles.Count $ExpectedCount 'Canonical receipt count.'
    $sessionLines = @([IO.File]::ReadAllLines((Join-Path $cycleRoot 'session-log.jsonl')) | Where-Object { $_.Length -gt 0 })
    Assert-Equal $sessionLines.Count $ExpectedCount 'Session-log projection count.'
    foreach ($name in @('heartbeat.json', 'snapshot.json', 'dashboard.json')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $cycleRoot $name) -PathType Leaf) "Projection $name must exist."
        [void] ([IO.File]::ReadAllText((Join-Path $cycleRoot $name)) | ConvertFrom-Json -Depth 30)
    }
}

function Start-AndKillAtBoundary {
    param(
        [Parameter(Mandatory)][string] $StateRoot,
        [Parameter(Mandatory)][string] $Boundary
    )

    $arguments = Get-EventArguments -StateRoot $StateRoot -EventId "interrupt-$Boundary" -Extra @('--failpoint', $Boundary, '--failpoint-action', 'pause')
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwsh
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $entryPoint) + $arguments) {
        [void] $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    try {
        $started = $process.Start()
        Assert-True $started "Could not start failpoint child for $Boundary."
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $lineTask = $process.StandardOutput.ReadLineAsync()
        if (-not $lineTask.Wait([TimeSpan]::FromSeconds(20))) {
            if (-not $process.HasExited) { $process.Kill($true) }
            throw "Timed out waiting for failpoint marker at $Boundary."
        }
        $marker = $lineTask.Result
        Assert-True ($marker -ceq "CYCLE_END_FAILPOINT boundary=$Boundary action=pause") "Unexpected failpoint marker at ${Boundary}: $marker"
        Assert-True (-not $process.HasExited) "Failpoint child exited before the kill at $Boundary."
        $process.Kill($true)
        $process.WaitForExit()
        [void] $stderrTask.Result
        Assert-True ($process.ExitCode -ne 0) "Killed failpoint child must be visibly nonzero at $Boundary."
    }
    finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

try {
    Assert-True (Test-Path -LiteralPath $entryPoint -PathType Leaf) 'PowerShell cycle-end entry point is missing.'
    Assert-True (Test-Path -LiteralPath $shellEntryPoint -PathType Leaf) 'POSIX cycle-end entry point is missing.'
    if ($IsWindows) {
        Assert-True ($bash -ceq $windowsGitBash -and (Test-Path -LiteralPath $bash -PathType Leaf)) "Required exact Git Bash binary is missing: $windowsGitBash"
    }
    else {
        Assert-True (-not [string]::IsNullOrEmpty($bash) -and (Test-Path -LiteralPath $bash -PathType Leaf)) 'Required bash Application is unavailable on PATH.'
    }

    # Duplicate delivery is one receipt and one entry in every append-shaped projection.
    $duplicateRoot = New-FixtureRoot
    $duplicateArguments = Get-EventArguments -StateRoot $duplicateRoot -EventId 'duplicate-1'
    $first = Invoke-CycleEnd -Arguments $duplicateArguments
    Assert-Equal $first.ExitCode 0 "First delivery failed: $($first.Text)"
    Assert-True ($first.Text -match 'receipt=new projections=complete') 'First delivery must report a new complete receipt.'
    $duplicate = Invoke-CycleEnd -Arguments $duplicateArguments
    Assert-Equal $duplicate.ExitCode 0 "Identical replay failed: $($duplicate.Text)"
    Assert-True ($duplicate.Text -match 'receipt=replayed projections=complete') 'Duplicate delivery must report replayed complete state.'
    Assert-CompleteState -StateRoot $duplicateRoot -ExpectedCount 1

    # Identity conflict, sequence reuse, and gaps fail closed without adding receipts.
    $conflict = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $duplicateRoot -EventId 'duplicate-1' -Summary 'A different canonical payload.')
    Assert-Equal $conflict.ExitCode 65 'Same event ID with a different payload must use the conflict exit.'
    $reuse = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $duplicateRoot -EventId 'other-id' -Sequence '1')
    Assert-Equal $reuse.ExitCode 65 'Reusing a sequence under another ID must use the conflict exit.'
    $gap = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $duplicateRoot -EventId 'gap-id' -Sequence '3')
    Assert-Equal $gap.ExitCode 65 'A sequence gap must use the conflict exit.'
    Assert-CompleteState -StateRoot $duplicateRoot -ExpectedCount 1
    $second = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $duplicateRoot -EventId 'cycle-2' -Sequence '2' -OccurredAt '2026-07-15T12:15:30+02:00')
    Assert-Equal $second.ExitCode 0 "Valid next sequence failed: $($second.Text)"
    $semanticReplay = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $duplicateRoot -EventId 'cycle-2' -Sequence '2' -OccurredAt '2026-07-15T10:15:30Z')
    Assert-Equal $semanticReplay.ExitCode 0 "Semantically identical timestamp replay failed: $($semanticReplay.Text)"
    Assert-True ($semanticReplay.Text -match 'receipt=replayed projections=complete') 'Semantically identical input must replay idempotently.'
    Assert-CompleteState -StateRoot $duplicateRoot -ExpectedCount 2

    # Numeric, mode, option, and path parsing reject ambiguous inputs before a receipt exists.
    foreach ($invalidSequence in @('0', '-1', '+1', '01', '1.0', '9223372036854775808')) {
        $validationRoot = New-FixtureRoot
        $result = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $validationRoot -Sequence $invalidSequence)
        Assert-True ($result.ExitCode -ne 0) "Invalid sequence '$invalidSequence' was accepted."
        $receiptDirectory = Join-Path $validationRoot 'cycle-end/receipts'
        if (Test-Path -LiteralPath $receiptDirectory) {
            Assert-Equal (@(Get-ChildItem -LiteralPath $receiptDirectory -File)).Count 0 "Invalid sequence '$invalidSequence' wrote a receipt."
        }
    }
    $invalidModeRoot = New-FixtureRoot
    $invalidMode = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $invalidModeRoot -Mode 'Attended')
    Assert-True ($invalidMode.ExitCode -ne 0) 'Mode matching must be exact and case-sensitive.'
    $unknownRoot = New-FixtureRoot
    $unknown = Invoke-CycleEnd -Arguments ((Get-EventArguments -StateRoot $unknownRoot) + @('--state', 'ambiguous'))
    Assert-True ($unknown.ExitCode -ne 0) 'Unknown or abbreviated options must fail closed.'
    $relative = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot 'relative-cycle-state')
    Assert-True ($relative.ExitCode -ne 0) 'Relative state roots must fail closed.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'relative-cycle-state'))) 'Relative state-root rejection must not create repository state.'

    # Production invocations cannot enable interruption controls without an exact environment opt-in.
    $disabledControlsParent = New-FixtureRoot
    $disabledControlsRoot = Join-Path $disabledControlsParent 'state-must-not-exist'
    $disabledControlsArguments = Get-EventArguments -StateRoot $disabledControlsRoot -EventId 'production-control-rejection' -Mode 'unattended' -Extra @('--failpoint', 'after-receipt', '--failpoint-action', 'pause')
    $disabledControls = Invoke-WithTestControlsEnvironment -Enabled $false -Action {
        Invoke-CycleEndWithTimeout -Arguments $disabledControlsArguments -TimeoutMilliseconds 5000
    }
    Assert-True (-not $disabledControls.TimedOut) 'Production pause control must return nonzero promptly instead of remaining alive.'
    Assert-True ($disabledControls.ExitCode -ne 0) 'Production pause control must be rejected nonzero.'
    Assert-True ($disabledControls.Text -match 'test-controls-disabled') 'Production pause rejection must identify the disabled test-control gate.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $disabledControlsRoot 'cycle-end/receipts'))) 'Rejected production test controls must not persist a receipt.'
    Assert-True (-not (Test-Path -LiteralPath $disabledControlsRoot)) 'Rejected production test controls must not create the state root.'

    $enabledWithoutControlRoot = New-FixtureRoot
    $enabledWithoutControl = Invoke-WithTestControlsEnvironment -Enabled $true -Action {
        Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $enabledWithoutControlRoot -EventId 'enabled-without-control')
    }
    Assert-Equal $enabledWithoutControl.ExitCode 0 "An opt-in without a test option changed production behavior: $($enabledWithoutControl.Text)"
    Assert-CompleteState -StateRoot $enabledWithoutControlRoot -ExpectedCount 1

    $reparseFixture = New-FixtureRoot
    $reparseTarget = Join-Path $reparseFixture 'target'
    $reparseLink = Join-Path $reparseFixture 'state-link'
    [void] [IO.Directory]::CreateDirectory($reparseTarget)
    if ($IsWindows) {
        [void] (New-Item -ItemType Junction -Path $reparseLink -Target $reparseTarget)
    }
    else {
        [void] (New-Item -ItemType SymbolicLink -Path $reparseLink -Target $reparseTarget)
    }
    $reparseResult = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $reparseLink)
    Assert-True ($reparseResult.ExitCode -ne 0) 'A reparse-point state root must fail closed.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $reparseTarget 'cycle-end'))) 'Reparse rejection must occur before runtime writes.'

    # PowerShell and the platform-selected exact Bash executable must create semantically equivalent state.
    $powerShellRoot = New-FixtureRoot
    $bashRoot = New-FixtureRoot
    $powerShellResult = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $powerShellRoot -EventId 'cross-shell-1' -Mode 'unattended' -Outcome 'quiescent' -Summary 'Equivalent "shell" payload \ café.')
    Assert-Equal $powerShellResult.ExitCode 0 "PowerShell cross-shell fixture failed: $($powerShellResult.Text)"
    try {
        $bashResult = Invoke-ShellCycleEnd -Arguments (Get-EventArguments -StateRoot $bashRoot -EventId 'cross-shell-1' -Mode 'unattended' -Outcome 'quiescent' -Summary 'Equivalent "shell" payload \ café.')
        Assert-Equal $bashResult.ExitCode 0 "Selected Bash cross-shell fixture failed: $($bashResult.Text)"
        $powerShellState = Read-StateSemantic -StateRoot $powerShellRoot
        $bashState = Read-StateSemantic -StateRoot $bashRoot
        Assert-Equal ($powerShellState | ConvertTo-Json -Depth 30 -Compress) ($bashState | ConvertTo-Json -Depth 30 -Compress) 'PowerShell and selected Bash state semantics.'
    }
    catch {
        $failures.Add($_.Exception.Message)
    }

    # Test-GatecraftReclaimBoundary: reclaim_at is only a valid boundary right after a
    # cycle-end event has durably completed every rebuilt projection.
    $reclaimOkRoot = New-FixtureRoot
    $reclaimOk = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $reclaimOkRoot -EventId 'reclaim-ok')
    Assert-Equal $reclaimOk.ExitCode 0 "Reclaim-boundary fixture cycle-end failed: $($reclaimOk.Text)"
    $reclaimOkResult = Test-GatecraftReclaimBoundary -StateRoot $reclaimOkRoot
    Assert-Equal $reclaimOkResult.Reason 'ok' 'A completed cycle-end boundary must permit reclaim.'
    Assert-True ([bool] $reclaimOkResult.Allowed) 'A completed cycle-end boundary must report Allowed=true.'

    # Ping-pong: a second, still-in-flight cycle on the same root must block reclaim
    # again even though an earlier cycle on that same root already completed cleanly.
    $reclaimSecondCycleFailpoint = Invoke-WithTestControlsEnvironment -Enabled $true -Action {
        Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $reclaimOkRoot -EventId 'reclaim-ok-2' -Sequence '2' -Extra @('--failpoint', 'after-receipt', '--failpoint-action', 'exit'))
    }
    Assert-Equal $reclaimSecondCycleFailpoint.ExitCode 86 "Second-cycle after-receipt failpoint must exit 86: $($reclaimSecondCycleFailpoint.Text)"
    $reclaimSecondCycleResult = Test-GatecraftReclaimBoundary -StateRoot $reclaimOkRoot
    Assert-Equal $reclaimSecondCycleResult.Reason 'blocked-mid-merge' 'A newer receipt whose projection rebuild has not caught up must block reclaim even though an older cycle already completed.'
    Assert-True (-not [bool] $reclaimSecondCycleResult.Allowed) 'A stale dashboard behind the latest receipt must not permit reclaim.'
    $reclaimSecondCycleReplay = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $reclaimOkRoot -EventId 'reclaim-ok-2' -Sequence '2')
    Assert-Equal $reclaimSecondCycleReplay.ExitCode 0 "Replay to repair the second-cycle fixture failed: $($reclaimSecondCycleReplay.Text)"
    $reclaimSecondCycleReplayResult = Test-GatecraftReclaimBoundary -StateRoot $reclaimOkRoot
    Assert-Equal $reclaimSecondCycleReplayResult.Reason 'ok' 'Completing the second cycle must restore a valid reclaim boundary at the new sequence.'
    Assert-True ([bool] $reclaimSecondCycleReplayResult.Allowed) 'A repaired second-cycle boundary must permit reclaim again.'

    $reclaimNoLedgerRoot = New-FixtureRoot
    $reclaimNoLedgerResult = Test-GatecraftReclaimBoundary -StateRoot $reclaimNoLedgerRoot
    Assert-Equal $reclaimNoLedgerResult.Reason 'blocked-no-ledger' 'A state root with no cycle-end history must block reclaim as no-ledger.'
    Assert-True (-not [bool] $reclaimNoLedgerResult.Allowed) 'No ledger must not permit reclaim.'

    $reclaimRelativeResult = Test-GatecraftReclaimBoundary -StateRoot 'relative-reclaim-state'
    Assert-Equal $reclaimRelativeResult.Reason 'blocked-no-ledger' 'A non-absolute state root must fail closed as no-ledger.'
    Assert-True (-not [bool] $reclaimRelativeResult.Allowed) 'A non-absolute state root must not permit reclaim.'

    $reclaimMidMergeRoot = New-FixtureRoot
    $reclaimMidMerge = Invoke-WithTestControlsEnvironment -Enabled $true -Action {
        Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $reclaimMidMergeRoot -EventId 'reclaim-mid-merge' -Extra @('--failpoint', 'after-receipt', '--failpoint-action', 'exit'))
    }
    Assert-Equal $reclaimMidMerge.ExitCode 86 "Deterministic after-receipt failpoint must exit 86: $($reclaimMidMerge.Text)"
    Assert-True (Test-Path -LiteralPath (Join-Path $reclaimMidMergeRoot 'cycle-end/receipts') -PathType Container) 'The receipt directory must exist after the after-receipt failpoint.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $reclaimMidMergeRoot 'cycle-end/dashboard.json') -PathType Leaf)) 'The after-receipt failpoint must land before any projection is written.'
    $reclaimMidMergeResult = Test-GatecraftReclaimBoundary -StateRoot $reclaimMidMergeRoot
    Assert-Equal $reclaimMidMergeResult.Reason 'blocked-mid-merge' 'A receipt without a durable projection rebuild must block reclaim as mid-merge.'
    Assert-True (-not [bool] $reclaimMidMergeResult.Allowed) 'Mid-merge state must not permit reclaim.'
    $reclaimMidMergeReplay = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $reclaimMidMergeRoot -EventId 'reclaim-mid-merge')
    Assert-Equal $reclaimMidMergeReplay.ExitCode 0 "Replay to repair the interrupted mid-merge fixture failed: $($reclaimMidMergeReplay.Text)"
    $reclaimMidMergeReplayResult = Test-GatecraftReclaimBoundary -StateRoot $reclaimMidMergeRoot
    Assert-Equal $reclaimMidMergeReplayResult.Reason 'ok' 'Replaying the exact event to completion must restore a valid reclaim boundary.'
    Assert-True ([bool] $reclaimMidMergeReplayResult.Allowed) 'A repaired boundary must permit reclaim again.'

    $reclaimMalformedRoot = New-FixtureRoot
    $reclaimMalformedReceipts = Join-Path $reclaimMalformedRoot 'cycle-end/receipts'
    [void] [IO.Directory]::CreateDirectory($reclaimMalformedReceipts)
    [IO.File]::WriteAllText((Join-Path $reclaimMalformedReceipts 'not-a-canonical-receipt.json'), '{}')
    $reclaimMalformedResult = Test-GatecraftReclaimBoundary -StateRoot $reclaimMalformedRoot
    Assert-Equal $reclaimMalformedResult.Reason 'blocked-malformed-ledger' 'A corrupt receipt ledger must block reclaim as malformed.'
    Assert-True (-not [bool] $reclaimMalformedResult.Allowed) 'Malformed ledger state must not permit reclaim.'

    # A dashboard.json that exists but fails exhaustive canonical validation is corrupt
    # durable state, not an in-flight window, and must be reported distinctly from
    # blocked-mid-merge.
    $reclaimMalformedDashboardRoot = New-FixtureRoot
    $reclaimMalformedDashboardFirstCycle = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $reclaimMalformedDashboardRoot -EventId 'reclaim-malformed-dashboard')
    Assert-Equal $reclaimMalformedDashboardFirstCycle.ExitCode 0 "Malformed-dashboard fixture's cycle-end failed: $($reclaimMalformedDashboardFirstCycle.Text)"
    [IO.File]::WriteAllText((Join-Path $reclaimMalformedDashboardRoot 'cycle-end/dashboard.json'), '{"protocol":"gatecraft-cycle/dashboard-v1","cycle_count":"not-a-number","latest":{}}')
    $reclaimMalformedDashboardResult = Test-GatecraftReclaimBoundary -StateRoot $reclaimMalformedDashboardRoot
    Assert-Equal $reclaimMalformedDashboardResult.Reason 'blocked-malformed-ledger' 'A dashboard that exists but fails canonical validation must block reclaim as malformed, not mid-merge.'
    Assert-True (-not [bool] $reclaimMalformedDashboardResult.Allowed) 'A malformed dashboard must not permit reclaim.'

    # Mid-merge via a live cycle-begin marker (GC-1.10 has started but not yet
    # completed): the previous cycle's receipt and dashboard still fully agree with each
    # other, so only the marker reveals a merge/ledger/cycle-end sequence in flight right
    # now -- this is the exact ping-pong gap the receipt/dashboard check alone cannot
    # see, distinct from the older after-receipt-failpoint fixture above which covers a
    # different, narrower window (a written receipt whose own projection rebuild has not
    # yet caught up).
    $reclaimMarkerRoot = New-FixtureRoot
    $reclaimMarkerFirstCycle = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $reclaimMarkerRoot -EventId 'reclaim-marker-1')
    Assert-Equal $reclaimMarkerFirstCycle.ExitCode 0 "Marker fixture's first cycle-end failed: $($reclaimMarkerFirstCycle.Text)"
    $reclaimMarkerFirstResult = Test-GatecraftReclaimBoundary -StateRoot $reclaimMarkerRoot
    Assert-Equal $reclaimMarkerFirstResult.Reason 'ok' 'The first completed cycle must be a clean reclaim boundary before the marker fixture begins.'

    $reclaimMarker = New-GatecraftCycleBeginMarker -StateRoot $reclaimMarkerRoot -CreatedAtUtc '2026-07-15T10:16:00Z'
    Assert-Equal $reclaimMarker.TargetCycleSequence 2 'The cycle-begin marker must target the sequence one past the latest completed receipt.'
    Assert-True (Test-Path -LiteralPath (Join-Path $reclaimMarkerRoot 'cycle-end/in-progress.marker') -PathType Leaf) 'New-GatecraftCycleBeginMarker must create the marker file.'
    $reclaimMarkerMidResult = Test-GatecraftReclaimBoundary -StateRoot $reclaimMarkerRoot
    Assert-Equal $reclaimMarkerMidResult.Reason 'blocked-mid-merge' 'A live cycle-begin marker targeting an unreached sequence must block reclaim even though the previous receipt and dashboard still fully agree.'
    Assert-True (-not [bool] $reclaimMarkerMidResult.Allowed) 'A live cycle-begin marker must not permit reclaim.'

    $reclaimMarkerSecondCycle = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $reclaimMarkerRoot -EventId 'reclaim-marker-2' -Sequence '2')
    Assert-Equal $reclaimMarkerSecondCycle.ExitCode 0 "Marker fixture's second cycle-end failed: $($reclaimMarkerSecondCycle.Text)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $reclaimMarkerRoot 'cycle-end/in-progress.marker') -PathType Leaf)) 'cycle-end.ps1 must delete the cycle-begin marker as the very last action of a successful run.'
    $reclaimMarkerAfterResult = Test-GatecraftReclaimBoundary -StateRoot $reclaimMarkerRoot
    Assert-Equal $reclaimMarkerAfterResult.Reason 'ok' 'Completing the marked cycle must clear the marker and restore a valid reclaim boundary.'
    Assert-True ([bool] $reclaimMarkerAfterResult.Allowed) 'A repaired boundary must permit reclaim again once the marker is cleared.'

    # Round-2 review Finding 1: a marker whose target sequence exactly equals the latest
    # completed receipt simulates a crash between writing the final dashboard and
    # deleting the marker. A sequence comparison (target > latest) lets this slip through
    # as "ok"; only existence-based blocking, regardless of target, is correct. Create the
    # marker before the cycle it targets even starts, then let cycle-end run all the way
    # through the dashboard write and stop at the after-dashboard failpoint -- strictly
    # after the dashboard is durable but strictly before the marker would be deleted.
    $reclaimCrashBeforeDeleteRoot = New-FixtureRoot
    $reclaimCrashBeforeDeleteMarker = New-GatecraftCycleBeginMarker -StateRoot $reclaimCrashBeforeDeleteRoot -CreatedAtUtc '2026-07-15T10:17:00Z'
    Assert-Equal $reclaimCrashBeforeDeleteMarker.TargetCycleSequence 1 'The pre-cycle marker on an empty ledger must target sequence 1.'
    $reclaimCrashBeforeDelete = Invoke-WithTestControlsEnvironment -Enabled $true -Action {
        Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $reclaimCrashBeforeDeleteRoot -EventId 'reclaim-crash-before-delete' -Extra @('--failpoint', 'after-dashboard', '--failpoint-action', 'exit'))
    }
    Assert-Equal $reclaimCrashBeforeDelete.ExitCode 86 "After-dashboard failpoint must exit 86: $($reclaimCrashBeforeDelete.Text)"
    Assert-True (Test-Path -LiteralPath (Join-Path $reclaimCrashBeforeDeleteRoot 'cycle-end/dashboard.json') -PathType Leaf) 'The after-dashboard failpoint must land after the dashboard is durable.'
    Assert-True (Test-Path -LiteralPath (Join-Path $reclaimCrashBeforeDeleteRoot 'cycle-end/in-progress.marker') -PathType Leaf) 'The after-dashboard failpoint must land strictly before the marker is deleted.'
    $reclaimCrashBeforeDeleteResult = Test-GatecraftReclaimBoundary -StateRoot $reclaimCrashBeforeDeleteRoot
    Assert-Equal $reclaimCrashBeforeDeleteResult.Reason 'blocked-mid-merge' 'A marker whose target equals the latest completed sequence must still block reclaim (crash-before-delete window).'
    Assert-True (-not [bool] $reclaimCrashBeforeDeleteResult.Allowed) 'A stale-but-present marker must never permit reclaim, regardless of its target sequence.'
    $reclaimCrashBeforeDeleteReplay = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $reclaimCrashBeforeDeleteRoot -EventId 'reclaim-crash-before-delete')
    Assert-Equal $reclaimCrashBeforeDeleteReplay.ExitCode 0 "Replay to clear the crash-before-delete marker failed: $($reclaimCrashBeforeDeleteReplay.Text)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $reclaimCrashBeforeDeleteRoot 'cycle-end/in-progress.marker') -PathType Leaf)) 'Replaying the exact same completed sequence must delete its own matching marker.'
    $reclaimCrashBeforeDeleteAfterResult = Test-GatecraftReclaimBoundary -StateRoot $reclaimCrashBeforeDeleteRoot
    Assert-Equal $reclaimCrashBeforeDeleteAfterResult.Reason 'ok' 'Clearing the crash-before-delete marker must restore a valid reclaim boundary.'
    Assert-True ([bool] $reclaimCrashBeforeDeleteAfterResult.Allowed) 'A repaired boundary must permit reclaim again.'

    # Round-2 review Finding 2: cycle-end.ps1 must never delete a marker that targets a
    # sequence other than the one this specific invocation is completing. A delayed
    # replay of an older, already-completed cycle-end call must not tear down a newer
    # cycle's live in-flight marker, and the older replay's own work must still succeed.
    $reclaimMarkerMismatchRoot = New-FixtureRoot
    $reclaimMarkerMismatchFirstCycle = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $reclaimMarkerMismatchRoot -EventId 'reclaim-marker-mismatch-1')
    Assert-Equal $reclaimMarkerMismatchFirstCycle.ExitCode 0 "Marker-mismatch fixture's first cycle-end failed: $($reclaimMarkerMismatchFirstCycle.Text)"
    $reclaimMarkerMismatchMarker = New-GatecraftCycleBeginMarker -StateRoot $reclaimMarkerMismatchRoot -CreatedAtUtc '2026-07-15T10:18:00Z'
    Assert-Equal $reclaimMarkerMismatchMarker.TargetCycleSequence 2 'The in-flight marker must target the next sequence (2), not the older sequence about to be replayed (1).'
    $reclaimMarkerMismatchReplay = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $reclaimMarkerMismatchRoot -EventId 'reclaim-marker-mismatch-1')
    Assert-Equal $reclaimMarkerMismatchReplay.ExitCode 0 "A delayed replay of the older, already-completed sequence must still succeed on its own: $($reclaimMarkerMismatchReplay.Text)"
    Assert-True (Test-Path -LiteralPath (Join-Path $reclaimMarkerMismatchRoot 'cycle-end/in-progress.marker') -PathType Leaf) 'A marker targeting a different sequence than the one just replayed must survive untouched.'
    $reclaimMarkerMismatchMarkerAfter = Read-GatecraftCycleBeginMarker -Path (Join-Path $reclaimMarkerMismatchRoot 'cycle-end/in-progress.marker')
    Assert-Equal $reclaimMarkerMismatchMarkerAfter.TargetCycleSequence 2 'The surviving marker must retain its original target sequence untouched.'

    # Round-2 review Finding 3: a marker created after every one of this function's own
    # earlier checks but before its final marker-existence check must still block. No
    # independent process can be raced deterministically against a single synchronous
    # PowerShell call, so use the module's dedicated test-only injection point (mirroring
    # cycle-end.ps1's own failpoint mechanism) to create the marker at that exact gap.
    $reclaimLateMarkerRoot = New-FixtureRoot
    $reclaimLateMarkerFirstCycle = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $reclaimLateMarkerRoot -EventId 'reclaim-late-marker')
    Assert-Equal $reclaimLateMarkerFirstCycle.ExitCode 0 "Late-marker fixture's cycle-end failed: $($reclaimLateMarkerFirstCycle.Text)"
    $reclaimLateMarkerBeforeResult = Test-GatecraftReclaimBoundary -StateRoot $reclaimLateMarkerRoot
    Assert-Equal $reclaimLateMarkerBeforeResult.Reason 'ok' 'The unmodified fixture must be a clean reclaim boundary before the injected race.'
    $reclaimLateMarkerResult = Test-GatecraftReclaimBoundary -StateRoot $reclaimLateMarkerRoot -BeforeFinalMarkerCheck {
        [void] (New-GatecraftCycleBeginMarker -StateRoot $reclaimLateMarkerRoot -CreatedAtUtc '2026-07-15T10:19:00Z')
    }
    Assert-Equal $reclaimLateMarkerResult.Reason 'blocked-mid-merge' 'A marker created after every earlier check but before the final check must still block reclaim.'
    Assert-True (-not [bool] $reclaimLateMarkerResult.Allowed) 'A late-appearing marker must never permit reclaim.'
    Assert-True (Test-Path -LiteralPath (Join-Path $reclaimLateMarkerRoot 'cycle-end/in-progress.marker') -PathType Leaf) 'The injection hook must actually have run and created the marker.'

    # Round-2 review Finding 4: count/ID/sequence agreement between the receipt ledger
    # and the dashboard projection is not sufficient -- every latest field must agree, or
    # the dashboard has not actually caught up to what the receipt says happened. Tamper
    # only the dashboard's "latest.outcome", keeping cycle_count/event_id/cycle_sequence
    # identical to the real receipt. The tampered "latest" fragment is hand-built in the
    # same canonical byte layout cycle-end.ps1 and the module both use (verified above by
    # the fixture's own untampered 'ok' result), so it still passes the dashboard's own
    # internal-consistency validation and isolates exactly the outcome mismatch under test.
    $reclaimFieldMismatchRoot = New-FixtureRoot
    $reclaimFieldMismatchFirstCycle = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $reclaimFieldMismatchRoot -EventId 'reclaim-field-mismatch' -Outcome 'continue' -Summary 'Original canonical summary.')
    Assert-Equal $reclaimFieldMismatchFirstCycle.ExitCode 0 "Field-mismatch fixture's cycle-end failed: $($reclaimFieldMismatchFirstCycle.Text)"
    $reclaimFieldMismatchOkResult = Test-GatecraftReclaimBoundary -StateRoot $reclaimFieldMismatchRoot
    Assert-Equal $reclaimFieldMismatchOkResult.Reason 'ok' 'The unmodified fixture must be a clean reclaim boundary before tampering.'
    $reclaimFieldMismatchTamperedLatest = '{"cycle_sequence":1,"event_id":"reclaim-field-mismatch","event_type":"cycle-end","mode":"attended","occurred_at":"2026-07-15T10:15:30.0000000Z","outcome":"failed","protocol":"gatecraft-cycle/v1","summary":"Original canonical summary."}'
    $reclaimFieldMismatchTamperedDashboard = '{"cycle_count":1,"latest":' + $reclaimFieldMismatchTamperedLatest + ',"protocol":"gatecraft-cycle/dashboard-v1"}'
    [IO.File]::WriteAllText((Join-Path $reclaimFieldMismatchRoot 'cycle-end/dashboard.json'), $reclaimFieldMismatchTamperedDashboard)
    $reclaimFieldMismatchResult = Test-GatecraftReclaimBoundary -StateRoot $reclaimFieldMismatchRoot
    Assert-Equal $reclaimFieldMismatchResult.Reason 'blocked-mid-merge' 'A dashboard whose latest.outcome disagrees with the actual receipt must block reclaim even though count/ID/sequence agree.'
    Assert-True (-not [bool] $reclaimFieldMismatchResult.Allowed) 'An outcome-mismatched dashboard must not permit reclaim.'

    # Kill a real child immediately after each named durable write, then replay.
    foreach ($boundary in @('after-receipt', 'after-session-log', 'after-heartbeat', 'after-snapshot', 'after-dashboard')) {
        $interruptionRoot = New-FixtureRoot
        Invoke-WithTestControlsEnvironment -Enabled $true -Action {
            Start-AndKillAtBoundary -StateRoot $interruptionRoot -Boundary $boundary
        }
        $replay = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $interruptionRoot -EventId "interrupt-$boundary")
        Assert-Equal $replay.ExitCode 0 "Replay after $boundary failed: $($replay.Text)"
        Assert-True ($replay.Text -match 'receipt=replayed projections=complete') "Replay after $boundary did not explicitly finish projections."
        Assert-CompleteState -StateRoot $interruptionRoot -ExpectedCount 1
    }

    # Projection failure is always nonzero; only attended mode emits the manual checklist.
    $attendedRoot = New-FixtureRoot
    $attendedFailure = Invoke-WithTestControlsEnvironment -Enabled $true -Action {
        Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $attendedRoot -EventId 'attended-failure' -Extra @('--fail-projection', 'snapshot'))
    }
    Assert-Equal $attendedFailure.ExitCode 74 'Attended projection failure exit.'
    Assert-True ($attendedFailure.Text -match 'CYCLE_END_MANUAL_FALLBACK.+automatic_completion=false') 'Attended failure must expose the documented manual fallback.'
    Assert-True ($attendedFailure.Text -notmatch 'CYCLE_END_COMPLETE') 'Attended fallback must not claim automatic completion.'
    $attendedReplay = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $attendedRoot -EventId 'attended-failure')
    Assert-Equal $attendedReplay.ExitCode 0 "Attended repair replay failed: $($attendedReplay.Text)"
    Assert-CompleteState -StateRoot $attendedRoot -ExpectedCount 1

    $unattendedRoot = New-FixtureRoot
    $unattendedFailure = Invoke-WithTestControlsEnvironment -Enabled $true -Action {
        Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $unattendedRoot -EventId 'unattended-failure' -Mode 'unattended' -Extra @('--fail-projection', 'dashboard'))
    }
    Assert-Equal $unattendedFailure.ExitCode 74 'Unattended projection failure exit.'
    Assert-True ($unattendedFailure.Text -match 'Unattended mode fails closed') 'Unattended projection failure must state fail-closed behavior.'
    Assert-True ($unattendedFailure.Text -notmatch 'CYCLE_END_MANUAL_FALLBACK|CYCLE_END_COMPLETE') 'Unattended failure must expose neither fallback nor completion.'
    $unattendedReplay = Invoke-CycleEnd -Arguments (Get-EventArguments -StateRoot $unattendedRoot -EventId 'unattended-failure' -Mode 'unattended')
    Assert-Equal $unattendedReplay.ExitCode 0 "Unattended repair replay failed: $($unattendedReplay.Text)"
    Assert-CompleteState -StateRoot $unattendedRoot -ExpectedCount 1
}
catch {
    $failures.Add($_.Exception.Message)
}
finally {
    foreach ($fixtureRoot in @($fixtureRoots | Sort-Object -Descending)) {
        if (-not [IO.Directory]::Exists($fixtureRoot)) {
            continue
        }
        try {
            $declared = [IO.Path]::GetFullPath($fixtureRoot)
            $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $fixtureRoot).ProviderPath)
            $leaf = [IO.Path]::GetFileName($resolved)
            $parent = [IO.Path]::GetDirectoryName($resolved).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            if ($resolved -cne $declared -or $parent -cne $tempRoot -or -not $leaf.StartsWith($fixturePrefix, [StringComparison]::Ordinal)) {
                throw "Refuse fixture cleanup outside the exact unique temp root: $resolved"
            }
            Remove-Item -LiteralPath $resolved -Recurse -Force
            if ([IO.Directory]::Exists($resolved) -or [IO.File]::Exists($resolved)) {
                throw "Fixture cleanup did not remove $resolved"
            }
        }
        catch {
            $failures.Add("Cleanup failure for ${fixtureRoot}: $($_.Exception.Message)")
        }
    }
}

if ($failures.Count -gt 0) {
    [Console]::Error.WriteLine("Cycle-end gate failed with $($failures.Count) issue(s):")
    foreach ($failure in $failures) {
        [Console]::Error.WriteLine(" - $failure")
    }
    exit 1
}

Write-Host 'Cycle-end gate passed: duplicate/conflict/sequence, platform Bash parity, gated test controls, five kill/replay boundaries, fail-closed projections, reclaim-boundary guard, cycle-begin-marker ping-pong guard (existence-based blocking, sequence-scoped marker deletion, marker TOCTOU closure, exhaustive latest-field dashboard comparison), and safe cleanup.'
exit 0
