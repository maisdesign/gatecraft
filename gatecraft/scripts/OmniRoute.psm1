Set-StrictMode -Version Latest

$script:DefaultEndpoint = 'http://localhost:20128'
$script:PreferenceProtocol = 'gatecraft-omniroute-preferences/v1'
$script:StartupAdapterProtocol = 'gatecraft-omniroute-startup-adapter/v1'
$script:RuntimeProtocol = 'gatecraft-omniroute-runtime/v2'
$script:ModulePath = $PSCommandPath

function New-GatecraftOmniRouteResult {
    param([Parameter(Mandatory)][hashtable] $Values)
    return [pscustomobject]$Values
}

function Get-GatecraftOmniRouteRuntimeIdentity {
    [CmdletBinding()]
    param()
    $entryPoint = Join-Path $PSScriptRoot 'omniroute-session.ps1'
    $processHost = Join-Path $PSScriptRoot 'omniroute-process-host.ps1'
    return New-GatecraftOmniRouteResult @{
        Protocol = $script:RuntimeProtocol
        ModuleSha256 = (Get-FileHash -LiteralPath $script:ModulePath -Algorithm SHA256).Hash
        EntryPointSha256 = if ([IO.File]::Exists($entryPoint)) { (Get-FileHash -LiteralPath $entryPoint -Algorithm SHA256).Hash } else { $null }
        ProcessHostSha256 = if ([IO.File]::Exists($processHost)) { (Get-FileHash -LiteralPath $processHost -Algorithm SHA256).Hash } else { $null }
    }
}

function Invoke-GatecraftOmniRouteProcess {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $Arguments,
        [string] $WorkingDirectory,
        [ValidateRange(100, 600000)][int] $TimeoutMilliseconds = 5000
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $startInfo.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory) }
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'process-start-failed' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try {
                $process.Kill($true)
                if (-not $process.WaitForExit(2000) -or -not $process.HasExited) { throw 'tree-still-live' }
            } catch { throw 'omniroute-process-reap-failed' }
            try { $process.StandardOutput.Close(); $process.StandardError.Close() } catch { }
            return New-GatecraftOmniRouteResult @{ ExitCode = $null; TimedOut = $true; Stdout = ''; Stderr = '' }
        }
        if (-not [Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 1000)) {
            try { $process.StandardOutput.Close(); $process.StandardError.Close() } catch { }
            return New-GatecraftOmniRouteResult @{ ExitCode = $process.ExitCode; TimedOut = $true; Stdout = ''; Stderr = '' }
        }
        return New-GatecraftOmniRouteResult @{
            ExitCode = $process.ExitCode
            TimedOut = $false
            Stdout = $stdoutTask.GetAwaiter().GetResult()
            Stderr = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $process.Dispose()
    }
}

function Get-GatecraftOmniRouteProcessSnapshot {
    try {
        $parents = @{}
        if ($IsWindows) {
            $getCimInstance = Get-Command Get-CimInstance -ErrorAction SilentlyContinue
            if ($null -eq $getCimInstance) { return New-GatecraftOmniRouteResult @{ Valid = $false; Processes = @() } }
            foreach ($entry in @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId -ErrorAction Stop)) {
                $parents[[int]$entry.ProcessId] = [int]$entry.ParentProcessId
            }
        } else {
            $ps = Get-Command ps -ErrorAction SilentlyContinue
            if ($null -eq $ps) { return New-GatecraftOmniRouteResult @{ Valid = $false; Processes = @() } }
            $listing = Invoke-GatecraftOmniRouteProcess -FilePath $ps.Source -Arguments @('-axo', 'pid=,ppid=') -TimeoutMilliseconds 3000
            if ($listing.TimedOut -or $listing.ExitCode -ne 0) { return New-GatecraftOmniRouteResult @{ Valid = $false; Processes = @() } }
            foreach ($line in @($listing.Stdout -split "`r?`n")) {
                if ($line -match '^\s*(?<pid>\d+)\s+(?<ppid>\d+)\s*$') {
                    $parents[[int]$Matches['pid']] = [int]$Matches['ppid']
                }
            }
        }
        $processes = foreach ($entry in $parents.GetEnumerator()) {
            [pscustomobject]@{ Id = [int]$entry.Key; ParentId = [int]$entry.Value }
        }
        return New-GatecraftOmniRouteResult @{ Valid = $true; Processes = @($processes) }
    } catch {
        return New-GatecraftOmniRouteResult @{ Valid = $false; Processes = @() }
    }
}

function Update-GatecraftOmniRouteObservedDescendants {
    param(
        [Parameter(Mandatory)][int] $RootId,
        [Parameter(Mandatory)][Collections.Generic.Dictionary[int, long]] $Observed
    )

    $snapshot = Get-GatecraftOmniRouteProcessSnapshot
    if (-not $snapshot.Valid) { return $false }
    $pending = [Collections.Generic.Queue[int]]::new()
    $pending.Enqueue($RootId)
    $descendantIds = [Collections.Generic.HashSet[int]]::new()
    while ($pending.Count -gt 0) {
        $parentId = $pending.Dequeue()
        foreach ($child in @($snapshot.Processes | Where-Object { $_.ParentId -eq $parentId })) {
            if ($child.Id -eq $PID -or -not $descendantIds.Add($child.Id)) { continue }
            $pending.Enqueue($child.Id)
        }
    }
    foreach ($descendantId in $descendantIds) {
        try {
            $process = Get-Process -Id $descendantId -ErrorAction Stop
            $Observed[$descendantId] = $process.StartTime.ToUniversalTime().Ticks
        } catch {
            if ($_.FullyQualifiedErrorId -notmatch 'NoProcessFoundForGivenId') { return $false }
        }
    }
    return $true
}

function Stop-GatecraftOmniRouteTrackedTree {
    param(
        [Parameter(Mandatory)][Diagnostics.Process] $RootProcess,
        [Parameter(Mandatory)][Collections.Generic.Dictionary[int, long]] $Observed,
        [Parameter(Mandatory)][bool] $ObservationComplete
    )

    if ($RootProcess.Id -eq $PID) { throw 'omniroute-reap-refused-current-process' }
    if (-not $RootProcess.HasExited) {
        try {
            $RootProcess.Kill($true)
            if (-not $RootProcess.WaitForExit(5000) -or -not $RootProcess.HasExited) { throw 'tree-still-live' }
        } catch { throw 'omniroute-reap-failed' }
    }
    foreach ($entry in @($Observed.GetEnumerator())) {
        if ($entry.Key -eq $PID) { throw 'omniroute-reap-refused-current-process' }
        try {
            $child = Get-Process -Id $entry.Key -ErrorAction Stop
        } catch {
            if ($_.FullyQualifiedErrorId -match 'NoProcessFoundForGivenId') { continue }
            throw 'omniroute-reap-unverifiable'
        }
        try {
            if ($child.StartTime.ToUniversalTime().Ticks -ne $entry.Value) { continue }
            $child.Kill($true)
            if (-not $child.WaitForExit(5000) -or -not $child.HasExited) { throw 'tree-still-live' }
        } catch { throw 'omniroute-reap-failed' }
        finally { $child.Dispose() }
    }
    if (-not $ObservationComplete) { throw 'omniroute-reap-unverifiable' }
}

function Start-GatecraftOmniRouteSourceProcessHost {
    param(
        [Parameter(Mandatory)][ValidateSet('source-start', 'source-build')][string] $Purpose,
        [Parameter(Mandatory)][string] $NodePath,
        [Parameter(Mandatory)][string] $RunnerPath,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [ValidateSet('start', 'dev')][string] $Mode = 'dev',
        [ValidateRange(1, 65535)][int] $Port = 20128
    )

    $pwsh = Get-Command pwsh -All -CommandType Application -ErrorAction SilentlyContinue | Where-Object { $_.Source -is [string] -and [IO.File]::Exists($_.Source) } | Sort-Object Source -Unique | Select-Object -First 1
    if ($null -eq $pwsh) { throw 'omniroute-process-host-pwsh-unavailable' }
    $hostScript = Join-Path $PSScriptRoot 'omniroute-process-host.ps1'
    if (-not [IO.File]::Exists($hostScript)) { throw 'omniroute-process-host-missing' }
    $logDirectory = Join-Path ([IO.Path]::GetTempPath()) ('gatecraft-omniroute-process-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($logDirectory) | Out-Null
    try {
        if ($IsWindows) {
            $acl = Get-Acl -LiteralPath $logDirectory
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($existingRule in @($acl.Access)) { [void]$acl.RemoveAccessRuleAll($existingRule) }
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit', [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
            $acl.SetAccessRule($rule)
            Set-Acl -LiteralPath $logDirectory -AclObject $acl
        } else {
            [IO.File]::SetUnixFileMode($logDirectory, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        }
    } catch {
        Remove-Item -LiteralPath $logDirectory -Recurse -Force -ErrorAction SilentlyContinue
        throw 'omniroute-process-log-permissions-failed'
    }
    $resultPath = Join-Path $logDirectory 'result.json'
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwsh.Source
    $startInfo.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    foreach ($argument in @(
        '-NoLogo', '-NoProfile', '-File', $hostScript,
        '-Purpose', $Purpose,
        '-NodePath', [IO.Path]::GetFullPath($NodePath),
        '-RunnerPath', [IO.Path]::GetFullPath($RunnerPath),
        '-WorkingDirectory', [IO.Path]::GetFullPath($WorkingDirectory),
        '-ExpectedNodeSha256', (Get-FileHash -LiteralPath $NodePath -Algorithm SHA256).Hash,
        '-ExpectedRunnerSha256', (Get-FileHash -LiteralPath $RunnerPath -Algorithm SHA256).Hash,
        '-LogDirectory', $logDirectory,
        '-ResultPath', $resultPath,
        '-Mode', $Mode,
        '-Port', [string]$Port,
        '-MaxFileBytes', '65536'
    )) { $startInfo.ArgumentList.Add([string]$argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'start-returned-false' }
    } catch {
        $process.Dispose()
        Remove-Item -LiteralPath $logDirectory -Recurse -Force -ErrorAction SilentlyContinue
        throw 'omniroute-process-host-launch-failed'
    }
    return New-GatecraftOmniRouteResult @{ Process = $process; LogDirectory = $logDirectory; ResultPath = $resultPath }
}

function Get-GatecraftOmniRouteProcessDiagnostic {
    param(
        [Parameter(Mandatory)][string] $LogDirectory,
        [Parameter(Mandatory)][string] $ResultPath,
        [Parameter(Mandatory)][string] $FallbackReasonCode
    )

    $result = $null
    try {
        if ([IO.File]::Exists($ResultPath)) {
            $candidate = [IO.File]::ReadAllText($ResultPath) | ConvertFrom-Json -Depth 5 -ErrorAction Stop
            if ($candidate.protocol -ceq 'gatecraft-omniroute-process-result/v1') { $result = $candidate }
        }
    } catch { $result = $null }
    $chunks = [Collections.Generic.List[string]]::new()
    foreach ($name in @('stderr.log.previous', 'stderr.log', 'stdout.log.previous', 'stdout.log')) {
        $path = Join-Path $LogDirectory $name
        if ([IO.File]::Exists($path)) {
            try { $chunks.Add([IO.File]::ReadAllText($path)) } catch { }
        }
    }
    $raw = $chunks -join "`n"
    $diagnosticCode = if ($raw -match '(?i)Could not find a production build|production build.+\.build[/\\]next|no production build') {
        'production-build-missing'
    } elseif ($raw -match '(?i)INITIAL_PASSWORD.+CHANGEME') {
        'default-password-warning'
    } elseif ($null -ne $result -and $result.reason_code -ceq 'process-host-failed') {
        'process-host-failed'
    } else { 'process-output-unclassified' }
    $sanitized = $raw
    $sanitized = [regex]::Replace($sanitized, '(?im)^.*INITIAL_PASSWORD.*$', 'INITIAL_PASSWORD=[REDACTED]')
    $sanitized = [regex]::Replace($sanitized, '(?i)\b(Bearer)\s+[A-Za-z0-9._~+/-]+=*', '$1 [REDACTED]')
    $sanitized = [regex]::Replace($sanitized, '(?i)\b(api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password)\s*[:=]\s*([^\s,;]+)', '$1=[REDACTED]')
    $sanitized = [regex]::Replace($sanitized, '(?i)[A-Z]:\\Users\\[^\\\s]+', '%USERPROFILE%')
    $lines = @($sanitized -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 20 | ForEach-Object { if ($_.Length -gt 300) { $_.Substring(0, 300) + '…' } else { $_ } })
    $total = 0
    $boundedLines = [Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if ($total + $line.Length -gt 4000) { break }
        $boundedLines.Add($line)
        $total += $line.Length
    }
    return New-GatecraftOmniRouteResult @{
        ReasonCode = $FallbackReasonCode
        DiagnosticCode = $diagnosticCode
        ExitCode = if ($null -ne $result) { $result.exit_code } else { $null }
        OutputTail = @($boundedLines)
        RawLogDirectory = $LogDirectory
    }
}

function Test-GatecraftOmniRouteLoopbackListener {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int] $Port,
        [AllowEmptyCollection()][string[]] $ObservedAddresses
    )

    $addresses = @()
    try {
        if ($PSBoundParameters.ContainsKey('ObservedAddresses')) {
            $addresses = @($ObservedAddresses)
        } elseif ($IsWindows) {
            $command = Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue
            if ($null -eq $command) { return New-GatecraftOmniRouteResult @{ Verified = $false; Safe = $false; Addresses = @(); ReasonCode = 'listener-inspection-unavailable' } }
            $addresses = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop | Select-Object -ExpandProperty LocalAddress -Unique)
        } else {
            $ss = Get-Command ss -ErrorAction SilentlyContinue
            if ($null -ne $ss) {
                $listing = Invoke-GatecraftOmniRouteProcess -FilePath $ss.Source -Arguments @('-ltn') -TimeoutMilliseconds 3000
                if ($listing.TimedOut -or $listing.ExitCode -ne 0) { throw 'listener-inspection-failed' }
                foreach ($line in @($listing.Stdout -split "`r?`n")) {
                    if ($line -match "(?<address>\[[^\]]+\]|[^\s:]+):$Port\s") { $addresses += $Matches['address'].Trim('[', ']') }
                }
            } else {
                $lsof = Get-Command lsof -ErrorAction SilentlyContinue
                if ($null -eq $lsof) { return New-GatecraftOmniRouteResult @{ Verified = $false; Safe = $false; Addresses = @(); ReasonCode = 'listener-inspection-unavailable' } }
                $listing = Invoke-GatecraftOmniRouteProcess -FilePath $lsof.Source -Arguments @('-nP', "-iTCP:$Port", '-sTCP:LISTEN') -TimeoutMilliseconds 3000
                if ($listing.TimedOut -or $listing.ExitCode -ne 0) { throw 'listener-inspection-failed' }
                foreach ($line in @($listing.Stdout -split "`r?`n")) {
                    if ($line -match 'TCP\s+(?<address>\[[^\]]+\]|[^:]+):\d+\s+\(LISTEN\)') { $addresses += $Matches['address'].Trim('[', ']') }
                }
            }
        }
        $addresses = @($addresses | Sort-Object -Unique)
        if ($addresses.Count -eq 0) { return New-GatecraftOmniRouteResult @{ Verified = $false; Safe = $false; Addresses = @(); ReasonCode = 'listener-not-found' } }
        $safe = $true
        foreach ($address in $addresses) {
            $parsed = $null
            if (-not [Net.IPAddress]::TryParse($address, [ref]$parsed) -or -not [Net.IPAddress]::IsLoopback($parsed)) { $safe = $false; break }
        }
        return New-GatecraftOmniRouteResult @{ Verified = $true; Safe = $safe; Addresses = $addresses; ReasonCode = if ($safe) { 'loopback-verified' } else { 'non-loopback-listener' } }
    } catch {
        return New-GatecraftOmniRouteResult @{ Verified = $false; Safe = $false; Addresses = @(); ReasonCode = 'listener-inspection-failed' }
    }
}

