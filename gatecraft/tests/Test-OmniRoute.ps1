[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module = Join-Path $PSScriptRoot '../scripts/OmniRoute.psm1'
Import-Module $module -Force
$moduleInfo = Get-Module OmniRoute
$runtimeIdentity = Get-GatecraftOmniRouteRuntimeIdentity

function Assert-Equal($Actual, $Expected, [string] $Message) {
    if ($Actual -ne $Expected) { throw "$Message Expected=$Expected Actual=$Actual" }
}
function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock] $Action, [string] $Pattern, [string] $Message) {
    try { & $Action; throw "$Message Expected an exception." } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "$Message Wrong exception: $($_.Exception.Message)" }
    }
}

Assert-Equal $runtimeIdentity.Protocol 'gatecraft-omniroute-runtime/v2' 'Runtime identity must expose an explicit implementation protocol.'
Assert-True ($runtimeIdentity.ModuleSha256 -match '^[A-F0-9]{64}$' -and $runtimeIdentity.EntryPointSha256 -match '^[A-F0-9]{64}$' -and $runtimeIdentity.ProcessHostSha256 -match '^[A-F0-9]{64}$') 'Runtime identity must bind module, entry point, and process host to exact hashes.'

Assert-True (Test-GatecraftOmniRouteEndpointUri 'http://localhost:20128') 'Loopback HTTP endpoint must be valid.'
Assert-True (Test-GatecraftOmniRouteEndpointUri 'https://router.example.test') 'HTTPS endpoint origin must be valid.'
Assert-True (-not (Test-GatecraftOmniRouteEndpointUri 'https://router.example.test/token-shaped-path')) 'Endpoint must reject arbitrary paths from persisted or projected origins.'
Assert-True (-not (Test-GatecraftOmniRouteEndpointUri 'http://user:secret@localhost:20128')) 'Endpoint must reject embedded credentials.'
Assert-True (-not (Test-GatecraftOmniRouteEndpointUri 'http://localhost:20128?token=secret')) 'Endpoint must reject query credentials.'
Assert-True (-not (Test-GatecraftOmniRouteEndpointUri 'file:///tmp/omniroute')) 'Endpoint must reject non-HTTP schemes.'
$boundedProcess = & $moduleInfo { Invoke-GatecraftOmniRouteProcess -FilePath (Get-Command pwsh).Source -Arguments @('-NoLogo', '-NoProfile', '-Command', 'Write-Output bounded') -TimeoutMilliseconds 5000 }
Assert-True (-not $boundedProcess.TimedOut -and $boundedProcess.ExitCode -eq 0 -and $boundedProcess.Stdout.Trim() -ceq 'bounded') 'External process wrapper must complete and drain output within its bound.'
$timedOutProcess = & $moduleInfo { Invoke-GatecraftOmniRouteProcess -FilePath (Get-Command pwsh).Source -Arguments @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 5') -TimeoutMilliseconds 200 }
Assert-True ($timedOutProcess.TimedOut) 'External process wrapper must kill and return on timeout.'
$treeReap = & $moduleInfo {
    $pwshPath = (Get-Command pwsh).Source
    $escapedPwshPath = $pwshPath.Replace("'", "''")
    $parentCode = @"
`$startInfo = [Diagnostics.ProcessStartInfo]::new()
`$startInfo.FileName = '$escapedPwshPath'
`$startInfo.UseShellExecute = `$false
foreach (`$argument in @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 30')) { `$startInfo.ArgumentList.Add(`$argument) }
`$child = [Diagnostics.Process]::Start(`$startInfo)
Start-Sleep -Seconds 30
"@
    $encodedParentCode = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($parentCode))
    $parent = Start-Process -FilePath $pwshPath -ArgumentList @('-NoLogo', '-NoProfile', '-EncodedCommand', $encodedParentCode) -PassThru -WindowStyle Hidden
    $observed = [Collections.Generic.Dictionary[int, long]]::new()
    $observationComplete = $true
    try {
        $observationDeadline = [datetimeoffset]::UtcNow.AddSeconds(5)
        do {
            $observationComplete = (Update-GatecraftOmniRouteObservedDescendants -RootId $parent.Id -Observed $observed) -and $observationComplete
            if ($observed.Count -gt 0) { break }
            Start-Sleep -Milliseconds 100
        } while ([datetimeoffset]::UtcNow -lt $observationDeadline)
        if ($observed.Count -eq 0) { throw 'Process-tree fixture did not produce an observable child.' }
        Stop-GatecraftOmniRouteTrackedTree -RootProcess $parent -Observed $observed -ObservationComplete $observationComplete
        [pscustomobject]@{ RootExited = $parent.HasExited; ObservedCount = $observed.Count }
    } finally {
        if (-not $parent.HasExited) { $parent.Kill($true); $parent.WaitForExit(5000) | Out-Null }
        $parent.Dispose()
    }
}
Assert-True ($treeReap.RootExited -and $treeReap.ObservedCount -gt 0) 'Tracked startup cleanup must observe and reap a descendant process tree.'
$loopbackListener = Test-GatecraftOmniRouteLoopbackListener -Port 20128 -ObservedAddresses @('127.0.0.1', '::1')
Assert-True ($loopbackListener.Verified -and $loopbackListener.Safe) 'Loopback-only listeners must verify as safe.'
$wildcardListener = Test-GatecraftOmniRouteLoopbackListener -Port 20128 -ObservedAddresses @('0.0.0.0')
Assert-True ($wildcardListener.Verified -and -not $wildcardListener.Safe -and $wildcardListener.ReasonCode -ceq 'non-loopback-listener') 'Wildcard listeners must fail the managed-start safety check.'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('gatecraft-omniroute-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
try {
    $preferencePath = Join-Path $tempRoot 'config/preferences.json'
    $defaults = Read-GatecraftOmniRoutePreferences -Path $preferencePath
    Assert-Equal $defaults.InstallPrompt 'ask' 'Missing preferences must ask about installation.'
    Assert-Equal $defaults.GlobalUsePolicy 'ask' 'Missing preferences must ask about use.'
    Assert-True (-not $defaults.Exists) 'Missing preferences must remain an observed fact, not a persisted installed flag.'
    $entryPoint = Join-Path $PSScriptRoot '../scripts/omniroute-session.ps1'
    $entryOutput = & pwsh -NoLogo -NoProfile -File $entryPoint get-preferences -PreferencePath $preferencePath
    if ($LASTEXITCODE -ne 0) { throw 'OmniRoute session entry point failed.' }
    $entryPreferences = $entryOutput | ConvertFrom-Json -Depth 8
    Assert-Equal $entryPreferences.InstallPrompt 'ask' 'Runtime entry point must wire preference resolution.'

    $written = Write-GatecraftOmniRoutePreferences -Path $preferencePath -InstallPrompt never -GlobalUsePolicy always -Endpoint 'http://localhost:22000' -Confirm:$false
    Assert-True $written.Valid 'Written preferences must validate.'
    Assert-Equal $written.InstallPrompt 'never' 'Install prompt preference must round-trip.'
    Assert-Equal $written.GlobalUsePolicy 'always' 'Global use preference must round-trip.'
    $resolvedOutput = & pwsh -NoLogo -NoProfile -File $entryPoint resolve-policy -PreferencePath $preferencePath -ProjectPolicy never
    if ($LASTEXITCODE -ne 0) { throw 'OmniRoute runtime policy resolution failed.' }
    $resolvedRuntime = $resolvedOutput | ConvertFrom-Json -Depth 8
    Assert-Equal $resolvedRuntime.decision 'skip' 'Runtime policy resolution must apply project-over-global precedence.'
    Assert-Equal $resolvedRuntime.source 'project' 'Runtime policy resolution must report its source.'
    Assert-Equal $resolvedRuntime.endpoint_origin 'http://localhost:22000' 'Runtime commands must honor the persisted endpoint when no override is supplied.'
    $rawPreferences = [IO.File]::ReadAllText($preferencePath)
    Assert-True ($rawPreferences -notmatch '(?i)installed|api[_-]?key|secret|token') 'Preferences must not persist observed installation state or secrets.'

    [IO.File]::WriteAllText($preferencePath, '{"protocol":"wrong","install_prompt":"never","global_use_policy":"always","endpoint":"http://localhost:20128"}')
    $invalidPreferences = Read-GatecraftOmniRoutePreferences -Path $preferencePath
    Assert-True (-not $invalidPreferences.Valid) 'Malformed preferences must be surfaced as invalid.'
    Assert-Equal $invalidPreferences.InstallPrompt 'ask' 'Invalid preferences must fail back to an ask decision.'
    $invalidResolutionOutput = & pwsh -NoLogo -NoProfile -File $entryPoint resolve-policy -PreferencePath $preferencePath -ProjectPolicy inherit
    if ($LASTEXITCODE -ne 0) { throw 'Malformed preferences must not abort safe runtime policy resolution.' }
    $invalidResolution = $invalidResolutionOutput | ConvertFrom-Json -Depth 8
    Assert-Equal $invalidResolution.decision 'ask' 'Malformed preferences must force explicit session consent.'
    Assert-Equal $invalidResolution.source 'invalid-preferences' 'Malformed preference fallback must be visible to the orchestrator.'
    $invalidExplicitSkipOutput = & pwsh -NoLogo -NoProfile -File $entryPoint resolve-policy -PreferencePath $preferencePath -SessionChoice skip
    if ($LASTEXITCODE -ne 0) { throw 'Explicit session choice must remain usable when global preferences are malformed.' }
    $invalidExplicitSkip = $invalidExplicitSkipOutput | ConvertFrom-Json -Depth 8
    Assert-Equal $invalidExplicitSkip.decision 'skip' 'Explicit session choice must retain highest precedence during malformed-preference fallback.'
    Assert-Equal $invalidExplicitSkip.source 'session' 'Malformed global preferences must not hide an explicit session decision.'

    $repo = Join-Path $tempRoot 'repo'
    [IO.Directory]::CreateDirectory($repo) | Out-Null
    & git -C $repo init -q
    if ($LASTEXITCODE -ne 0) { throw 'Temporary git repository setup failed.' }
    Assert-Equal (Get-GatecraftOmniRouteProjectPolicy -RepositoryRoot $repo) 'inherit' 'A project without an override must inherit.'
    Assert-Equal (Set-GatecraftOmniRouteProjectPolicy -RepositoryRoot $repo -Policy always -Confirm:$false) 'always' 'Project always policy must persist locally.'
    Assert-Equal (Set-GatecraftOmniRouteProjectPolicy -RepositoryRoot $repo -Policy never -Confirm:$false) 'never' 'Project never policy must replace always.'
    Assert-Equal (Set-GatecraftOmniRouteProjectPolicy -RepositoryRoot $repo -Policy inherit -Confirm:$false) 'inherit' 'Inherit must remove the local override.'

    $sourceRoot = Join-Path $tempRoot 'search/OmniRoute/upstream'
    [IO.Directory]::CreateDirectory($sourceRoot) | Out-Null
    & git -C $sourceRoot init -q
    & git -C $sourceRoot remote add origin https://github.com/diegosouzapw/OmniRoute.git
    if ($LASTEXITCODE -ne 0) { throw 'Temporary OmniRoute source repository setup failed.' }
    $sourcePackage = [ordered]@{ name = 'omniroute'; version = '3.8.49'; scripts = [ordered]@{ start = 'node server.mjs'; dev = 'node dev.mjs'; build = 'node scripts/build/build-next-isolated.mjs' } } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'package.json'), $sourcePackage)
    [IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'scripts/dev')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'scripts/build')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'scripts/dev/run-next.mjs'), 'process.exit(0);')
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'scripts/build/build-next-isolated.mjs'), 'process.exit(0);')
    [IO.File]::WriteAllText((Join-Path $sourceRoot '.gitignore'), ".build/`n")
    & git -C $sourceRoot config user.email test@example.invalid
    & git -C $sourceRoot config user.name 'Gatecraft Test'
    & git -C $sourceRoot add package.json scripts/dev/run-next.mjs scripts/build/build-next-isolated.mjs .gitignore
    & git -C $sourceRoot commit -q -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Temporary OmniRoute source commit failed.' }
    Assert-True (Test-GatecraftOmniRouteSourceCheckout -Path $sourceRoot -Mode dev) 'Official source checkout with an allowed script must validate.'
    $missingBuildPreflight = Get-GatecraftOmniRouteSourcePreflight -Target $sourceRoot -Mode start
    Assert-Equal $missingBuildPreflight.Decision 'needs-action' 'Production start must stop before launch when the Next build marker is missing.'
    Assert-Equal $missingBuildPreflight.ReasonCode 'production-build-missing' 'Missing production build must have a stable reason code.'
    Assert-Equal $missingBuildPreflight.RecommendedMode 'dev' 'An unbuilt source checkout must recommend dev without silently switching modes.'
    Assert-True ($missingBuildPreflight.AvailableActions -contains 'build-with-confirmation') 'Missing build preflight must expose a separately confirmed build option.'
    Assert-True ($missingBuildPreflight.SecurityWarnings -contains 'default-initial-password') 'Preflight must report an unset/default initial password without exposing its value.'
    $devPreflight = Get-GatecraftOmniRouteSourcePreflight -Target $sourceRoot -Mode dev
    Assert-Equal $devPreflight.Decision 'ready' 'Development mode must not require a production build.'
    Assert-Equal $devPreflight.RecommendedMode 'dev' 'Development mode must be the recommended unbuilt source mode.'
    $runtimePreflightOutput = & pwsh -NoLogo -NoProfile -File $entryPoint preflight -Adapter source-checkout -Target $sourceRoot -Mode start -PreferencePath $preferencePath
    if ($LASTEXITCODE -ne 0) { throw 'Runtime preflight command failed.' }
    $runtimePreflight = $runtimePreflightOutput | ConvertFrom-Json -Depth 8
    Assert-Equal $runtimePreflight.ReasonCode 'production-build-missing' 'Runtime preflight must expose the same structured decision.'
    $sourceCandidates = @(Find-GatecraftOmniRouteSourceCheckouts -SearchRoots @((Join-Path $tempRoot 'search')) -MaxDepth 4)
    Assert-Equal $sourceCandidates.Count 2 'Discovery must return the typed start and dev modes without traversing dependency trees.'
    Assert-True (@($sourceCandidates | Where-Object { -not $_.PersistentEligible }).Count -eq 0) 'Clean official source candidates must be eligible for identity-bound persistence.'
    Assert-True (@($sourceCandidates | Where-Object { $_.Mode -ceq 'start' -and $_.Startability -ceq 'needs-action' }).Count -eq 1) 'Discovery must expose that unbuilt start mode is not immediately startable.'
    Assert-True (@($sourceCandidates | Where-Object { $_.Mode -ceq 'dev' -and $_.Recommended }).Count -eq 1) 'Discovery must recommend dev for an unbuilt checkout.'
    $buildPlan = New-GatecraftOmniRouteSourceBuildPlan -Target $sourceRoot
    Assert-Equal $buildPlan.DisplayCommand 'node scripts/build/build-next-isolated.mjs' 'Build plan must use the fixed runner instead of mutable npm script text.'
    Assert-True ($buildPlan.RunnerSha256 -match '^[A-F0-9]{64}$' -and $buildPlan.NodeSha256 -match '^[A-F0-9]{64}$') 'Build consent must bind both runner and Node identities.'
    Assert-Throws { Build-GatecraftOmniRouteSourceCheckout -Target $sourceRoot -ExpectedRunnerSha256 $buildPlan.RunnerSha256 -ExpectedNodeSha256 $buildPlan.NodeSha256 -UserConfirmed:$false -Confirm:$false } 'build-direct-confirmation-required' 'Source build must require separate direct confirmation.'
    $preflightStartResult = Start-GatecraftOmniRoute -Adapter source-checkout -Target $sourceRoot -Mode start -Endpoint 'http://localhost:22991' -StartupAdapterPath (Join-Path $tempRoot 'config/no-adapter.json') -UserConfirmedUnregistered:$true -ReadyTimeoutSeconds 5 -Confirm:$false
    Assert-Equal $preflightStartResult.State 'needs-action' 'Start must return the preflight choice without launching an unbuilt source process.'
    Assert-Equal $preflightStartResult.Mode 'start' 'Start must not silently switch an explicit production mode to dev.'
    [IO.Directory]::CreateDirectory((Join-Path $sourceRoot '.build/next')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $sourceRoot '.build/next/BUILD_ID'), 'fixture-build')
    $builtPreflight = Get-GatecraftOmniRouteSourcePreflight -Target $sourceRoot -Mode start
    Assert-Equal $builtPreflight.Decision 'ready' 'A non-empty canonical Next BUILD_ID must satisfy production preflight.'
    $adapterPath = Join-Path $tempRoot 'config/omniroute-startup.json'
    Assert-Throws { Register-GatecraftOmniRouteStartupAdapter -Type source-checkout -Target $sourceRoot -Mode dev -UserConfirmed:$false -Path $adapterPath -Confirm:$false } 'adapter-direct-confirmation-required' 'A discovered source checkout must still require direct registration.'
    $registeredSource = Register-GatecraftOmniRouteStartupAdapter -Type source-checkout -Target $sourceRoot -Mode dev -UserConfirmed:$true -Path $adapterPath -Confirm:$false
    Assert-True ($registeredSource.Exists -and $registeredSource.Valid) 'A directly approved typed source adapter must persist.'
    Assert-Equal $registeredSource.Record.type 'source-checkout' 'Registered source adapter type must round-trip.'
    Assert-Equal $registeredSource.Record.mode 'dev' 'Registered source adapter mode must round-trip.'
    Assert-True ($registeredSource.Record.identity -match '^git:[a-f0-9]+;runner-sha256:[A-F0-9]{64}$') 'Source adapter must bind the approved commit and fixed runner hash.'
    $rawAdapter = [IO.File]::ReadAllText($adapterPath)
    Assert-True ($rawAdapter -notmatch '(?i)api[_-]?key|secret|token|command') 'Startup adapter must not persist secrets or free-form commands.'
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'scripts/dev/run-next.mjs'), 'process.exit(1);')
    $driftedSource = Read-GatecraftOmniRouteStartupAdapter -Path $adapterPath
    Assert-True (-not $driftedSource.Valid) 'A changed source checkout must invalidate persisted startup authority.'
    $ephemeralDirtySource = & $moduleInfo { param($Path) Get-GatecraftOmniRouteEphemeralAdapterIdentity -Type source-checkout -Target $Path -Mode dev } $sourceRoot
    Assert-True ($null -ne $ephemeralDirtySource -and $ephemeralDirtySource.Identity -match '^ephemeral-runner-sha256:[A-F0-9]{64}$') 'A dirty official checkout may be identified for one directly confirmed session without becoming persistently eligible.'
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'scripts/dev/run-next.mjs'), 'process.exit(0);')

    [IO.File]::WriteAllText((Join-Path $sourceRoot 'scripts/dev/run-next.mjs'), 'console.error("INITIAL_PASSWORD is not set — using default CHANGEME; api_key=SUPERSECRET"); console.error("Could not find a production build in the .build/next directory"); process.exit(7);')
    $hostDiagnostic = & $moduleInfo {
        param($Root)
        $node = (Get-Command node -CommandType Application | Select-Object -First 1).Source
        $runner = Join-Path $Root 'scripts/dev/run-next.mjs'
        $host = Start-GatecraftOmniRouteSourceProcessHost -Purpose source-start -NodePath $node -RunnerPath $runner -WorkingDirectory $Root -Mode dev -Port 22992
        if (-not $host.Process.WaitForExit(10000)) { $host.Process.Kill($true); throw 'Diagnostic process host timed out.' }
        Get-GatecraftOmniRouteProcessDiagnostic -LogDirectory $host.LogDirectory -ResultPath $host.ResultPath -FallbackReasonCode 'process-exited-before-ready'
    } $sourceRoot
    Assert-Equal $hostDiagnostic.ExitCode 7 'Process host must preserve the child exit code.'
    Assert-Equal $hostDiagnostic.DiagnosticCode 'production-build-missing' 'Known startup output must map to a structured diagnostic code.'
    $diagnosticProjection = $hostDiagnostic.OutputTail -join "`n"
    Assert-True ($diagnosticProjection -match 'INITIAL_PASSWORD=\[REDACTED\]' -and $diagnosticProjection -notmatch 'CHANGEME|SUPERSECRET') 'Diagnostic output must redact password and API-key material.'
    Assert-True ($diagnosticProjection.Length -le 4000 -and $hostDiagnostic.OutputTail.Count -le 20) 'Diagnostic projection must remain line- and size-bounded.'
    $diagnosticLogBytes = (Get-ChildItem -LiteralPath $hostDiagnostic.RawLogDirectory -File | Measure-Object -Property Length -Sum).Sum
    Assert-True ($diagnosticLogBytes -le 262144) 'Rotating raw startup logs must remain within the fixed aggregate bound.'
    Remove-Item -LiteralPath $hostDiagnostic.RawLogDirectory -Recurse -Force

    $portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $portProbe.Start()
    $managedPort = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
    $portProbe.Stop()
    $managedServerCode = @'
