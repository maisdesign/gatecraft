Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-GuardUsage {
    [Console]::Out.WriteLine(@'
Usage:
  guard.ps1 acquire --repository-root <absolute-path> --owner-token <opaque-token> --pid <positive-decimal> --process-start <canonical-UTC>
  guard.ps1 release --repository-root <absolute-path> --owner-token <opaque-token> --pid <positive-decimal> --process-start <canonical-UTC>
  guard.ps1 baseline --repository-root <absolute-path> --state-root <absolute-path> --baseline-id <stable-id> --owned-paths-json <JSON-array> --process-manifest-json <JSON-array>
  guard.ps1 sweep --repository-root <absolute-path> --state-root <absolute-path> --baseline-id <stable-id>

Canonical process timestamps use yyyy-MM-ddTHH:mm:ss.fffffffZ.
Owner tokens use 32-128 ASCII letters, digits, underscore, or hyphen.

Test-only acquire barrier:
  --test-acquire-barrier <absolute-existing-directory> --test-participant <stable-id> --test-timeout-ms <100-30000>
  All three options require GATECRAFT_GUARD_TEST_CONTROLS=1.
'@)
}

function Stop-Guard {
    param([Parameter(Mandatory)][int] $ExitCode, [Parameter(Mandatory)][string] $Code)
    [Console]::Error.WriteLine("GUARD_FAILED code=$Code")
    exit $ExitCode
}

function Get-GuardExitCode {
    param([Parameter(Mandatory)][string] $Code)
    if ($Code -match '^argument-|^powershell-') { return 64 }
    if ($Code -match '^git-|^repository-|^path-|^state-root-|^guard-root-') { return 69 }
    if ($Code -match '^lock-') { return 73 }
    if ($Code -match '^baseline-exists$') { return 74 }
    if ($Code -match '^sweep-|^main-moved$|^foreign-change$') { return 75 }
    if ($Code -match '^process-') { return 76 }
    return 65
}

function Read-GuardArguments {
    param([Parameter(Mandatory)][object[]] $Tokens)
    if ($Tokens.Count -eq 1 -and [string]$Tokens[0] -ceq '--help') { Write-GuardUsage; exit 0 }
    if ($Tokens.Count -lt 1) { throw 'argument-command-required' }
    $command = [string]$Tokens[0]
    if ($command -cnotin @('acquire', 'release', 'baseline', 'sweep')) { throw 'argument-command-invalid' }
    $allowedByCommand = @{
        acquire = @('--repository-root', '--owner-token', '--pid', '--process-start', '--test-acquire-barrier', '--test-participant', '--test-timeout-ms')
        release = @('--repository-root', '--owner-token', '--pid', '--process-start')
        baseline = @('--repository-root', '--state-root', '--baseline-id', '--owned-paths-json', '--process-manifest-json')
        sweep = @('--repository-root', '--state-root', '--baseline-id')
    }
    $requiredByCommand = @{
        acquire = @('--repository-root', '--owner-token', '--pid', '--process-start')
        release = @('--repository-root', '--owner-token', '--pid', '--process-start')
        baseline = @('--repository-root', '--state-root', '--baseline-id', '--owned-paths-json', '--process-manifest-json')
        sweep = @('--repository-root', '--state-root', '--baseline-id')
    }
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $allowedByCommand[$command]) { [void]$allowed.Add($name) }
    $values = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $index = 1
    while ($index -lt $Tokens.Count) {
        $name = [string]$Tokens[$index]
        if (-not $allowed.Contains($name)) { throw 'argument-unknown' }
        if ($values.ContainsKey($name)) { throw 'argument-duplicate' }
        if ($index + 1 -ge $Tokens.Count) { throw 'argument-missing-value' }
        $value = [string]$Tokens[$index + 1]
        if ($value.StartsWith('--', [StringComparison]::Ordinal)) { throw 'argument-missing-value' }
        $values.Add($name, $value)
        $index += 2
    }
    foreach ($required in $requiredByCommand[$command]) {
        if (-not $values.ContainsKey($required)) { throw 'argument-required' }
    }
    return [pscustomobject]@{ Command = $command; Values = $values }
}

function Assert-NotReparsePoint {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Code)
    foreach ($candidate in @([IO.FileInfo]::new($Path), [IO.DirectoryInfo]::new($Path))) {
        try { if (-not [string]::IsNullOrEmpty($candidate.LinkTarget)) { throw $Code } }
        catch [IO.FileNotFoundException] { }
        catch [IO.DirectoryNotFoundException] { }
    }
    if (-not [IO.File]::Exists($Path) -and -not [IO.Directory]::Exists($Path)) { return }
    if (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw $Code }
}

function ConvertTo-LocalFullPath {
    param(
        [Parameter(Mandatory)][string] $DeclaredPath,
        [Parameter(Mandatory)][string] $InvalidCode,
        [Parameter(Mandatory)][string] $NonLocalCode
    )
    if ([string]::IsNullOrWhiteSpace($DeclaredPath) -or $DeclaredPath -match '[\x00-\x1F\x7F*?]' -or -not $DeclaredPath.IsNormalized([Text.NormalizationForm]::FormC) -or -not [IO.Path]::IsPathFullyQualified($DeclaredPath)) { throw $InvalidCode }
    foreach ($segment in @($DeclaredPath -split '[\\/]')) {
        if ($segment -in @('.', '..') -or $segment.EndsWith(' ', [StringComparison]::Ordinal) -or $segment.EndsWith('.', [StringComparison]::Ordinal)) { throw $InvalidCode }
    }
    $fullPath = [IO.Path]::GetFullPath($DeclaredPath)
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrEmpty($pathRoot)) { throw $InvalidCode }
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        if ($DeclaredPath.StartsWith('\\', [StringComparison]::Ordinal) -or $DeclaredPath.StartsWith('//', [StringComparison]::Ordinal) -or $DeclaredPath.StartsWith('\\?\', [StringComparison]::Ordinal) -or $DeclaredPath.StartsWith('\\.\', [StringComparison]::Ordinal)) { throw $NonLocalCode }
    }
    try {
        $drive = $null
        foreach ($candidateDrive in [IO.DriveInfo]::GetDrives()) {
            if (-not (Test-PathAtOrBelow -Candidate $fullPath -Parent $candidateDrive.Name)) { continue }
            if ($null -eq $drive -or $candidateDrive.Name.Length -gt $drive.Name.Length -or ($candidateDrive.Name.Length -eq $drive.Name.Length -and [StringComparer]::Ordinal.Compare($candidateDrive.Name, $drive.Name) -lt 0)) {
                $drive = $candidateDrive
            }
        }
    }
    catch { throw $NonLocalCode }
    if ($null -eq $drive -or -not $drive.IsReady -or $drive.DriveType -cnotin @([IO.DriveType]::Fixed, [IO.DriveType]::Removable, [IO.DriveType]::Ram)) { throw $NonLocalCode }
    return $fullPath
}