function Test-GatecraftOmniRouteEndpointUri {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Endpoint)

    $uri = $null
    if (-not [uri]::TryCreate($Endpoint, [UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -cnotin @('http', 'https')) { return $false }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo) -or -not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment)) { return $false }
    if ($uri.AbsolutePath -cnotin @('', '/')) { return $false }
    return -not [string]::IsNullOrWhiteSpace($uri.Host)
}

function Get-GatecraftOmniRouteNativeCommand {
    if ($IsWindows) {
        foreach ($name in @('omniroute.exe', 'omniroute.cmd')) {
            $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
            if ($null -ne $command) { return $command }
        }
        return $null
    }
    return Get-Command omniroute -CommandType Application -ErrorAction SilentlyContinue
}

function Get-GatecraftOmniRouteGlobalPreferencePath {
    [CmdletBinding()]
    param()

    if ($IsWindows -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return Join-Path $env:LOCALAPPDATA 'Gatecraft/preferences.json'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:XDG_CONFIG_HOME)) {
        return Join-Path $env:XDG_CONFIG_HOME 'gatecraft/preferences.json'
    }
    $userHome = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($userHome)) { throw 'omniroute-user-config-root-unavailable' }
    return Join-Path $userHome '.config/gatecraft/preferences.json'
}

function Get-GatecraftOmniRouteStartupAdapterPath {
    [CmdletBinding()]
    param([string] $PreferencePath = (Get-GatecraftOmniRouteGlobalPreferencePath))
    return Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($PreferencePath))) 'omniroute-startup.json'
}

function Test-GatecraftOmniRouteSourceCheckout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [ValidateSet('start', 'dev')][string] $Mode = 'start'
    )

    try {
        $root = [IO.Path]::GetFullPath($Path)
        $packagePath = Join-Path $root 'package.json'
        if (-not [IO.Directory]::Exists($root) -or -not [IO.File]::Exists($packagePath)) { return $false }
        $package = [IO.File]::ReadAllText($packagePath) | ConvertFrom-Json -Depth 10 -ErrorAction Stop
        if ($package.name -isnot [string] -or $package.name -cne 'omniroute') { return $false }
        if ($null -eq $package.scripts -or $null -eq $package.scripts.PSObject.Properties[$Mode] -or $package.scripts.PSObject.Properties[$Mode].Value -isnot [string]) { return $false }
        $git = Get-Command git -ErrorAction SilentlyContinue
        if ($null -eq $git) { return $false }
        $remote = & $git.Source -C $root remote get-url origin 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        return ([string]$remote).Trim() -cmatch '^https://github\.com/diegosouzapw/OmniRoute(?:\.git)?$'
    } catch { return $false }
}

function Get-GatecraftOmniRouteSourcePreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Target,
        [Parameter(Mandatory)][ValidateSet('start', 'dev')][string] $Mode
    )

    if (-not (Test-GatecraftOmniRouteSourceCheckout -Path $Target -Mode $Mode)) {
        return New-GatecraftOmniRouteResult @{ Decision = 'block'; ReasonCode = 'source-checkout-invalid'; RecommendedMode = $null; AvailableActions = @('use-direct-profiles'); BuildReady = $false; SecurityWarnings = @(); SetupState = 'unknown' }
    }
    $root = [IO.Path]::GetFullPath($Target)
    $initialPassword = $env:INITIAL_PASSWORD
    # OMNIROUTE_BOOTSTRAPPED e' l'unico marcatore che dice se l'istanza ha completato
    # la configurazione iniziale. Serve a distinguere "installato ma mai configurato"
    # da "configurato e rotto": senza di esso il warning sulla password di default,
    # da solo, non basta a classificare nulla.
    $bootstrapped = $env:OMNIROUTE_BOOTSTRAPPED
    if ([string]::IsNullOrWhiteSpace($initialPassword) -or [string]::IsNullOrWhiteSpace($bootstrapped)) {
        $envPath = Join-Path $root '.env'
        if ([IO.File]::Exists($envPath)) {
            try {
                # ReadAllLines, non ReadLines: quest'ultima e' lazy, e uscire
                # dall'enumerazione con un break lascia lo StreamReader non disposto,
                # tenendo il file bloccato fino alla garbage collection. Un .env e'
                # piccolo, quindi leggerlo tutto non costa nulla e non lascia handle.
                foreach ($line in [IO.File]::ReadAllLines($envPath)) {
                    if ([string]::IsNullOrWhiteSpace($initialPassword) -and $line -cmatch '^\s*INITIAL_PASSWORD\s*=') { $initialPassword = ($line -split '=', 2)[1].Trim().Trim('"', "'") }
                    if ([string]::IsNullOrWhiteSpace($bootstrapped) -and $line -cmatch '^\s*OMNIROUTE_BOOTSTRAPPED\s*=') { $bootstrapped = ($line -split '=', 2)[1].Trim().Trim('"', "'") }
                }
            } catch { $initialPassword = $null; $bootstrapped = $null }
        }
    }
    $securityWarnings = if ([string]::IsNullOrWhiteSpace($initialPassword) -or $initialPassword -ceq 'CHANGEME') { @('default-initial-password') } else { @() }
    # Solo un 'true' esplicito conta come configurato: l'assenza del marcatore resta
    # 'unknown' e non autorizza a dare per configurata un'istanza.
    $setupState = if ($bootstrapped -ceq 'true') { 'configured' } elseif ($bootstrapped -ceq 'false') { 'unconfigured' } else { 'unknown' }
    $buildMarker = Join-Path $root '.build/next/BUILD_ID'
    $buildReady = $false
    if ([IO.File]::Exists($buildMarker)) {
        try { $buildReady = -not [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($buildMarker)) } catch { $buildReady = $false }
    }
    if ($Mode -ceq 'start' -and -not $buildReady) {
        return New-GatecraftOmniRouteResult @{
            Decision = 'needs-action'
            ReasonCode = 'production-build-missing'
            RecommendedMode = 'dev'
            AvailableActions = @('use-dev', 'build-with-confirmation', 'use-direct-profiles')
            BuildReady = $false
            SecurityWarnings = $securityWarnings
            SetupState = $setupState
        }
    }
    return New-GatecraftOmniRouteResult @{
        Decision = 'ready'
        ReasonCode = if ($Mode -ceq 'dev' -and -not $buildReady) { 'development-no-production-build-required' } else { 'preflight-ready' }
        RecommendedMode = if ($Mode -ceq 'dev' -and -not $buildReady) { 'dev' } else { $Mode }
        AvailableActions = @('start')
        BuildReady = $buildReady
        SecurityWarnings = $securityWarnings
        SetupState = $setupState
    }
}

function Find-GatecraftOmniRouteSourceCheckouts {
    [CmdletBinding()]
    param(
        [string[]] $SearchRoots,
        [ValidateRange(1, 6)][int] $MaxDepth = 4,
        [ValidateRange(10, 10000)][int] $MaxDirectories = 2500
    )

    if ($null -eq $SearchRoots -or $SearchRoots.Count -eq 0) {
        $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        $SearchRoots = @('Documents', 'Downloads', 'source', 'src', 'repos') | ForEach-Object { Join-Path $userProfile $_ } | Where-Object { [IO.Directory]::Exists($_) }
    }
    $queue = [Collections.Generic.Queue[object]]::new()
    foreach ($root in $SearchRoots) {
        if ([IO.Directory]::Exists($root)) { $queue.Enqueue([pscustomobject]@{ Path = [IO.Path]::GetFullPath($root); Depth = 0 }) }
    }
    $visited = 0
    $results = [Collections.Generic.List[object]]::new()
    $skipNames = @('.git', '.next', 'node_modules', 'dist', 'build', 'coverage')
    while ($queue.Count -gt 0 -and $visited -lt $MaxDirectories) {
        $item = $queue.Dequeue()
        $visited++
        $packagePath = Join-Path $item.Path 'package.json'
        if ([IO.File]::Exists($packagePath)) {
            foreach ($mode in @('start', 'dev')) {
                if (Test-GatecraftOmniRouteSourceCheckout -Path $item.Path -Mode $mode) {
                    $binding = Get-GatecraftOmniRouteStartupAdapterIdentity -Type source-checkout -Target $item.Path -Mode $mode
                    $preflight = Get-GatecraftOmniRouteSourcePreflight -Target $item.Path -Mode $mode
                    $results.Add((New-GatecraftOmniRouteResult @{ Type = 'source-checkout'; Target = $item.Path; Mode = $mode; PersistentEligible = ($null -ne $binding); RequiresDirectConfirmation = $true; Startability = $preflight.Decision; ReasonCode = $preflight.ReasonCode; Recommended = ($preflight.RecommendedMode -ceq $mode); SecurityWarnings = $preflight.SecurityWarnings }))
                }
            }
        }
        if ($item.Depth -ge $MaxDepth) { continue }
        try {
            foreach ($directory in [IO.Directory]::EnumerateDirectories($item.Path)) {
                if ([IO.Path]::GetFileName($directory) -notin $skipNames) {
                    $queue.Enqueue([pscustomobject]@{ Path = $directory; Depth = $item.Depth + 1 })
                }
            }
        } catch { continue }
    }
    return @($results | Sort-Object Target, Mode -Unique)
}

