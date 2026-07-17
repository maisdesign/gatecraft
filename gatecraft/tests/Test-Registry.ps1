[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    [Console]::Error.WriteLine('Test-Registry requires PowerShell 7 or newer.')
    exit 1
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$registryScript = Join-Path $repoRoot 'gatecraft/scripts/registry.ps1'
$registryShell = Join-Path $repoRoot 'gatecraft/scripts/registry.sh'
$cycleEndScript = Join-Path $repoRoot 'gatecraft/scripts/cycle-end.ps1'
$receiptEventScript = Join-Path $repoRoot 'gatecraft/scripts/receipt-event.ps1'
$protocolModule = Join-Path $repoRoot 'gatecraft/scripts/Gatecraft.Protocol.psm1'
$pwshPath = @(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
$onWindows = [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)
if ($onWindows) {
    $bash = 'C:\Program Files\Git\bin\bash.exe'
    if (-not [IO.File]::Exists($bash)) { throw "Exact Git for Windows Bash is required at $bash." }
}
else {
    $bashCommand = Get-Command bash -CommandType Application -ErrorAction Stop
    $bash = $bashCommand.Source
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('gatecraft-registry-tests-' + [Guid]::NewGuid().ToString('N') + ' with space')
$utf8 = [Text.UTF8Encoding]::new($false)
$bashEnvironmentFailure = ''

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Equal {
    param([AllowNull()][object] $Actual, [AllowNull()][object] $Expected, [string] $Message)
    if ($null -eq $Actual -and $null -eq $Expected) { return }
    if ($null -eq $Actual -or $null -eq $Expected -or $Actual -ne $Expected) { throw "ASSERTION FAILED: $Message Expected '$Expected'; found '$Actual'." }
}

function New-OwnerToken {
    return [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N').Substring(0, 8)
}

function Invoke-Registry {
    param([string] $Surface = 'powershell', [string[]] $Arguments, [hashtable] $EnvironmentOverride = @{}, [int] $TimeoutMilliseconds = 30000)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = if ($Surface -ceq 'bash') { $bash } else { $pwshPath }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    if ($Surface -ceq 'bash') { $info.ArgumentList.Add($registryShell) }
    else {
        $info.ArgumentList.Add('-NoLogo')
        $info.ArgumentList.Add('-NoProfile')
        $info.ArgumentList.Add('-File')
        $info.ArgumentList.Add($registryScript)
    }
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    foreach ($key in $EnvironmentOverride.Keys) { $info.Environment[$key] = [string] $EnvironmentOverride[$key] }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Could not start registry child.' }
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'Registry child exceeded its hard timeout.'
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $outTask.GetAwaiter().GetResult(); Error = $errorTask.GetAwaiter().GetResult() }
    }
    finally { $process.Dispose() }
}

function Start-RegistryChild {
    param([string[]] $Arguments, [hashtable] $EnvironmentOverride = @{})
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwshPath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.ArgumentList.Add('-NoLogo')
    $info.ArgumentList.Add('-NoProfile')
    $info.ArgumentList.Add('-File')
    $info.ArgumentList.Add($registryScript)
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    foreach ($key in $EnvironmentOverride.Keys) { $info.Environment[$key] = [string] $EnvironmentOverride[$key] }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'Could not start concurrent registry child.' }
    return $process
}

function Complete-RegistryChild {
    param([Diagnostics.Process] $Process, [int] $TimeoutMilliseconds = 30000)
    $outTask = $Process.StandardOutput.ReadToEndAsync()
    $errorTask = $Process.StandardError.ReadToEndAsync()
    if (-not $Process.WaitForExit($TimeoutMilliseconds)) {
        $Process.Kill($true)
        $Process.WaitForExit()
        throw 'Concurrent registry child exceeded its hard timeout.'
    }
    return [pscustomobject]@{ ExitCode = $Process.ExitCode; Output = $outTask.GetAwaiter().GetResult(); Error = $errorTask.GetAwaiter().GetResult() }
}

function Get-InstanceId {
    param([string] $Output)
    $match = [regex]::Match($Output, 'instance_id=(?<id>[A-Za-z0-9_-]{32})')
    if (-not $match.Success) { throw "ASSERTION FAILED: Could not find instance_id in output '$Output'." }
    return $match.Groups['id'].Value
}

function Read-RegistryJson {
    param([string] $LocalStateRoot)
    $path = Join-Path $LocalStateRoot 'debategui/v1/instances.json'
    return ConvertFrom-Json ([IO.File]::ReadAllText($path, $utf8))
}

function Invoke-CycleEnd {
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
    $info.ArgumentList.Add($cycleEndScript)
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Could not start cycle-end child.' }
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) { $process.Kill($true); $process.WaitForExit(); throw 'cycle-end child exceeded its hard timeout.' }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $outTask.GetAwaiter().GetResult(); Error = $errorTask.GetAwaiter().GetResult() }
    }
    finally { $process.Dispose() }
}