function Assert-SafePathComponents {
    param([Parameter(Mandatory)][string] $FullPath, [Parameter(Mandatory)][string] $ReparseCode)
    $root = [IO.Path]::GetPathRoot($FullPath)
    Assert-NotReparsePoint -Path $root -Code $ReparseCode
    $current = $root
    $relative = $FullPath.Substring($root.Length)
    foreach ($segment in @($relative -split '[\\/]' | Where-Object { $_.Length -gt 0 })) {
        $current = [IO.Path]::Combine($current, $segment)
        Assert-NotReparsePoint -Path $current -Code $ReparseCode
    }
}

function Initialize-SafeDirectory {
    param([string] $FullPath, [string] $InvalidCode, [string] $ReparseCode)
    Assert-SafePathComponents -FullPath $FullPath -ReparseCode $ReparseCode
    if ([IO.File]::Exists($FullPath) -and -not [IO.Directory]::Exists($FullPath)) { throw $InvalidCode }
    [void][IO.Directory]::CreateDirectory($FullPath)
    if (-not [IO.Directory]::Exists($FullPath)) { throw $InvalidCode }
    Assert-SafePathComponents -FullPath $FullPath -ReparseCode $ReparseCode
}

function Test-PathEqual {
    param([string] $Left, [string] $Right)
    $comparison = if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return $Left.Equals($Right, $comparison)
}

function Test-PathAtOrBelow {
    param([string] $Candidate, [string] $Parent)
    $comparison = if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if ($Candidate.Equals($Parent, $comparison)) { return $true }
    $prefix = $Parent.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    return $Candidate.StartsWith($prefix, $comparison)
}

function Invoke-GitBytes {
    param([string] $RepositoryRoot, [string[]] $Arguments, [string] $FailureCode)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $RepositoryRoot
    $start.Environment['GIT_OPTIONAL_LOCKS'] = '0'
    $start.Environment['LC_ALL'] = 'C'
    $start.Environment['LANG'] = 'C'
    $start.ArgumentList.Add('-C')
    $start.ArgumentList.Add($RepositoryRoot)
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $memory = [IO.MemoryStream]::new()
    try {
        if (-not $process.Start()) { throw $FailureCode }
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [void]$stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw $FailureCode }
        return ,$memory.ToArray()
    }
    catch [ComponentModel.Win32Exception] { throw $FailureCode }
    finally { $memory.Dispose(); $process.Dispose() }
}

function ConvertFrom-GitLine {
    param([byte[]] $Bytes, [string] $FailureCode)
    $length = $Bytes.Length
    if ($length -gt 0 -and $Bytes[$length - 1] -eq 0x0A) {
        $length--
        if ($length -gt 0 -and $Bytes[$length - 1] -eq 0x0D) { $length-- }
    }
    if ($length -eq 0) { throw $FailureCode }
    for ($i = 0; $i -lt $length; $i++) { if ($Bytes[$i] -in @(0x00, 0x0A, 0x0D)) { throw $FailureCode } }
    try { return [Text.UTF8Encoding]::new($false, $true).GetString($Bytes, 0, $length) }
    catch [Text.DecoderFallbackException] { throw $FailureCode }
}

function Get-RepositoryContext {
    param([Parameter(Mandatory)][string] $DeclaredRoot)
    $root = ConvertTo-LocalFullPath -DeclaredPath $DeclaredRoot -InvalidCode 'repository-root-invalid' -NonLocalCode 'repository-nonlocal'
    if (-not [IO.Directory]::Exists($root)) { throw 'repository-root-missing' }
    Assert-SafePathComponents -FullPath $root -ReparseCode 'path-reparse'
    $inside = ConvertFrom-GitLine -Bytes (Invoke-GitBytes -RepositoryRoot $root -Arguments @('rev-parse', '--is-inside-work-tree') -FailureCode 'git-repository-failed') -FailureCode 'git-output-invalid'
    if ($inside -cne 'true') { throw 'repository-worktree-required' }
    $topText = ConvertFrom-GitLine -Bytes (Invoke-GitBytes -RepositoryRoot $root -Arguments @('rev-parse', '--path-format=absolute', '--show-toplevel') -FailureCode 'git-toplevel-failed') -FailureCode 'git-output-invalid'
    $top = ConvertTo-LocalFullPath -DeclaredPath $topText -InvalidCode 'repository-root-invalid' -NonLocalCode 'repository-nonlocal'
    if (-not (Test-PathEqual -Left $root -Right $top)) { throw 'repository-root-not-toplevel' }
    Assert-SafePathComponents -FullPath $top -ReparseCode 'path-reparse'
    $commonText = ConvertFrom-GitLine -Bytes (Invoke-GitBytes -RepositoryRoot $root -Arguments @('rev-parse', '--path-format=absolute', '--git-common-dir') -FailureCode 'git-common-dir-failed') -FailureCode 'git-output-invalid'
    $common = ConvertTo-LocalFullPath -DeclaredPath $commonText -InvalidCode 'git-common-dir-invalid' -NonLocalCode 'repository-nonlocal'
    if (-not [IO.Directory]::Exists($common)) { throw 'git-common-dir-invalid' }
    Assert-SafePathComponents -FullPath $common -ReparseCode 'path-reparse'
    return [pscustomobject]@{ RepositoryRoot = $top; GitCommonDir = $common }
}