function Get-GatecraftOmniRouteSha256 {
    param([Parameter(Mandatory)][string] $Value)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Get-GatecraftOmniRouteDesktopExecutable {
    param([Parameter(Mandatory)][string] $Target)
    $fullTarget = [IO.Path]::GetFullPath($Target)
    $leaf = [IO.Path]::GetFileName($fullTarget)
    if ($IsMacOS -and [IO.Directory]::Exists($fullTarget) -and $leaf -cmatch '(?i)^OmniRoute[^\\/]*\.app$') {
        $macDirectory = Join-Path $fullTarget 'Contents/MacOS'
        if (-not [IO.Directory]::Exists($macDirectory)) { return $null }
        $macExecutable = [IO.Directory]::EnumerateFiles($macDirectory) | Where-Object { [IO.Path]::GetFileName($_) -cmatch '(?i)^OmniRoute' } | Select-Object -First 1
        if ($null -eq $macExecutable) { return $null }
        $fullTarget = $macExecutable
        $leaf = [IO.Path]::GetFileName($fullTarget)
    }
    if (-not [IO.File]::Exists($fullTarget)) { return $null }
    $header = [byte[]]::new(4)
    $stream = [IO.File]::Open($fullTarget, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Read($header, 0, $header.Length) -ne $header.Length) { return $null }
        if ($IsWindows -and $leaf -cmatch '(?i)^OmniRoute[^\\/]*\.exe$') {
            $stream.Position = 0
            $peReader = [Reflection.PortableExecutable.PEReader]::new($stream, [Reflection.PortableExecutable.PEStreamOptions]::LeaveOpen)
            try { if ($null -ne $peReader.PEHeaders.PEHeader) { return $fullTarget } }
            finally { $peReader.Dispose() }
        }
    } catch { return $null }
    finally { $stream.Dispose() }
    if ($IsLinux -and $leaf -cmatch '(?i)^OmniRoute[^\\/]*\.AppImage$' -and $header[0] -eq 0x7F -and $header[1] -eq 0x45 -and $header[2] -eq 0x4C -and $header[3] -eq 0x46) {
        if ([IO.FileInfo]::new($fullTarget).Length -lt 4096) { return $null }
        $mode = [IO.File]::GetUnixFileMode($fullTarget)
        if (($mode -band ([IO.UnixFileMode]::UserExecute -bor [IO.UnixFileMode]::GroupExecute -bor [IO.UnixFileMode]::OtherExecute)) -ne 0) { return $fullTarget }
    }
    if ($IsMacOS -and $header.Length -eq 4) {
        $magic = [Convert]::ToHexString($header)
        if ($magic -cin @('FEEDFACE', 'FEEDFACF', 'CEFAEDFE', 'CFFAEDFE', 'CAFEBABE', 'BEBAFECA')) {
            $mode = [IO.File]::GetUnixFileMode($fullTarget)
            if (($mode -band ([IO.UnixFileMode]::UserExecute -bor [IO.UnixFileMode]::GroupExecute -bor [IO.UnixFileMode]::OtherExecute)) -ne 0) { return $fullTarget }
        }
    }
    return $null
}

function Get-GatecraftOmniRouteStartupAdapterIdentity {
    param(
        [Parameter(Mandatory)][ValidateSet('native-cli', 'docker-existing', 'source-checkout', 'desktop-app', 'systemd-user')][string] $Type,
        [string] $Target,
        [ValidateSet('default', 'start', 'dev')][string] $Mode = 'default'
    )

    try {
        switch ($Type) {
            'native-cli' {
                $native = Get-GatecraftOmniRouteNativeCommand
                if ($null -eq $native -or -not [IO.File]::Exists($native.Source)) { return $null }
                $resolved = [IO.Path]::GetFullPath($native.Source)
                return New-GatecraftOmniRouteResult @{ Target = $resolved; Identity = 'sha256:' + (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash; Mode = 'default' }
            }
            'docker-existing' {
                $docker = Get-Command docker -ErrorAction SilentlyContinue
                if ($null -eq $docker -or $Target -cne 'omniroute') { return $null }
                $inspect = Invoke-GatecraftOmniRouteProcess -FilePath $docker.Source -Arguments @('inspect', '--type', 'container', '--format', '{{.Id}}|{{.Image}}', 'omniroute') -TimeoutMilliseconds 3000
                if ($inspect.TimedOut -or $inspect.ExitCode -ne 0) { return $null }
                $binding = $inspect.Stdout.Trim()
                if ($binding -cnotmatch '^[a-f0-9]{12,}\|sha256:[a-f0-9]{12,}$') { return $null }
                return New-GatecraftOmniRouteResult @{ Target = 'omniroute'; Identity = 'container:' + $binding; Mode = 'default' }
            }
            'source-checkout' {
                if ($Mode -cnotin @('start', 'dev') -or -not (Test-GatecraftOmniRouteSourceCheckout -Path $Target -Mode $Mode)) { return $null }
                $root = [IO.Path]::GetFullPath($Target)
                $git = Get-Command git -ErrorAction SilentlyContinue
                if ($null -eq $git) { return $null }
                $status = & $git.Source -C $root status --porcelain=v1 --untracked-files=all 2>$null
                if ($LASTEXITCODE -ne 0 -or -not [string]::IsNullOrWhiteSpace(($status -join "`n"))) { return $null }
                $head = (& $git.Source -C $root rev-parse --verify HEAD 2>$null | Select-Object -First 1).Trim()
                if ($LASTEXITCODE -ne 0 -or $head -cnotmatch '^[a-f0-9]{40,64}$') { return $null }
                $runner = Join-Path $root 'scripts/dev/run-next.mjs'
                if (-not [IO.File]::Exists($runner)) { return $null }
                $runnerHash = (Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash
                return New-GatecraftOmniRouteResult @{ Target = $root; Identity = "git:$head;runner-sha256:$runnerHash"; Mode = $Mode }
            }
            'desktop-app' {
                $executable = Get-GatecraftOmniRouteDesktopExecutable -Target $Target
                if ($null -eq $executable) { return $null }
                $resolvedTarget = [IO.Path]::GetFullPath($Target)
                $hash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
                return New-GatecraftOmniRouteResult @{ Target = $resolvedTarget; Identity = 'sha256:' + $hash; Mode = 'default' }
            }
            'systemd-user' {
                if ($IsWindows -or $Target -cne 'omniroute.service') { return $null }
                $systemctl = Get-Command systemctl -ErrorAction SilentlyContinue
                if ($null -eq $systemctl) { return $null }
                $unit = Invoke-GatecraftOmniRouteProcess -FilePath $systemctl.Source -Arguments @('--user', 'cat', 'omniroute.service') -TimeoutMilliseconds 3000
                if ($unit.TimedOut -or $unit.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($unit.Stdout)) { return $null }
                return New-GatecraftOmniRouteResult @{ Target = 'omniroute.service'; Identity = 'unit-sha256:' + (Get-GatecraftOmniRouteSha256 -Value $unit.Stdout); Mode = 'default' }
            }
        }
    } catch { return $null }
    return $null
}

function Get-GatecraftOmniRouteEphemeralAdapterIdentity {
    param(
        [Parameter(Mandatory)][ValidateSet('source-checkout', 'desktop-app', 'systemd-user')][string] $Type,
        [string] $Target,
        [ValidateSet('default', 'start', 'dev')][string] $Mode = 'default'
    )

    if ($Type -cne 'source-checkout') {
        return Get-GatecraftOmniRouteStartupAdapterIdentity -Type $Type -Target $Target -Mode $Mode
    }
    if ($Mode -cnotin @('start', 'dev') -or -not (Test-GatecraftOmniRouteSourceCheckout -Path $Target -Mode $Mode)) { return $null }
    $root = [IO.Path]::GetFullPath($Target)
    $runner = Join-Path $root 'scripts/dev/run-next.mjs'
    if (-not [IO.File]::Exists($runner)) { return $null }
    return New-GatecraftOmniRouteResult @{
        Target = $root
        Identity = 'ephemeral-runner-sha256:' + (Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash
        Mode = $Mode
    }
}

function Find-GatecraftOmniRouteStartupAdapters {
    [CmdletBinding()]
    param(
        [string[]] $SearchRoots,
        [string[]] $DesktopPaths
    )

    $results = [Collections.Generic.List[object]]::new()
    foreach ($candidate in @(Find-GatecraftOmniRouteSourceCheckouts -SearchRoots $SearchRoots)) { $results.Add($candidate) }

    $native = Get-GatecraftOmniRouteStartupAdapterIdentity -Type native-cli -Target '' -Mode default
    if ($null -ne $native) { $results.Add((New-GatecraftOmniRouteResult @{ Type = 'native-cli'; Target = $native.Target; Mode = 'default'; PersistentEligible = $true; RequiresDirectConfirmation = $true })) }
    $docker = Get-GatecraftOmniRouteStartupAdapterIdentity -Type docker-existing -Target 'omniroute' -Mode default
    if ($null -ne $docker) { $results.Add((New-GatecraftOmniRouteResult @{ Type = 'docker-existing'; Target = 'omniroute'; Mode = 'default'; PersistentEligible = $true; RequiresDirectConfirmation = $true })) }
    $systemd = Get-GatecraftOmniRouteStartupAdapterIdentity -Type systemd-user -Target 'omniroute.service' -Mode default
    if ($null -ne $systemd) { $results.Add((New-GatecraftOmniRouteResult @{ Type = 'systemd-user'; Target = 'omniroute.service'; Mode = 'default'; PersistentEligible = $true; RequiresDirectConfirmation = $true })) }

    if ($null -eq $DesktopPaths -or $DesktopPaths.Count -eq 0) {
        $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        if ($IsWindows) {
            $DesktopPaths = @()
            if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $DesktopPaths += Join-Path $env:LOCALAPPDATA 'Programs/OmniRoute/OmniRoute.exe' }
            if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) { $DesktopPaths += Join-Path $env:ProgramFiles 'OmniRoute/OmniRoute.exe' }
        } elseif ($IsMacOS) {
            $DesktopPaths = @('/Applications/OmniRoute.app', (Join-Path $userProfile 'Applications/OmniRoute.app'))
        } else {
            $DesktopPaths = @('/opt/OmniRoute.AppImage', (Join-Path $userProfile 'Applications/OmniRoute.AppImage'), (Join-Path $userProfile 'Downloads/OmniRoute.AppImage'))
        }
    }
    foreach ($desktopPath in @($DesktopPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $desktop = Get-GatecraftOmniRouteStartupAdapterIdentity -Type desktop-app -Target $desktopPath -Mode default
        if ($null -ne $desktop) { $results.Add((New-GatecraftOmniRouteResult @{ Type = 'desktop-app'; Target = $desktop.Target; Mode = 'default'; PersistentEligible = $true; RequiresDirectConfirmation = $true })) }
    }
    return @($results | Sort-Object Type, Target, Mode -Unique)
}

function Test-GatecraftOmniRouteStartupAdapterRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Record)

    try {
        $names = @($Record.PSObject.Properties.Name)
        $expected = @('protocol', 'type', 'target', 'mode', 'identity')
        if (@($names | Where-Object { $_ -cnotin $expected }).Count -gt 0 -or @($expected | Where-Object { $_ -cnotin $names }).Count -gt 0) { return $false }
        if ($Record.protocol -cne $script:StartupAdapterProtocol -or $Record.type -cnotin @('native-cli', 'docker-existing', 'source-checkout', 'desktop-app', 'systemd-user')) { return $false }
        if ($Record.target -isnot [string] -or $Record.mode -isnot [string] -or $Record.identity -isnot [string] -or [string]::IsNullOrWhiteSpace($Record.identity)) { return $false }
        $current = Get-GatecraftOmniRouteStartupAdapterIdentity -Type $Record.type -Target $Record.target -Mode $Record.mode
        return $null -ne $current -and $current.Target -ceq $Record.target -and $current.Mode -ceq $Record.mode -and $current.Identity -ceq $Record.identity
    } catch { return $false }
    return $false
}