import http from "node:http";
const host = process.env.HOST;
const port = Number(process.env.PORT);
const server = http.createServer((request, response) => {
  response.setHeader("content-type", "application/json");
  response.end(JSON.stringify({ data: [{ id: "fixture/model" }] }));
});
server.listen(port, host);
'@
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'scripts/dev/run-next.mjs'), $managedServerCode)
    $managedStart = $null
    $managedProcessId = $null
    $managedLogDirectory = $null
    try {
        $managedStart = Start-GatecraftOmniRoute -Adapter source-checkout -Target $sourceRoot -Mode dev -Endpoint "http://127.0.0.1:$managedPort" -StartupAdapterPath (Join-Path $tempRoot 'config/no-live-adapter.json') -UserConfirmedUnregistered:$true -ReadyTimeoutSeconds 10 -Confirm:$false
        if ($null -ne $managedStart.PSObject.Properties['ProcessId']) { $managedProcessId = $managedStart.ProcessId }
        if ($null -ne $managedStart.PSObject.Properties['RawLogDirectory']) { $managedLogDirectory = $managedStart.RawLogDirectory }
        Assert-Equal $managedStart.State 'ready' 'Managed source startup must reach readiness through the typed process host.'
        Assert-True ($managedProcessId -is [int] -and -not [string]::IsNullOrWhiteSpace($managedLogDirectory)) 'Managed startup must return its reaping root and bounded local log directory.'
        $managedListener = Test-GatecraftOmniRouteLoopbackListener -Port $managedPort
        Assert-True ($managedListener.Verified -and $managedListener.Safe -and $managedListener.Addresses -notcontains '0.0.0.0') 'Managed source startup must force and verify an actual loopback-only listener.'
    } finally {
        if ($null -ne $managedProcessId) {
            $managedProcess = Get-Process -Id $managedProcessId -ErrorAction SilentlyContinue
            if ($null -ne $managedProcess) { $managedProcess.Kill($true); $managedProcess.WaitForExit(5000) | Out-Null; $managedProcess.Dispose() }
        }
        if (-not [string]::IsNullOrWhiteSpace($managedLogDirectory) -and [IO.Directory]::Exists($managedLogDirectory)) {
            Remove-Item -LiteralPath $managedLogDirectory -Recurse -Force
        }
    }
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'scripts/dev/run-next.mjs'), 'process.exit(0);')

    if ($IsWindows) {
        $desktopPath = Join-Path $tempRoot 'OmniRoute.exe'
        [IO.File]::Copy((Get-Command pwsh).Source, $desktopPath)
    } elseif ($IsLinux) {
        $desktopPath = Join-Path $tempRoot 'OmniRoute.AppImage'
        [IO.File]::Copy('/bin/true', $desktopPath)
        [IO.File]::SetUnixFileMode($desktopPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
    } else {
        $desktopPath = Join-Path $tempRoot 'OmniRoute.app'
        $macExecutable = Join-Path $desktopPath 'Contents/MacOS/OmniRoute'
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($macExecutable)) | Out-Null
        [IO.File]::Copy('/bin/true', $macExecutable)
        [IO.File]::SetUnixFileMode($macExecutable, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
    }
    $registeredDesktop = Register-GatecraftOmniRouteStartupAdapter -Type desktop-app -Target $desktopPath -UserConfirmed:$true -Path $adapterPath -Confirm:$false
    Assert-Equal $registeredDesktop.Record.type 'desktop-app' 'A directly approved typed desktop adapter must persist.'
    Assert-True ($registeredDesktop.Record.identity -match '^sha256:[A-F0-9]{64}$') 'Desktop adapter must bind the approved executable bytes.'
    $allCandidates = @(Find-GatecraftOmniRouteStartupAdapters -SearchRoots @((Join-Path $tempRoot 'search')) -DesktopPaths @($desktopPath))
    Assert-True (@($allCandidates | Where-Object { $_.Type -ceq 'source-checkout' }).Count -eq 2) 'Unified discovery must include source modes.'
    Assert-True (@($allCandidates | Where-Object { $_.Type -ceq 'desktop-app' }).Count -eq 1) 'Unified discovery must include the platform-compatible desktop app.'
    Assert-Throws { Start-GatecraftOmniRoute -Adapter native-cli -Endpoint 'http://localhost:20128' -StartupAdapterPath $adapterPath -UserConfirmedUnregistered:$false -ReadyTimeoutSeconds 5 -Confirm:$false } 'unregistered-start-direct-confirmation-required' 'An unregistered discovered adapter must require a fresh session confirmation.'

    $sessionWins = Resolve-GatecraftOmniRouteUsePolicy -SessionChoice skip -ProjectPolicy always -GlobalUsePolicy always
    Assert-Equal $sessionWins.Decision 'skip' 'Session choice must have highest precedence.'
    Assert-Equal $sessionWins.Source 'session' 'Session choice source must be explicit.'
    $projectWins = Resolve-GatecraftOmniRouteUsePolicy -ProjectPolicy never -GlobalUsePolicy always
    Assert-Equal $projectWins.Decision 'skip' 'Project policy must override global policy.'
    $projectAsk = Resolve-GatecraftOmniRouteUsePolicy -ProjectPolicy ask -GlobalUsePolicy always
    Assert-Equal $projectAsk.Decision 'ask' 'Project ask must preserve per-session consent.'
    $globalUse = Resolve-GatecraftOmniRouteUsePolicy -ProjectPolicy inherit -GlobalUsePolicy always
    Assert-Equal $globalUse.Decision 'use' 'Inherited global always must enable use.'
    $defaultAsk = Resolve-GatecraftOmniRouteUsePolicy
    Assert-Equal $defaultAsk.Decision 'ask' 'Default policy must ask.'

    Assert-Equal (Resolve-GatecraftOmniRouteInstallDecision -ObservedState missing -InstallPrompt ask).Decision 'ask-install' 'Missing OmniRoute must prompt by default.'
    Assert-Equal (Resolve-GatecraftOmniRouteInstallDecision -ObservedState missing -InstallPrompt never).Decision 'skip' 'Never-install preference must suppress the prompt.'
    Assert-Equal (Resolve-GatecraftOmniRouteInstallDecision -ObservedState ready -InstallPrompt never).Decision 'present' 'Observed readiness must supersede install preferences.'

    Assert-Equal (Resolve-GatecraftOmniRouteObservedState -ProbeState ready -NativeCommandPresent $false -DockerContainerPresent $false) 'ready' 'A valid endpoint is ready even when no CLI is on PATH.'
    Assert-Equal (Resolve-GatecraftOmniRouteObservedState -ProbeState unreachable -NativeCommandPresent $true -DockerContainerPresent $false) 'installed-stopped' 'A discovered native CLI with no endpoint is stopped.'
    Assert-Equal (Resolve-GatecraftOmniRouteObservedState -ProbeState unreachable -NativeCommandPresent $false -DockerContainerPresent $false) 'missing' 'No endpoint or adapter is missing.'
    Assert-Equal (Resolve-GatecraftOmniRouteObservedState -ProbeState unreachable -NativeCommandPresent $false -DockerContainerPresent $false -RegisteredAdapterPresent $true) 'installed-stopped' 'A validated registered adapter must make an unreachable installation startable.'
    Assert-Equal (Resolve-GatecraftOmniRouteObservedState -ProbeState unreachable -NativeCommandPresent $false -DockerContainerPresent $false -DiscoveredAdapterPresent $true) 'installed-stopped' 'A discovered unregistered installation must not be misclassified as missing.'
    Assert-Equal (Resolve-GatecraftOmniRouteObservedState -ProbeState invalid -NativeCommandPresent $true -DockerContainerPresent $false) 'broken' 'An invalid live endpoint is broken.'
    Assert-Equal (Resolve-GatecraftOmniRouteObservedState -ProbeState unreachable -NativeCommandPresent $false -DockerContainerPresent $true -DockerContainerRunning $true) 'broken' 'A running container with no endpoint is broken.'

    $validCatalog = Test-GatecraftOmniRouteEndpoint -Request { param($Uri, $Timeout) [pscustomobject]@{ data = @([pscustomobject]@{ id = 'auto/cheap' }, [pscustomobject]@{ id = 'auto/fast' }) } }
    Assert-Equal $validCatalog.ProbeState 'ready' 'A valid injected model catalog must be ready.'
    Assert-Equal $validCatalog.ModelIds.Count 2 'All model IDs must be returned.'
    $duplicateCatalog = Test-GatecraftOmniRouteEndpoint -Request { param($Uri, $Timeout) [pscustomobject]@{ data = @([pscustomobject]@{ id = 'same' }, [pscustomobject]@{ id = 'same' }) } }
    Assert-Equal $duplicateCatalog.ProbeState 'invalid' 'Duplicate model IDs must invalidate the catalog.'
    $unreachable = Test-GatecraftOmniRouteEndpoint -Request { param($Uri, $Timeout) throw [System.Net.Http.HttpRequestException]::new('offline') }
    Assert-Equal $unreachable.ProbeState 'unreachable' 'Transport failures must remain distinct from invalid catalogs.'

    # Probe-ready branch of Get-GatecraftOmniRouteStatus. Without the -Request seam it
    # is reachable only with a live gateway, so the empty-discovery projection could
    # not be asserted deterministically on a machine that has no OmniRoute at all.
    $readyStatus = Get-GatecraftOmniRouteStatus -Endpoint 'http://127.0.0.1:20128' -Request { param($Uri, $Timeout) [pscustomobject]@{ data = @([pscustomobject]@{ id = 'auto/cheap' }) } }
    Assert-Equal $readyStatus.Probe.ProbeState 'ready' 'An injected ready catalog must make the status probe ready.'
    Assert-Equal $readyStatus.DiscoveredAdapters.Count 0 'A ready gateway must skip discovery and still expose a countable collection.'
    Assert-Equal @($readyStatus.DiscoveredAdapters | ForEach-Object { $_.Type } | Sort-Object -Unique).Count 0 'Projecting adapter types over the empty ready-path collection must not throw.'

    # IPv6-first `localhost` resolution against the IPv4-only loopback bind that
    # managed startup forces.
    $loopbackAttempts = [Collections.Generic.List[string]]::new()
    $loopbackRetry = Test-GatecraftOmniRouteEndpoint -Endpoint 'http://localhost:20128' -Request {
        param($Uri, $Timeout)
        $loopbackAttempts.Add($Uri)
        if ($Uri -clike '*//localhost:*') { throw [System.Net.Http.HttpRequestException]::new('offline') }
        [pscustomobject]@{ data = @([pscustomobject]@{ id = 'auto/cheap' }) }
    }
    Assert-Equal $loopbackRetry.ProbeState 'ready' 'An IPv4-only loopback bind must be reached after the localhost attempt fails.'
    Assert-Equal $loopbackAttempts.Count 2 'A localhost transport failure must trigger exactly one IPv4 retry.'
    Assert-Equal $loopbackAttempts[1] 'http://127.0.0.1:20128/v1/models' 'The retry must target the literal IPv4 loopback.'

    $loopbackExhausted = Test-GatecraftOmniRouteEndpoint -Endpoint 'http://localhost:20128' -Request { param($Uri, $Timeout) throw [System.Net.Http.HttpRequestException]::new('offline') }
    Assert-Equal $loopbackExhausted.ProbeState 'unreachable' 'Exhausting both loopback candidates must still report unreachable.'

    $remoteAttempts = [Collections.Generic.List[string]]::new()
    $null = Test-GatecraftOmniRouteEndpoint -Endpoint 'http://192.168.0.15:20128' -Request {
        param($Uri, $Timeout)
        $remoteAttempts.Add($Uri)
        throw [System.Net.Http.HttpRequestException]::new('offline')
    }
    Assert-Equal $remoteAttempts.Count 1 'A non-localhost endpoint must never get a loopback retry.'

    $invalidCatalogNotRetried = [Collections.Generic.List[string]]::new()
    $null = Test-GatecraftOmniRouteEndpoint -Endpoint 'http://localhost:20128' -Request {
        param($Uri, $Timeout)
        $invalidCatalogNotRetried.Add($Uri)
        [pscustomobject]@{ data = @() }
    }
    Assert-Equal $invalidCatalogNotRetried.Count 1 'A responding endpoint with an unusable catalog is authoritative and must not be retried.'

    # An instance that answers but has nothing usable behind it is a setup gap, not a
    # fault. Keeping these reason codes distinct is what onboarding classifies on.
    $emptyCatalog = Test-GatecraftOmniRouteEndpoint -Request { param($Uri, $Timeout) [pscustomobject]@{ data = @() } }
    Assert-Equal $emptyCatalog.ProbeState 'invalid' 'An empty catalog must not be reported as ready.'
    Assert-Equal $emptyCatalog.ReasonCode 'catalog-empty' 'An empty catalog must stay distinct from a malformed one.'
    $unauthorized = Test-GatecraftOmniRouteEndpoint -Request { param($Uri, $Timeout) throw [System.Net.Http.HttpRequestException]::new('denied', $null, [System.Net.HttpStatusCode]::Unauthorized) }
    Assert-Equal $unauthorized.ReasonCode 'authentication-required' 'HTTP 401 must be distinct from a transport failure.'
    Assert-Equal $unauthorized.HttpStatus 401 'The observed HTTP status must be projected for authentication failures.'
    $malformedCatalog = Test-GatecraftOmniRouteEndpoint -Request { param($Uri, $Timeout) [pscustomobject]@{ nothing = $true } }
    Assert-Equal $malformedCatalog.ReasonCode 'catalog-invalid' 'A shape violation must remain catalog-invalid.'

    Assert-Equal (Get-GatecraftOmniRouteDashboardUrl -Endpoint 'http://localhost:20128') 'http://localhost:20128/dashboard' 'A loopback endpoint must project a dashboard URL.'
    Assert-Equal (Get-GatecraftOmniRouteDashboardUrl -Endpoint 'http://192.168.0.15:20128') $null 'A non-loopback endpoint must never be projected as a clickable dashboard.'

    $safeListener = [pscustomobject]@{ Verified = $true; Safe = $true }
    $unsafeListener = [pscustomobject]@{ Verified = $true; Safe = $false }
    Assert-True (Test-GatecraftOmniRouteInstanceUnconfigured -SecurityWarnings @('default-initial-password') -SetupState unknown -Probe $emptyCatalog -Listener $safeListener) 'Concordant evidence must classify an instance as merely unconfigured.'
    Assert-True (-not (Test-GatecraftOmniRouteInstanceUnconfigured -SecurityWarnings @() -SetupState unknown -Probe $emptyCatalog -Listener $safeListener)) 'Without the default-password signal an empty catalog stays an ordinary failure.'
    Assert-True (-not (Test-GatecraftOmniRouteInstanceUnconfigured -SecurityWarnings @('default-initial-password') -SetupState configured -Probe $emptyCatalog -Listener $safeListener)) 'A checkout marked configured must keep ordinary readiness semantics.'
    Assert-True (-not (Test-GatecraftOmniRouteInstanceUnconfigured -SecurityWarnings @('default-initial-password') -SetupState unknown -Probe $emptyCatalog -Listener $unsafeListener)) 'An unsafe listener must never be offered for attended setup.'
    Assert-True (-not (Test-GatecraftOmniRouteInstanceUnconfigured -SecurityWarnings @('default-initial-password') -SetupState unknown -Probe $malformedCatalog -Listener $safeListener)) 'A malformed catalog is a fault, not a setup gap.'

    function New-OnboardingStatusFixture([string] $State, [string] $Reason, [string[]] $Ids, [bool] $AdapterExists, [bool] $AdapterValid) {
        [pscustomobject]@{
            State = $State
            Endpoint = 'http://localhost:20128'
            Probe = [pscustomobject]@{ ProbeState = 'invalid'; ReasonCode = $Reason; ModelIds = @($Ids) }
            StartupAdapter = [pscustomobject]@{ Exists = $AdapterExists; Valid = $AdapterValid }
        }
    }

    $missingOnboarding = Get-GatecraftOmniRouteOnboarding -Status (New-OnboardingStatusFixture 'missing' 'endpoint-unreachable' @() $false $false)
    Assert-Equal $missingOnboarding.Stage 'not-installed' 'A missing gateway must be projected as not installed.'
    Assert-True ($missingOnboarding.NextActions -contains 'install-omniroute') 'A missing gateway must offer installation.'
    $neverInstall = Get-GatecraftOmniRouteOnboarding -Status (New-OnboardingStatusFixture 'missing' 'endpoint-unreachable' @() $false $false) -InstallPrompt never
    Assert-True ($neverInstall.NextActions -contains 'respect-never-install') 'A never-install preference must not be overridden by onboarding.'

    $stoppedOnboarding = Get-GatecraftOmniRouteOnboarding -Status (New-OnboardingStatusFixture 'installed-stopped' 'endpoint-unreachable' @() $true $true)
    Assert-Equal $stoppedOnboarding.Stage 'installed-not-running' 'A stopped installation must be projected as not running.'
    Assert-Equal $stoppedOnboarding.AdapterAuthority 'valid' 'A matching startup adapter must project standing authority.'

    $unconfiguredOnboarding = Get-GatecraftOmniRouteOnboarding -Status (New-OnboardingStatusFixture 'broken' 'catalog-empty' @() $false $false) -SecurityWarnings @('default-initial-password')
    Assert-Equal $unconfiguredOnboarding.Stage 'running-unconfigured' 'A responding empty instance must be projected as needing attended setup, not as broken.'
    Assert-True ($unconfiguredOnboarding.NextActions -contains 'connect-provider' -and $unconfiguredOnboarding.NextActions -contains 'create-api-key') 'Unconfigured onboarding must name the provider and key steps.'
    Assert-True ($unconfiguredOnboarding.NextActions -contains 'change-initial-password') 'A default initial password must be surfaced as an action.'
    Assert-Equal $unconfiguredOnboarding.ConfigurationOwner 'user' 'Onboarding must record that configuration stays the user'"'"'s.'

    $brokenOnboarding = Get-GatecraftOmniRouteOnboarding -Status (New-OnboardingStatusFixture 'broken' 'catalog-invalid' @() $false $false) -SecurityWarnings @('default-initial-password')
    Assert-Equal $brokenOnboarding.Stage 'broken' 'A malformed catalog must stay broken even with a default password warning.'

    $usableOnboarding = Get-GatecraftOmniRouteOnboarding -Status (New-OnboardingStatusFixture 'ready' 'catalog-valid' @('auto/cheap') $false $false)
    Assert-Equal $usableOnboarding.Stage 'usable' 'A ready gateway with models must be projected as usable.'
    Assert-Equal @($usableOnboarding.NextActions).Count 1 'A usable gateway must project exactly the none sentinel.'
    Assert-Equal $usableOnboarding.NextActions[0] 'none' 'A usable gateway must project the none sentinel.'

    $staleAdapterOnboarding = Get-GatecraftOmniRouteOnboarding -Status (New-OnboardingStatusFixture 'ready' 'catalog-valid' @('auto/cheap') $true $false)
    Assert-Equal $staleAdapterOnboarding.AdapterAuthority 'stale' 'A stored adapter whose identity drifted must be reported as stale.'
    Assert-True ($staleAdapterOnboarding.NextActions -contains 're-register-adapter') 'A stale adapter must ask for re-registration.'
    Assert-True (-not ($staleAdapterOnboarding.NextActions -contains 'none')) 'The none sentinel must never coexist with a real action.'

    $installPlan = New-GatecraftOmniRouteInstallPlan -Version '3.8.49'
    Assert-Equal $installPlan.DisplayCommand 'npm install --global omniroute@3.8.49 --include=optional' 'Install plan must pin and display the exact package version.'
    Assert-True ($installPlan.Source -ceq 'https://www.npmjs.com/package/omniroute') 'Install plan must name the official npm source.'
    if ($IsWindows) { Assert-True ($installPlan.Executable -cmatch '(?i)npm\.cmd$' -and $installPlan.Executable -cnotmatch '(?i)\.ps1$') 'Windows installation must use npm.cmd and never hand npm.ps1 to process launch or file association.' }
    Assert-Throws { Install-GatecraftOmniRoute -Version '3.8.49' -UserConfirmed:$false -Confirm:$false } 'direct-confirmation-required' 'Installation must require direct confirmation.'
    Assert-Throws { New-GatecraftOmniRouteInstallPlan -Version 'latest;whoami' } 'version-invalid' 'Install plan must reject command-shaped versions.'

    $installProbeRoot = Join-Path $tempRoot 'install-probe'
    [IO.Directory]::CreateDirectory($installProbeRoot) | Out-Null
    $absentPostinstall = Invoke-GatecraftOmniRoutePostinstall -PackageRoot $installProbeRoot -Confirm:$false
    Assert-True (-not $absentPostinstall.Ran) 'A package without a postinstall runner must report that it did not run.'
    Assert-Equal $absentPostinstall.ReasonCode 'postinstall-runner-absent' 'A missing postinstall runner must be a named reason, not a failure.'
    [IO.Directory]::CreateDirectory((Join-Path $installProbeRoot 'scripts/build')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $installProbeRoot 'scripts/build/postinstall.mjs'), "process.exit(0)`n")
    $declinedPostinstall = Invoke-GatecraftOmniRoutePostinstall -PackageRoot $installProbeRoot -WhatIf 6>$null
    Assert-True (-not $declinedPostinstall.Ran) 'Postinstall must not run when the caller declines it.'
    Assert-Equal $declinedPostinstall.ReasonCode 'postinstall-declined' 'A declined postinstall must be distinguishable from an absent one.'
    $ranPostinstall = Invoke-GatecraftOmniRoutePostinstall -PackageRoot $installProbeRoot -Confirm:$false
    Assert-True ($ranPostinstall.Ran -and $ranPostinstall.ExitCode -eq 0) 'An explicitly confirmed postinstall must run and report its real exit code.'
    Assert-Equal $ranPostinstall.ReasonCode 'postinstall-complete' 'A zero-exit postinstall must be reported as complete.'
    [IO.File]::WriteAllText((Join-Path $installProbeRoot 'scripts/build/postinstall.mjs'), "process.exit(3)`n")
    $failedPostinstall = Invoke-GatecraftOmniRoutePostinstall -PackageRoot $installProbeRoot -Confirm:$false
    Assert-Equal $failedPostinstall.ExitCode 3 'A failing postinstall must surface its real exit code.'
    Assert-Equal $failedPostinstall.ReasonCode 'postinstall-failed' 'A nonzero postinstall must not be reported as complete.'
    Assert-Throws { Invoke-GatecraftOmniRoutePostinstall -PackageRoot (Join-Path $tempRoot 'no-such-install') -Confirm:$false } 'install-root-missing' 'Postinstall must refuse a package root that does not exist.'

    $unhealthy = Test-GatecraftOmniRouteInstallHealth -PackageRoot $installProbeRoot -NativeModules @('better-sqlite3')
    Assert-True (-not $unhealthy.Healthy) 'A package root whose native modules cannot be required must never be reported healthy.'
    Assert-True (@($unhealthy.Checks | Where-Object { $_.Check -ceq 'native-module' -and -not $_.Passed }).Count -gt 0) 'Health must record the specific native module that failed to load.'
    Assert-Throws { Test-GatecraftOmniRouteInstallHealth -PackageRoot $installProbeRoot -NativeModules @("x'); process.exit(0); ('") } 'health-module-invalid' 'Health checks must reject command-shaped module names instead of interpolating them into node -e.'
    Assert-Throws { Test-GatecraftOmniRouteInstallHealth -PackageRoot (Join-Path $tempRoot 'no-such-install') } 'install-root-missing' 'Health checks must refuse a package root that does not exist.'
    Assert-Throws { Get-GatecraftOmniRouteInstallRoot -NpmPath 'C:\shim\npm.ps1' } 'npm-unavailable' 'Install-root resolution must never hand a .ps1 wrapper to process launch.'

    $entryPointPath = (Resolve-Path (Join-Path $PSScriptRoot '../scripts/omniroute-session.ps1')).Path
    $escapedEntryPoint = $entryPointPath.Replace("'", "''")
    $escapedPwsh = (Get-Command pwsh).Source.Replace("'", "''")
    $statusProbe = & $moduleInfo ([scriptblock]::Create("Invoke-GatecraftOmniRouteProcess -FilePath '$escapedPwsh' -Arguments @('-NoLogo', '-NoProfile', '-File', '$escapedEntryPoint', 'status') -TimeoutMilliseconds 30000"))
    Assert-True (-not $statusProbe.TimedOut) 'GC-0.2 status discovery must complete within its bound.'
    Assert-Equal $statusProbe.ExitCode 0 'GC-0.2 status must project an observed state even when discovery returns no startup adapter.'
    $statusProjection = $statusProbe.Stdout | ConvertFrom-Json
    Assert-True ($statusProjection.state -cin @('missing', 'installed-stopped', 'ready', 'broken')) 'Status must project one of the four observed states, never an empty state.'
    Assert-True ($statusProjection.adapter -cin @('none', 'native-cli', 'docker-existing', 'source-checkout', 'desktop-application', 'user-systemd-service')) 'Status must project a resolved adapter token, never an empty adapter.'
    Assert-True ($statusProjection.discovered_adapter_types -is [array]) 'Discovered adapter types must project as an array even when discovery is empty.'
    Assert-True ($statusProjection.discovered_adapter_count -ge 0) 'Discovered adapter count must project as a number even when discovery is empty.'
} finally {
    if ([IO.Directory]::Exists($tempRoot)) {
        $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
        $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing cleanup outside the system temp directory.' }
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}

Write-Host 'OmniRoute gate passed: preferences, precedence, discovery states, typed startup registry, endpoint validation, project scope, pinned consent, loopback retry, and guided onboarding stages.'