function ConvertTo-CanonicalProcessStart {
    param([Parameter(Mandatory)][string] $Value)
    if ($Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') { throw 'process-start-invalid' }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact($Value, "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed)) { throw 'process-start-invalid' }
    $canonical = $parsed.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    if ($canonical -cne $Value) { throw 'process-start-invalid' }
    return $canonical
}

function ConvertTo-PositivePid {
    param([Parameter(Mandatory)][string] $Value)
    [int]$pidValue = 0
    if ($Value -notmatch '^[1-9][0-9]{0,9}$' -or -not [int]::TryParse($Value, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$pidValue) -or $pidValue -lt 1) { throw 'process-pid-invalid' }
    return $pidValue
}

function Get-ProcessBindingState {
    param([int] $ProcessId, [string] $ExpectedStart)
    $process = $null
    try {
        $process = [Diagnostics.Process]::GetProcessById($ProcessId)
        if ($process.HasExited) { return 'process-dead' }
        $actual = $process.StartTime.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        if ($actual -cne $ExpectedStart) { return 'process-start-mismatch' }
        return 'ok'
    }
    catch [ArgumentException] { return 'process-dead' }
    catch { return 'process-unverifiable' }
    finally { if ($null -ne $process) { $process.Dispose() } }
}

function Assert-LiveProcessBinding {
    param([int] $ProcessId, [string] $ExpectedStart)
    $state = Get-ProcessBindingState -ProcessId $ProcessId -ExpectedStart $ExpectedStart
    if ($state -cne 'ok') { throw $state }
}

function ConvertTo-CanonicalJson {
    param([Parameter(Mandatory)][object] $Value, [int] $Depth = 8)
    return ConvertTo-Json -InputObject $Value -Depth $Depth -Compress -EscapeHandling EscapeNonAscii
}

function Sort-OrdinalStrings {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Values)
    [string[]]$sorted = @($Values)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return $sorted
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Read-StrictUtf8File {
    param([string] $Path, [string] $FailureCode, [long] $MaximumBytes)
    Assert-NotReparsePoint -Path $Path -Code 'path-reparse'
    if (-not [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) { throw $FailureCode }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0 -or $bytes.Length -gt $MaximumBytes) { throw $FailureCode }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { throw $FailureCode }
    try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
    catch [Text.DecoderFallbackException] { throw $FailureCode }
    if ($text.Contains("`r", [StringComparison]::Ordinal) -or $text.Contains("`n", [StringComparison]::Ordinal)) { throw $FailureCode }
    return [pscustomobject]@{ Bytes = $bytes; Text = $text }
}

function Get-ExactJsonFields {
    param([Text.Json.JsonElement] $Element, [string[]] $Names, [string] $FailureCode)
    if ($Element.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw $FailureCode }
    $allowed = [Collections.Generic.HashSet[string]]::new($Names, [StringComparer]::Ordinal)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $fields = [Collections.Generic.Dictionary[string,Text.Json.JsonElement]]::new([StringComparer]::Ordinal)
    foreach ($property in $Element.EnumerateObject()) {
        if (-not $allowed.Contains($property.Name) -or -not $seen.Add($property.Name)) { throw $FailureCode }
        $fields.Add($property.Name, $property.Value.Clone())
    }
    if ($seen.Count -ne $allowed.Count) { throw $FailureCode }
    return ,$fields
}

function New-LockRecord {
    param([string] $OwnerToken, [int] $ProcessId, [string] $ProcessStart)
    return [pscustomobject][ordered]@{
        owner_token = $OwnerToken
        pid = $ProcessId
        process_start = $ProcessStart
        protocol = 'gatecraft-local-lock/v1'
    }
}

function Read-LockRecord {
    param([Parameter(Mandatory)][string] $Path)
    $file = Read-StrictUtf8File -Path $Path -FailureCode 'lock-record-invalid' -MaximumBytes 4096
    try { $document = [Text.Json.JsonDocument]::Parse($file.Text) } catch { throw 'lock-record-invalid' }
    try {
        $fields = Get-ExactJsonFields -Element $document.RootElement -Names @('owner_token', 'pid', 'process_start', 'protocol') -FailureCode 'lock-record-invalid'
        foreach ($name in @('owner_token', 'process_start', 'protocol')) { if ($fields[$name].ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'lock-record-invalid' } }
        [int]$persistedPid = 0
        if ($fields['pid'].ValueKind -ne [Text.Json.JsonValueKind]::Number -or -not $fields['pid'].TryGetInt32([ref]$persistedPid) -or $persistedPid -lt 1) { throw 'lock-record-invalid' }
        $ownerToken = $fields['owner_token'].GetString()
        if ($ownerToken -notmatch '^[A-Za-z0-9_-]{32,128}$') { throw 'lock-record-invalid' }
        try { $start = ConvertTo-CanonicalProcessStart -Value $fields['process_start'].GetString() } catch { throw 'lock-record-invalid' }
        if ($fields['protocol'].GetString() -cne 'gatecraft-local-lock/v1') { throw 'lock-record-invalid' }
        $record = New-LockRecord -OwnerToken $ownerToken -ProcessId $persistedPid -ProcessStart $start
        if ((ConvertTo-CanonicalJson $record) -cne $file.Text) { throw 'lock-record-invalid' }
        return [pscustomobject]@{ Record = $record; Bytes = $file.Bytes; Text = $file.Text }
    }
    finally { $document.Dispose() }
}

function Get-GuardPaths {
    param([Parameter(Mandatory)][string] $GitCommonDir)
    $directory = [IO.Path]::Combine($GitCommonDir, 'gatecraft-local-guard-v1')
    return [pscustomobject]@{ Directory = $directory; Holder = [IO.Path]::Combine($directory, 'holder.json') }
}

function Assert-GuardDirectoryEntries {
    param([Parameter(Mandatory)][string] $Directory)
    Assert-NotReparsePoint -Path $Directory -Code 'guard-root-reparse'
    if (-not [IO.Directory]::Exists($Directory)) { throw 'guard-root-missing' }
    foreach ($entry in [IO.DirectoryInfo]::new($Directory).GetFileSystemInfos()) {
        if ($entry.Name -cne 'holder.json' -or $entry -isnot [IO.FileInfo]) { throw 'lock-unexpected-entry' }
        Assert-NotReparsePoint -Path $entry.FullName -Code 'guard-root-reparse'
    }
}

function Invoke-TestAcquireBarrier {
    param([Collections.Generic.Dictionary[string,string]] $Options)
    $selected = @(@('--test-acquire-barrier', '--test-participant', '--test-timeout-ms') | Where-Object { $Options.ContainsKey($_) })
    if ($selected.Count -eq 0) { return }
    if ($selected.Count -ne 3) { throw 'test-controls-incomplete' }
    if ([Environment]::GetEnvironmentVariable('GATECRAFT_GUARD_TEST_CONTROLS', [EnvironmentVariableTarget]::Process) -cne '1') { throw 'test-controls-disabled' }
    $participant = $Options['--test-participant']
    if ($participant -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw 'test-participant-invalid' }
    [int]$timeout = 0
    if ($Options['--test-timeout-ms'] -notmatch '^[1-9][0-9]{2,4}$' -or -not [int]::TryParse($Options['--test-timeout-ms'], [ref]$timeout) -or $timeout -lt 100 -or $timeout -gt 30000) { throw 'test-timeout-invalid' }
    $barrier = ConvertTo-LocalFullPath -DeclaredPath $Options['--test-acquire-barrier'] -InvalidCode 'test-barrier-invalid' -NonLocalCode 'test-barrier-nonlocal'
    if (-not [IO.Directory]::Exists($barrier)) { throw 'test-barrier-invalid' }
    Assert-SafePathComponents -FullPath $barrier -ReparseCode 'path-reparse'
    $ready = [IO.Path]::Combine($barrier, "ready-$participant")
    $stream = [IO.FileStream]::new($ready, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 1, [IO.FileOptions]::WriteThrough)
    $stream.Dispose()
    [Console]::Out.WriteLine("GUARD_TEST_READY participant=$participant")
    [Console]::Out.Flush()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $release = [IO.Path]::Combine($barrier, 'release')
    while (-not [IO.File]::Exists($release)) {
        if ($clock.ElapsedMilliseconds -ge $timeout) { throw 'test-barrier-timeout' }
        Start-Sleep -Milliseconds 20
    }
    Assert-NotReparsePoint -Path $release -Code 'path-reparse'
    if ([IO.Directory]::Exists($release)) { throw 'test-barrier-invalid' }
}

function Invoke-LockAcquire {
    param([object] $Context, [Collections.Generic.Dictionary[string,string]] $Options)
    $token = $Options['--owner-token']
    if ($token -notmatch '^[A-Za-z0-9_-]{32,128}$') { throw 'lock-owner-token-invalid' }
    $ownerPid = ConvertTo-PositivePid -Value $Options['--pid']
    $ownerStart = ConvertTo-CanonicalProcessStart -Value $Options['--process-start']
    Assert-LiveProcessBinding -ProcessId $ownerPid -ExpectedStart $ownerStart
    Invoke-TestAcquireBarrier -Options $Options

    $paths = Get-GuardPaths -GitCommonDir $Context.GitCommonDir
    Assert-SafePathComponents -FullPath $paths.Directory -ReparseCode 'guard-root-reparse'
    Initialize-SafeDirectory -FullPath $paths.Directory -InvalidCode 'guard-root-invalid' -ReparseCode 'guard-root-reparse'
    Assert-GuardDirectoryEntries -Directory $paths.Directory
    if ([IO.File]::Exists($paths.Holder)) {
        $existing = Read-LockRecord -Path $paths.Holder
        $binding = Get-ProcessBindingState -ProcessId $existing.Record.pid -ExpectedStart $existing.Record.process_start
        if ($binding -ceq 'ok') { throw 'lock-held' }
        throw 'lock-stale-attended-recovery-required'
    }

    $record = New-LockRecord -OwnerToken $token -ProcessId $ownerPid -ProcessStart $ownerStart
    $text = ConvertTo-CanonicalJson $record
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    try { $stream = [IO.FileStream]::new($paths.Holder, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough) }
    catch [IO.IOException] { throw 'lock-contended' }
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }

    Assert-GuardDirectoryEntries -Directory $paths.Directory
    $persisted = Read-LockRecord -Path $paths.Holder
    if ($persisted.Text -cne $text) { throw 'lock-record-invalid' }
    Assert-LiveProcessBinding -ProcessId $ownerPid -ExpectedStart $ownerStart
    [Console]::Out.WriteLine('GUARD_LOCK_ACQUIRED code=lock-acquired')
}