function Read-GatecraftOmniRouteStartupAdapter {
    [CmdletBinding()]
    param([string] $Path = (Get-GatecraftOmniRouteStartupAdapterPath))

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($fullPath)) { return New-GatecraftOmniRouteResult @{ Exists = $false; Valid = $true; Path = $fullPath; Record = $null; ReasonCode = 'not-configured' } }
    try {
        $record = [IO.File]::ReadAllText($fullPath) | ConvertFrom-Json -Depth 8 -ErrorAction Stop
        $valid = Test-GatecraftOmniRouteStartupAdapterRecord -Record $record
        return New-GatecraftOmniRouteResult @{ Exists = $true; Valid = $valid; Path = $fullPath; Record = if ($valid) { $record } else { $null }; ReasonCode = if ($valid) { 'loaded' } else { 'adapter-invalid' } }
    } catch {
        return New-GatecraftOmniRouteResult @{ Exists = $true; Valid = $false; Path = $fullPath; Record = $null; ReasonCode = 'adapter-invalid' }
    }
}

function Register-GatecraftOmniRouteStartupAdapter {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][ValidateSet('native-cli', 'docker-existing', 'source-checkout', 'desktop-app', 'systemd-user')][string] $Type,
        [string] $Target,
        [ValidateSet('default', 'start', 'dev')][string] $Mode = 'default',
        [Parameter(Mandatory)][bool] $UserConfirmed,
        [string] $Path = (Get-GatecraftOmniRouteStartupAdapterPath)
    )

    if (-not $UserConfirmed) { throw 'omniroute-adapter-direct-confirmation-required' }
    if ($Type -ceq 'native-cli') { $Mode = 'default' }
    if ($Type -ceq 'docker-existing') { $Target = 'omniroute'; $Mode = 'default' }
    if ($Type -ceq 'systemd-user') { $Target = 'omniroute.service'; $Mode = 'default' }
    if ($Type -ceq 'source-checkout' -and $Mode -cnotin @('start', 'dev')) { throw 'omniroute-source-mode-invalid' }
    if ($Type -ceq 'desktop-app') { $Mode = 'default' }
    $binding = Get-GatecraftOmniRouteStartupAdapterIdentity -Type $Type -Target $Target -Mode $Mode
    if ($null -eq $binding) { throw 'omniroute-adapter-invalid' }
    $record = [pscustomobject][ordered]@{ protocol = $script:StartupAdapterProtocol; type = $Type; target = $binding.Target; mode = $binding.Mode; identity = $binding.Identity }
    if (-not (Test-GatecraftOmniRouteStartupAdapterRecord -Record $record)) { throw 'omniroute-adapter-invalid' }
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $PSCmdlet.ShouldProcess($fullPath, "Register typed OmniRoute startup adapter $Type")) { return }
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.omniroute-startup-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $fullPath, $true)
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
    return Read-GatecraftOmniRouteStartupAdapter -Path $fullPath
}

function Read-GatecraftOmniRoutePreferences {
    [CmdletBinding()]
    param([string] $Path = (Get-GatecraftOmniRouteGlobalPreferencePath))

    $defaults = [ordered]@{
        Valid = $true
        Exists = $false
        InstallPrompt = 'ask'
        GlobalUsePolicy = 'ask'
        Endpoint = $script:DefaultEndpoint
        Path = [IO.Path]::GetFullPath($Path)
        ReasonCode = 'defaults'
    }
    if (-not [IO.File]::Exists($defaults.Path)) { return [pscustomobject]$defaults }

    try {
        $record = [IO.File]::ReadAllText($defaults.Path) | ConvertFrom-Json -Depth 8 -ErrorAction Stop
        $names = @($record.PSObject.Properties.Name)
        $expected = @('protocol', 'install_prompt', 'global_use_policy', 'endpoint')
        if (@($names | Where-Object { $_ -cnotin $expected }).Count -gt 0 -or @($expected | Where-Object { $_ -cnotin $names }).Count -gt 0) { throw 'schema' }
        if ($record.protocol -cne $script:PreferenceProtocol) { throw 'protocol' }
        if ($record.install_prompt -cnotin @('ask', 'never')) { throw 'install-policy' }
        if ($record.global_use_policy -cnotin @('ask', 'always')) { throw 'use-policy' }
        if ($record.endpoint -isnot [string] -or -not (Test-GatecraftOmniRouteEndpointUri -Endpoint $record.endpoint)) { throw 'endpoint' }
        $defaults.Exists = $true
        $defaults.InstallPrompt = $record.install_prompt
        $defaults.GlobalUsePolicy = $record.global_use_policy
        $defaults.Endpoint = $record.endpoint.TrimEnd('/')
        $defaults.ReasonCode = 'loaded'
    } catch {
        $defaults.Valid = $false
        $defaults.Exists = $true
        $defaults.ReasonCode = 'preferences-invalid'
    }
    return [pscustomobject]$defaults
}

function Write-GatecraftOmniRoutePreferences {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateSet('ask', 'never')][string] $InstallPrompt,
        [Parameter(Mandatory)][ValidateSet('ask', 'always')][string] $GlobalUsePolicy,
        [string] $Endpoint = $script:DefaultEndpoint,
        [string] $Path = (Get-GatecraftOmniRouteGlobalPreferencePath)
    )

    if (-not (Test-GatecraftOmniRouteEndpointUri -Endpoint $Endpoint)) { throw 'omniroute-endpoint-invalid' }
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $PSCmdlet.ShouldProcess($fullPath, 'Write Gatecraft OmniRoute preferences')) { return }
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $record = [ordered]@{
        protocol = $script:PreferenceProtocol
        install_prompt = $InstallPrompt
        global_use_policy = $GlobalUsePolicy
        endpoint = $Endpoint.TrimEnd('/')
    }
    $json = ($record | ConvertTo-Json -Depth 4 -Compress) + [Environment]::NewLine
    $temporary = Join-Path $directory ('.preferences-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $fullPath, $true)
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
    return Read-GatecraftOmniRoutePreferences -Path $fullPath
}

function Get-GatecraftOmniRouteProjectPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepositoryRoot)

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) { throw 'omniroute-git-unavailable' }
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $value = & $git.Source -C $root config --local --get gatecraft.omniroute.policy 2>$null
    if ($LASTEXITCODE -eq 1) { return 'inherit' }
    if ($LASTEXITCODE -ne 0) { throw 'omniroute-project-policy-read-failed' }
    $policy = ([string]$value).Trim()
    if ($policy -cnotin @('ask', 'always', 'never')) { throw 'omniroute-project-policy-invalid' }
    return $policy
}

function Set-GatecraftOmniRouteProjectPolicy {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][ValidateSet('inherit', 'ask', 'always', 'never')][string] $Policy
    )

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) { throw 'omniroute-git-unavailable' }
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    if (-not $PSCmdlet.ShouldProcess($root, "Set local Gatecraft OmniRoute policy to $Policy")) { return }
    if ($Policy -ceq 'inherit') {
        & $git.Source -C $root config --local --unset-all gatecraft.omniroute.policy 2>$null
        if ($LASTEXITCODE -notin @(0, 5)) { throw 'omniroute-project-policy-write-failed' }
    } else {
        & $git.Source -C $root config --local gatecraft.omniroute.policy $Policy
        if ($LASTEXITCODE -ne 0) { throw 'omniroute-project-policy-write-failed' }
    }
    return Get-GatecraftOmniRouteProjectPolicy -RepositoryRoot $root
}

function Resolve-GatecraftOmniRouteUsePolicy {
    [CmdletBinding()]
    param(
        [ValidateSet('none', 'use', 'skip')][string] $SessionChoice = 'none',
        [ValidateSet('inherit', 'ask', 'always', 'never')][string] $ProjectPolicy = 'inherit',
        [ValidateSet('ask', 'always')][string] $GlobalUsePolicy = 'ask'
    )

    if ($SessionChoice -ceq 'use') { return New-GatecraftOmniRouteResult @{ Decision = 'use'; Source = 'session' } }
    if ($SessionChoice -ceq 'skip') { return New-GatecraftOmniRouteResult @{ Decision = 'skip'; Source = 'session' } }
    if ($ProjectPolicy -cne 'inherit') {
        $decision = if ($ProjectPolicy -ceq 'always') { 'use' } elseif ($ProjectPolicy -ceq 'never') { 'skip' } else { 'ask' }
        return New-GatecraftOmniRouteResult @{ Decision = $decision; Source = 'project' }
    }
    $globalDecision = if ($GlobalUsePolicy -ceq 'always') { 'use' } else { 'ask' }
    return New-GatecraftOmniRouteResult @{ Decision = $globalDecision; Source = 'global' }
}

function Resolve-GatecraftOmniRouteInstallDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('missing', 'installed-stopped', 'ready', 'broken')][string] $ObservedState,
        [ValidateSet('ask', 'never')][string] $InstallPrompt = 'ask'
    )

    if ($ObservedState -cne 'missing') { return New-GatecraftOmniRouteResult @{ Decision = 'present'; Source = 'observed-state' } }
    if ($InstallPrompt -ceq 'never') { return New-GatecraftOmniRouteResult @{ Decision = 'skip'; Source = 'global-install-policy' } }
    return New-GatecraftOmniRouteResult @{ Decision = 'ask-install'; Source = 'global-install-policy' }
}

function Test-GatecraftOmniRouteEndpoint {
    [CmdletBinding()]
    param(
        [string] $Endpoint = $script:DefaultEndpoint,
        [ValidateRange(1, 30)][int] $TimeoutSeconds = 3,
        [scriptblock] $Request
    )

    if (-not (Test-GatecraftOmniRouteEndpointUri -Endpoint $Endpoint)) {
        return New-GatecraftOmniRouteResult @{ ProbeState = 'invalid'; ReasonCode = 'endpoint-invalid'; ModelIds = @() }
    }
    $modelsUri = $Endpoint.TrimEnd('/') + '/v1/models'
    # `localhost` resolves to ::1 first, but managed startup forces the IPv4-only
    # HOST=127.0.0.1, so an IPv6 attempt fails with a transport error while the
    # gateway is actually serving. Retry the literal IPv4 loopback before reporting
    # `unreachable`; any non-transport outcome is authoritative and is never retried.
    $candidateUris = [Collections.Generic.List[string]]::new()
    $candidateUris.Add($modelsUri)
    # Only the cast is guarded: an unparsable URI simply gets no retry. Keeping the
    # Add() outside the catch means a fault there surfaces instead of silently
    # degrading to a single attempt.
    $modelsUriHost = $null
    try { $modelsUriHost = ([uri] $modelsUri).Host } catch { $modelsUriHost = $null }
    if ($modelsUriHost -ceq 'localhost') {
        # Parentheses are required: a bare operator inside a method argument list is
        # parsed as two arguments.
        $candidateUris.Add(($modelsUri -creplace '(?<=://)localhost(?=[:/])', '127.0.0.1'))
    }

    $probeResult = $null
    foreach ($candidateUri in $candidateUris) {
        $probeResult = Invoke-GatecraftOmniRouteCatalogProbe -Uri $candidateUri -TimeoutSeconds $TimeoutSeconds -Request $Request
        if ($probeResult.ProbeState -cne 'unreachable') { break }
    }
    return $probeResult
}

function Invoke-GatecraftOmniRouteCatalogProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Uri,
        [ValidateRange(1, 30)][int] $TimeoutSeconds = 3,
        [scriptblock] $Request
    )

    $modelsUri = $Uri
    try {
        if ($null -ne $Request) {
            $payload = & $Request $modelsUri $TimeoutSeconds
        } else {
            $response = Invoke-RestMethod -Method Get -Uri $modelsUri -TimeoutSec $TimeoutSeconds -ErrorAction Stop
            $payload = $response
        }
        if ($payload -is [string]) { $payload = $payload | ConvertFrom-Json -Depth 20 -ErrorAction Stop }
        if ($null -eq $payload -or $null -eq $payload.data) { throw 'catalog-shape' }
        $ids = @($payload.data | ForEach-Object { if ($_.id -is [string] -and -not [string]::IsNullOrWhiteSpace($_.id)) { $_.id } })
        # An endpoint that answers with zero models is a freshly installed instance
        # with no provider connected, not a broken one. Keeping it distinct from
        # `catalog-invalid` is what lets onboarding guide the user instead of
        # reporting a misleading readiness failure.
        if ($ids.Count -eq 0) {
            return New-GatecraftOmniRouteResult @{ ProbeState = 'invalid'; ReasonCode = 'catalog-empty'; ModelIds = @(); HttpStatus = 200 }
        }
        if ($ids.Count -ne @($ids | Sort-Object -Unique).Count) { throw 'catalog-models' }
        return New-GatecraftOmniRouteResult @{ ProbeState = 'ready'; ReasonCode = 'catalog-valid'; ModelIds = @($ids); HttpStatus = 200 }
    } catch [System.Net.Http.HttpRequestException], [System.Net.WebException], [System.Threading.Tasks.TaskCanceledException] {
        # A responding endpoint that rejects the caller is also not a transport
        # failure: it means the instance is up but this caller has no usable key.
        $status = Get-GatecraftOmniRouteResponseStatus -ErrorRecord $_
        if ($status -in @(401, 403)) {
            return New-GatecraftOmniRouteResult @{ ProbeState = 'invalid'; ReasonCode = 'authentication-required'; ModelIds = @(); HttpStatus = $status }
        }
        return New-GatecraftOmniRouteResult @{ ProbeState = 'unreachable'; ReasonCode = 'endpoint-unreachable'; ModelIds = @(); HttpStatus = $status }
    } catch {
        return New-GatecraftOmniRouteResult @{ ProbeState = 'invalid'; ReasonCode = 'catalog-invalid'; ModelIds = @(); HttpStatus = $null }
    }
}

function Get-GatecraftOmniRouteResponseStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $ErrorRecord)

    foreach ($candidate in @($ErrorRecord.Exception, $ErrorRecord.Exception.InnerException)) {
        if ($null -eq $candidate) { continue }
        $directStatus = $candidate.PSObject.Properties['StatusCode']
        if ($null -ne $directStatus -and $null -ne $directStatus.Value) { return [int] $directStatus.Value }
        $response = $candidate.PSObject.Properties['Response']
        if ($null -ne $response -and $null -ne $response.Value) {
            $responseStatus = $response.Value.PSObject.Properties['StatusCode']
            if ($null -ne $responseStatus -and $null -ne $responseStatus.Value) { return [int] $responseStatus.Value }
        }
    }
    return $null
}

function Resolve-GatecraftOmniRouteObservedState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('ready', 'unreachable', 'invalid')][string] $ProbeState,
        [Parameter(Mandatory)][bool] $NativeCommandPresent,
        [Parameter(Mandatory)][bool] $DockerContainerPresent,
        [bool] $DockerContainerRunning = $false,
        [bool] $RegisteredAdapterPresent = $false,
        [bool] $DiscoveredAdapterPresent = $false
    )

    if ($ProbeState -ceq 'ready') { return 'ready' }
    if ($ProbeState -ceq 'invalid' -or ($DockerContainerRunning -and $ProbeState -ceq 'unreachable')) { return 'broken' }
    if ($NativeCommandPresent -or $DockerContainerPresent -or $RegisteredAdapterPresent -or $DiscoveredAdapterPresent) { return 'installed-stopped' }
    return 'missing'
}

function New-GatecraftOmniRouteLaneProbeBody {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ModelId)

    # A gateway route that answers a one-line request can still be unusable as a
    # worker lane. Two observed rejections only appear at realistic size and shape:
    # a free tier that caps the per-request payload (HTTP 413 "Request too large"),
    # and a model that refuses the reasoning parameter the anthropic launch adapter
    # always sends (HTTP 400 "reasoning_effort is not enabled/supported"). A small
    # ping misses both and reports the lane as good.
    #
    # This body therefore approximates a worker session: reasoning enabled, a long
    # system prompt, and a realistic number of tool definitions. It is the size and
    # shape that matter, not the wording, so the filler is deliberately inert and
    # carries no repository content.
    $filler = ('Operates as a coding agent inside a repository. ' * 300)
    $tools = @(
        0..19 | ForEach-Object {
            [ordered]@{
                name = "probe_tool_$_"
                description = ('Performs one agent operation. ' * 40)
                input_schema = [ordered]@{
                    type = 'object'
                    properties = [ordered]@{
                        path = [ordered]@{ type = 'string'; description = ('absolute file path ' * 10) }
                        content = [ordered]@{ type = 'string'; description = ('content to write ' * 10) }
                        pattern = [ordered]@{ type = 'string'; description = ('regular expression ' * 10) }
                    }
                    required = @('path')
                }
            }
        }
    )
    return [ordered]@{
        model = $ModelId
        max_tokens = 16
        thinking = [ordered]@{ type = 'enabled'; budget_tokens = 1024 }
        system = $filler
        tools = @($tools)
        messages = @([ordered]@{ role = 'user'; content = 'ok' })
    }
}

function Test-GatecraftOmniRouteModelLane {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Endpoint,
        [Parameter(Mandatory)][string] $ModelId,
        [ValidateRange(5, 600)][int] $TimeoutSeconds = 120,
        # Test seam: receives the request URI, body and timeout, and returns either
        # the HTTP status code or throws like the real transport would.
        [scriptblock] $Request
    )

    if (-not (Test-GatecraftOmniRouteEndpointUri -Endpoint $Endpoint)) {
        return New-GatecraftOmniRouteResult @{ ModelId = $ModelId; Usable = $false; Verdict = 'invalid'; ReasonCode = 'endpoint-invalid'; HttpStatus = $null }
    }

    # The key is read from the inherited environment and never persisted, logged or
    # projected — the contract allows an inherited secret supplied by the user, and
    # nothing else.
    $apiKey = if (-not [string]::IsNullOrWhiteSpace($env:OMNIROUTE_API_KEY)) { $env:OMNIROUTE_API_KEY } else { $env:ANTHROPIC_AUTH_TOKEN }
    if ($null -eq $Request -and [string]::IsNullOrWhiteSpace($apiKey)) {
        return New-GatecraftOmniRouteResult @{ ModelId = $ModelId; Usable = $false; Verdict = 'blocked'; ReasonCode = 'probe-key-missing'; HttpStatus = $null }
    }

    $uri = $Endpoint.TrimEnd('/') + '/v1/messages'
    $body = New-GatecraftOmniRouteLaneProbeBody -ModelId $ModelId
    $status = $null
    $failureText = ''
    try {
        if ($null -ne $Request) {
            $status = & $Request $uri $body $TimeoutSeconds
        } else {
            $response = Invoke-WebRequest -Method Post -Uri $uri -TimeoutSec $TimeoutSeconds -ErrorAction Stop `
                -Headers @{ 'x-api-key' = $apiKey; 'anthropic-version' = '2023-06-01' } `
                -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 8 -Compress)
            $status = [int] $response.StatusCode
        }
    } catch {
        $status = Get-GatecraftOmniRouteResponseStatus -ErrorRecord $_
        # The message is needed to tell one 5xx apart from another: OmniRoute's own
        # queue rejection arrives as a 502 that says nothing about the model. ErrorDetails
        # is absent on most failures, and reading through it unguarded throws under
        # Set-StrictMode.
        $errorDetailsText = if ($null -ne $_.ErrorDetails) { [string] $_.ErrorDetails.Message } else { '' }
        $failureText = "$($_.Exception.Message) $errorDetailsText"
        if ($null -eq $status) {
            # No status at all: transport failure or timeout. Never a permanent verdict.
            return New-GatecraftOmniRouteResult @{ ModelId = $ModelId; Usable = $false; Verdict = 'transient'; ReasonCode = 'lane-unreachable'; HttpStatus = $null }
        }
    }

    if ($status -ge 200 -and $status -lt 300) {
        return New-GatecraftOmniRouteResult @{ ModelId = $ModelId; Usable = $true; Verdict = 'permanent'; ReasonCode = 'lane-usable'; HttpStatus = $status }
    }
    if ($status -in @(401, 403)) {
        # The caller's key is wrong, which says nothing about the model. Reporting this
        # per-model would blacklist every lane over one bad credential.
        return New-GatecraftOmniRouteResult @{ ModelId = $ModelId; Usable = $false; Verdict = 'blocked'; ReasonCode = 'probe-unauthorized'; HttpStatus = $status }
    }
    # OmniRoute drops a request that waited longer than its own local rate-limit queue
    # budget, and reports it as a 502 that looks like an upstream fault. The default
    # budget is 15s, which is tight for a free tier where a worker-sized request
    # routinely takes longer — so the lane looks broken when only that budget is.
    # Naming it separately turns an opaque 502 into an actionable setting.
    if ($failureText -match 'maxWaitMs' -or $failureText -match 'rate-limit queue budget') {
        return New-GatecraftOmniRouteResult @{ ModelId = $ModelId; Usable = $false; Verdict = 'transient'; ReasonCode = 'lane-queue-budget'; HttpStatus = $status }
    }
    if ($status -in @(408, 425, 429) -or $status -ge 500) {
        # Rate limit, cooldown or upstream fault: retryable, so it must never become a
        # permanent exclusion. Observed live as 429 "all credentials are cooling down"
        # on a lane that works minutes later.
        return New-GatecraftOmniRouteResult @{ ModelId = $ModelId; Usable = $false; Verdict = 'transient'; ReasonCode = 'lane-indeterminate'; HttpStatus = $status }
    }
    return New-GatecraftOmniRouteResult @{ ModelId = $ModelId; Usable = $false; Verdict = 'permanent'; ReasonCode = 'lane-rejected'; HttpStatus = $status }
}

function Test-GatecraftOmniRouteInstanceUnconfigured {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]] $SecurityWarnings = @(),
        [Parameter(Mandatory)][ValidateSet('configured', 'unconfigured', 'unknown')][string] $SetupState,
        [Parameter(Mandatory)] $Probe,
        [Parameter(Mandatory)] $Listener
    )

    # Concordant evidence only: a responding-but-unusable endpoint on a verified
    # loopback listener, on a checkout that still reports the default initial
    # password and no completed bootstrap. Any single signal on its own stays an
    # ordinary readiness failure, so a genuinely broken instance is never sold to
    # the user as "just needs setup".
    $respondingButUnusable = $Probe.ProbeState -ceq 'invalid' -and
        $Probe.ReasonCode -cin @('catalog-empty', 'authentication-required')
    return $SecurityWarnings -contains 'default-initial-password' -and
        $SetupState -cne 'configured' -and
        $Listener.Verified -and
        $Listener.Safe -and
        $respondingButUnusable
}

function Get-GatecraftOmniRouteDashboardUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Endpoint)

    # Only a loopback origin may be projected as a clickable dashboard: a remote
    # origin could carry the user somewhere Gatecraft never validated.
    try { $parsed = [uri] $Endpoint } catch { return $null }
    if ($parsed.Host -cnotin @('localhost', '127.0.0.1', '::1', '[::1]')) { return $null }
    return $Endpoint.TrimEnd('/') + '/dashboard'
}

