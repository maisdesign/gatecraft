[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    [Console]::Error.WriteLine('Test-Guard requires PowerShell 7 or newer.')
    exit 1
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$guardScript = Join-Path $repoRoot 'gatecraft/scripts/guard.ps1'
$guardShell = Join-Path $repoRoot 'gatecraft/scripts/guard.sh'
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

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('gatecraft-guard-tests-' + [Guid]::NewGuid().ToString('N'))
$children = [Collections.Generic.List[Diagnostics.Process]]::new()
$junctions = [Collections.Generic.List[string]]::new()
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

function Test-BytesEqual {
    param([byte[]] $Left, [byte[]] $Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    return (Get-FileSha256Bytes $Left) -ceq (Get-FileSha256Bytes $Right)
}

function Get-FileSha256Bytes {
    param([byte[]] $Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
}

function Assert-CanonicalUtf8Bytes {
    param([byte[]] $Bytes, [string] $Label)
    Assert-True ($Bytes.Length -gt 0) "$Label must not be empty."
    Assert-True (-not ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)) "$Label must not contain a UTF-8 BOM."
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
    Assert-True (-not $text.Contains("`r", [StringComparison]::Ordinal) -and -not $text.Contains("`n", [StringComparison]::Ordinal)) "$Label must have no trailing or embedded newline."
}

function Invoke-Git {
    param([string] $Repository, [Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
    & git -C $Repository @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Fixture git command failed with exit $LASTEXITCODE." }
}

function New-TestRepository {
    param([string] $Name)
    $path = Join-Path $testRoot $Name
    [void][IO.Directory]::CreateDirectory($path)
    Invoke-Git $path init -b main | Out-Null
    Invoke-Git $path config user.email guard-test@example.invalid | Out-Null
    Invoke-Git $path config user.name 'Guard Test' | Out-Null
    Invoke-Git $path config core.autocrlf false | Out-Null
    [IO.File]::WriteAllText((Join-Path $path 'owned.txt'), "owned-base`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $path 'foreign.txt'), "foreign-base`n", $utf8)
    Invoke-Git $path add -- owned.txt foreign.txt | Out-Null
    Invoke-Git $path commit -m initial | Out-Null
    return $path
}

function Start-TestSleeper {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwshPath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.ArgumentList.Add('-NoLogo')
    $info.ArgumentList.Add('-NoProfile')
    $info.ArgumentList.Add('-Command')
    $info.ArgumentList.Add('Start-Sleep -Seconds 300')
    $process = [Diagnostics.Process]::Start($info)
    $children.Add($process)
    return $process
}

function Get-CanonicalStart {
    param([Diagnostics.Process] $Process)
    return $Process.StartTime.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function New-GuardStartInfo {
    param([string] $Surface, [string[]] $Arguments, [bool] $TestControls)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = if ($Surface -ceq 'bash') { $bash } else { $pwshPath }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    if ($Surface -ceq 'bash') { $info.ArgumentList.Add($guardShell) }
    else {
        $info.ArgumentList.Add('-NoLogo')
        $info.ArgumentList.Add('-NoProfile')
        $info.ArgumentList.Add('-File')
        $info.ArgumentList.Add($guardScript)
    }
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    if ($TestControls) { $info.Environment['GATECRAFT_GUARD_TEST_CONTROLS'] = '1' }
    else { [void]$info.Environment.Remove('GATECRAFT_GUARD_TEST_CONTROLS') }
    return $info
}

function Invoke-Guard {
    param([string] $Surface = 'powershell', [string[]] $Arguments, [bool] $TestControls = $false, [int] $TimeoutMilliseconds = 30000)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = New-GuardStartInfo -Surface $Surface -Arguments $Arguments -TestControls $TestControls
    try {
        if (-not $process.Start()) { throw 'Could not start guard child.' }
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'Guard child exceeded its hard timeout.'
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $outTask.GetAwaiter().GetResult(); Error = $errorTask.GetAwaiter().GetResult() }
    }
    finally { $process.Dispose() }
}

function Invoke-CultureGuard {
    param([string] $CultureName, [string[]] $Arguments, [int] $TimeoutMilliseconds = 30000)
    $argumentsJson = ConvertTo-Json -InputObject @($Arguments) -Compress
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwshPath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Environment['GATECRAFT_TEST_CULTURE'] = $CultureName
    $info.Environment['GATECRAFT_TEST_GUARD_SCRIPT'] = $guardScript
    $info.Environment['GATECRAFT_TEST_GUARD_ARGUMENTS_BASE64'] = [Convert]::ToBase64String($utf8.GetBytes($argumentsJson))
    $info.ArgumentList.Add('-NoLogo')
    $info.ArgumentList.Add('-NoProfile')
    $info.ArgumentList.Add('-Command')
    $info.ArgumentList.Add(@'
$culture = [Globalization.CultureInfo]::GetCultureInfo($env:GATECRAFT_TEST_CULTURE)
[Threading.Thread]::CurrentThread.CurrentCulture = $culture
[Threading.Thread]::CurrentThread.CurrentUICulture = $culture
$argumentsJson = [Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String($env:GATECRAFT_TEST_GUARD_ARGUMENTS_BASE64))
$guardArguments = @(ConvertFrom-Json -InputObject $argumentsJson)
& $env:GATECRAFT_TEST_GUARD_SCRIPT @guardArguments
exit $LASTEXITCODE
'@)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw "Could not start $CultureName guard child." }
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "$CultureName guard child exceeded its hard timeout."
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $outTask.GetAwaiter().GetResult(); Error = $errorTask.GetAwaiter().GetResult() }
    }
    finally { $process.Dispose() }
}

function Start-GuardChild {
    param([string[]] $Arguments)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = New-GuardStartInfo -Surface powershell -Arguments $Arguments -TestControls $true
    if (-not $process.Start()) { throw 'Could not start concurrent guard child.' }
    $children.Add($process)
    return $process
}

function Complete-GuardChild {
    param([Diagnostics.Process] $Process, [int] $TimeoutMilliseconds = 30000)
    $outTask = $Process.StandardOutput.ReadToEndAsync()
    $errorTask = $Process.StandardError.ReadToEndAsync()
    if (-not $Process.WaitForExit($TimeoutMilliseconds)) {
        $Process.Kill($true)
        $Process.WaitForExit()
        throw 'Concurrent guard child exceeded its hard timeout.'
    }
    return [pscustomobject]@{ ExitCode = $Process.ExitCode; Output = $outTask.GetAwaiter().GetResult(); Error = $errorTask.GetAwaiter().GetResult() }
}

function New-ManifestJson {
    param([Diagnostics.Process] $Process, [string] $WorkerId = 'worker-1', [string] $Start = '')
    if ([string]::IsNullOrEmpty($Start)) { $Start = Get-CanonicalStart $Process }
    return ConvertTo-Json @([ordered]@{ worker_id = $WorkerId; pid = $Process.Id; process_start = $Start }) -Compress
}

function New-BaselineArguments {
    param([string] $Repository, [string] $StateRoot, [string] $BaselineId, [string] $Manifest, [string] $OwnedJson = '["owned.txt"]')
    return @('baseline','--repository-root',$Repository,'--state-root',$StateRoot,'--baseline-id',$BaselineId,'--owned-paths-json',$OwnedJson,'--process-manifest-json',$Manifest)
}

function New-SweepArguments {
    param([string] $Repository, [string] $StateRoot, [string] $BaselineId)
    return @('sweep','--repository-root',$Repository,'--state-root',$StateRoot,'--baseline-id',$BaselineId)
}

function Invoke-ThirdShellWrite {
    param([string] $Path, [byte[]] $Bytes)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $pwshPath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.Environment['GATECRAFT_TEST_WRITE_PATH'] = $Path
    $info.Environment['GATECRAFT_TEST_WRITE_BASE64'] = [Convert]::ToBase64String($Bytes)
    $info.ArgumentList.Add('-NoLogo')
    $info.ArgumentList.Add('-NoProfile')
    $info.ArgumentList.Add('-Command')
    $info.ArgumentList.Add('[IO.File]::WriteAllBytes($env:GATECRAFT_TEST_WRITE_PATH,[Convert]::FromBase64String($env:GATECRAFT_TEST_WRITE_BASE64))')
    $process = [Diagnostics.Process]::Start($info)
    $children.Add($process)
    if (-not $process.WaitForExit(10000)) { $process.Kill($true); $process.WaitForExit(); throw 'Third-shell writer timed out.' }
    if ($process.ExitCode -ne 0) { throw 'Third-shell writer failed.' }
}

function Get-FileSha {
    param([string] $Path)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path))).ToLowerInvariant()
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)

    # Production rejects synchronization controls before creating the guard directory.
    $controlRepo = New-TestRepository 'controls-repo'
    $controlOwner = Start-TestSleeper
    $controlStart = Get-CanonicalStart $controlOwner
    $controlCommon = (git -C $controlRepo rev-parse --path-format=absolute --git-common-dir).Trim()
    $controlGuard = Join-Path $controlCommon 'gatecraft-local-guard-v1'
    $controlBarrier = Join-Path $testRoot 'disabled-barrier'
    [void][IO.Directory]::CreateDirectory($controlBarrier)
    $disabled = Invoke-Guard -Arguments @('acquire','--repository-root',$controlRepo,'--owner-token',([Guid]::NewGuid().ToString('N')),'--pid',([string]$controlOwner.Id),'--process-start',$controlStart,'--test-acquire-barrier',$controlBarrier,'--test-participant','disabled','--test-timeout-ms','1000') -TestControls $false
    Assert-True ($disabled.ExitCode -ne 0) 'Test controls must fail without the exact opt-in.'
    Assert-True ($disabled.Error -match 'code=test-controls-disabled') 'Disabled test controls must expose a stable reason.'
    Assert-True (-not [IO.Directory]::Exists($controlGuard)) 'Disabled test controls must be rejected before guard writes.'

    $controlManifest = New-ManifestJson $controlOwner
    $insideState = Join-Path $controlRepo 'runtime-state'
    $insideBaseline = Invoke-Guard -Arguments (New-BaselineArguments -Repository $controlRepo -StateRoot $insideState -BaselineId inside -Manifest $controlManifest)
    Assert-True ($insideBaseline.ExitCode -ne 0 -and $insideBaseline.Error -match 'code=state-root-repository-overlap') 'State evidence inside the checkout must be rejected.'
    Assert-True (-not [IO.Directory]::Exists($insideState)) 'Overlapping state root must fail before state writes.'
    $collisionState = Join-Path $testRoot 'collision-state'
    $collisionBaseline = Invoke-Guard -Arguments (New-BaselineArguments -Repository $controlRepo -StateRoot $collisionState -BaselineId collision -Manifest $controlManifest -OwnedJson '["owned.txt","OWNED.txt"]')
    Assert-True ($collisionBaseline.ExitCode -ne 0 -and $collisionBaseline.Error -match 'code=owned-paths-case-collision') 'Owned path case collisions must fail closed.'
    Assert-True (-not [IO.Directory]::Exists($collisionState)) 'Invalid owned paths must fail before state writes.'
    $traversalState = Join-Path $testRoot 'traversal-state'
    $traversalBaseline = Invoke-Guard -Arguments (New-BaselineArguments -Repository $controlRepo -StateRoot $traversalState -BaselineId traversal -Manifest $controlManifest -OwnedJson '["../foreign.txt"]')
    Assert-True ($traversalBaseline.ExitCode -ne 0 -and $traversalBaseline.Error -match 'code=owned-paths-malformed') 'Owned traversal must fail closed.'
    Assert-True (-not [IO.Directory]::Exists($traversalState)) 'Traversal must fail before state writes.'
    $manifestState = Join-Path $testRoot 'malformed-manifest-state'
    $malformedManifest = Invoke-Guard -Arguments (New-BaselineArguments -Repository $controlRepo -StateRoot $manifestState -BaselineId malformed -Manifest '[{"worker_id":"worker-1","pid":1}]')
    Assert-True ($malformedManifest.ExitCode -ne 0 -and $malformedManifest.Error -match 'code=process-manifest-malformed') 'Malformed process manifest must fail closed.'
    Assert-True (-not [IO.Directory]::Exists($manifestState)) 'Malformed manifest must fail before state writes.'

    # Canonical baseline bytes and every persisted path/process array use ordinal ordering under any culture.
    $ordinalRepo = New-TestRepository 'ordinal-culture-repo'
    $ordinalWorkerA = Start-TestSleeper
    $ordinalWorkerZ = Start-TestSleeper
    $aUmlautPath = "$([char]0x00E4).txt"
    [IO.File]::WriteAllText((Join-Path $ordinalRepo 'z.txt'), "z-dirty`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $ordinalRepo $aUmlautPath), "a-umlaut-dirty`n", $utf8)
    $ordinalOwnedJson = ConvertTo-Json -InputObject @($aUmlautPath, 'z.txt') -Compress
    $ordinalManifest = ConvertTo-Json -InputObject @(
        [ordered]@{ worker_id = 'z-worker'; pid = $ordinalWorkerZ.Id; process_start = Get-CanonicalStart $ordinalWorkerZ },
        [ordered]@{ worker_id = 'a-worker'; pid = $ordinalWorkerA.Id; process_start = Get-CanonicalStart $ordinalWorkerA }
    ) -Compress
    $deState = Join-Path $testRoot 'ordinal-state-de'
    $svState = Join-Path $testRoot 'ordinal-state-sv'
    $deResult = Invoke-CultureGuard -CultureName 'de-DE' -Arguments (New-BaselineArguments -Repository $ordinalRepo -StateRoot $deState -BaselineId ordinal -Manifest $ordinalManifest -OwnedJson $ordinalOwnedJson)
    $svResult = Invoke-CultureGuard -CultureName 'sv-SE' -Arguments (New-BaselineArguments -Repository $ordinalRepo -StateRoot $svState -BaselineId ordinal -Manifest $ordinalManifest -OwnedJson $ordinalOwnedJson)
    Assert-Equal $deResult.ExitCode 0 "de-DE baseline must pass. stderr=$($deResult.Error)"
    Assert-Equal $svResult.ExitCode 0 "sv-SE baseline must pass. stderr=$($svResult.Error)"
    $deOrdinalBytes = [IO.File]::ReadAllBytes((Join-Path $deState 'guard-baselines-v1/ordinal.json'))
    $svOrdinalBytes = [IO.File]::ReadAllBytes((Join-Path $svState 'guard-baselines-v1/ordinal.json'))
    Assert-CanonicalUtf8Bytes $deOrdinalBytes 'de-DE ordinal baseline record'
    Assert-CanonicalUtf8Bytes $svOrdinalBytes 'sv-SE ordinal baseline record'
    Assert-True (Test-BytesEqual $deOrdinalBytes $svOrdinalBytes) 'de-DE and sv-SE canonical baseline records must be byte-identical.'
    $ordinalRecord = ConvertFrom-Json ([Text.UTF8Encoding]::new($false, $true).GetString($deOrdinalBytes))
    Assert-Equal @($ordinalRecord.owned_paths).Count 2 'Ordinal fixture must persist both owned paths.'
    Assert-Equal $ordinalRecord.owned_paths[0] 'z.txt' 'Owned paths must put z.txt before ä.txt by ordinal comparison.'
    Assert-Equal $ordinalRecord.owned_paths[1] $aUmlautPath 'Owned paths must retain the exact Unicode path.'
    Assert-Equal @($ordinalRecord.dirty_paths).Count 2 'Ordinal fixture must persist both dirty paths.'
    Assert-Equal $ordinalRecord.dirty_paths[0].path 'z.txt' 'Dirty paths must put z.txt before ä.txt by ordinal comparison.'
    Assert-Equal $ordinalRecord.dirty_paths[1].path $aUmlautPath 'Dirty paths must retain the exact Unicode path.'
    Assert-Equal @($ordinalRecord.expected_processes).Count 2 'Ordinal fixture must persist both live process bindings.'
    Assert-Equal $ordinalRecord.expected_processes[0].worker_id 'a-worker' 'Expected-process manifest must use ordinal worker ordering.'
    Assert-Equal $ordinalRecord.expected_processes[1].worker_id 'z-worker' 'Expected-process manifest must retain both live bindings.'

    # Two real acquisitions leave one holder; wrong-token release is byte preserving.
    $lockRepo = New-TestRepository 'concurrent-lock-repo'
    $ownerA = Start-TestSleeper
    $ownerB = Start-TestSleeper
    $startA = Get-CanonicalStart $ownerA
    $startB = Get-CanonicalStart $ownerB
    $tokenA = [Guid]::NewGuid().ToString('N')
    $tokenB = [Guid]::NewGuid().ToString('N')
    $barrier = Join-Path $testRoot 'acquire-barrier'
    [void][IO.Directory]::CreateDirectory($barrier)
    $common = (git -C $lockRepo rev-parse --path-format=absolute --git-common-dir).Trim()
    $keepPath = Join-Path $common 'guard-sibling-keep.txt'
    [IO.File]::WriteAllText($keepPath, 'keep', $utf8)
    $argsA = @('acquire','--repository-root',$lockRepo,'--owner-token',$tokenA,'--pid',([string]$ownerA.Id),'--process-start',$startA,'--test-acquire-barrier',$barrier,'--test-participant','one','--test-timeout-ms','30000')
    $argsB = @('acquire','--repository-root',$lockRepo,'--owner-token',$tokenB,'--pid',([string]$ownerB.Id),'--process-start',$startB,'--test-acquire-barrier',$barrier,'--test-participant','two','--test-timeout-ms','30000')
    $acquireA = Start-GuardChild $argsA
    $acquireB = Start-GuardChild $argsB
    $wait = [Diagnostics.Stopwatch]::StartNew()
    while ((-not [IO.File]::Exists((Join-Path $barrier 'ready-one')) -or -not [IO.File]::Exists((Join-Path $barrier 'ready-two'))) -and $wait.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 20 }
    if (-not [IO.File]::Exists((Join-Path $barrier 'ready-one')) -or -not [IO.File]::Exists((Join-Path $barrier 'ready-two'))) {
        if ($acquireA.HasExited) { $earlyA = Complete-GuardChild $acquireA; [Console]::Error.WriteLine("early acquire A: exit=$($earlyA.ExitCode) out=$($earlyA.Output) err=$($earlyA.Error)") }
        if ($acquireB.HasExited) { $earlyB = Complete-GuardChild $acquireB; [Console]::Error.WriteLine("early acquire B: exit=$($earlyB.ExitCode) out=$($earlyB.Output) err=$($earlyB.Error)") }
    }
    Assert-True ([IO.File]::Exists((Join-Path $barrier 'ready-one')) -and [IO.File]::Exists((Join-Path $barrier 'ready-two'))) 'Both acquisitions must reach one release barrier.'
    [IO.File]::WriteAllBytes((Join-Path $barrier 'release'), [byte[]]::new(0))
    $resultA = Complete-GuardChild $acquireA
    $resultB = Complete-GuardChild $acquireB
    $acquireExitCodes = @($resultA.ExitCode, $resultB.ExitCode)
    Assert-Equal (@($acquireExitCodes | Where-Object { $_ -eq 0 }).Count) 1 'Exactly one concurrent acquisition must exit zero.'
    Assert-Equal (@($acquireExitCodes | Where-Object { $_ -ne 0 }).Count) 1 'Exactly one concurrent acquisition must exit nonzero.'
    $holderPath = Join-Path $common 'gatecraft-local-guard-v1/holder.json'
    Assert-True ([IO.File]::Exists($holderPath)) 'One holder record must remain.'
    $holderBytes = [IO.File]::ReadAllBytes($holderPath)
    Assert-CanonicalUtf8Bytes $holderBytes 'Holder record'
    $holder = ConvertFrom-Json ([Text.UTF8Encoding]::new($false, $true).GetString($holderBytes))
    Assert-Equal $holder.protocol 'gatecraft-local-lock/v1' 'Holder protocol must be exact.'
    $heldProcess = [Diagnostics.Process]::GetProcessById([int]$holder.pid)
    $persistedHolderStart = ([DateTime]$holder.process_start).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    try { Assert-Equal (Get-CanonicalStart $heldProcess) $persistedHolderStart 'Holder PID/start must bind to the live process.' } finally { $heldProcess.Dispose() }
    if ($holder.owner_token -ceq $tokenA) { $heldToken = $tokenA; $heldPid = $ownerA.Id; $heldStart = $startA }
    elseif ($holder.owner_token -ceq $tokenB) { $heldToken = $tokenB; $heldPid = $ownerB.Id; $heldStart = $startB }
    else { throw 'ASSERTION FAILED: Holder token is not either contender.' }
    $wrongToken = [Guid]::NewGuid().ToString('N')
    $wrong = Invoke-Guard -Arguments @('release','--repository-root',$lockRepo,'--owner-token',$wrongToken,'--pid',([string]$heldPid),'--process-start',$heldStart)
    Assert-True ($wrong.ExitCode -ne 0) 'Wrong-token release must fail.'
    Assert-True ($wrong.Error -match 'code=lock-owner-mismatch') 'Wrong-token release must expose the stable owner mismatch.'
    Assert-True (Test-BytesEqual ([IO.File]::ReadAllBytes($holderPath)) $holderBytes) 'Wrong-token release must leave the record byte-identical.'
    $released = Invoke-Guard -Arguments @('release','--repository-root',$lockRepo,'--owner-token',$heldToken,'--pid',([string]$heldPid),'--process-start',$heldStart)
    Assert-Equal $released.ExitCode 0 'Correct owner release must pass.'
    Assert-True (-not [IO.File]::Exists($holderPath)) 'Correct release must remove its holder file.'
    Assert-Equal ([IO.File]::ReadAllText($keepPath)) 'keep' 'Release must not remove a sibling common-dir file.'

    # Stale, empty/partial, and unexpected guard state remains untouched for attended handling.
    $safetyRepo = New-TestRepository 'lock-safety-repo'
    $staleOwner = Start-TestSleeper
    $safetyContender = Start-TestSleeper
    $staleToken = [Guid]::NewGuid().ToString('N')
    $safetyToken = [Guid]::NewGuid().ToString('N')
    $staleStart = Get-CanonicalStart $staleOwner
    $safetyStart = Get-CanonicalStart $safetyContender
    $safetyCommon = (git -C $safetyRepo rev-parse --path-format=absolute --git-common-dir).Trim()
    $safetyDirectory = Join-Path $safetyCommon 'gatecraft-local-guard-v1'
    $safetyHolder = Join-Path $safetyDirectory 'holder.json'
    Assert-Equal (Invoke-Guard -Arguments @('acquire','--repository-root',$safetyRepo,'--owner-token',$staleToken,'--pid',([string]$staleOwner.Id),'--process-start',$staleStart)).ExitCode 0 'Stale fixture acquisition must pass while live.'
    $staleBytes = [IO.File]::ReadAllBytes($safetyHolder)
    $staleOwner.Kill($true)
    $staleOwner.WaitForExit()
    $staleAttempt = Invoke-Guard -Arguments @('acquire','--repository-root',$safetyRepo,'--owner-token',$safetyToken,'--pid',([string]$safetyContender.Id),'--process-start',$safetyStart)
    Assert-True ($staleAttempt.ExitCode -ne 0 -and $staleAttempt.Error -match 'code=lock-stale-attended-recovery-required') 'A stale lock must block without auto-steal.'
    Assert-True (Test-BytesEqual ([IO.File]::ReadAllBytes($safetyHolder)) $staleBytes) 'Stale rejection must preserve the holder bytes.'
    [IO.File]::Delete($safetyHolder) # Exact fixture teardown; production has no recovery path.
    [IO.File]::WriteAllBytes($safetyHolder, [byte[]]::new(0))
    $emptyAttempt = Invoke-Guard -Arguments @('acquire','--repository-root',$safetyRepo,'--owner-token',$safetyToken,'--pid',([string]$safetyContender.Id),'--process-start',$safetyStart)
    Assert-True ($emptyAttempt.ExitCode -ne 0 -and $emptyAttempt.Error -match 'code=lock-record-invalid') 'An empty holder must fail closed.'
    Assert-Equal ([IO.FileInfo]::new($safetyHolder).Length) 0 'Malformed holder must not be rewritten.'
    [IO.File]::Delete($safetyHolder)
    $unexpected = Join-Path $safetyDirectory 'unexpected.txt'
    [IO.File]::WriteAllText($unexpected, 'unexpected', $utf8)
    $unexpectedAttempt = Invoke-Guard -Arguments @('acquire','--repository-root',$safetyRepo,'--owner-token',$safetyToken,'--pid',([string]$safetyContender.Id),'--process-start',$safetyStart)
    Assert-True ($unexpectedAttempt.ExitCode -ne 0 -and $unexpectedAttempt.Error -match 'code=lock-unexpected-entry') 'Unexpected guard entries must fail closed.'
    Assert-Equal ([IO.File]::ReadAllText($unexpected)) 'unexpected' 'Unexpected guard entry must remain untouched.'

    # PowerShell and platform-selected Bash use the same lock and baseline bytes/exits.
    $parityRepo = New-TestRepository 'shell-parity-repo'
    $parityOwner = Start-TestSleeper
    $parityStart = Get-CanonicalStart $parityOwner
    $parityToken = [Guid]::NewGuid().ToString('N')
    $parityCommon = (git -C $parityRepo rev-parse --path-format=absolute --git-common-dir).Trim()
    $parityHolder = Join-Path $parityCommon 'gatecraft-local-guard-v1/holder.json'
    $lockArguments = @('acquire','--repository-root',$parityRepo,'--owner-token',$parityToken,'--pid',([string]$parityOwner.Id),'--process-start',$parityStart)
    $releaseArguments = @('release','--repository-root',$parityRepo,'--owner-token',$parityToken,'--pid',([string]$parityOwner.Id),'--process-start',$parityStart)
    $psLock = Invoke-Guard -Surface powershell -Arguments $lockArguments
    Assert-Equal $psLock.ExitCode 0 'PowerShell lock acquire must pass.'
    $psLockBytes = [IO.File]::ReadAllBytes($parityHolder)
    Assert-Equal (Invoke-Guard -Surface powershell -Arguments $releaseArguments).ExitCode 0 'PowerShell lock release must pass.'
    $bashLock = Invoke-Guard -Surface bash -Arguments $lockArguments
    if ($bashLock.ExitCode -ne 0) {
        $bashEnvironmentFailure = "Exact Git Bash could not start the guard (exit=$($bashLock.ExitCode))."
        [Console]::Error.WriteLine($bashEnvironmentFailure)
    }
    else {
        Assert-True (Test-BytesEqual ([IO.File]::ReadAllBytes($parityHolder)) $psLockBytes) 'PowerShell and Bash lock bytes must match.'
        Assert-Equal (Invoke-Guard -Surface bash -Arguments $releaseArguments).ExitCode 0 'Bash lock release must pass.'
    }
    $parityManifest = New-ManifestJson $parityOwner
    $psState = Join-Path $testRoot 'parity-state-ps'
    $bashState = Join-Path $testRoot 'parity-state-bash'
    $psBaselineArgs = New-BaselineArguments -Repository $parityRepo -StateRoot $psState -BaselineId parity -Manifest $parityManifest
    $bashBaselineArgs = New-BaselineArguments -Repository $parityRepo -StateRoot $bashState -BaselineId parity -Manifest $parityManifest
    $psBaselineResult = Invoke-Guard -Surface powershell -Arguments $psBaselineArgs
    Assert-Equal $psBaselineResult.ExitCode 0 'PowerShell baseline must pass.'
    $psBaselinePath = Join-Path $psState 'guard-baselines-v1/parity.json'
    $bashBaselinePath = Join-Path $bashState 'guard-baselines-v1/parity.json'
    Assert-CanonicalUtf8Bytes ([IO.File]::ReadAllBytes($psBaselinePath)) 'Baseline record'
    $psDuplicate = Invoke-Guard -Surface powershell -Arguments $psBaselineArgs
    Assert-True ($psDuplicate.ExitCode -ne 0 -and $psDuplicate.Error -match 'code=baseline-exists') 'PowerShell must report create-only baseline conflict.'
    if ([string]::IsNullOrEmpty($bashEnvironmentFailure)) {
        Assert-Equal (Invoke-Guard -Surface bash -Arguments $bashBaselineArgs).ExitCode 0 'Bash baseline must pass.'
        Assert-True (Test-BytesEqual ([IO.File]::ReadAllBytes($psBaselinePath)) ([IO.File]::ReadAllBytes($bashBaselinePath))) 'PowerShell and Bash baseline bytes must match.'
        $bashDuplicate = Invoke-Guard -Surface bash -Arguments $bashBaselineArgs
        Assert-Equal $psDuplicate.ExitCode $bashDuplicate.ExitCode 'Duplicate baseline exits must agree across shells.'
        Assert-True ($bashDuplicate.Error -match 'code=baseline-exists') 'Bash must report create-only baseline conflict.'
    }

    # Owned-only changes pass; a separate shell's foreign edit blocks without mutation.
    $foreignRepo = New-TestRepository 'foreign-change-repo'
    $foreignWorker = Start-TestSleeper
    $foreignState = Join-Path $testRoot 'foreign-state'
    $foreignManifest = New-ManifestJson $foreignWorker
    Assert-Equal (Invoke-Guard -Arguments (New-BaselineArguments -Repository $foreignRepo -StateRoot $foreignState -BaselineId foreign -Manifest $foreignManifest)).ExitCode 0 'Foreign-change baseline must pass.'
    [IO.File]::WriteAllText((Join-Path $foreignRepo 'owned.txt'), "owned-change`n", $utf8)
    $ownedSweep = Invoke-Guard -Arguments (New-SweepArguments -Repository $foreignRepo -StateRoot $foreignState -BaselineId foreign)
    Assert-Equal $ownedSweep.ExitCode 0 'A change confined to owned paths must pass.'
    Assert-True ($ownedSweep.Output -match 'owned_changes=1') 'Owned-only sweep must report an owned finding.'
    $foreignPath = Join-Path $foreignRepo 'foreign.txt'
    $foreignBytes = $utf8.GetBytes("third-shell-foreign-edit`n")
    Invoke-ThirdShellWrite -Path $foreignPath -Bytes $foreignBytes
    $foreignHashBefore = Get-FileSha $foreignPath
    $blockedSweep = Invoke-Guard -Arguments (New-SweepArguments -Repository $foreignRepo -StateRoot $foreignState -BaselineId foreign)
    Assert-True ($blockedSweep.ExitCode -ne 0 -and $blockedSweep.Error -match 'code=foreign-change') 'Out-of-owned change must block visibly.'
    Assert-Equal (Get-FileSha $foreignPath) $foreignHashBefore 'Blocked sweep must leave foreign bytes exact.'
    Assert-True (Test-BytesEqual ([IO.File]::ReadAllBytes($foreignPath)) $foreignBytes) 'Blocked sweep must preserve the third-shell payload.'
    & git -C $foreignRepo diff --cached --quiet --
    Assert-Equal $LASTEXITCODE 0 'Sweep must not stage any path.'

    # Repository config must not hide a dirty submodule from the foreign-change sweep.
    $submoduleSource = New-TestRepository 'submodule-source-repo'
    $submoduleParent = New-TestRepository 'submodule-foreign-parent'
    Invoke-Git $submoduleParent -c protocol.file.allow=always submodule add $submoduleSource vendor/dep | Out-Null
    Invoke-Git $submoduleParent add .gitmodules vendor/dep | Out-Null
    Invoke-Git $submoduleParent commit -m add-submodule | Out-Null
    Invoke-Git $submoduleParent config submodule.vendor/dep.ignore all | Out-Null
    $submoduleWorker = Start-TestSleeper
    $submoduleState = Join-Path $testRoot 'submodule-foreign-state'
    Assert-Equal (Invoke-Guard -Arguments (New-BaselineArguments -Repository $submoduleParent -StateRoot $submoduleState -BaselineId submoduleforeign -Manifest (New-ManifestJson $submoduleWorker))).ExitCode 0 'Submodule baseline must pass before a foreign edit.'
    $submoduleForeignPath = Join-Path $submoduleParent 'vendor/dep/foreign.txt'
    $submoduleForeignBytes = $utf8.GetBytes("hidden-submodule-foreign-edit`n")
    Invoke-ThirdShellWrite -Path $submoduleForeignPath -Bytes $submoduleForeignBytes
    $submoduleSweep = Invoke-Guard -Arguments (New-SweepArguments -Repository $submoduleParent -StateRoot $submoduleState -BaselineId submoduleforeign)
    Assert-True ($submoduleSweep.ExitCode -ne 0 -and $submoduleSweep.Error -match 'code=foreign-change') 'A configured ignored submodule edit must block visibly.'
    Assert-True (Test-BytesEqual ([IO.File]::ReadAllBytes($submoduleForeignPath)) $submoduleForeignBytes) 'Blocked submodule sweep must preserve foreign bytes.'

    # Movement of refs/heads/main blocks and does not rewrite history.
    $mainRepo = New-TestRepository 'main-movement-repo'
    $mainWorker = Start-TestSleeper
    $mainState = Join-Path $testRoot 'main-state'
    Assert-Equal (Invoke-Guard -Arguments (New-BaselineArguments -Repository $mainRepo -StateRoot $mainState -BaselineId mainmove -Manifest (New-ManifestJson $mainWorker))).ExitCode 0 'Main movement baseline must pass.'
    [IO.File]::WriteAllText((Join-Path $mainRepo 'owned.txt'), "new-main`n", $utf8)
    Invoke-Git $mainRepo add -- owned.txt | Out-Null
    Invoke-Git $mainRepo commit -m move-main | Out-Null
    $movedSha = (git -C $mainRepo rev-parse refs/heads/main).Trim()
    $mainBlocked = Invoke-Guard -Arguments (New-SweepArguments -Repository $mainRepo -StateRoot $mainState -BaselineId mainmove)
    Assert-True ($mainBlocked.ExitCode -ne 0 -and $mainBlocked.Error -match 'code=main-moved') 'Main movement must block visibly.'
    Assert-Equal ((git -C $mainRepo rev-parse refs/heads/main).Trim()) $movedSha 'Blocked main sweep must not mutate history.'

    # Live, dead, and wrong-start process bindings.
    $processRepo = New-TestRepository 'process-binding-repo'
    $liveWorker = Start-TestSleeper
    $processState = Join-Path $testRoot 'process-state'
    Assert-Equal (Invoke-Guard -Arguments (New-BaselineArguments -Repository $processRepo -StateRoot $processState -BaselineId process -Manifest (New-ManifestJson $liveWorker))).ExitCode 0 'A real live expected process must baseline.'
    Assert-Equal (Invoke-Guard -Arguments (New-SweepArguments -Repository $processRepo -StateRoot $processState -BaselineId process)).ExitCode 0 'A real live expected process must sweep.'
    $liveWorker.Kill($true)
    $liveWorker.WaitForExit()
    $deadSweep = Invoke-Guard -Arguments (New-SweepArguments -Repository $processRepo -StateRoot $processState -BaselineId process)
    Assert-True ($deadSweep.ExitCode -ne 0 -and $deadSweep.Error -match 'code=process-dead') 'Killed expected process must block.'
    $wrongWorker = Start-TestSleeper
    $wrongStart = $wrongWorker.StartTime.ToUniversalTime().AddSeconds(1).ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    $wrongState = Join-Path $testRoot 'wrong-start-state'
    $wrongBaseline = Invoke-Guard -Arguments (New-BaselineArguments -Repository $processRepo -StateRoot $wrongState -BaselineId wrongstart -Manifest (New-ManifestJson -Process $wrongWorker -Start $wrongStart))
    Assert-True ($wrongBaseline.ExitCode -ne 0 -and $wrongBaseline.Error -match 'code=process-start-mismatch') 'Live PID with wrong start time must block before baseline persistence.'
    Assert-True (-not [IO.Directory]::Exists($wrongState)) 'Wrong-start manifest must fail before local state writes.'

    # Already dirty and untracked bytes are hashed even when porcelain tokens stay fixed.
    $dirtyRepo = New-TestRepository 'dirty-byte-repo'
    $dirtyWorker = Start-TestSleeper
    [IO.File]::WriteAllText((Join-Path $dirtyRepo 'foreign.txt'), "dirty-before-baseline`n", $utf8)
    $untrackedPath = Join-Path $dirtyRepo 'untracked.txt'
    [IO.File]::WriteAllText($untrackedPath, "untracked-before-baseline`n", $utf8)
    $statusBefore = (& git -C $dirtyRepo status --porcelain=v1 --untracked-files=all) -join "`n"
    $dirtyState = Join-Path $testRoot 'dirty-state'
    Assert-Equal (Invoke-Guard -Arguments (New-BaselineArguments -Repository $dirtyRepo -StateRoot $dirtyState -BaselineId dirty -Manifest (New-ManifestJson $dirtyWorker))).ExitCode 0 'Dirty/untracked baseline must pass.'
    [IO.File]::WriteAllText((Join-Path $dirtyRepo 'foreign.txt'), "dirty-after-baseline`n", $utf8)
    [IO.File]::WriteAllText($untrackedPath, "untracked-after-baseline`n", $utf8)
    $statusAfter = (& git -C $dirtyRepo status --porcelain=v1 --untracked-files=all) -join "`n"
    Assert-Equal $statusAfter $statusBefore 'Fixture must retain identical porcelain status tokens.'
    $dirtyBlocked = Invoke-Guard -Arguments (New-SweepArguments -Repository $dirtyRepo -StateRoot $dirtyState -BaselineId dirty)
    Assert-True ($dirtyBlocked.ExitCode -ne 0 -and $dirtyBlocked.Error -match 'code=foreign-change') 'Further byte changes under identical status must block.'

    # Canonical JSON cannot omit a path that remains present in the persisted raw status.
    $inconsistentRepo = New-TestRepository 'inconsistent-baseline-repo'
    $inconsistentWorker = Start-TestSleeper
    $inconsistentForeign = Join-Path $inconsistentRepo 'foreign.txt'
    [IO.File]::WriteAllText($inconsistentForeign, "dirty-before-inconsistent-baseline`n", $utf8)
    $inconsistentStatusBefore = (& git -C $inconsistentRepo status --porcelain=v1 --untracked-files=all) -join "`n"
    Assert-Equal $inconsistentStatusBefore ' M foreign.txt' 'Inconsistent-record fixture must begin with one dirty foreign path.'
    $inconsistentState = Join-Path $testRoot 'inconsistent-baseline-state'
    Assert-Equal (Invoke-Guard -Arguments (New-BaselineArguments -Repository $inconsistentRepo -StateRoot $inconsistentState -BaselineId inconsistent -Manifest (New-ManifestJson $inconsistentWorker))).ExitCode 0 'Inconsistent-record fixture baseline must start valid.'
    $inconsistentBaselinePath = Join-Path $inconsistentState 'guard-baselines-v1/inconsistent.json'
    $inconsistentBaseline = ConvertFrom-Json ([IO.File]::ReadAllText($inconsistentBaselinePath, $utf8))
    Assert-Equal @($inconsistentBaseline.dirty_paths).Count 1 'Valid fixture baseline must fingerprint the dirty foreign path.'
    Assert-Equal $inconsistentBaseline.dirty_paths[0].path 'foreign.txt' 'Valid fixture baseline must bind the exact dirty foreign path.'
    $inconsistentBaseline.dirty_paths = @()
    $inconsistentCanonical = ConvertTo-Json -InputObject $inconsistentBaseline -Depth 8 -Compress -EscapeHandling EscapeNonAscii
    [IO.File]::WriteAllText($inconsistentBaselinePath, $inconsistentCanonical, $utf8)
    Assert-CanonicalUtf8Bytes ([IO.File]::ReadAllBytes($inconsistentBaselinePath)) 'Semantically inconsistent baseline record'
    $inconsistentBytes = $utf8.GetBytes("dirty-after-inconsistent-baseline`n")
    Invoke-ThirdShellWrite -Path $inconsistentForeign -Bytes $inconsistentBytes
    $inconsistentStatusAfter = (& git -C $inconsistentRepo status --porcelain=v1 --untracked-files=all) -join "`n"
    Assert-Equal $inconsistentStatusAfter $inconsistentStatusBefore 'Inconsistent-record fixture must retain the same porcelain status token.'
    $inconsistentCheckoutBeforeSweep = [IO.File]::ReadAllBytes($inconsistentForeign)
    $inconsistentSweep = Invoke-Guard -Arguments (New-SweepArguments -Repository $inconsistentRepo -StateRoot $inconsistentState -BaselineId inconsistent)
    Assert-True ($inconsistentSweep.ExitCode -ne 0 -and $inconsistentSweep.Error -match 'code=baseline-record-invalid') 'Sweep must reject a canonical baseline whose dirty paths omit a persisted status path.'
    Assert-True (Test-BytesEqual ([IO.File]::ReadAllBytes($inconsistentForeign)) $inconsistentCheckoutBeforeSweep) 'Invalid-baseline sweep must leave checkout bytes exact.'
    Assert-True (Test-BytesEqual ([IO.File]::ReadAllBytes($inconsistentForeign)) $inconsistentBytes) 'Invalid-baseline sweep must preserve the third-shell payload.'

    # Index bytes are also bound when both porcelain tokens and worktree bytes stay fixed.
    $indexRepo = New-TestRepository 'dirty-index-repo'
    $indexWorker = Start-TestSleeper
    $indexForeign = Join-Path $indexRepo 'foreign.txt'
    [IO.File]::WriteAllText($indexForeign, "index-stage-one`n", $utf8)
    Invoke-Git $indexRepo add -- foreign.txt | Out-Null
    [IO.File]::WriteAllText($indexForeign, "stable-worktree-bytes`n", $utf8)
    $indexStatusBefore = (& git -C $indexRepo status --porcelain=v1 --untracked-files=all) -join "`n"
    $indexState = Join-Path $testRoot 'dirty-index-state'
    Assert-Equal (Invoke-Guard -Arguments (New-BaselineArguments -Repository $indexRepo -StateRoot $indexState -BaselineId indexdirty -Manifest (New-ManifestJson $indexWorker))).ExitCode 0 'Dirty index baseline must pass.'
    [IO.File]::WriteAllText($indexForeign, "index-stage-two`n", $utf8)
    Invoke-Git $indexRepo add -- foreign.txt | Out-Null
    [IO.File]::WriteAllText($indexForeign, "stable-worktree-bytes`n", $utf8)
    $indexStatusAfter = (& git -C $indexRepo status --porcelain=v1 --untracked-files=all) -join "`n"
    Assert-Equal $indexStatusAfter $indexStatusBefore 'Index fixture must retain identical porcelain tokens.'
    $indexBlocked = Invoke-Guard -Arguments (New-SweepArguments -Repository $indexRepo -StateRoot $indexState -BaselineId indexdirty)
    Assert-True ($indexBlocked.ExitCode -ne 0 -and $indexBlocked.Error -match 'code=foreign-change') 'Changed index bytes under identical status/worktree bytes must block.'

    # A junction/symlink at the fixed guard directory is rejected before target mutation.
    $reparseRepo = New-TestRepository 'reparse-repo'
    $reparseOwner = Start-TestSleeper
    $reparseCommon = (git -C $reparseRepo rev-parse --path-format=absolute --git-common-dir).Trim()
    $reparseGuard = Join-Path $reparseCommon 'gatecraft-local-guard-v1'
    $externalTarget = Join-Path $testRoot 'reparse-external-target'
    [void][IO.Directory]::CreateDirectory($externalTarget)
    $externalMarker = Join-Path $externalTarget 'marker.bin'
    $markerBytes = [byte[]](0,1,2,3,250,251,252)
    [IO.File]::WriteAllBytes($externalMarker, $markerBytes)
    if ($onWindows) { [void](New-Item -ItemType Junction -Path $reparseGuard -Target $externalTarget) }
    else { [void](New-Item -ItemType SymbolicLink -Path $reparseGuard -Target $externalTarget) }
    $junctions.Add($reparseGuard)
    $reparseResult = Invoke-Guard -Arguments @('acquire','--repository-root',$reparseRepo,'--owner-token',([Guid]::NewGuid().ToString('N')),'--pid',([string]$reparseOwner.Id),'--process-start',(Get-CanonicalStart $reparseOwner))
    Assert-True ($reparseResult.ExitCode -ne 0 -and $reparseResult.Error -match 'code=(?:path-reparse|guard-root-reparse)') 'Reparse guard path must fail closed.'
    Assert-True (Test-BytesEqual ([IO.File]::ReadAllBytes($externalMarker)) $markerBytes) 'Reparse rejection must not mutate the external target.'
    Assert-True (-not [IO.File]::Exists((Join-Path $externalTarget 'holder.json'))) 'Reparse rejection must not create an external holder.'

    if (-not [string]::IsNullOrEmpty($bashEnvironmentFailure)) { throw $bashEnvironmentFailure }
    Write-Host 'Guard gate passed: concurrent lock, owner release, ordinal culture determinism, foreign sweep, process binding, dirty-byte hashing, shell parity, and reparse rejection are green.'
}
finally {
    foreach ($process in $children) {
        try {
            if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        }
        catch { }
        finally { $process.Dispose() }
    }
    foreach ($junction in $junctions) {
        if ([IO.Directory]::Exists($junction)) { Remove-Item -LiteralPath $junction -Force }
    }
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $expectedPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar + 'gatecraft-guard-tests-'
    if (-not $resolvedRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refuse fixture cleanup outside the exact unique temp root.' }
    if ([IO.Directory]::Exists($resolvedRoot)) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
}