function Invoke-LockRelease {
    param([object] $Context, [Collections.Generic.Dictionary[string,string]] $Options)
    $token = $Options['--owner-token']
    if ($token -notmatch '^[A-Za-z0-9_-]{32,128}$') { throw 'lock-owner-token-invalid' }
    $ownerPid = ConvertTo-PositivePid -Value $Options['--pid']
    $ownerStart = ConvertTo-CanonicalProcessStart -Value $Options['--process-start']
    $paths = Get-GuardPaths -GitCommonDir $Context.GitCommonDir
    if (-not [IO.Directory]::Exists($paths.Directory)) { throw 'lock-not-held' }
    Assert-SafePathComponents -FullPath $paths.Directory -ReparseCode 'guard-root-reparse'
    Assert-GuardDirectoryEntries -Directory $paths.Directory
    if (-not [IO.File]::Exists($paths.Holder)) { throw 'lock-not-held' }

    $stream = [IO.FileStream]::new($paths.Holder, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Delete)
    try {
        if ($stream.Length -lt 1 -or $stream.Length -gt 4096) { throw 'lock-record-invalid' }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -eq 0) { throw 'lock-record-invalid' }
            $offset += $read
        }
        try { $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) } catch { throw 'lock-record-invalid' }
        try { $document = [Text.Json.JsonDocument]::Parse($text) } catch { throw 'lock-record-invalid' }
        try {
            $fields = Get-ExactJsonFields -Element $document.RootElement -Names @('owner_token', 'pid', 'process_start', 'protocol') -FailureCode 'lock-record-invalid'
            if ($fields['owner_token'].ValueKind -ne [Text.Json.JsonValueKind]::String -or $fields['process_start'].ValueKind -ne [Text.Json.JsonValueKind]::String -or $fields['protocol'].ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'lock-record-invalid' }
            [int]$persistedPid = 0
            if ($fields['pid'].ValueKind -ne [Text.Json.JsonValueKind]::Number -or -not $fields['pid'].TryGetInt32([ref]$persistedPid)) { throw 'lock-record-invalid' }
            $persistedToken = $fields['owner_token'].GetString()
            $persistedStart = $fields['process_start'].GetString()
            try { $canonicalStart = ConvertTo-CanonicalProcessStart $persistedStart } catch { throw 'lock-record-invalid' }
            $canonical = ConvertTo-CanonicalJson (New-LockRecord -OwnerToken $persistedToken -ProcessId $persistedPid -ProcessStart $canonicalStart)
            if ($persistedToken -notmatch '^[A-Za-z0-9_-]{32,128}$' -or $persistedPid -lt 1 -or $fields['protocol'].GetString() -cne 'gatecraft-local-lock/v1' -or $canonical -cne $text) { throw 'lock-record-invalid' }
            if ($persistedToken -cne $token -or $persistedPid -ne $ownerPid -or $persistedStart -cne $ownerStart) { throw 'lock-owner-mismatch' }
            Assert-LiveProcessBinding -ProcessId $persistedPid -ExpectedStart $persistedStart
            Assert-GuardDirectoryEntries -Directory $paths.Directory
            Assert-NotReparsePoint -Path $paths.Holder -Code 'guard-root-reparse'
            [IO.File]::Delete($paths.Holder)
        }
        finally { $document.Dispose() }
    }
    finally { $stream.Dispose() }
    if ([IO.File]::Exists($paths.Holder)) { throw 'lock-release-failed' }
    [Console]::Out.WriteLine('GUARD_LOCK_RELEASED code=lock-released')
}

function Assert-RepositoryRelativePath {
    param([Parameter(Mandatory)][string] $Value)
    if ([string]::IsNullOrEmpty($Value) -or $Value.Length -gt 1024 -or -not $Value.IsNormalized([Text.NormalizationForm]::FormC) -or $Value -match '[\x00-\x1F\x7F\\:*?\[\]]' -or $Value.StartsWith('/', [StringComparison]::Ordinal) -or $Value.EndsWith('/', [StringComparison]::Ordinal)) { throw 'repository-path-invalid' }
    $segments = @($Value.Split([char]'/', [StringSplitOptions]::None))
    if ($segments.Count -eq 0 -or $segments[0] -ieq '.git') { throw 'repository-path-invalid' }
    foreach ($segment in $segments) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -in @('.', '..') -or $segment.EndsWith(' ', [StringComparison]::Ordinal) -or $segment.EndsWith('.', [StringComparison]::Ordinal)) { throw 'repository-path-invalid' }
    }
    return $Value
}

function Assert-RepositoryPathSafe {
    param([string] $RepositoryRoot, [string] $RelativePath)
    [void](Assert-RepositoryRelativePath -Value $RelativePath)
    $native = $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath([IO.Path]::Combine($RepositoryRoot, $native))
    $prefix = $RepositoryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $comparison = if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $full.StartsWith($prefix, $comparison)) { throw 'repository-path-escape' }
    Assert-SafePathComponents -FullPath $full -ReparseCode 'path-reparse'
    return $full
}

function Read-OwnedPathsJson {
    param([string] $Json, [string] $RepositoryRoot)
    try { $document = [Text.Json.JsonDocument]::Parse($Json) } catch { throw 'owned-paths-malformed' }
    try {
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Array) { throw 'owned-paths-malformed' }
        $paths = [Collections.Generic.List[string]]::new()
        $ordinal = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $folded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($element in $document.RootElement.EnumerateArray()) {
            if ($element.ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'owned-paths-malformed' }
            try { $path = Assert-RepositoryRelativePath -Value $element.GetString() } catch { throw 'owned-paths-malformed' }
            if (-not $ordinal.Add($path)) { throw 'owned-paths-duplicate' }
            if (-not $folded.Add($path)) { throw 'owned-paths-case-collision' }
            [void](Assert-RepositoryPathSafe -RepositoryRoot $RepositoryRoot -RelativePath $path)
            $paths.Add($path)
        }
        if ($paths.Count -eq 0) { throw 'owned-paths-empty' }
        return @(Sort-OrdinalStrings -Values @($paths))
    }
    finally { $document.Dispose() }
}