function Get-GatecraftOmniRouteOnboarding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Status,
        [AllowEmptyCollection()][string[]] $SecurityWarnings = @(),
        [ValidateSet('configured', 'unconfigured', 'unknown')][string] $SetupState = 'unknown',
        [ValidateSet('ask', 'never')][string] $InstallPrompt = 'ask'
    )

    $endpoint = $Status.Endpoint
    $reason = $Status.Probe.ReasonCode
    $modelCount = @($Status.Probe.ModelIds).Count
    $dashboardUrl = Get-GatecraftOmniRouteDashboardUrl -Endpoint $endpoint
    $actions = [Collections.Generic.List[string]]::new()

    switch ($Status.State) {
        'missing' {
            $stage = 'not-installed'
            if ($InstallPrompt -ceq 'never') { $actions.Add('respect-never-install') } else { $actions.Add('install-omniroute') }
        }
        'installed-stopped' {
            $stage = 'installed-not-running'
            $actions.Add('start-omniroute')
        }
        'ready' {
            if ($modelCount -gt 0) {
                $stage = 'usable'
                $actions.Add('none')
            } else {
                # Defensive: 'ready' is defined as a non-empty catalog, so this is a
                # contract violation rather than an expected state. Report it instead
                # of projecting a usable gateway.
                $stage = 'inconsistent'
                $actions.Add('report-contract-violation')
            }
        }
        'broken' {
            if ($reason -cin @('catalog-empty', 'authentication-required')) {
                # Up and answering, but nothing usable behind it: this is the fresh
                # install that needs an attended setup pass, not a fault to repair.
                $stage = 'running-unconfigured'
                if ($SecurityWarnings -contains 'default-initial-password') { $actions.Add('change-initial-password') }
                $actions.Add('open-dashboard')
                $actions.Add('connect-provider')
                $actions.Add('create-api-key')
                $actions.Add('retry-readiness')
            } else {
                $stage = 'broken'
                $actions.Add('inspect-endpoint')
            }
        }
        default {
            $stage = 'unknown'
            $actions.Add('inspect-endpoint')
        }
    }

    # Orthogonal to the stage: a stored startup adapter whose identity no longer
    # matches has silently lost its standing authority. Managed source startup runs
    # `scripts/dev/run-next.mjs`, which regenerates tracked files under `.source/`,
    # so a source-checkout registration can be invalidated by the very start it
    # authorized. Say so instead of letting the next session look unexplained.
    $adapterRecord = $Status.PSObject.Properties['StartupAdapter']
    $adapterAuthority = 'none'
    if ($null -ne $adapterRecord -and $null -ne $adapterRecord.Value) {
        if ($adapterRecord.Value.Exists -and $adapterRecord.Value.Valid) {
            $adapterAuthority = 'valid'
        } elseif ($adapterRecord.Value.Exists) {
            $adapterAuthority = 'stale'
            $actions.Add('re-register-adapter')
        }
    }

    # `none` is a sentinel meaning "nothing to do": it must never coexist with a
    # real action, or a caller reading the first element would report the opposite
    # of the truth.
    if ($actions.Count -gt 1 -and $actions.Contains('none')) { $actions.Remove('none') | Out-Null }

    return New-GatecraftOmniRouteResult @{
        Stage = $stage
        State = $Status.State
        Endpoint = $endpoint
        ReasonCode = $reason
        ModelCount = $modelCount
        DashboardUrl = $dashboardUrl
        NextActions = @($actions)
        AdapterAuthority = $adapterAuthority
        SetupState = $SetupState
        SecurityWarnings = @($SecurityWarnings)
        # Configuration is the user's: Gatecraft never connects a provider, changes
        # a password, or reads a credential. It reports what is missing and stops.
        ConfigurationOwner = 'user'
    }
}

function Get-GatecraftOmniRouteStatus {
    [CmdletBinding()]
    param(
        [string] $Endpoint = $script:DefaultEndpoint,
        [ValidateRange(1, 30)][int] $TimeoutSeconds = 3,
        [string] $StartupAdapterPath = (Get-GatecraftOmniRouteStartupAdapterPath),
        # Test seam mirroring Test-GatecraftOmniRouteEndpoint: without it the
        # probe-ready branch below can only be reached with a live gateway, so no
        # machine-independent test could exercise it.
        [scriptblock] $Request
    )

    $probeArguments = @{ Endpoint = $Endpoint; TimeoutSeconds = $TimeoutSeconds }
    if ($null -ne $Request) { $probeArguments.Request = $Request }
    $probe = Test-GatecraftOmniRouteEndpoint @probeArguments
    $native = Get-GatecraftOmniRouteNativeCommand
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    $containerPresent = $false
    $containerRunning = $false
    if ($null -ne $docker) {
        $inspect = Invoke-GatecraftOmniRouteProcess -FilePath $docker.Source -Arguments @('inspect', '--type', 'container', '--format', '{{.State.Running}}', 'omniroute') -TimeoutMilliseconds 3000
        if (-not $inspect.TimedOut -and $inspect.ExitCode -eq 0) {
            $containerPresent = $true
            $containerRunning = $inspect.Stdout.Trim() -ceq 'true'
        }
    }
    $registered = Read-GatecraftOmniRouteStartupAdapter -Path $StartupAdapterPath
    $registeredPresent = $registered.Exists -and $registered.Valid
    $discovered = @(if ($probe.ProbeState -cne 'ready' -and -not $registeredPresent -and -not $containerPresent -and $null -eq $native) { Find-GatecraftOmniRouteStartupAdapters } else { @() })
    $state = Resolve-GatecraftOmniRouteObservedState -ProbeState $probe.ProbeState -NativeCommandPresent ($null -ne $native) -DockerContainerPresent $containerPresent -DockerContainerRunning $containerRunning -RegisteredAdapterPresent $registeredPresent -DiscoveredAdapterPresent ($discovered.Count -gt 0)
    $adapter = if ($registeredPresent) { $registered.Record.type } elseif ($containerPresent) { 'docker-existing' } elseif ($null -ne $native) { 'native-cli' } elseif ($discovered.Count -gt 0) { $discovered[0].Type } else { 'none' }
    return New-GatecraftOmniRouteResult @{
        State = $state
        Endpoint = $Endpoint.TrimEnd('/')
        Probe = $probe
        Adapter = $adapter
        NativeCommandPresent = ($null -ne $native)
        DockerContainerPresent = $containerPresent
        DockerContainerRunning = $containerRunning
        StartupAdapter = $registered
        DiscoveredAdapters = @($discovered)
    }
}

