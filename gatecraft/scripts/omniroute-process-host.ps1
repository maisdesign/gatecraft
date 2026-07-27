[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('source-start', 'source-build')][string] $Purpose,
    [Parameter(Mandatory)][string] $NodePath,
    [Parameter(Mandatory)][string] $RunnerPath,
    [Parameter(Mandatory)][string] $WorkingDirectory,
    [Parameter(Mandatory)][string] $ExpectedNodeSha256,
    [Parameter(Mandatory)][string] $ExpectedRunnerSha256,
    [Parameter(Mandatory)][string] $LogDirectory,
    [Parameter(Mandatory)][string] $ResultPath,
    [ValidateSet('start', 'dev')][string] $Mode = 'dev',
    [ValidateRange(1, 65535)][int] $Port = 20128,
    [ValidateRange(16384, 1048576)][int] $MaxFileBytes = 65536
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-HostResult {
    param([Nullable[int]] $ExitCode, [string] $ReasonCode, [Nullable[int]] $ChildProcessId)
    $result = [ordered]@{
        protocol = 'gatecraft-omniroute-process-result/v1'
        purpose = $Purpose
        exit_code = $ExitCode
        reason_code = $ReasonCode
        child_process_id = $ChildProcessId
    }
    $temporaryResult = $ResultPath + '.tmp'
    [IO.File]::WriteAllText($temporaryResult, ($result | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporaryResult, $ResultPath, $true)
}

function Open-RotatingStream {
    param([Parameter(Mandatory)][string] $Path)
    return [IO.FileStream]::new($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
}

function Write-RotatingChunk {
    param(
        [Parameter(Mandatory)][ref] $StreamReference,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][char[]] $Buffer,
        [Parameter(Mandatory)][int] $Count
    )
    if ($Count -le 0) { return }
    $text = [string]::new($Buffer, 0, $Count)
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    try {
        if ($StreamReference.Value.Length + $bytes.Length -gt $MaxFileBytes) {
            $StreamReference.Value.Dispose()
            $previousPath = $Path + '.previous'
            if ([IO.File]::Exists($previousPath)) { [IO.File]::Delete($previousPath) }
            if ([IO.File]::Exists($Path)) { [IO.File]::Move($Path, $previousPath) }
            $StreamReference.Value = Open-RotatingStream -Path $Path
        }
        $offset = [Math]::Max(0, $bytes.Length - $MaxFileBytes)
        $StreamReference.Value.Write($bytes, $offset, $bytes.Length - $offset)
        $StreamReference.Value.Flush()
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

$child = $null
$stdoutStream = $null
$stderrStream = $null
try {
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $resolvedLogDirectory = [IO.Path]::GetFullPath($LogDirectory)
    $resolvedResultPath = [IO.Path]::GetFullPath($ResultPath)
    $expectedLogParent = [IO.Path]::TrimEndingDirectorySeparator($systemTemp)
    $actualLogParent = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetDirectoryName($resolvedLogDirectory))
    if ($actualLogParent -cne $expectedLogParent -or
        [IO.Path]::GetFileName($resolvedLogDirectory) -cnotmatch '^gatecraft-omniroute-process-[a-f0-9]{32}$' -or
        $resolvedResultPath -cne (Join-Path $resolvedLogDirectory 'result.json')) {
        throw 'host-output-path-invalid'
    }
    [IO.Directory]::CreateDirectory($resolvedLogDirectory) | Out-Null

    $resolvedNode = [IO.Path]::GetFullPath($NodePath)
    $resolvedRunner = [IO.Path]::GetFullPath($RunnerPath)
    $resolvedWorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    $expectedRunnerRelative = if ($Purpose -ceq 'source-start') { 'scripts/dev/run-next.mjs' } else { 'scripts/build/build-next-isolated.mjs' }
    $expectedRunner = [IO.Path]::GetFullPath((Join-Path $resolvedWorkingDirectory $expectedRunnerRelative))
    if ($resolvedRunner -cne $expectedRunner -or -not [IO.File]::Exists($resolvedNode) -or -not [IO.File]::Exists($resolvedRunner)) { throw 'host-launcher-invalid' }
    if ((Get-FileHash -LiteralPath $resolvedNode -Algorithm SHA256).Hash -cne $ExpectedNodeSha256 -or
        (Get-FileHash -LiteralPath $resolvedRunner -Algorithm SHA256).Hash -cne $ExpectedRunnerSha256) {
        throw 'host-launcher-identity-drift'
    }

    $stdoutPath = Join-Path $resolvedLogDirectory 'stdout.log'
    $stderrPath = Join-Path $resolvedLogDirectory 'stderr.log'
    $stdoutStream = Open-RotatingStream -Path $stdoutPath
    $stderrStream = Open-RotatingStream -Path $stderrPath

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $resolvedNode
    $startInfo.WorkingDirectory = $resolvedWorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($Purpose -ceq 'source-start') {
        $startInfo.ArgumentList.Add('--max-old-space-size=8192')
        $startInfo.ArgumentList.Add($resolvedRunner)
        $startInfo.ArgumentList.Add($Mode)
        $startInfo.Environment['HOST'] = '127.0.0.1'
        $startInfo.Environment['PORT'] = [string]$Port
        $startInfo.Environment['API_PORT'] = [string]$Port
        $startInfo.Environment['DASHBOARD_PORT'] = [string]$Port
        $startInfo.Environment['OMNIROUTE_PORT'] = [string]$Port
    } else {
        $startInfo.ArgumentList.Add($resolvedRunner)
    }

    $child = [Diagnostics.Process]::new()
    $child.StartInfo = $startInfo
    if (-not $child.Start()) { throw 'host-child-start-failed' }

    $stdoutBuffer = [char[]]::new(2048)
    $stderrBuffer = [char[]]::new(2048)
    $stdoutTask = $child.StandardOutput.ReadAsync($stdoutBuffer, 0, $stdoutBuffer.Length)
    $stderrTask = $child.StandardError.ReadAsync($stderrBuffer, 0, $stderrBuffer.Length)
    $stdoutComplete = $false
    $stderrComplete = $false
    while (-not ($child.HasExited -and $stdoutComplete -and $stderrComplete)) {
        if (-not $stdoutComplete -and $stdoutTask.IsCompleted) {
            $count = $stdoutTask.GetAwaiter().GetResult()
            if ($count -eq 0) { $stdoutComplete = $true } else {
                Write-RotatingChunk -StreamReference ([ref]$stdoutStream) -Path $stdoutPath -Buffer $stdoutBuffer -Count $count
                $stdoutTask = $child.StandardOutput.ReadAsync($stdoutBuffer, 0, $stdoutBuffer.Length)
            }
        }
        if (-not $stderrComplete -and $stderrTask.IsCompleted) {
            $count = $stderrTask.GetAwaiter().GetResult()
            if ($count -eq 0) { $stderrComplete = $true } else {
                Write-RotatingChunk -StreamReference ([ref]$stderrStream) -Path $stderrPath -Buffer $stderrBuffer -Count $count
                $stderrTask = $child.StandardError.ReadAsync($stderrBuffer, 0, $stderrBuffer.Length)
            }
        }
        if (-not ($child.HasExited -and $stdoutComplete -and $stderrComplete)) { Start-Sleep -Milliseconds 25 }
    }
    $child.WaitForExit()
    Write-HostResult -ExitCode $child.ExitCode -ReasonCode 'child-exited' -ChildProcessId $child.Id
    exit $child.ExitCode
} catch {
    try { Write-HostResult -ExitCode $null -ReasonCode 'process-host-failed' -ChildProcessId $(if ($null -ne $child) { $child.Id } else { $null }) } catch { }
    exit 125
} finally {
    if ($null -ne $stdoutStream) { $stdoutStream.Dispose() }
    if ($null -ne $stderrStream) { $stderrStream.Dispose() }
    if ($null -ne $child) { $child.Dispose() }
}