function Read-ProcessManifestJson {
    param([Parameter(Mandatory)][string] $Json)
    try { $document = [Text.Json.JsonDocument]::Parse($Json) } catch { throw 'process-manifest-malformed' }
    try {
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Array) { throw 'process-manifest-malformed' }
        $manifest = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $workers = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $bindings = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($element in $document.RootElement.EnumerateArray()) {
            $fields = Get-ExactJsonFields -Element $element -Names @('worker_id', 'pid', 'process_start') -FailureCode 'process-manifest-malformed'
            if ($fields['worker_id'].ValueKind -ne [Text.Json.JsonValueKind]::String -or $fields['process_start'].ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'process-manifest-malformed' }
            $worker = $fields['worker_id'].GetString()
            if ($worker -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$' -or -not $workers.Add($worker)) { throw 'process-manifest-malformed' }
            [int]$manifestPid = 0
            if ($fields['pid'].ValueKind -ne [Text.Json.JsonValueKind]::Number -or -not $fields['pid'].TryGetInt32([ref]$manifestPid) -or $manifestPid -lt 1) { throw 'process-manifest-malformed' }
            try { $manifestStart = ConvertTo-CanonicalProcessStart -Value $fields['process_start'].GetString() } catch { throw 'process-manifest-malformed' }
            if (-not $bindings.Add("$manifestPid`n$manifestStart")) { throw 'process-manifest-malformed' }
            $manifest.Add($worker, [pscustomobject][ordered]@{ worker_id = $worker; pid = $manifestPid; process_start = $manifestStart })
        }
        if ($manifest.Count -eq 0) { throw 'process-manifest-empty' }
        $sortedManifest = [Collections.Generic.List[object]]::new()
        foreach ($worker in @(Sort-OrdinalStrings -Values @($manifest.Keys))) { $sortedManifest.Add($manifest[$worker]) }
        return @($sortedManifest)
    }
    finally { $document.Dispose() }
}

function Assert-ExpectedProcesses {
    param([Parameter(Mandatory)][object[]] $Manifest)
    foreach ($entry in $Manifest) { Assert-LiveProcessBinding -ProcessId $entry.pid -ExpectedStart $entry.process_start }
}

function Get-MainSha {
    param([Parameter(Mandatory)][string] $RepositoryRoot)
    $sha = ConvertFrom-GitLine -Bytes (Invoke-GitBytes -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse', '--verify', 'refs/heads/main^{commit}') -FailureCode 'git-main-ref-failed') -FailureCode 'git-output-invalid'
    if ($sha -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') { throw 'git-main-ref-invalid' }
    return $sha
}

function Get-StatusBytes {
    param([Parameter(Mandatory)][string] $RepositoryRoot)
    return ,(Invoke-GitBytes -RepositoryRoot $RepositoryRoot -Arguments @('status', '--porcelain=v1', '-z', '--untracked-files=all') -FailureCode 'git-status-failed')
}

function ConvertFrom-StatusPathBytes {
    param([byte[]] $Bytes, [int] $Offset, [int] $Count)
    if ($Count -lt 1) { throw 'git-status-malformed' }
    try { $path = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes, $Offset, $Count) } catch { throw 'git-status-malformed' }
    try { return Assert-RepositoryRelativePath -Value $path } catch { throw 'git-status-malformed' }
}

function Read-NulSegment {
    param([byte[]] $Bytes, [ref] $Index)
    $start = $Index.Value
    $cursor = $start
    while ($cursor -lt $Bytes.Length -and $Bytes[$cursor] -ne 0) { $cursor++ }
    if ($cursor -ge $Bytes.Length) { throw 'git-status-malformed' }
    $Index.Value = $cursor + 1
    return [pscustomobject]@{ Offset = $start; Count = $cursor - $start }
}

function ConvertFrom-GitStatus {
    param([byte[]] $Bytes, [string] $RepositoryRoot)
    $map = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $allPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $casePaths = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    $index = 0
    while ($index -lt $Bytes.Length) {
        $segment = Read-NulSegment -Bytes $Bytes -Index ([ref]$index)
        if ($segment.Count -lt 4 -or $Bytes[$segment.Offset + 2] -ne 0x20) { throw 'git-status-malformed' }
        $x = [char]$Bytes[$segment.Offset]
        $y = [char]$Bytes[$segment.Offset + 1]
        if (" MADRCU?!T".IndexOf($x) -lt 0 -or " MADRCU?!T".IndexOf($y) -lt 0) { throw 'git-status-malformed' }
        $first = ConvertFrom-StatusPathBytes -Bytes $Bytes -Offset ($segment.Offset + 3) -Count ($segment.Count - 3)
        $paths = [Collections.Generic.List[string]]::new()
        $paths.Add($first)
        if ($x -in @('R', 'C') -or $y -in @('R', 'C')) {
            if ($index -ge $Bytes.Length) { throw 'git-status-malformed' }
            $secondSegment = Read-NulSegment -Bytes $Bytes -Index ([ref]$index)
            $paths.Add((ConvertFrom-StatusPathBytes -Bytes $Bytes -Offset $secondSegment.Offset -Count $secondSegment.Count))
        }
        $signature = ConvertTo-CanonicalJson ([pscustomobject][ordered]@{ status = "$x$y"; paths = @($paths) })
        foreach ($path in $paths) {
            [void](Assert-RepositoryPathSafe -RepositoryRoot $RepositoryRoot -RelativePath $path)
            if ($casePaths.ContainsKey($path) -and $casePaths[$path] -cne $path) { throw 'git-status-case-collision' }
            if (-not $casePaths.ContainsKey($path)) { $casePaths.Add($path, $path) }
            if ($map.ContainsKey($path)) { throw 'git-status-duplicate-path' }
            $map.Add($path, $signature)
            [void]$allPaths.Add($path)
        }
    }
    [string[]]$sortedPaths = @(Sort-OrdinalStrings -Values @($allPaths))
    return [pscustomobject]@{ Map = $map; Paths = $sortedPaths }
}

function Get-FileHashRecord {
    param([string] $FullPath, [string] $RelativePath)
    Assert-NotReparsePoint -Path $FullPath -Code 'path-reparse'
    $stream = [IO.FileStream]::new($FullPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $length = $stream.Length
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = $sha.ComputeHash($stream) } finally { $sha.Dispose() }
        if ($stream.Length -ne $length) { throw 'path-changed-during-read' }
        return [pscustomobject][ordered]@{ kind = 'file'; length = $length; path = $RelativePath; sha256 = [Convert]::ToHexString($hash).ToLowerInvariant() }
    }
    finally { $stream.Dispose() }
}