function Start-GatecraftOmniRoute {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateSet('native-cli', 'docker-existing', 'source-checkout', 'desktop-app', 'systemd-user')][string] $Adapter,
        [string] $Endpoint = $script:DefaultEndpoint,
        [ValidateRange(5, 180)][int] $ReadyTimeoutSeconds = 60,
        [string] $StartupAdapterPath = (Get-GatecraftOmniRouteStartupAdapterPath),
        [bool] $UserConfirmedUnregistered = $false,
        [string] $Target,
        [ValidateSet('default', 'start', 'dev')][string] $Mode = 'default'
    )

    if (-not (Test-GatecraftOmniRouteEndpointUri -Endpoint $Endpoint)) { throw 'omniroute-endpoint-invalid' }
    $uri = [uri]$Endpoint
    if (-not $uri.IsLoopback) { throw 'omniroute-autostart-requires-loopback-endpoint' }
    if (-not $PSCmdlet.ShouldProcess($Endpoint, "Start OmniRoute with adapter $Adapter")) { return }

    $registered = Read-GatecraftOmniRouteStartupAdapter -Path $StartupAdapterPath
    if ($registered.Exists -and -not $registered.Valid) { throw 'omniroute-registered-adapter-invalid' }
    $usesRegistered = $registered.Exists -and $registered.Valid -and $registered.Record.type -ceq $Adapter
    if (-not $usesRegistered -and -not $UserConfirmedUnregistered) { throw 'omniroute-unregistered-start-direct-confirmation-required' }
    if ($usesRegistered -and -not (Test-GatecraftOmniRouteStartupAdapterRecord -Record $registered.Record)) { throw 'omniroute-adapter-identity-drift' }
    $ephemeral = $null
    if (-not $usesRegistered -and $Adapter -cin @('source-checkout', 'desktop-app', 'systemd-user')) {
        $ephemeralTarget = if ($Adapter -ceq 'systemd-user') { 'omniroute.service' } else { $Target }
        $ephemeral = Get-GatecraftOmniRouteEphemeralAdapterIdentity -Type $Adapter -Target $ephemeralTarget -Mode $Mode
        if ($null -eq $ephemeral) { throw 'omniroute-ephemeral-adapter-invalid' }
    }
    $launchRecord = if ($usesRegistered) { $registered.Record } else { $ephemeral }
    if ($Adapter -ceq 'source-checkout') {
        $preflight = Get-GatecraftOmniRouteSourcePreflight -Target $launchRecord.Target -Mode $launchRecord.Mode
        if ($preflight.Decision -cne 'ready') {
            return New-GatecraftOmniRouteResult @{
                State = $preflight.Decision
                ReasonCode = $preflight.ReasonCode
                Adapter = $Adapter
                Mode = $launchRecord.Mode
                RecommendedMode = $preflight.RecommendedMode
                AvailableActions = $preflight.AvailableActions
                BuildReady = $preflight.BuildReady
                SecurityWarnings = $preflight.SecurityWarnings
            }
        }
    }

    $launchedProcess = $null
    $processStart = $null
    $sourceHost = $null
    $observedDescendants = [Collections.Generic.Dictionary[int, long]]::new()
    $treeObservationComplete = $true
    # Ultimo esito del probe: serve a rendere il timeout diagnosticabile invece che
    # opaco. Un 'readiness-timeout' non dice se l'endpoint non rispondeva o se
    # rispondeva con un catalogo inutilizzabile, che sono problemi diversi.
    $lastProbe = $null

    if ($Adapter -ceq 'docker-existing') {
        $docker = Get-Command docker -ErrorAction SilentlyContinue
        if ($null -eq $docker) { throw 'omniroute-docker-unavailable' }
        $dockerTarget = 'omniroute'
        if ($usesRegistered -and $registered.Record.identity -cmatch '^container:(?<id>[a-f0-9]{12,})\|sha256:') { $dockerTarget = $Matches['id'] }
        $dockerStart = Invoke-GatecraftOmniRouteProcess -FilePath $docker.Source -Arguments @('start', $dockerTarget) -TimeoutMilliseconds 10000
        if ($dockerStart.TimedOut -or $dockerStart.ExitCode -ne 0) { throw 'omniroute-start-failed' }
    } elseif ($Adapter -ceq 'native-cli') {
        $nativeCommand = if ($usesRegistered) { $null } else { Get-GatecraftOmniRouteNativeCommand }
        $nativePath = if ($usesRegistered) { $registered.Record.target } elseif ($null -ne $nativeCommand) { $nativeCommand.Source } else { $null }
        if ([string]::IsNullOrWhiteSpace($nativePath) -or -not [IO.File]::Exists($nativePath)) { throw 'omniroute-command-unavailable' }
        $arguments = @('--no-open', '--port', [string]$uri.Port)
        $start = @{ FilePath = $nativePath; ArgumentList = $arguments; PassThru = $true }
        if ($IsWindows) { $start.WindowStyle = 'Hidden' }
        $launchedProcess = Start-Process @start
        $processStart = $launchedProcess.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
    } else {
        $currentEphemeral = if ($usesRegistered) { $null } else { Get-GatecraftOmniRouteEphemeralAdapterIdentity -Type $Adapter -Target $launchRecord.Target -Mode $launchRecord.Mode }
        if (-not $usesRegistered -and ($null -eq $currentEphemeral -or $currentEphemeral.Target -cne $launchRecord.Target -or $currentEphemeral.Mode -cne $launchRecord.Mode -or $currentEphemeral.Identity -cne $launchRecord.Identity)) { throw 'omniroute-ephemeral-adapter-identity-drift' }
        switch ($Adapter) {
            'source-checkout' {
                $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($null -eq $node) { throw 'omniroute-node-unavailable' }
                $runner = Join-Path $launchRecord.Target 'scripts/dev/run-next.mjs'
                try {
                    $sourceHost = Start-GatecraftOmniRouteSourceProcessHost -Purpose source-start -NodePath $node.Source -RunnerPath $runner -WorkingDirectory $launchRecord.Target -Mode $launchRecord.Mode -Port $uri.Port
                } catch {
                    return New-GatecraftOmniRouteResult @{ State = 'failed'; Endpoint = $Endpoint.TrimEnd('/'); Adapter = $Adapter; ReasonCode = 'process-host-launch-failed'; DiagnosticCode = 'process-host-launch-failed'; ExitCode = $null; OutputTail = @(); RawLogDirectory = $null }
                }
                $launchedProcess = $sourceHost.Process
                $processStart = $launchedProcess.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
            }
            'desktop-app' {
                $desktopExecutable = Get-GatecraftOmniRouteDesktopExecutable -Target $launchRecord.Target
                if ($null -eq $desktopExecutable) { throw 'omniroute-desktop-launcher-unavailable' }
                $start = @{ FilePath = $desktopExecutable; PassThru = $true }
                if ($IsWindows) { $start.WindowStyle = 'Hidden' }
                $launchedProcess = Start-Process @start
                $processStart = $launchedProcess.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
            }
            'systemd-user' {
                $systemctl = Get-Command systemctl -ErrorAction SilentlyContinue
                if ($null -eq $systemctl) { throw 'omniroute-systemd-unavailable' }
                $serviceStart = Invoke-GatecraftOmniRouteProcess -FilePath $systemctl.Source -Arguments @('--user', 'start', 'omniroute.service') -TimeoutMilliseconds 10000
                if ($serviceStart.TimedOut -or $serviceStart.ExitCode -ne 0) { throw 'omniroute-start-failed' }
            }
        }
    }

    if ($null -ne $launchedProcess) {
        $treeObservationComplete = Update-GatecraftOmniRouteObservedDescendants -RootId $launchedProcess.Id -Observed $observedDescendants
        if (-not $treeObservationComplete) {
            Stop-GatecraftOmniRouteTrackedTree -RootProcess $launchedProcess -Observed $observedDescendants -ObservationComplete $false
        }
    }
    $deadline = [datetimeoffset]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
    do {
        if ($null -ne $launchedProcess) {
            $treeObservationComplete = (Update-GatecraftOmniRouteObservedDescendants -RootId $launchedProcess.Id -Observed $observedDescendants) -and $treeObservationComplete
        }
        $probe = Test-GatecraftOmniRouteEndpoint -Endpoint $Endpoint -TimeoutSeconds 2
        $lastProbe = $probe
        if ($probe.ProbeState -ceq 'ready') {
            if ($Adapter -ceq 'source-checkout') {
                $listener = Test-GatecraftOmniRouteLoopbackListener -Port $uri.Port
                if (-not $listener.Verified -or -not $listener.Safe) {
                    Stop-GatecraftOmniRouteTrackedTree -RootProcess $launchedProcess -Observed $observedDescendants -ObservationComplete $treeObservationComplete
                    $diagnostic = Get-GatecraftOmniRouteProcessDiagnostic -LogDirectory $sourceHost.LogDirectory -ResultPath $sourceHost.ResultPath -FallbackReasonCode $listener.ReasonCode
                    return New-GatecraftOmniRouteResult @{ State = 'failed'; Endpoint = $Endpoint.TrimEnd('/'); Adapter = $Adapter; ReasonCode = $listener.ReasonCode; DiagnosticCode = $diagnostic.DiagnosticCode; ExitCode = $diagnostic.ExitCode; OutputTail = $diagnostic.OutputTail; RawLogDirectory = $diagnostic.RawLogDirectory; ListenerAddresses = $listener.Addresses }
                }
            }
            return New-GatecraftOmniRouteResult @{ State = 'ready'; Endpoint = $Endpoint.TrimEnd('/'); Probe = $probe; Adapter = $Adapter; ProcessId = if ($null -ne $launchedProcess) { $launchedProcess.Id } else { $null }; ProcessStart = $processStart; RawLogDirectory = if ($null -ne $sourceHost) { $sourceHost.LogDirectory } else { $null } }
        }
        # Un'istanza appena installata risponde ma non ha provider: il catalogo e'
        # vuoto e la readiness non arrivera' mai. Senza questo ramo l'attesa scadeva
        # come un fallimento generico, lasciando l'operatore a interpretare un
        # timeout invece di leggere "manca la configurazione". Il processo autorizzato
        # resta vivo per la sessione di setup attendita, e resta nel manifest di reap.
        if ($Adapter -ceq 'source-checkout' -and $null -ne $launchedProcess -and -not $launchedProcess.HasExited) {
            $listener = Test-GatecraftOmniRouteLoopbackListener -Port $uri.Port
            if ($listener.Verified -and -not $listener.Safe) {
                # Un listener non-loopback fallisce chiuso anche qui: non si offre mai
                # all'utente un'istanza esposta come se fosse solo da configurare.
                Stop-GatecraftOmniRouteTrackedTree -RootProcess $launchedProcess -Observed $observedDescendants -ObservationComplete $treeObservationComplete
                $diagnostic = Get-GatecraftOmniRouteProcessDiagnostic -LogDirectory $sourceHost.LogDirectory -ResultPath $sourceHost.ResultPath -FallbackReasonCode $listener.ReasonCode
                return New-GatecraftOmniRouteResult @{ State = 'failed'; Endpoint = $Endpoint.TrimEnd('/'); Adapter = $Adapter; ReasonCode = $listener.ReasonCode; DiagnosticCode = $diagnostic.DiagnosticCode; ExitCode = $diagnostic.ExitCode; OutputTail = $diagnostic.OutputTail; RawLogDirectory = $diagnostic.RawLogDirectory; ListenerAddresses = $listener.Addresses }
            }
            if (Test-GatecraftOmniRouteInstanceUnconfigured -SecurityWarnings $preflight.SecurityWarnings -SetupState $preflight.SetupState -Probe $probe -Listener $listener) {
                $diagnostic = Get-GatecraftOmniRouteProcessDiagnostic -LogDirectory $sourceHost.LogDirectory -ResultPath $sourceHost.ResultPath -FallbackReasonCode 'instance-unconfigured'
                return New-GatecraftOmniRouteResult @{
                    State = 'needs-action'
                    ReasonCode = 'instance-unconfigured'
                    DiagnosticCode = 'instance-unconfigured'
                    Endpoint = $Endpoint.TrimEnd('/')
                    DashboardUrl = Get-GatecraftOmniRouteDashboardUrl -Endpoint $Endpoint
                    Adapter = $Adapter
                    Mode = $launchRecord.Mode
                    ProbeReasonCode = $probe.ReasonCode
                    SecurityWarnings = @($preflight.SecurityWarnings)
                    SetupState = $preflight.SetupState
                    RequiredActions = @('login', 'change-initial-password', 'configure-provider', 'retry-readiness')
                    AvailableActions = @('open-dashboard', 'use-direct-profiles', 'stop-omniroute')
                    ProcessId = $launchedProcess.Id
                    ProcessStart = $processStart
                    KeptRunningForSetup = $true
                    ListenerAddresses = @($listener.Addresses)
                    OutputTail = $diagnostic.OutputTail
                    RawLogDirectory = $diagnostic.RawLogDirectory
                }
            }
        }
        if ($null -ne $launchedProcess -and $launchedProcess.HasExited) {
            Stop-GatecraftOmniRouteTrackedTree -RootProcess $launchedProcess -Observed $observedDescendants -ObservationComplete $treeObservationComplete
            if ($Adapter -ceq 'source-checkout') {
                $diagnostic = Get-GatecraftOmniRouteProcessDiagnostic -LogDirectory $sourceHost.LogDirectory -ResultPath $sourceHost.ResultPath -FallbackReasonCode 'process-exited-before-ready'
                return New-GatecraftOmniRouteResult @{ State = 'failed'; Endpoint = $Endpoint.TrimEnd('/'); Adapter = $Adapter; ReasonCode = $diagnostic.ReasonCode; DiagnosticCode = $diagnostic.DiagnosticCode; ExitCode = $diagnostic.ExitCode; OutputTail = $diagnostic.OutputTail; RawLogDirectory = $diagnostic.RawLogDirectory }
            }
            throw 'omniroute-process-exited-before-ready'
        }
        Start-Sleep -Milliseconds 500
    } while ([datetimeoffset]::UtcNow -lt $deadline)
    if ($null -ne $launchedProcess) {
        $treeObservationComplete = (Update-GatecraftOmniRouteObservedDescendants -RootId $launchedProcess.Id -Observed $observedDescendants) -and $treeObservationComplete
        Stop-GatecraftOmniRouteTrackedTree -RootProcess $launchedProcess -Observed $observedDescendants -ObservationComplete $treeObservationComplete
    }
    if ($Adapter -ceq 'source-checkout') {
        $diagnostic = Get-GatecraftOmniRouteProcessDiagnostic -LogDirectory $sourceHost.LogDirectory -ResultPath $sourceHost.ResultPath -FallbackReasonCode 'readiness-timeout'
        return New-GatecraftOmniRouteResult @{ State = 'failed'; Endpoint = $Endpoint.TrimEnd('/'); Adapter = $Adapter; ReasonCode = $diagnostic.ReasonCode; DiagnosticCode = $diagnostic.DiagnosticCode; ExitCode = $diagnostic.ExitCode; OutputTail = $diagnostic.OutputTail; RawLogDirectory = $diagnostic.RawLogDirectory; ProbeReasonCode = if ($null -ne $lastProbe) { $lastProbe.ReasonCode } else { $null }; SecurityWarnings = if ($null -ne $preflight) { @($preflight.SecurityWarnings) } else { @() }; SetupState = if ($null -ne $preflight) { $preflight.SetupState } else { $null } }
    }
    throw 'omniroute-readiness-timeout'
}

function New-GatecraftOmniRouteInstallPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Version)

    if ($Version -cnotmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') { throw 'omniroute-version-invalid' }
    $npm = if ($IsWindows) {
        Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue
    } else {
        Get-Command npm -CommandType Application -ErrorAction SilentlyContinue
    }
    if ($null -eq $npm) { throw 'omniroute-npm-unavailable' }
    $package = "omniroute@$Version"
    return New-GatecraftOmniRouteResult @{
        Source = 'https://www.npmjs.com/package/omniroute'
        Version = $Version
        Executable = $npm.Source
        Arguments = @('install', '--global', $package, '--include=optional')
        DisplayCommand = "npm install --global $package --include=optional"
    }
}

function New-GatecraftOmniRouteSourceBuildPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Target)

    if (-not (Test-GatecraftOmniRouteSourceCheckout -Path $Target -Mode dev)) { throw 'omniroute-source-checkout-invalid' }
    $root = [IO.Path]::GetFullPath($Target)
    $package = [IO.File]::ReadAllText((Join-Path $root 'package.json')) | ConvertFrom-Json -Depth 10 -ErrorAction Stop
    if ($null -eq $package.scripts -or $null -eq $package.scripts.PSObject.Properties['build']) { throw 'omniroute-source-build-unavailable' }
    $runner = Join-Path $root 'scripts/build/build-next-isolated.mjs'
    if (-not [IO.File]::Exists($runner)) { throw 'omniroute-source-build-runner-unavailable' }
    $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $node) { throw 'omniroute-node-unavailable' }
    return New-GatecraftOmniRouteResult @{
        Target = $root
        Runner = $runner
        RunnerSha256 = (Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash
        Node = $node.Source
        NodeSha256 = (Get-FileHash -LiteralPath $node.Source -Algorithm SHA256).Hash
        DisplayCommand = 'node scripts/build/build-next-isolated.mjs'
        Mutates = '.build/next'
        RequiresDirectConfirmation = $true
    }
}

function Build-GatecraftOmniRouteSourceCheckout {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string] $Target,
        [Parameter(Mandatory)][string] $ExpectedRunnerSha256,
        [Parameter(Mandatory)][string] $ExpectedNodeSha256,
        [Parameter(Mandatory)][bool] $UserConfirmed,
        [ValidateRange(60, 1800)][int] $TimeoutSeconds = 900
    )

    if (-not $UserConfirmed) { throw 'omniroute-build-direct-confirmation-required' }
    $plan = New-GatecraftOmniRouteSourceBuildPlan -Target $Target
    if ($ExpectedRunnerSha256 -cnotmatch '^[A-Fa-f0-9]{64}$' -or $ExpectedNodeSha256 -cnotmatch '^[A-Fa-f0-9]{64}$' -or
        $plan.RunnerSha256 -cne $ExpectedRunnerSha256.ToUpperInvariant() -or $plan.NodeSha256 -cne $ExpectedNodeSha256.ToUpperInvariant()) {
        throw 'omniroute-build-plan-identity-drift'
    }
    if (-not $PSCmdlet.ShouldProcess($plan.Target, $plan.DisplayCommand)) { return }
    try {
        $host = Start-GatecraftOmniRouteSourceProcessHost -Purpose source-build -NodePath $plan.Node -RunnerPath $plan.Runner -WorkingDirectory $plan.Target
    } catch {
        return New-GatecraftOmniRouteResult @{ State = 'failed'; ReasonCode = 'process-host-launch-failed'; DiagnosticCode = 'process-host-launch-failed'; ExitCode = $null; OutputTail = @(); RawLogDirectory = $null }
    }
    $observed = [Collections.Generic.Dictionary[int, long]]::new()
    $observationComplete = Update-GatecraftOmniRouteObservedDescendants -RootId $host.Process.Id -Observed $observed
    $deadline = [datetimeoffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not $host.Process.HasExited -and [datetimeoffset]::UtcNow -lt $deadline) {
        $observationComplete = (Update-GatecraftOmniRouteObservedDescendants -RootId $host.Process.Id -Observed $observed) -and $observationComplete
        Start-Sleep -Milliseconds 250
    }
    if (-not $host.Process.HasExited) {
        Stop-GatecraftOmniRouteTrackedTree -RootProcess $host.Process -Observed $observed -ObservationComplete $observationComplete
        $diagnostic = Get-GatecraftOmniRouteProcessDiagnostic -LogDirectory $host.LogDirectory -ResultPath $host.ResultPath -FallbackReasonCode 'build-timeout'
        return New-GatecraftOmniRouteResult @{ State = 'failed'; ReasonCode = $diagnostic.ReasonCode; DiagnosticCode = $diagnostic.DiagnosticCode; ExitCode = $diagnostic.ExitCode; OutputTail = $diagnostic.OutputTail; RawLogDirectory = $diagnostic.RawLogDirectory }
    }
    Stop-GatecraftOmniRouteTrackedTree -RootProcess $host.Process -Observed $observed -ObservationComplete $observationComplete
    $diagnostic = Get-GatecraftOmniRouteProcessDiagnostic -LogDirectory $host.LogDirectory -ResultPath $host.ResultPath -FallbackReasonCode 'build-failed'
    if ($diagnostic.ExitCode -ne 0) {
        return New-GatecraftOmniRouteResult @{ State = 'failed'; ReasonCode = $diagnostic.ReasonCode; DiagnosticCode = $diagnostic.DiagnosticCode; ExitCode = $diagnostic.ExitCode; OutputTail = $diagnostic.OutputTail; RawLogDirectory = $diagnostic.RawLogDirectory }
    }
    $preflight = Get-GatecraftOmniRouteSourcePreflight -Target $plan.Target -Mode start
    if ($preflight.Decision -cne 'ready') {
        return New-GatecraftOmniRouteResult @{ State = 'failed'; ReasonCode = 'build-output-missing'; DiagnosticCode = $preflight.ReasonCode; ExitCode = 0; OutputTail = $diagnostic.OutputTail; RawLogDirectory = $diagnostic.RawLogDirectory }
    }
    return New-GatecraftOmniRouteResult @{ State = 'built'; ReasonCode = 'production-build-ready'; Target = $plan.Target; RawLogDirectory = $diagnostic.RawLogDirectory }
}

