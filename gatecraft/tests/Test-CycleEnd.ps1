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

Write-Host 'Cycle-end gate passed: duplicate/conflict/sequence, platform Bash parity, gated test controls, five kill/replay boundaries, fail-closed projections, and safe cleanup.'
exit 0