function Get-DirectoryHashRecord {
    param([string] $FullPath, [string] $RelativePath, [string] $RepositoryRoot)
    $entries = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($FullPath)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        Assert-NotReparsePoint -Path $directory -Code 'path-reparse'
        foreach ($entry in [IO.DirectoryInfo]::new($directory).GetFileSystemInfos()) {
            Assert-NotReparsePoint -Path $entry.FullName -Code 'path-reparse'
            $repoRelative = [IO.Path]::GetRelativePath($RepositoryRoot, $entry.FullName).Replace([IO.Path]::DirectorySeparatorChar, '/')
            [void](Assert-RepositoryRelativePath -Value $repoRelative)
            if ($entry -is [IO.DirectoryInfo]) {
                $entries.Add($repoRelative, [pscustomobject]@{ Kind = 'directory'; Relative = $repoRelative; Full = $entry.FullName })
                $pending.Push($entry.FullName)
            }
            elseif ($entry -is [IO.FileInfo]) { $entries.Add($repoRelative, [pscustomobject]@{ Kind = 'file'; Relative = $repoRelative; Full = $entry.FullName }) }
            else { throw 'repository-path-type-unsupported' }
        }
    }
    $lines = [Collections.Generic.List[string]]::new()
    [long]$totalLength = 0
    foreach ($relative in @(Sort-OrdinalStrings -Values @($entries.Keys))) {
        $entry = $entries[$relative]
        if ($entry.Kind -ceq 'directory') { $lines.Add("D`0$($entry.Relative)") }
        else {
            $file = Get-FileHashRecord -FullPath $entry.Full -RelativePath $entry.Relative
            $totalLength += $file.length
            $lines.Add("F`0$($file.path)`0$($file.length)`0$($file.sha256)")
        }
    }
    $payload = [Text.UTF8Encoding]::new($false).GetBytes([string]::Join("`n", $lines))
    return [pscustomobject][ordered]@{ kind = 'directory'; length = $totalLength; path = $RelativePath; sha256 = Get-Sha256Hex $payload }
}

function Get-PathHashRecord {
    param([string] $RepositoryRoot, [string] $RelativePath)
    $full = Assert-RepositoryPathSafe -RepositoryRoot $RepositoryRoot -RelativePath $RelativePath
    if ([IO.File]::Exists($full) -and -not [IO.Directory]::Exists($full)) { return Get-FileHashRecord -FullPath $full -RelativePath $RelativePath }
    if ([IO.Directory]::Exists($full)) { return Get-DirectoryHashRecord -FullPath $full -RelativePath $RelativePath -RepositoryRoot $RepositoryRoot }
    return [pscustomobject][ordered]@{ kind = 'missing'; length = 0; path = $RelativePath; sha256 = '' }
}

function Get-DirtyPathRecord {
    param([string] $RepositoryRoot, [string] $RelativePath)
    $pathRecord = Get-PathHashRecord -RepositoryRoot $RepositoryRoot -RelativePath $RelativePath
    $indexBytes = Invoke-GitBytes -RepositoryRoot $RepositoryRoot -Arguments @('--literal-pathspecs', 'ls-files', '--stage', '-z', '--', $RelativePath) -FailureCode 'git-index-state-failed'
    return [pscustomobject][ordered]@{
        index_sha256 = Get-Sha256Hex $indexBytes
        kind = $pathRecord.kind
        length = $pathRecord.length
        path = $pathRecord.path
        sha256 = $pathRecord.sha256
    }
}

function New-BaselineRecord {
    param([string] $BaselineId, [object[]] $DirtyPaths, [object[]] $ExpectedProcesses, [string] $GitCommonDir, [string] $MainSha, [string[]] $OwnedPaths, [string] $RepositoryRoot, [byte[]] $StatusBytes)
    return [pscustomobject][ordered]@{
        baseline_id = $BaselineId
        dirty_paths = @($DirtyPaths)
        expected_processes = @($ExpectedProcesses)
        git_common_dir = $GitCommonDir
        main_ref = 'refs/heads/main'
        main_sha = $MainSha
        owned_paths = @($OwnedPaths)
        protocol = 'gatecraft-foreign-baseline/v1'
        repository_root = $RepositoryRoot
        status_base64 = [Convert]::ToBase64String($StatusBytes)
        status_sha256 = Get-Sha256Hex $StatusBytes
    }
}

function Assert-BaselineIdentifier {
    param([Parameter(Mandatory)][string] $Value)
    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw 'baseline-id-invalid' }
}

function Get-BaselinePaths {
    param([string] $StateRoot, [string] $BaselineId)
    $directory = [IO.Path]::Combine($StateRoot, 'guard-baselines-v1')
    return [pscustomobject]@{ Directory = $directory; File = [IO.Path]::Combine($directory, "$BaselineId.json") }
}

function Assert-BaselineDirectoryEntries {
    param([Parameter(Mandatory)][string] $Directory)
    Assert-NotReparsePoint -Path $Directory -Code 'path-reparse'
    foreach ($entry in [IO.DirectoryInfo]::new($Directory).GetFileSystemInfos()) {
        if ($entry -isnot [IO.FileInfo] -or $entry.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.json$') { throw 'baseline-directory-unexpected-entry' }
        Assert-NotReparsePoint -Path $entry.FullName -Code 'path-reparse'
    }
}

function Write-CreateOnlyUtf8 {
    param([string] $Path, [string] $Text, [string] $ExistsCode)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    try { $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough) } catch [IO.IOException] { throw $ExistsCode }
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}