function Get-GatecraftOmniRouteInstallRoot {
    [CmdletBinding()]
    param([string] $NpmPath)

    $npm = if (-not [string]::IsNullOrWhiteSpace($NpmPath)) {
        $NpmPath
    } else {
        $resolved = if ($IsWindows) {
            Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue
        } else {
            Get-Command npm -CommandType Application -ErrorAction SilentlyContinue
        }
        if ($null -eq $resolved) { throw 'omniroute-npm-unavailable' }
        $resolved.Source
    }
    if ($npm -cmatch '(?i)\.ps1$') { throw 'omniroute-npm-unavailable' }
    $probe = Invoke-GatecraftOmniRouteProcess -FilePath $npm -Arguments @('root', '--global') -TimeoutMilliseconds 30000
    if ($probe.TimedOut -or $probe.ExitCode -ne 0) { throw 'omniroute-npm-root-unavailable' }
    $globalRoot = @($probe.Stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)[0]
    if ($null -eq $globalRoot) { throw 'omniroute-npm-root-unavailable' }
    $globalRoot = $globalRoot.Trim()
    if (-not [IO.Directory]::Exists($globalRoot)) { throw 'omniroute-npm-root-unavailable' }
    $packageRoot = Join-Path $globalRoot 'omniroute'
    if (-not [IO.Directory]::Exists($packageRoot)) { throw 'omniroute-install-root-missing' }
    return [IO.Path]::GetFullPath($packageRoot)
}

# npm 11.16+ defers install scripts it has not been told to allow, and `npm approve-scripts` refuses
# global installs outright (EGLOBAL), so a global `npm install omniroute` exits 0 while omniroute's own
# postinstall never ran. That postinstall only copies already-downloaded platform-native binaries into
# the standalone bundle, so running it explicitly afterwards is idempotent and needs no build toolchain.
function Invoke-GatecraftOmniRoutePostinstall {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $PackageRoot,
        [ValidateRange(1000, 600000)][int] $TimeoutMilliseconds = 600000
    )

    $root = [IO.Path]::GetFullPath($PackageRoot)
    if (-not [IO.Directory]::Exists($root)) { throw 'omniroute-install-root-missing' }
    $runner = Join-Path $root 'scripts/build/postinstall.mjs'
    if (-not [IO.File]::Exists($runner)) {
        return New-GatecraftOmniRouteResult @{ Ran = $false; ReasonCode = 'postinstall-runner-absent'; ExitCode = 0 }
    }
    $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $node) { throw 'omniroute-node-unavailable' }
    if (-not $PSCmdlet.ShouldProcess($runner, 'Run the OmniRoute package postinstall')) {
        return New-GatecraftOmniRouteResult @{ Ran = $false; ReasonCode = 'postinstall-declined'; ExitCode = 0 }
    }
    $run = Invoke-GatecraftOmniRouteProcess -FilePath $node.Source -Arguments @($runner) -WorkingDirectory $root -TimeoutMilliseconds $TimeoutMilliseconds
    if ($run.TimedOut) { return New-GatecraftOmniRouteResult @{ Ran = $false; ReasonCode = 'postinstall-timeout'; ExitCode = -1 } }
    $reasonCode = if ($run.ExitCode -eq 0) { 'postinstall-complete' } else { 'postinstall-failed' }
    # The runner's own narrative is deliberately not projected or trusted: on Windows its wreq-js branch
    # reports a false negative ("OAuth providers may not work") for a binary that is present and loads,
    # and its output embeds user-home paths. Test-GatecraftOmniRouteInstallHealth decides instead.
    return New-GatecraftOmniRouteResult @{ Ran = $true; ReasonCode = $reasonCode; ExitCode = $run.ExitCode }
}

function Test-GatecraftOmniRouteInstallHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $PackageRoot,
        [string] $ExpectedVersion,
        [string[]] $NativeModules = @('better-sqlite3', 'wreq-js')
    )

    $root = [IO.Path]::GetFullPath($PackageRoot)
    if (-not [IO.Directory]::Exists($root)) { throw 'omniroute-install-root-missing' }
    $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $node) { throw 'omniroute-node-unavailable' }
    $checks = [Collections.Generic.List[object]]::new()
    $healthy = $true
    $reasonCode = 'install-healthy'

    $native = Get-GatecraftOmniRouteNativeCommand
    if ($null -eq $native) {
        $healthy = $false
        $reasonCode = 'cli-unavailable'
        $checks.Add([pscustomobject]@{ Check = 'cli'; Scope = 'path'; Passed = $false })
    } else {
        $versionRun = Invoke-GatecraftOmniRouteProcess -FilePath $native.Source -Arguments @('--version') -TimeoutMilliseconds 30000
        # Only the parsed semver is projected. The command also prints the resolved .env path, which is user-home-shaped.
        $observedVersion = @($versionRun.Stdout -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -cmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$' } | Select-Object -First 1)[0]
        $versionPassed = -not $versionRun.TimedOut -and $versionRun.ExitCode -eq 0 -and $null -ne $observedVersion
        if ($versionPassed -and -not [string]::IsNullOrWhiteSpace($ExpectedVersion)) { $versionPassed = $observedVersion -ceq $ExpectedVersion }
        $checks.Add([pscustomobject]@{ Check = 'cli'; Scope = 'path'; Passed = $versionPassed; Version = $observedVersion })
        if (-not $versionPassed) { $healthy = $false; $reasonCode = 'cli-version-mismatch' }
    }

    # The standalone bundle under dist/ resolves its own node_modules, so a module that loads from the
    # package root proves nothing about the runtime that actually serves /v1/models. Check both.
    $scopes = [ordered]@{ root = $root }
    $dist = Join-Path $root 'dist'
    if ([IO.Directory]::Exists($dist)) { $scopes['dist'] = $dist }
    foreach ($scopeName in $scopes.Keys) {
        foreach ($moduleName in $NativeModules) {
            if ($moduleName -cnotmatch '^[@A-Za-z0-9][A-Za-z0-9._/-]*$') { throw 'omniroute-health-module-invalid' }
            $run = Invoke-GatecraftOmniRouteProcess -FilePath $node.Source -Arguments @('-e', "require('$moduleName')") -WorkingDirectory $scopes[$scopeName] -TimeoutMilliseconds 30000
            $passed = -not $run.TimedOut -and $run.ExitCode -eq 0
            $checks.Add([pscustomobject]@{ Check = 'native-module'; Scope = $scopeName; Module = $moduleName; Passed = $passed })
            if (-not $passed) { $healthy = $false; $reasonCode = 'native-module-unloadable' }
        }
    }

    return New-GatecraftOmniRouteResult @{ Healthy = $healthy; ReasonCode = $reasonCode; PackageRoot = $root; Checks = @($checks) }
}

function Install-GatecraftOmniRoute {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string] $Version,
        [Parameter(Mandatory)][bool] $UserConfirmed
    )

    if (-not $UserConfirmed) { throw 'omniroute-install-direct-confirmation-required' }
    $plan = New-GatecraftOmniRouteInstallPlan -Version $Version
    if (-not $PSCmdlet.ShouldProcess($plan.DisplayCommand, 'Install OmniRoute from the official npm package')) { return }
    & $plan.Executable @($plan.Arguments)
    if ($LASTEXITCODE -ne 0) { throw "omniroute-install-failed:$LASTEXITCODE" }
    $installed = Get-GatecraftOmniRouteNativeCommand
    if ($null -eq $installed) { throw 'omniroute-install-verification-failed' }
    $packageRoot = Get-GatecraftOmniRouteInstallRoot -NpmPath $plan.Executable
    $postinstall = Invoke-GatecraftOmniRoutePostinstall -PackageRoot $packageRoot -Confirm:$false
    $health = Test-GatecraftOmniRouteInstallHealth -PackageRoot $packageRoot -ExpectedVersion $Version
    if (-not $health.Healthy) { throw "omniroute-install-health-failed:$($health.ReasonCode)" }
    return New-GatecraftOmniRouteResult @{
        Installed = $true
        Version = $Version
        Command = $installed.Source
        PackageRoot = $packageRoot
        PostinstallRan = $postinstall.Ran
        PostinstallReasonCode = $postinstall.ReasonCode
        PostinstallExitCode = $postinstall.ExitCode
        Healthy = $true
        Checks = $health.Checks
    }
}

Export-ModuleMember -Function @(
    'Get-GatecraftOmniRouteRuntimeIdentity',
    'Test-GatecraftOmniRouteEndpointUri',
    'Get-GatecraftOmniRouteGlobalPreferencePath',
    'Get-GatecraftOmniRouteStartupAdapterPath',
    'Test-GatecraftOmniRouteSourceCheckout',
    'Get-GatecraftOmniRouteSourcePreflight',
    'Find-GatecraftOmniRouteSourceCheckouts',
    'Find-GatecraftOmniRouteStartupAdapters',
    'Test-GatecraftOmniRouteStartupAdapterRecord',
    'Read-GatecraftOmniRouteStartupAdapter',
    'Register-GatecraftOmniRouteStartupAdapter',
    'Read-GatecraftOmniRoutePreferences',
    'Write-GatecraftOmniRoutePreferences',
    'Get-GatecraftOmniRouteProjectPolicy',
    'Set-GatecraftOmniRouteProjectPolicy',
    'Resolve-GatecraftOmniRouteUsePolicy',
    'Resolve-GatecraftOmniRouteInstallDecision',
    'Test-GatecraftOmniRouteEndpoint',
    'Resolve-GatecraftOmniRouteObservedState',
    'Get-GatecraftOmniRouteInstallRoot',
    'Invoke-GatecraftOmniRoutePostinstall',
    'Test-GatecraftOmniRouteInstallHealth',
    'Get-GatecraftOmniRouteStatus',
    'Test-GatecraftOmniRouteInstanceUnconfigured',
    'Test-GatecraftOmniRouteModelLane',
    'New-GatecraftOmniRouteLaneProbeBody',
    'Get-GatecraftOmniRouteDashboardUrl',
    'Get-GatecraftOmniRouteOnboarding',
    'Start-GatecraftOmniRoute',
    'Test-GatecraftOmniRouteLoopbackListener',
    'New-GatecraftOmniRouteSourceBuildPlan',
    'Build-GatecraftOmniRouteSourceCheckout',
    'New-GatecraftOmniRouteInstallPlan',
    'Install-GatecraftOmniRoute'
)