function Invoke-ReceiptEvent {
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
    $info.ArgumentList.Add($receiptEventScript)
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Could not start receipt-event child.' }
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) { $process.Kill($true); $process.WaitForExit(); throw 'receipt-event child exceeded its hard timeout.' }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $outTask.GetAwaiter().GetResult(); Error = $errorTask.GetAwaiter().GetResult() }
    }
    finally { $process.Dispose() }
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)

    # ---- 1. Basic lifecycle: register, list, heartbeat, update, unregister ----
    $lifecycleRoot = Join-Path $testRoot 'lifecycle'
    $token = New-OwnerToken
    $register = Invoke-Registry -Arguments @('register', '--local-state-root', $lifecycleRoot, '--owner-token', $token, '--gatecraft-version', '1.2.3', '--debategui-range', '>=1.0.0 <2.0.0', '--endpoint-base', 'http://127.0.0.1:54001')
    Assert-Equal $register.ExitCode 0 "Register must pass. stderr=$($register.Error)"
    $instanceId = Get-InstanceId $register.Output

    $list = Invoke-Registry -Arguments @('list', '--local-state-root', $lifecycleRoot)
    Assert-Equal $list.ExitCode 0 'List must pass after register.'
    Assert-True ($list.Output -match 'count=1') 'List must report exactly one instance.'
    $registryJson = Read-RegistryJson -LocalStateRoot $lifecycleRoot
    Assert-Equal @($registryJson.instances).Count 1 'Registry file must contain exactly one instance.'
    Assert-Equal $registryJson.instances[0].lifecycle 'running' 'A freshly registered instance must be running.'
    Assert-Equal $registryJson.instances[0].cursor $null 'A freshly registered instance must start with a null cursor.'
    Assert-Equal ((@($registryJson.instances[0].capabilities) -join ',')) 'events.read' 'Capabilities must be exactly events.read.'

    # Descriptors never contain absolute local paths (per the ADR).
    $rawRegistryText = [IO.File]::ReadAllText((Join-Path $lifecycleRoot 'debategui/v1/instances.json'), $utf8)
    Assert-True (-not $rawRegistryText.Contains($lifecycleRoot, [StringComparison]::OrdinalIgnoreCase)) 'The registry file must never embed the local-state-root absolute path.'
    Assert-True (-not $rawRegistryText.Contains('\', [StringComparison]::Ordinal)) 'The registry file must never contain a backslash (no raw Windows paths).'

    $heartbeat = Invoke-Registry -Arguments @('heartbeat', '--local-state-root', $lifecycleRoot, '--instance-id', $instanceId, '--owner-token', $token)
    Assert-Equal $heartbeat.ExitCode 0 'Heartbeat by the owner must pass.'
    $afterHeartbeat = Read-RegistryJson -LocalStateRoot $lifecycleRoot
    Assert-True ($afterHeartbeat.instances[0].freshness -cne $registryJson.instances[0].freshness) 'Heartbeat must advance freshness.'

    $wrongToken = New-OwnerToken
    $wrongHeartbeat = Invoke-Registry -Arguments @('heartbeat', '--local-state-root', $lifecycleRoot, '--instance-id', $instanceId, '--owner-token', $wrongToken)
    Assert-True ($wrongHeartbeat.ExitCode -ne 0 -and $wrongHeartbeat.Error -match 'code=owner-mismatch') 'Heartbeat by a non-owner token must fail with owner-mismatch.'

    $update = Invoke-Registry -Arguments @('update', '--local-state-root', $lifecycleRoot, '--instance-id', $instanceId, '--owner-token', $token, '--lifecycle', 'stopped')
    Assert-Equal $update.ExitCode 0 'Owner update must pass.'
    $afterUpdate = Read-RegistryJson -LocalStateRoot $lifecycleRoot
    Assert-Equal $afterUpdate.instances[0].lifecycle 'stopped' 'Update must persist the new lifecycle.'

    $unregister = Invoke-Registry -Arguments @('unregister', '--local-state-root', $lifecycleRoot, '--instance-id', $instanceId, '--owner-token', $token)
    Assert-Equal $unregister.ExitCode 0 'Owner unregister must pass.'
    $afterUnregister = Read-RegistryJson -LocalStateRoot $lifecycleRoot
    Assert-Equal @($afterUnregister.instances).Count 0 'Unregister must remove the descriptor.'
    $unregisterAgain = Invoke-Registry -Arguments @('unregister', '--local-state-root', $lifecycleRoot, '--instance-id', $instanceId, '--owner-token', $token)
    Assert-True ($unregisterAgain.ExitCode -ne 0 -and $unregisterAgain.Error -match 'code=(?:instance-not-found|owner-token-unknown)') 'Unregistering an already-removed instance must fail visibly.'

    # ---- 2. Restart: unregister then re-register gets a NEW instance ID ----
    $restartRoot = Join-Path $testRoot 'restart'
    $restartToken = New-OwnerToken
    $firstRegister = Invoke-Registry -Arguments @('register', '--local-state-root', $restartRoot, '--owner-token', $restartToken, '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54002')
    Assert-Equal $firstRegister.ExitCode 0 'First restart-fixture register must pass.'
    $firstId = Get-InstanceId $firstRegister.Output
    Assert-Equal (Invoke-Registry -Arguments @('unregister', '--local-state-root', $restartRoot, '--instance-id', $firstId, '--owner-token', $restartToken)).ExitCode 0 'Restart-fixture unregister must pass.'
    $secondRegister = Invoke-Registry -Arguments @('register', '--local-state-root', $restartRoot, '--owner-token', $restartToken, '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54002')
    Assert-Equal $secondRegister.ExitCode 0 'Second restart-fixture register must pass.'
    $secondId = Get-InstanceId $secondRegister.Output
    Assert-True ($firstId -cne $secondId) 'Restart must mint a new instance ID, never reuse the old one.'
    $restartHeartbeatOld = Invoke-Registry -Arguments @('heartbeat', '--local-state-root', $restartRoot, '--instance-id', $firstId, '--owner-token', $restartToken)
    Assert-True ($restartHeartbeatOld.ExitCode -ne 0 -and $restartHeartbeatOld.Error -match 'code=owner-token-unknown') 'The old instance owner record must be gone after unregister.'

    # ---- 3. Label denylist: reject paths, URLs, control chars, @-identifiers, credential-shaped text ----
    $labelRoot = Join-Path $testRoot 'label-denylist'
    $labelToken = New-OwnerToken
    $badLabels = @(
        'C:\Users\marco\secret',
        '/etc/passwd',
        'https://example.invalid/path',
        "control`tchar",
        'user@example.invalid',
        'token=sk-abc123DEF456',
        '../traversal',
        'trailing-space '
    )
    foreach ($badLabel in $badLabels) {
        $attempt = Invoke-Registry -Arguments @('register', '--local-state-root', $labelRoot, '--owner-token', $labelToken, '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54003', '--label', $badLabel)
        Assert-True ($attempt.ExitCode -ne 0 -and $attempt.Error -match 'code=label-invalid') "Label '$badLabel' must be rejected as label-invalid."
    }
    Assert-True (-not [IO.Directory]::Exists($labelRoot)) 'Every label rejection must fail before any local-state-root directory is created.'
    $goodLabel = Invoke-Registry -Arguments @('register', '--local-state-root', $labelRoot, '--owner-token', $labelToken, '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54003', '--label', 'demo-instance-1')
    Assert-Equal $goodLabel.ExitCode 0 'A safe allowlisted label must be accepted.'

    # ---- 4. Isolation: two concurrent registrations against the SAME registry file ----
    # simulates two different repositories/worktrees/orchestrators sharing one user's local state.
    $concurrentRoot = Join-Path $testRoot 'concurrent'
    $tokenA = New-OwnerToken
    $tokenB = New-OwnerToken
    $childA = Start-RegistryChild -Arguments @('register', '--local-state-root', $concurrentRoot, '--owner-token', $tokenA, '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54010', '--label', 'repo-a')
    $childB = Start-RegistryChild -Arguments @('register', '--local-state-root', $concurrentRoot, '--owner-token', $tokenB, '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54011', '--label', 'repo-b')
    $resultA = Complete-RegistryChild $childA
    $resultB = Complete-RegistryChild $childB
    $childA.Dispose(); $childB.Dispose()
    Assert-Equal $resultA.ExitCode 0 "Concurrent register A must pass. stderr=$($resultA.Error)"
    Assert-Equal $resultB.ExitCode 0 "Concurrent register B must pass. stderr=$($resultB.Error)"
    $idA = Get-InstanceId $resultA.Output
    $idB = Get-InstanceId $resultB.Output
    Assert-True ($idA -cne $idB) 'Two concurrent registrations must never collide on instance ID.'
    $concurrentRegistry = Read-RegistryJson -LocalStateRoot $concurrentRoot
    Assert-Equal @($concurrentRegistry.instances).Count 2 'Neither concurrent registration may be lost or overwritten.'
    $feedA = @($concurrentRegistry.instances | Where-Object { $_.instance_id -ceq $idA })[0].feed
    $feedB = @($concurrentRegistry.instances | Where-Object { $_.instance_id -ceq $idB })[0].feed
    Assert-True ($feedA -cne $feedB) 'Each concurrently registered instance must have a distinct feed reference.'
    $concurrentList = Invoke-Registry -Arguments @('list', '--local-state-root', $concurrentRoot)
    Assert-Equal $concurrentList.ExitCode 0 'List must accept the concurrently written registry file (not torn/corrupt).'

    # ---- 5. Duplicate instance_id collision on register must be rejected, not silently overwritten ----
    $collisionRoot = Join-Path $testRoot 'collision'
    $collisionToken = New-OwnerToken
    $forcedId = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    $forceEnv = @{ GATECRAFT_REGISTRY_TEST_CONTROLS = '1' }
    $unauthorizedForce = Invoke-Registry -Arguments @('register', '--local-state-root', $collisionRoot, '--owner-token', $collisionToken, '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54020', '--test-force-instance-id', $forcedId)
    Assert-True ($unauthorizedForce.ExitCode -ne 0 -and $unauthorizedForce.Error -match 'code=test-controls-disabled') 'Forced instance ID must require the exact test-controls opt-in.'
    $firstForced = Invoke-Registry -Arguments @('register', '--local-state-root', $collisionRoot, '--owner-token', $collisionToken, '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54020', '--test-force-instance-id', $forcedId) -EnvironmentOverride $forceEnv
    Assert-Equal $firstForced.ExitCode 0 'The first forced-ID registration must pass.'
    $collisionAttempt = Invoke-Registry -Arguments @('register', '--local-state-root', $collisionRoot, '--owner-token', (New-OwnerToken), '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54021', '--test-force-instance-id', $forcedId) -EnvironmentOverride $forceEnv
    Assert-True ($collisionAttempt.ExitCode -ne 0 -and $collisionAttempt.Error -match 'code=instance-id-collision') 'A duplicate instance ID on register must be rejected.'
    $collisionRegistry = Read-RegistryJson -LocalStateRoot $collisionRoot
    Assert-Equal @($collisionRegistry.instances).Count 1 'A rejected collision must not overwrite the existing descriptor.'
    Assert-Equal $collisionRegistry.instances[0].endpoint 'http://127.0.0.1:54020/v1/instances/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' 'The original descriptor must remain byte-exact after a rejected collision.'

    # ---- 6. Crashed-owner simulation: sweep-stale marks only the stale, owned entry ----
    $staleRoot = Join-Path $testRoot 'stale'
    $staleToken = New-OwnerToken
    $freshToken = New-OwnerToken
    $staleRegister = Invoke-Registry -Arguments @('register', '--local-state-root', $staleRoot, '--owner-token', $staleToken, '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54030')
    $staleId = Get-InstanceId $staleRegister.Output
    $freshRegister = Invoke-Registry -Arguments @('register', '--local-state-root', $staleRoot, '--owner-token', $freshToken, '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54031')
    $freshId = Get-InstanceId $freshRegister.Output
    $farPast = '2000-01-01T00:00:00.0000000Z'
    $forcedFreshness = Invoke-Registry -Arguments @('heartbeat', '--local-state-root', $staleRoot, '--instance-id', $staleId, '--owner-token', $staleToken, '--freshness', $farPast) -EnvironmentOverride $forceEnv
    Assert-Equal $forcedFreshness.ExitCode 0 'Forcing a crashed-owner freshness (test-only) must pass.'
    $sweep = Invoke-Registry -Arguments @('sweep-stale', '--local-state-root', $staleRoot, '--threshold-seconds', '60')
    Assert-Equal $sweep.ExitCode 0 "Sweep-stale must pass. stderr=$($sweep.Error)"
    Assert-True ($sweep.Output -match 'marked=1') 'Sweep-stale must mark exactly the one crashed-owner instance.'
    $staleRegistry = Read-RegistryJson -LocalStateRoot $staleRoot
    $staleEntry = @($staleRegistry.instances | Where-Object { $_.instance_id -ceq $staleId })[0]
    $freshEntry = @($staleRegistry.instances | Where-Object { $_.instance_id -ceq $freshId })[0]
    Assert-Equal $staleEntry.lifecycle 'stale' 'The crashed-owner instance must be marked stale.'
    Assert-Equal $freshEntry.lifecycle 'running' 'A fresh instance must never be touched by sweep-stale.'

    # ---- 7. Incompatible descriptors are visible but never auto-upgraded/rewritten by sweep-stale ----
    $incompatibleRoot = Join-Path $testRoot 'incompatible'
    $incompatibleToken = New-OwnerToken
    $incompatibleRegister = Invoke-Registry -Arguments @('register', '--local-state-root', $incompatibleRoot, '--owner-token', $incompatibleToken, '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54040')
    $incompatibleId = Get-InstanceId $incompatibleRegister.Output
    Assert-Equal (Invoke-Registry -Arguments @('update', '--local-state-root', $incompatibleRoot, '--instance-id', $incompatibleId, '--owner-token', $incompatibleToken, '--lifecycle', 'incompatible')).ExitCode 0 'Marking an instance incompatible must pass.'
    Assert-Equal (Invoke-Registry -Arguments @('heartbeat', '--local-state-root', $incompatibleRoot, '--instance-id', $incompatibleId, '--owner-token', $incompatibleToken, '--freshness', $farPast) -EnvironmentOverride $forceEnv).ExitCode 0 'Forcing an old freshness on the incompatible fixture must pass.'
    $incompatibleSweep = Invoke-Registry -Arguments @('sweep-stale', '--local-state-root', $incompatibleRoot, '--threshold-seconds', '60')
    Assert-Equal $incompatibleSweep.ExitCode 0 'Sweep-stale must still pass even with an incompatible entry present.'
    Assert-True ($incompatibleSweep.Output -match 'marked=0') 'Sweep-stale must never touch an incompatible entry.'
    $incompatibleRegistry = Read-RegistryJson -LocalStateRoot $incompatibleRoot
    Assert-Equal $incompatibleRegistry.instances[0].lifecycle 'incompatible' 'Incompatible lifecycle must remain visible and untouched.'

    # ---- 8. Registry file corruption: malformed JSON / unknown field / duplicate ID must fail closed ----
    $corruptRoot = Join-Path $testRoot 'corrupt'
    [void][IO.Directory]::CreateDirectory((Join-Path $corruptRoot 'debategui/v1'))
    $corruptInstancesPath = Join-Path $corruptRoot 'debategui/v1/instances.json'

    [IO.File]::WriteAllText($corruptInstancesPath, '{not valid json', $utf8)
    $malformedJsonList = Invoke-Registry -Arguments @('list', '--local-state-root', $corruptRoot)
    Assert-True ($malformedJsonList.ExitCode -ne 0 -and $malformedJsonList.Error -match 'code=registry-corrupt-json') 'Malformed JSON must fail closed on list.'
    $malformedJsonRegister = Invoke-Registry -Arguments @('register', '--local-state-root', $corruptRoot, '--owner-token', (New-OwnerToken), '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54050')
    Assert-True ($malformedJsonRegister.ExitCode -ne 0 -and $malformedJsonRegister.Error -match 'code=registry-corrupt-json') 'Malformed JSON must fail closed on register (never silently overwritten).'
    Assert-Equal ([IO.File]::ReadAllText($corruptInstancesPath, $utf8)) '{not valid json' 'A rejected corrupt file must remain byte-exact.'

    $unknownFieldJson = '{"protocol":"gatecraft-debategui/v1","generated_at":"2026-01-01T00:00:00.0000000Z","instances":[],"unexpected_field":true}'
    [IO.File]::WriteAllText($corruptInstancesPath, $unknownFieldJson, $utf8)
    $unknownFieldList = Invoke-Registry -Arguments @('list', '--local-state-root', $corruptRoot)
    Assert-True ($unknownFieldList.ExitCode -ne 0 -and $unknownFieldList.Error -match 'code=registry-corrupt-root-fields') 'An unknown top-level field must fail closed.'

    $duplicateIdJson = '{"protocol":"gatecraft-debategui/v1","generated_at":"2026-01-01T00:00:00.0000000Z","instances":[' +
        '{"capabilities":["events.read"],"cursor":null,"debategui_range":"^1.0.0","endpoint":"http://127.0.0.1:54051/v1/instances/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","feed":"local:v1:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","freshness":"2026-01-01T00:00:00.0000000Z","gatecraft_version":"1.0.0","instance_id":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","label":"dup-one","lifecycle":"running","protocol":"gatecraft-debategui/v1"},' +
        '{"capabilities":["events.read"],"cursor":null,"debategui_range":"^1.0.0","endpoint":"http://127.0.0.1:54051/v1/instances/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","feed":"local:v1:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","freshness":"2026-01-01T00:00:00.0000000Z","gatecraft_version":"1.0.0","instance_id":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","label":"dup-two","lifecycle":"running","protocol":"gatecraft-debategui/v1"}' +
        ']}'
    [IO.File]::WriteAllText($corruptInstancesPath, $duplicateIdJson, $utf8)
    $duplicateIdList = Invoke-Registry -Arguments @('list', '--local-state-root', $corruptRoot)
    Assert-True ($duplicateIdList.ExitCode -ne 0 -and $duplicateIdList.Error -match 'code=registry-corrupt-duplicate-id') 'A duplicate instance_id already present in the raw file must fail closed.'
    $duplicateIdRegister = Invoke-Registry -Arguments @('register', '--local-state-root', $corruptRoot, '--owner-token', (New-OwnerToken), '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54052')
    Assert-True ($duplicateIdRegister.ExitCode -ne 0 -and $duplicateIdRegister.Error -match 'code=registry-corrupt-duplicate-id') 'Register must also fail closed against a corrupt duplicate-ID file rather than silently dropping data.'

    # ---- 9. Path with spaces: PowerShell and Bash surfaces both work under a space-containing path ----
    $spacedRoot = Join-Path $testRoot 'spaced state root'
    $spacedToken = New-OwnerToken
    $spacedRegisterPs = Invoke-Registry -Surface powershell -Arguments @('register', '--local-state-root', $spacedRoot, '--owner-token', $spacedToken, '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54060', '--label', 'spaced-one')
    Assert-Equal $spacedRegisterPs.ExitCode 0 "PowerShell register under a space-containing path must pass. stderr=$($spacedRegisterPs.Error)"
    $spacedId = Get-InstanceId $spacedRegisterPs.Output
    $spacedListPs = Invoke-Registry -Surface powershell -Arguments @('list', '--local-state-root', $spacedRoot)
    Assert-Equal $spacedListPs.ExitCode 0 'PowerShell list under a space-containing path must pass.'

    $spacedRegisterBash = Invoke-Registry -Surface bash -Arguments @('register', '--local-state-root', $spacedRoot, '--owner-token', (New-OwnerToken), '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54061', '--label', 'spaced-two')
    if ($spacedRegisterBash.ExitCode -ne 0) {
        $bashEnvironmentFailure = "Exact Git Bash could not run registry.sh under a space-containing path (exit=$($spacedRegisterBash.ExitCode) stderr=$($spacedRegisterBash.Error))."
        [Console]::Error.WriteLine($bashEnvironmentFailure)
    }
    else {
        $spacedListBash = Invoke-Registry -Surface bash -Arguments @('list', '--local-state-root', $spacedRoot)
        Assert-Equal $spacedListBash.ExitCode 0 'Bash list under a space-containing path must pass.'
        Assert-True ($spacedListBash.Output -match 'count=2') 'Bash-registered instance must be visible alongside the PowerShell-registered one.'
    }

    # ---- 10. Sanitized-feed publication: charset denylist and cross-instance isolation ----
    $feedRoot = Join-Path $testRoot 'feed'
    $feedTokenA = New-OwnerToken
    $feedTokenB = New-OwnerToken
    $feedRegisterA = Invoke-Registry -Arguments @('register', '--local-state-root', $feedRoot, '--owner-token', $feedTokenA, '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54070')
    $feedIdA = Get-InstanceId $feedRegisterA.Output
    $feedRegisterB = Invoke-Registry -Arguments @('register', '--local-state-root', $feedRoot, '--owner-token', $feedTokenB, '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54071')
    $feedIdB = Get-InstanceId $feedRegisterB.Output

    $unsafeSummaries = @(
        'C:\Users\marco\secret.txt',
        'https://example.invalid/path',
        '../../etc/passwd',
        "control`tchar"
    )
    foreach ($unsafe in $unsafeSummaries) {
        $badPublish = Invoke-Registry -Arguments @('publish-event', '--local-state-root', $feedRoot, '--instance-id', $feedIdA, '--owner-token', $feedTokenA, '--event-type', 'cycle-end', '--occurred-at', '2026-07-17T10:00:00Z', '--outcome', 'completed', '--summary', $unsafe)
        Assert-True ($badPublish.ExitCode -ne 0 -and $badPublish.Error -match 'code=summary-invalid') "Unsafe summary '$unsafe' must be rejected as summary-invalid."
    }
    $feedsDirectory = Join-Path $feedRoot 'debategui/v1/feeds'
    Assert-True (-not [IO.File]::Exists((Join-Path $feedsDirectory "$feedIdA.jsonl"))) 'No feed file may be created when every publish attempt was rejected.'

    $goodPublish = Invoke-Registry -Arguments @('publish-event', '--local-state-root', $feedRoot, '--instance-id', $feedIdA, '--owner-token', $feedTokenA, '--event-type', 'cycle-end', '--occurred-at', '2026-07-17T10:00:00Z', '--outcome', 'completed', '--summary', 'cycle one finished gate=Test-All exit=0', '--event-id', 'evt-1')
    Assert-Equal $goodPublish.ExitCode 0 "A sanitized summary must publish. stderr=$($goodPublish.Error)"
    $feedALines = @([IO.File]::ReadAllLines((Join-Path $feedsDirectory "$feedIdA.jsonl")))
    Assert-Equal $feedALines.Count 1 'One publish must append exactly one feed line.'
    Assert-True (-not [IO.File]::Exists((Join-Path $feedsDirectory "$feedIdB.jsonl"))) "Publishing to instance A's feed must never create or touch instance B's feed file."

    $replayPublish = Invoke-Registry -Arguments @('publish-event', '--local-state-root', $feedRoot, '--instance-id', $feedIdA, '--owner-token', $feedTokenA, '--event-type', 'cycle-end', '--occurred-at', '2026-07-17T10:00:00Z', '--outcome', 'completed', '--summary', 'cycle one finished gate=Test-All exit=0', '--event-id', 'evt-1')
    Assert-Equal $replayPublish.ExitCode 0 'Replaying the same event ID must be idempotent, not an error.'
    Assert-True ($replayPublish.Output -match 'code=event-replayed') 'A replayed event ID must be visibly skipped.'
    $feedALinesAfterReplay = @([IO.File]::ReadAllLines((Join-Path $feedsDirectory "$feedIdA.jsonl")))
    Assert-Equal $feedALinesAfterReplay.Count 1 'A replayed event ID must never duplicate a feed line.'

    $wrongOwnerPublish = Invoke-Registry -Arguments @('publish-event', '--local-state-root', $feedRoot, '--instance-id', $feedIdA, '--owner-token', $feedTokenB, '--event-type', 'cycle-end', '--occurred-at', '2026-07-17T10:01:00Z', '--outcome', 'completed', '--summary', 'attempted cross-owner publish')
    Assert-True ($wrongOwnerPublish.ExitCode -ne 0 -and $wrongOwnerPublish.Error -match 'code=owner-mismatch') "Instance B's owner token must never publish to instance A's feed."

    # ---- 11. ConvertTo-GatecraftSanitizedFeedEvent: VERIFIED/VERIFY_PHASE receipt -> sanitized event ----
    Import-Module $protocolModule -Force
    $secretMarker = 'RAW-EVIDENCE-SECRET-MARKER-DO-NOT-LEAK'
    $verifiedPassLine = "VERIFIED protocol=verification/v2 receipt_id=postmerge-1 phase=postmerge verified_by=verifier-1 verified_at=2026-07-17T10:05:00Z commit=abc123 main=abc123 artifact_sha=deadbeef baseline_ref=baseline-1 integration_ref=integration-1 review_ref=review-1 gate=`"pwsh -NoProfile -File gate.ps1`" exit=0 result=pass required=`"gate`" evidence=`"$secretMarker`""
    $verifiedFailLine = $verifiedPassLine -replace 'result=pass', 'result=fail'
    $verifyPhaseObservedLine = 'VERIFY_PHASE protocol=verification/v2 receipt_id=baseline-1 phase=baseline verified_by=verifier-1 verified_at=2026-07-17T10:06:00Z artifact_sha=deadbeef gate="pwsh -NoProfile -File gate.ps1" exit=0 result=observed required="gate" evidence="unrelated"'
    $malformedLine = 'NOT_A_KNOWN_RECEIPT_TYPE this is garbage'

    $eventPass = ConvertTo-GatecraftSanitizedFeedEvent -Line $verifiedPassLine
    Assert-True $eventPass.IsApplicable 'A VERIFIED pass receipt must produce an applicable sanitized event.'
    Assert-Equal $eventPass.Outcome 'verified' 'result=pass must map to outcome=verified.'
    Assert-True (-not $eventPass.Summary.Contains($secretMarker, [StringComparison]::Ordinal)) 'The sanitized event summary must never contain the raw quoted evidence field.'

    $eventFail = ConvertTo-GatecraftSanitizedFeedEvent -Line $verifiedFailLine
    Assert-True $eventFail.IsApplicable 'A VERIFIED fail receipt must produce an applicable sanitized event.'
    Assert-Equal $eventFail.Outcome 'verification-failed' 'result=fail must map to outcome=verification-failed.'

    $eventObserved = ConvertTo-GatecraftSanitizedFeedEvent -Line $verifyPhaseObservedLine
    Assert-True (-not $eventObserved.IsApplicable) 'A non-pass/fail VERIFY_PHASE observation must not produce a feed event.'

    $eventMalformed = ConvertTo-GatecraftSanitizedFeedEvent -Line $malformedLine
    Assert-True (-not $eventMalformed.IsApplicable) 'A malformed/unknown receipt line must not produce a feed event.'

    # ---- 12. receipt-event.ps1 end-to-end: a VERIFIED receipt automatically publishes a sanitized event ----
    $receiptRoot = Join-Path $testRoot 'receipt-hook'
    $receiptToken = New-OwnerToken
    $receiptRegister = Invoke-Registry -Arguments @('register', '--local-state-root', $receiptRoot, '--owner-token', $receiptToken, '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54080')
    $receiptInstanceId = Get-InstanceId $receiptRegister.Output
    $receiptEvent = Invoke-ReceiptEvent -Arguments @('--receipt-line', $verifiedPassLine, '--local-state-root', $receiptRoot, '--instance-id', $receiptInstanceId, '--owner-token', $receiptToken, '--cycle-sequence', '4')
    Assert-Equal $receiptEvent.ExitCode 0 "receipt-event.ps1 must publish a VERIFIED receipt automatically. stderr=$($receiptEvent.Error)"
    Assert-True ($receiptEvent.Output -match 'RECEIPT_EVENT_PUBLISHED') 'A VERIFIED receipt must be reported as published.'
    $receiptFeedPath = Join-Path $receiptRoot "debategui/v1/feeds/$receiptInstanceId.jsonl"
    Assert-True ([IO.File]::Exists($receiptFeedPath)) 'receipt-event.ps1 must append to the correct instance feed without a human editing any file.'
    $receiptFeedText = [IO.File]::ReadAllText($receiptFeedPath, $utf8)
    Assert-True (-not $receiptFeedText.Contains($secretMarker, [StringComparison]::Ordinal)) 'No raw evidence/transcript content may ever reach the on-disk feed.'

    $skippedReceiptEvent = Invoke-ReceiptEvent -Arguments @('--receipt-line', $verifyPhaseObservedLine, '--local-state-root', $receiptRoot, '--instance-id', $receiptInstanceId, '--owner-token', $receiptToken)
    Assert-Equal $skippedReceiptEvent.ExitCode 0 'A non-applicable receipt line must be a documented no-op, not a failure.'
    Assert-True ($skippedReceiptEvent.Output -match 'RECEIPT_EVENT_SKIPPED') 'A non-applicable receipt line must report itself as skipped.'

    # ---- 13. cycle-end.ps1 automatic publication hook ----
    $cycleRoot = Join-Path $testRoot 'cycle-hook'
    $cycleRegistryRoot = Join-Path $testRoot 'cycle-hook-registry'
    $cycleToken = New-OwnerToken
    $cycleRegister = Invoke-Registry -Arguments @('register', '--local-state-root', $cycleRegistryRoot, '--owner-token', $cycleToken, '--gatecraft-version', '1.0.0', '--debategui-range', '^1.0.0', '--endpoint-base', 'http://127.0.0.1:54090')
    $cycleInstanceId = Get-InstanceId $cycleRegister.Output

    $cycleEndOk = Invoke-CycleEnd -Arguments @('--state-root', $cycleRoot, '--event-id', 'cycle-a', '--cycle-sequence', '1', '--mode', 'unattended', '--occurred-at', '2026-07-17T10:10:00Z', '--outcome', 'continue', '--summary', 'first cycle finished', '--publish-local-state-root', $cycleRegistryRoot, '--publish-instance-id', $cycleInstanceId, '--publish-owner-token', $cycleToken)
    Assert-Equal $cycleEndOk.ExitCode 0 "cycle-end with valid publish args must still exit zero. stderr=$($cycleEndOk.Error)"
    Assert-True ($cycleEndOk.Output -match 'CYCLE_END_PUBLISHED') 'A successful cycle-end publish must be reported.'
    $cycleFeedPath = Join-Path $cycleRegistryRoot "debategui/v1/feeds/$cycleInstanceId.jsonl"
    Assert-True ([IO.File]::Exists($cycleFeedPath)) 'cycle-end.ps1 must automatically append a feed event with no manual file edit.'
    $cycleFeedLine = [IO.File]::ReadAllLines($cycleFeedPath)[0] | ConvertFrom-Json
    Assert-Equal $cycleFeedLine.event_type 'cycle-end' 'The automatic cycle-end feed event must carry event_type=cycle-end.'
    Assert-Equal $cycleFeedLine.cycle_sequence 1 'The automatic cycle-end feed event must carry the cycle sequence.'

    # A registry/publish failure (wrong owner token) must never fail cycle-end itself.
    $cycleEndBadOwner = Invoke-CycleEnd -Arguments @('--state-root', $cycleRoot, '--event-id', 'cycle-b', '--cycle-sequence', '2', '--mode', 'unattended', '--occurred-at', '2026-07-17T10:11:00Z', '--outcome', 'continue', '--summary', 'second cycle finished', '--publish-local-state-root', $cycleRegistryRoot, '--publish-instance-id', $cycleInstanceId, '--publish-owner-token', (New-OwnerToken))
    Assert-Equal $cycleEndBadOwner.ExitCode 0 'cycle-end must exit zero even when the automatic publish attempt fails (never a Gatecraft failure).'
    Assert-True ($cycleEndBadOwner.Error -match 'CYCLE_END_PUBLISH_WARNING') 'A failed automatic publish must surface as a non-fatal warning.'
    Assert-True ($cycleEndBadOwner.Output -match 'CYCLE_END_COMPLETE') 'cycle-end must still report completion despite the publish warning.'

    # Supplying only some publish arguments must fail closed (misconfiguration, not "DebateGUI absent").
    $cycleEndPartial = Invoke-CycleEnd -Arguments @('--state-root', $cycleRoot, '--event-id', 'cycle-c', '--cycle-sequence', '3', '--mode', 'unattended', '--occurred-at', '2026-07-17T10:12:00Z', '--outcome', 'continue', '--summary', 'third cycle finished', '--publish-local-state-root', $cycleRegistryRoot)
    Assert-True ($cycleEndPartial.ExitCode -ne 0 -and $cycleEndPartial.Error -match 'publish-arguments-incomplete') 'Partial publish arguments must fail closed rather than silently skip publication.'

    # cycle-end with NO publish arguments at all must remain fully functional (DebateGUI absent).
    $cycleEndNone = Invoke-CycleEnd -Arguments @('--state-root', $cycleRoot, '--event-id', 'cycle-d', '--cycle-sequence', '3', '--mode', 'unattended', '--occurred-at', '2026-07-17T10:13:00Z', '--outcome', 'continue', '--summary', 'fourth cycle finished')
    Assert-Equal $cycleEndNone.ExitCode 0 'cycle-end must remain fully functional with zero publish arguments.'
    Assert-True (-not ($cycleEndNone.Output -match 'CYCLE_END_PUBLISHED')) 'No publish attempt may occur when no publish arguments are supplied.'

    if (-not [string]::IsNullOrEmpty($bashEnvironmentFailure)) { throw $bashEnvironmentFailure }
    Write-Host 'Registry gate passed: lifecycle, restart identity, label denylist, concurrent isolation, collision rejection, crashed-owner sweep, incompatible visibility, corruption fail-closed, spaced-path shell parity, sanitized feed publication, and automatic cycle-end/receipt publication are green.'
}
finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $expectedPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar + 'gatecraft-registry-tests-'
    if (-not $resolvedRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refuse fixture cleanup outside the exact unique temp root.' }
    if ([IO.Directory]::Exists($resolvedRoot)) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
}