function Invoke-BaselineCreate {
    param([object] $Context, [Collections.Generic.Dictionary[string,string]] $Options)
    $baselineId = $Options['--baseline-id']
    Assert-BaselineIdentifier $baselineId
    $owned = @(Read-OwnedPathsJson -Json $Options['--owned-paths-json'] -RepositoryRoot $Context.RepositoryRoot)
    $manifest = @(Read-ProcessManifestJson -Json $Options['--process-manifest-json'])
    Assert-ExpectedProcesses -Manifest $manifest
    $mainSha = Get-MainSha -RepositoryRoot $Context.RepositoryRoot
    $statusBytes = Get-StatusBytes -RepositoryRoot $Context.RepositoryRoot
    $status = ConvertFrom-GitStatus -Bytes $statusBytes -RepositoryRoot $Context.RepositoryRoot
    $dirty = [Collections.Generic.List[object]]::new()
    foreach ($path in $status.Paths) { $dirty.Add((Get-DirtyPathRecord -RepositoryRoot $Context.RepositoryRoot -RelativePath $path)) }
    $confirmMain = Get-MainSha -RepositoryRoot $Context.RepositoryRoot
    $confirmStatus = Get-StatusBytes -RepositoryRoot $Context.RepositoryRoot
    if ($confirmMain -cne $mainSha -or $confirmStatus.Length -ne $statusBytes.Length -or (Get-Sha256Hex $confirmStatus) -cne (Get-Sha256Hex $statusBytes)) { throw 'baseline-repository-raced' }
    Assert-ExpectedProcesses -Manifest $manifest
    $record = New-BaselineRecord -BaselineId $baselineId -DirtyPaths @($dirty) -ExpectedProcesses $manifest -GitCommonDir $Context.GitCommonDir -MainSha $mainSha -OwnedPaths $owned -RepositoryRoot $Context.RepositoryRoot -StatusBytes $statusBytes
    $canonical = ConvertTo-CanonicalJson -Value $record -Depth 8

    $stateRoot = ConvertTo-LocalFullPath -DeclaredPath $Options['--state-root'] -InvalidCode 'state-root-invalid' -NonLocalCode 'state-root-nonlocal'
    $trimmed = $stateRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($trimmed -ceq [IO.Path]::GetPathRoot($stateRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)) { throw 'state-root-invalid' }
    if ((Test-PathAtOrBelow -Candidate $stateRoot -Parent $Context.RepositoryRoot) -or (Test-PathAtOrBelow -Candidate $stateRoot -Parent $Context.GitCommonDir)) { throw 'state-root-repository-overlap' }
    Initialize-SafeDirectory -FullPath $stateRoot -InvalidCode 'state-root-invalid' -ReparseCode 'path-reparse'
    $paths = Get-BaselinePaths -StateRoot $stateRoot -BaselineId $baselineId
    Initialize-SafeDirectory -FullPath $paths.Directory -InvalidCode 'baseline-directory-invalid' -ReparseCode 'path-reparse'
    Assert-BaselineDirectoryEntries -Directory $paths.Directory
    Write-CreateOnlyUtf8 -Path $paths.File -Text $canonical -ExistsCode 'baseline-exists'
    $persisted = Read-StrictUtf8File -Path $paths.File -FailureCode 'baseline-record-invalid' -MaximumBytes 1073741824
    if ($persisted.Text -cne $canonical) { throw 'baseline-record-invalid' }
    [Console]::Out.WriteLine("GUARD_BASELINE_CREATED code=baseline-created dirty_count=$($dirty.Count) owned_count=$($owned.Count) process_count=$($manifest.Count)")
}

function Read-BaselineRecord {
    param([Parameter(Mandatory)][string] $Path)
    $file = Read-StrictUtf8File -Path $Path -FailureCode 'baseline-record-invalid' -MaximumBytes 1073741824
    try { $document = [Text.Json.JsonDocument]::Parse($file.Text) } catch { throw 'baseline-record-invalid' }
    try {
        $root = Get-ExactJsonFields -Element $document.RootElement -Names @('baseline_id','dirty_paths','expected_processes','git_common_dir','main_ref','main_sha','owned_paths','protocol','repository_root','status_base64','status_sha256') -FailureCode 'baseline-record-invalid'
        foreach ($name in @('baseline_id','git_common_dir','main_ref','main_sha','protocol','repository_root','status_base64','status_sha256')) { if ($root[$name].ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'baseline-record-invalid' } }
        $baselineId = $root['baseline_id'].GetString()
        try { Assert-BaselineIdentifier $baselineId } catch { throw 'baseline-record-invalid' }
        if ($root['main_ref'].GetString() -cne 'refs/heads/main' -or $root['protocol'].GetString() -cne 'gatecraft-foreign-baseline/v1') { throw 'baseline-record-invalid' }
        $mainSha = $root['main_sha'].GetString()
        if ($mainSha -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') { throw 'baseline-record-invalid' }
        try { $statusBytes = [Convert]::FromBase64String($root['status_base64'].GetString()) } catch { throw 'baseline-record-invalid' }
        if ([Convert]::ToBase64String($statusBytes) -cne $root['status_base64'].GetString() -or (Get-Sha256Hex $statusBytes) -cne $root['status_sha256'].GetString()) { throw 'baseline-record-invalid' }

        if ($root['owned_paths'].ValueKind -ne [Text.Json.JsonValueKind]::Array) { throw 'baseline-record-invalid' }
        try { $owned = @(Read-OwnedPathsJson -Json $root['owned_paths'].GetRawText() -RepositoryRoot $root['repository_root'].GetString()) } catch { throw 'baseline-record-invalid' }
        if ($root['expected_processes'].ValueKind -ne [Text.Json.JsonValueKind]::Array) { throw 'baseline-record-invalid' }
        try { $manifest = @(Read-ProcessManifestJson -Json $root['expected_processes'].GetRawText()) } catch { throw 'baseline-record-invalid' }

        if ($root['dirty_paths'].ValueKind -ne [Text.Json.JsonValueKind]::Array) { throw 'baseline-record-invalid' }
        $dirty = [Collections.Generic.List[object]]::new()
        $seenDirty = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($element in $root['dirty_paths'].EnumerateArray()) {
            $fields = Get-ExactJsonFields -Element $element -Names @('index_sha256','kind','length','path','sha256') -FailureCode 'baseline-record-invalid'
            if ($fields['kind'].ValueKind -ne [Text.Json.JsonValueKind]::String -or $fields['path'].ValueKind -ne [Text.Json.JsonValueKind]::String -or $fields['sha256'].ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'baseline-record-invalid' }
            [long]$length = 0
            if ($fields['length'].ValueKind -ne [Text.Json.JsonValueKind]::Number -or -not $fields['length'].TryGetInt64([ref]$length) -or $length -lt 0) { throw 'baseline-record-invalid' }
            $kind = $fields['kind'].GetString()
            $dirtyPath = $fields['path'].GetString()
            try { [void](Assert-RepositoryRelativePath $dirtyPath) } catch { throw 'baseline-record-invalid' }
            if (-not $seenDirty.Add($dirtyPath) -or $kind -cnotin @('file','directory','missing')) { throw 'baseline-record-invalid' }
            if ($dirty.Count -gt 0 -and [StringComparer]::Ordinal.Compare([string]$dirty[$dirty.Count - 1].path, $dirtyPath) -ge 0) { throw 'baseline-record-invalid' }
            $sha = $fields['sha256'].GetString()
            if ($fields['index_sha256'].ValueKind -ne [Text.Json.JsonValueKind]::String -or $fields['index_sha256'].GetString() -notmatch '^[0-9a-f]{64}$') { throw 'baseline-record-invalid' }
            if (($kind -ceq 'missing' -and ($length -ne 0 -or $sha -cne '')) -or ($kind -cne 'missing' -and $sha -notmatch '^[0-9a-f]{64}$')) { throw 'baseline-record-invalid' }
            $dirty.Add([pscustomobject][ordered]@{ index_sha256 = $fields['index_sha256'].GetString(); kind = $kind; length = $length; path = $dirtyPath; sha256 = $sha })
        }
        $sortedDirty = @($dirty)
        $record = New-BaselineRecord -BaselineId $baselineId -DirtyPaths $sortedDirty -ExpectedProcesses $manifest -GitCommonDir $root['git_common_dir'].GetString() -MainSha $mainSha -OwnedPaths $owned -RepositoryRoot $root['repository_root'].GetString() -StatusBytes $statusBytes
        if ((ConvertTo-CanonicalJson -Value $record -Depth 8) -cne $file.Text) { throw 'baseline-record-invalid' }
        return [pscustomobject]@{ Record = $record; StatusBytes = $statusBytes }
    }
    finally { $document.Dispose() }
}

function Test-OwnedPath {
    param([string] $Path, [string[]] $OwnedPaths)
    $comparison = if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    foreach ($owned in $OwnedPaths) { if ($Path.Equals($owned, $comparison) -or $Path.StartsWith($owned + '/', $comparison)) { return $true } }
    return $false
}

function Test-HashRecordEqual {
    param([object] $Left, [object] $Right)
    return $Left.index_sha256 -ceq $Right.index_sha256 -and $Left.kind -ceq $Right.kind -and $Left.length -eq $Right.length -and $Left.path -ceq $Right.path -and $Left.sha256 -ceq $Right.sha256
}

function Invoke-BaselineSweep {
    param([object] $Context, [Collections.Generic.Dictionary[string,string]] $Options)
    $baselineId = $Options['--baseline-id']
    Assert-BaselineIdentifier $baselineId
    $stateRoot = ConvertTo-LocalFullPath -DeclaredPath $Options['--state-root'] -InvalidCode 'state-root-invalid' -NonLocalCode 'state-root-nonlocal'
    if (-not [IO.Directory]::Exists($stateRoot)) { throw 'state-root-missing' }
    if ((Test-PathAtOrBelow -Candidate $stateRoot -Parent $Context.RepositoryRoot) -or (Test-PathAtOrBelow -Candidate $stateRoot -Parent $Context.GitCommonDir)) { throw 'state-root-repository-overlap' }
    Assert-SafePathComponents -FullPath $stateRoot -ReparseCode 'path-reparse'
    $paths = Get-BaselinePaths -StateRoot $stateRoot -BaselineId $baselineId
    if (-not [IO.Directory]::Exists($paths.Directory)) { throw 'baseline-directory-missing' }
    Assert-SafePathComponents -FullPath $paths.Directory -ReparseCode 'path-reparse'
    Assert-BaselineDirectoryEntries -Directory $paths.Directory
    if (-not [IO.File]::Exists($paths.File)) { throw 'baseline-record-missing' }
    $baseline = Read-BaselineRecord -Path $paths.File
    if ($baseline.Record.baseline_id -cne $baselineId) { throw 'baseline-record-invalid' }
    if (-not (Test-PathEqual $baseline.Record.repository_root $Context.RepositoryRoot) -or -not (Test-PathEqual $baseline.Record.git_common_dir $Context.GitCommonDir)) { throw 'baseline-repository-mismatch' }

    Assert-ExpectedProcesses -Manifest $baseline.Record.expected_processes
    if ((Get-MainSha -RepositoryRoot $Context.RepositoryRoot) -cne $baseline.Record.main_sha) { throw 'main-moved' }
    try { $baselineStatus = ConvertFrom-GitStatus -Bytes $baseline.StatusBytes -RepositoryRoot $Context.RepositoryRoot }
    catch {
        if ([string]$_.Exception.Message -cmatch '^git-status-') { throw 'baseline-record-invalid' }
        throw
    }
    $baselineDirty = @($baseline.Record.dirty_paths)
    if ($baselineStatus.Paths.Count -ne $baselineDirty.Count) { throw 'baseline-record-invalid' }
    for ($index = 0; $index -lt $baselineStatus.Paths.Count; $index++) {
        if ([StringComparer]::Ordinal.Compare([string]$baselineStatus.Paths[$index], [string]$baselineDirty[$index].path) -ne 0) { throw 'baseline-record-invalid' }
    }
    $currentBytes = Get-StatusBytes -RepositoryRoot $Context.RepositoryRoot
    $currentStatus = ConvertFrom-GitStatus -Bytes $currentBytes -RepositoryRoot $Context.RepositoryRoot
    $changed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in $baselineStatus.Map.Keys) { [void]$keys.Add($key) }
    foreach ($key in $currentStatus.Map.Keys) { [void]$keys.Add($key) }
    foreach ($key in $keys) {
        if (-not $baselineStatus.Map.ContainsKey($key) -or -not $currentStatus.Map.ContainsKey($key) -or $baselineStatus.Map[$key] -cne $currentStatus.Map[$key]) { [void]$changed.Add($key) }
    }
    $currentFingerprints = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($prior in $baseline.Record.dirty_paths) {
        $current = Get-DirtyPathRecord -RepositoryRoot $Context.RepositoryRoot -RelativePath $prior.path
        $currentFingerprints.Add($prior.path, $current)
        if (-not (Test-HashRecordEqual $prior $current)) { [void]$changed.Add($prior.path) }
    }

    $ownedCount = 0
    foreach ($path in $changed) {
        if (-not (Test-OwnedPath -Path $path -OwnedPaths $baseline.Record.owned_paths)) { throw 'foreign-change' }
        $ownedCount++
    }
    Assert-ExpectedProcesses -Manifest $baseline.Record.expected_processes
    if ((Get-MainSha -RepositoryRoot $Context.RepositoryRoot) -cne $baseline.Record.main_sha) { throw 'main-moved' }
    $confirmBytes = Get-StatusBytes -RepositoryRoot $Context.RepositoryRoot
    if ($confirmBytes.Length -ne $currentBytes.Length -or (Get-Sha256Hex $confirmBytes) -cne (Get-Sha256Hex $currentBytes)) { throw 'sweep-repository-raced' }
    foreach ($path in $currentFingerprints.Keys) {
        $confirmFingerprint = Get-DirtyPathRecord -RepositoryRoot $Context.RepositoryRoot -RelativePath $path
        if (-not (Test-HashRecordEqual $currentFingerprints[$path] $confirmFingerprint)) { throw 'sweep-repository-raced' }
    }
    [Console]::Out.WriteLine("GUARD_SWEEP_OK code=sweep-clean owned_changes=$ownedCount")
}

if ($PSVersionTable.PSVersion.Major -lt 7) { Stop-Guard -ExitCode 64 -Code 'powershell-version' }

try {
    $parsed = Read-GuardArguments -Tokens @($args)
    $testOptionsPresent = @(@('--test-acquire-barrier','--test-participant','--test-timeout-ms') | Where-Object { $parsed.Values.ContainsKey($_) })
    if ($testOptionsPresent.Count -gt 0 -and [Environment]::GetEnvironmentVariable('GATECRAFT_GUARD_TEST_CONTROLS', [EnvironmentVariableTarget]::Process) -cne '1') { throw 'test-controls-disabled' }
    $context = Get-RepositoryContext -DeclaredRoot $parsed.Values['--repository-root']
    switch ($parsed.Command) {
        'acquire' { Invoke-LockAcquire -Context $context -Options $parsed.Values }
        'release' { Invoke-LockRelease -Context $context -Options $parsed.Values }
        'baseline' { Invoke-BaselineCreate -Context $context -Options $parsed.Values }
        'sweep' { Invoke-BaselineSweep -Context $context -Options $parsed.Values }
    }
    exit 0
}
catch {
    $message = [string]$_.Exception.Message
    $code = if ($message -cmatch '^(?<code>[a-z][a-z0-9.-]*)') { $Matches.code } else { 'internal-error' }
    Stop-Guard -ExitCode (Get-GuardExitCode -Code $code) -Code $code
}
