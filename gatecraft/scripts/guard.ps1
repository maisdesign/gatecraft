Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-GuardUsage {
    [Console]::Out.WriteLine(@'
Usage:
  guard.ps1 acquire --repository-root <absolute-path> --owner-token <opaque-token> --pid <positive-decimal> --process-start <canonical-UTC>
  guard.ps1 release --repository-root <absolute-path> --owner-token <opaque-token> --pid <positive-decimal> --process-start <canonical-UTC>
  guard.ps1 baseline --repository-root <absolute-path> --state-root <absolute-path> --baseline-id <stable-id> --owned-paths-json <JSON-array> --process-manifest-json <JSON-array>
  guard.ps1 sweep --repository-root <absolute-path> --state-root <absolute-path> --baseline-id <stable-id>
  guard.ps1 worktree-remove --repository-root <absolute-path> --worktree-path <absolute-path> --worker-pid <positive-decimal> --worker-process-start <canonical-UTC>

Canonical process timestamps use yyyy-MM-ddTHH:mm:ss.fffffffZ.
Owner tokens use 32-128 ASCII letters, digits, underscore, or hyphen.

Test-only acquire barrier:
  --test-acquire-barrier <absolute-existing-directory> --test-participant <stable-id> --test-timeout-ms <100-30000>
  All three options require GATECRAFT_GUARD_TEST_CONTROLS=1.

Test-only diagnostic (requires GATECRAFT_GUARD_TEST_CONTROLS=1, never used in production removal logic):
  guard.ps1 probe-child-window --repository-root <absolute-path> --parent-pid <positive-decimal> --minimum-start <canonical-UTC>
  Prints the exact PIDs Get-ChildProcessRecords accepts for that parent at-or-after --minimum-start -- a direct, deterministic way to exercise the ancestry lower-bound logic without depending on real OS PID-reuse timing.

Test-only descendant-count override (requires GATECRAFT_GUARD_TEST_CONTROLS=1):
  guard.ps1 worktree-remove ... --test-max-descendants <positive-decimal>
  Overrides the production 256-descendant ceiling so a fixture can deterministically cross it with a handful of real processes instead of spawning hundreds. Production callers never pass this.
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
    if ($Code -match '^worktree-') { return 77 }
    return 65
}

function Read-GuardArguments {
    param([Parameter(Mandatory)][object[]] $Tokens)
    if ($Tokens.Count -eq 1 -and [string]$Tokens[0] -ceq '--help') { Write-GuardUsage; exit 0 }
    if ($Tokens.Count -lt 1) { throw 'argument-command-required' }
    $command = [string]$Tokens[0]
    if ($command -cnotin @('acquire', 'release', 'baseline', 'sweep', 'worktree-remove', 'probe-child-window')) { throw 'argument-command-invalid' }
    $allowedByCommand = @{
        acquire = @('--repository-root', '--owner-token', '--pid', '--process-start', '--test-acquire-barrier', '--test-participant', '--test-timeout-ms')
        release = @('--repository-root', '--owner-token', '--pid', '--process-start')
        baseline = @('--repository-root', '--state-root', '--baseline-id', '--owned-paths-json', '--process-manifest-json')
        sweep = @('--repository-root', '--state-root', '--baseline-id')
        'worktree-remove' = @('--repository-root', '--worktree-path', '--worker-pid', '--worker-process-start', '--test-max-descendants')
        'probe-child-window' = @('--repository-root', '--parent-pid', '--minimum-start')
    }
    $requiredByCommand = @{
        acquire = @('--repository-root', '--owner-token', '--pid', '--process-start')
        release = @('--repository-root', '--owner-token', '--pid', '--process-start')
        baseline = @('--repository-root', '--state-root', '--baseline-id', '--owned-paths-json', '--process-manifest-json')
        sweep = @('--repository-root', '--state-root', '--baseline-id')
        'worktree-remove' = @('--repository-root', '--worktree-path', '--worker-pid', '--worker-process-start')
        'probe-child-window' = @('--repository-root', '--parent-pid', '--minimum-start')
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

function Get-ProcessCanonicalStart {
    param([Parameter(Mandatory)][Diagnostics.Process] $Process)
    return $Process.StartTime.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

$script:GatecraftNativeProcessReady = $false
function Initialize-GatecraftNativeProcess {
    # A single native handle, opened with exactly the rights this operation needs (PROCESS_TERMINATE |
    # PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE — the same union .NET's own Kill()/HasExited use
    # internally), reused for the start-time check and the terminate call. This exists instead of the
    # public Process.Handle/SafeHandle property specifically because that property requests
    # PROCESS_ALL_ACCESS: a restricted/sandboxed declared worker's process ACL can legitimately deny that
    # broad mask while still granting the narrow rights this command actually needs, which would make
    # worktree-remove fail closed against a worker it should have been able to stop cleanly (lived: found
    # by external review round 9).
    if ($script:GatecraftNativeProcessReady) { return }
    Add-Type -Namespace Gatecraft -Name NativeProcess -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool CloseHandle(IntPtr hObject);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetProcessTimes(IntPtr hProcess, out long lpCreationTime, out long lpExitTime, out long lpKernelTime, out long lpUserTime);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
'@
    $script:GatecraftNativeProcessReady = $true
}

function Resolve-ProcessLifecycle {
    # Opens exactly ONE native handle for $ProcessId and performs the entire validate -> (terminate if
    # still alive) -> confirm-dead sequence through that same handle, never reopening or re-resolving by
    # PID at any step (closing external review round 16's finding). On SUCCESS the handle is returned
    # STILL OPEN, not closed here -- the caller must add it to a pinned-handle set and close it only once
    # every query that treats this PID as an ancestry key has finished (see Stop-DescendantProcesses).
    #
    # This is a deliberate correction of this function's own first version (round 17), which closed the
    # handle immediately and instead returned `ExitUtc` -- the OS-reported exit FILETIME -- for callers to
    # use as a wall-clock upper bound on "no child of this PID after this instant". External review round
    # 17 found that broken two ways: (1) a genuine same-instant child (creation time exactly equal to the
    # bound) was silently treated as ancestry-unrelated and excluded, a fail-open hole letting a live
    # descendant go unswept; (2) more fundamentally, FILETIME is wall-clock, and Windows does not guarantee
    # system time is monotonic across process events -- a clock adjustment could make an unrelated,
    # PID-reused process's child fall inside a stale window, reintroducing the exact ancestry confusion
    # this was meant to close. Round 17 itself named the correct structural fix: Windows documents that a
    # PID is not reused until every open handle to its process object is closed -- so holding the handle
    # open (not reading a timestamp off it) is what actually prevents reuse for as long as it matters.
    #
    # Fails closed (throws $FailClosedCode, closing the handle first) on anything that cannot be resolved
    # through this one handle: the PID could not be opened, its creation time no longer matches
    # $ExpectedStart (reused/wrong process), or termination could not be confirmed within the wait. Never
    # touches any process but the exact declared PID+start-time.
    param(
        [Parameter(Mandatory)][int] $ProcessId,
        [Parameter(Mandatory)][string] $ExpectedStart,
        [Parameter(Mandatory)][string] $FailClosedCode
    )
    Initialize-GatecraftNativeProcess
    $access = 0x00101001  # PROCESS_TERMINATE (0x0001) | PROCESS_QUERY_LIMITED_INFORMATION (0x1000) | SYNCHRONIZE (0x00100000)
    $handle = [Gatecraft.NativeProcess]::OpenProcess($access, $false, [uint32]$ProcessId)
    if ($handle -eq [IntPtr]::Zero) { throw $FailClosedCode }
    $succeeded = $false
    try {
        [long]$creation = 0; [long]$exitTime = 0; [long]$kernelTime = 0; [long]$userTime = 0
        if (-not [Gatecraft.NativeProcess]::GetProcessTimes($handle, [ref]$creation, [ref]$exitTime, [ref]$kernelTime, [ref]$userTime)) { throw $FailClosedCode }
        $actualStart = [DateTime]::FromFileTimeUtc($creation).ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        if ($actualStart -cne $ExpectedStart) { throw $FailClosedCode }
        [uint32]$exitCode = 0
        if (-not [Gatecraft.NativeProcess]::GetExitCodeProcess($handle, [ref]$exitCode)) { throw $FailClosedCode }
        if ($exitCode -eq 259) {  # STILL_ACTIVE
            [void][Gatecraft.NativeProcess]::TerminateProcess($handle, 1)
            if ([Gatecraft.NativeProcess]::WaitForSingleObject($handle, 5000) -ne 0) { throw $FailClosedCode }  # not WAIT_OBJECT_0
            if (-not [Gatecraft.NativeProcess]::GetExitCodeProcess($handle, [ref]$exitCode)) { throw $FailClosedCode }
            if ($exitCode -eq 259) { throw $FailClosedCode }
        }
        $succeeded = $true
        return [pscustomobject]@{ ProcessId = $ProcessId; Start = $actualStart; Handle = $handle }
    }
    finally { if (-not $succeeded) { [void][Gatecraft.NativeProcess]::CloseHandle($handle) } }
}

function Get-ProcessBindingState {
    param([int] $ProcessId, [string] $ExpectedStart)
    $process = $null
    try {
        $process = [Diagnostics.Process]::GetProcessById($ProcessId)
        if ($process.HasExited) { return 'process-dead' }
        $actual = Get-ProcessCanonicalStart -Process $process
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

function Get-ChildProcessRecords {
    # Win32_Process.ParentProcessId is a live, single-level snapshot: a caller enumerating the whole
    # tree must walk it repeatedly (see Stop-DescendantProcesses) since a child discovered here can
    # itself spawn a further child between this call and the next. Each CIM row is independently
    # re-validated against a freshly-opened handle to the same PID -- and specifically against the
    # creation time WMI itself reported for that PID, not merely "whichever process currently owns that
    # PID" -- so a PID that exited and was reused by an unrelated process in the gap between the CIM
    # query and this call is never mistaken for the child WMI actually saw a moment ago. The comparison
    # is tick-level (well under one WMI-reportable microsecond), not a multi-second tolerance: confirmed
    # empirically that WMI's CreationDate and .NET's Process.StartTime for the exact same, never-reused
    # process differ only by representation rounding within that one microsecond (WMI's DMTF datetime
    # carries microsecond precision; StartTime carries the OS's full 100ns-tick FILETIME) -- a genuine
    # PID-reuse gap is measured in whole process lifecycles, not ticks, so a sub-microsecond threshold
    # still catches real reuse while absorbing only that representation noise (lived: found by external
    # review round 14 -- the first fix used a 2-second tolerance, wide enough to itself authenticate a
    # reused PID).
    #
    # A CIM row with no CreationDate at all is not skipped as if absent: a live descendant WMI genuinely
    # reported but could not fully describe is exactly the kind of state this project's "unverifiable
    # fails closed" standard exists for (matching Get-ProcessBindingState's own `process-unverifiable`
    # handling for the declared root) -- treating it as "not there" would let a real survivor go
    # undetected by both discovery and the final confirmation pass, which both call this same function
    # (lived: found by external review round 14).
    #
    # $MinimumStart bounds ancestry, not just PID-reuse-in-the-moment: a numeric ParentProcessId match
    # alone does not prove the discovered process is actually a descendant of the caller's intended
    # lineage -- a long-dead, wholly unrelated ancestor process could have held this exact PID number
    # long before it was ever reassigned to the declared worker's own lineage, leaving behind a live
    # child that still reports the same numeric ParentProcessId purely by coincidence of PID reuse
    # (lived: found by external review round 14). A real child can never have been created before its
    # true parent, so any candidate whose own creation time predates $MinimumStart (the queried parent's
    # own validated creation time) is rejected as ancestry-unrelated rather than trusted on PID match alone.
    # This lower bound is about the PAST (whether $ParentProcessId's number was recently reused from an
    # older, unrelated ancestor before the caller ever validated it) and is untouched by the handle-pinning
    # fix below, which is about the FUTURE (this call's own point forward).
    #
    # Every ACCEPTED candidate's handle is returned STILL OPEN (never disposed here) -- this is what
    # actually closes external review rounds 16 and 17's ancestry-confusion class of finding, replacing
    # this function's first fix attempt (round 17), which tried to bound acceptance with a caller-supplied
    # wall-clock exit timestamp instead. Round 17 review found that timestamp-window approach unsound: an
    # exact-instant tie was wrongly treated as proof of non-ancestry (fail-open, a real same-tick child
    # would be silently excluded and left unswept), and more fundamentally FILETIME is wall-clock and
    # Windows does not guarantee system time is monotonic across process events, so a clock adjustment
    # could make a reused-PID impostor's own child fall inside a stale window and be wrongly accepted.
    # Holding this handle open instead of reading a timestamp off it is what Windows itself documents as
    # authoritative: a PID cannot be reused by a new process while any handle to the old process object
    # remains open. As long as the caller keeps this handle open for as long as it keeps treating this PID
    # as an ancestry key (through every further discovery pass and the final confirmation query), no
    # subsequent "ParentProcessId=<this pid>" query can ever be confused by an unrelated process reusing
    # the number, because the number provably cannot have been reused yet. A rejected/dead candidate's
    # handle is closed immediately here, since there is nothing left to protect once it is not accepted.
    # KNOWN RESIDUAL GAP (found by external review round 18, not fixed -- accepted, see
    # Stop-DescendantProcesses' own note): $MinimumStart is itself a wall-clock FILETIME comparison, and
    # round 18 correctly extended round 17's "system time is not guaranteed monotonic" finding to this
    # lower bound too -- a backward clock adjustment could in principle either wrongly reject a genuine
    # child (its recorded creation time now reads earlier than its true parent's) or wrongly accept a
    # reused-PID impostor's child (an old, unrelated ancestor's real child now reads as created after the
    # current occupant's start). Handle-pinning (this function's own core fix, round 17->18) closes PID
    # reuse from the moment of validation FORWARD; it cannot authenticate ancestry claims that depend on
    # comparing two wall-clock readings taken before that pin ever existed, and Windows exposes no simple
    # monotonic, cross-process creation-order API to replace FILETIME comparison here. This is the same
    # category of gap as the two already-accepted ones below (dead-intermediary-before-first-query;
    # skip-sweep-when-worker-already-dead) -- real, narrow, and requiring infrastructure outside this
    # function (a monotonic ordering primitive, or a Windows Job Object) to close completely.
    param([Parameter(Mandatory)][int] $ParentProcessId, [Parameter(Mandatory)][DateTime] $MinimumStart)
    Initialize-GatecraftNativeProcess
    $access = 0x00101001  # PROCESS_TERMINATE (0x0001) | PROCESS_QUERY_LIMITED_INFORMATION (0x1000) | SYNCHRONIZE (0x00100000)
    $errorInvalidParameter = 87  # ERROR_INVALID_PARAMETER: no process exists with this PID -- genuinely gone.
    try {
        $rows = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$ParentProcessId" -ErrorAction Stop)
    }
    catch { throw 'worktree-holder-descendant-unverifiable' }
    $records = [Collections.Generic.List[object]]::new()
    $completedNormally = $false
    try {
        foreach ($row in $rows) {
            if ($null -eq $row.CreationDate) { throw 'worktree-holder-descendant-unverifiable' }
            $childPid = [int]$row.ProcessId
            $handle = [Gatecraft.NativeProcess]::OpenProcess($access, $false, [uint32]$childPid)
            if ($handle -eq [IntPtr]::Zero) {
                # A NULL handle alone is not proof of death (lived: found by external review round 18) --
                # Windows returns NULL for ERROR_ACCESS_DENIED just as it does for a genuinely nonexistent
                # PID, and a live candidate whose ACL denies the requested rights would otherwise be
                # silently treated as "already gone" and skipped by both discovery and final confirmation,
                # while it remains free to write to the worktree. Only ERROR_INVALID_PARAMETER -- no
                # process exists with this PID -- is actually conclusive; any other reason fails closed,
                # matching this project's established "unverifiable fails closed" standard.
                $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                if ($lastError -eq $errorInvalidParameter) { continue }
                throw 'worktree-holder-descendant-unverifiable'
            }
            $accepted = $false
            try {
                [uint32]$exitCode = 0
                if (-not [Gatecraft.NativeProcess]::GetExitCodeProcess($handle, [ref]$exitCode)) { throw 'worktree-holder-descendant-unverifiable' }
                if ($exitCode -ne 259) { continue }  # already exited -- STILL_ACTIVE check
                [long]$creation = 0; [long]$exitTime = 0; [long]$kernelTime = 0; [long]$userTime = 0
                if (-not [Gatecraft.NativeProcess]::GetProcessTimes($handle, [ref]$creation, [ref]$exitTime, [ref]$kernelTime, [ref]$userTime)) { throw 'worktree-holder-descendant-unverifiable' }
                $actualStartUtc = [DateTime]::FromFileTimeUtc($creation)
                $deltaTicks = [Math]::Abs(($row.CreationDate.ToUniversalTime() - $actualStartUtc).Ticks)
                if ($deltaTicks -ge 10) { continue }
                if ($actualStartUtc -lt $MinimumStart) { continue }
                $canonicalStart = $actualStartUtc.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
                $records.Add([pscustomobject]@{ ProcessId = $childPid; Start = $canonicalStart; StartUtc = $actualStartUtc; Handle = $handle })
                $accepted = $true
            }
            catch { throw 'worktree-holder-descendant-unverifiable' }
            finally { if (-not $accepted) { [void][Gatecraft.NativeProcess]::CloseHandle($handle) } }
        }
        # Materialize the array BEFORE flipping $completedNormally (lived: found by external review round
        # 19 -- the prior order set the flag first, so a throwing .ToArray() would skip cleanup below even
        # though nothing was actually returned to a caller yet).
        $resultArray = $records.ToArray()
        $completedNormally = $true
        return ,$resultArray
    }
    finally {
        # If this function is exiting via an exception (a later CIM row was unverifiable, for example),
        # every handle already accepted into $records earlier in THIS SAME call has not yet been handed to
        # any caller and would otherwise leak (lived: found by external review round 18) -- close them all
        # here. On a normal return, ownership passes to the caller and this is a no-op ($completedNormally
        # is true, nothing in $records is touched).
        if (-not $completedNormally) { foreach ($record in $records) { [void][Gatecraft.NativeProcess]::CloseHandle($record.Handle) } }
    }
}

function Stop-DescendantProcesses {
    # Sweeps and stops a declared root PID's entire descendant tree, then confirms none remain. Called
    # only from the branch where this exact invocation just validated the declared worker as live
    # ('ok') and killed it itself (see the caller, Invoke-WorktreeRemove) -- NOT unconditionally.
    #
    # A per-pass restart from the root alone is not enough: once an intermediary node (say C, a child of
    # the root) is itself stopped, Win32_Process's ParentProcessId enumeration can no longer reach it by
    # querying the root's current children -- C no longer appears there at all. But any of C's own live
    # children still correctly report ParentProcessId=C's old PID regardless of whether C itself is alive,
    # so as long as this function keeps re-querying children of every PID it has EVER seen in this sweep
    # (not just the ones still alive), a live grandchild whose only path from the root ran through a node
    # THIS FUNCTION ITSELF stopped in an earlier pass is never lost.
    #
    # KNOWN RESIDUAL GAP #1 (documented, not fixed -- confirmed real by external review round 13 and by a
    # direct repro): the above only helps for an intermediary this sweep has already observed alive at
    # least once. If C exits ON ITS OWN before this function's very first query ever runs (e.g. a worker
    # that spawns a short-lived relay process which itself spawns a longer-lived one, then exits
    # immediately), this sweep never learns C's PID existed at all. G's own live process still correctly
    # reports ParentProcessId=C's old PID -- that field itself never becomes wrong or disappears -- but
    # the *discoverable path* from the root to that fact is gone: nothing enumerable from the root's own
    # (or any other known) PID ever points at C once Win32_Process stops listing C, because it only lists
    # currently-alive processes. No pure application-level fix closes this: it needs a Windows Job Object
    # assigned to the worker at spawn time (TerminateJobObject kills every process ever added to the job,
    # including ones already dead-and-delinked from live enumeration) -- a change to how workers are
    # launched, not to this function.
    #
    # GAP #2 CLOSED FOR REAL (external review round 16's finding; round 17's first attempt at this was
    # itself found unsound by round 17 review and is corrected here): every PID used as an ancestry key --
    # the root (see caller, whose `Resolve-ProcessLifecycle` handle is passed in as `$RootHandle`) and
    # every descendant discovered below -- now stays PINNED: its native handle, opened once and validated
    # by either `Resolve-ProcessLifecycle` (root) or `Get-ChildProcessRecords` (every descendant, which now
    # returns each accepted candidate's handle still open instead of disposing it), is kept in
    # `$pinnedHandles` and never closed until this entire function is done, success or failure. Round 17's
    # first fix instead tried to bound acceptance with a caller-read wall-clock exit timestamp
    # (`ExitUtc`/`-MaximumStartExclusive`) and was found unsound on re-review: an exact-instant tie was
    # wrongly excluded (fail-open -- a live same-tick child would go unswept), and system time is not
    # guaranteed monotonic, so a clock adjustment could let a reused-PID impostor's own child fall inside a
    # stale window. Holding the real OS handle open, rather than trusting any timestamp read from it, is
    # what Windows itself documents as authoritative: a PID cannot be reused by a new process while any
    # handle to the old process object remains open. As long as every ancestry-key PID's handle stays open
    # for this function's entire run, no "ParentProcessId=<that pid>" query anywhere in this sweep can ever
    # be confused by an unrelated process reusing the number, because reuse is structurally impossible
    # while pinned -- no wall-clock reasoning needed or trusted anywhere in this function.
    #
    # KNOWN RESIDUAL GAP #3 (documented, not fixed -- found by external review round 18): pinning closes
    # PID reuse from the moment of validation forward, but every candidate still has to clear
    # Get-ChildProcessRecords' `$MinimumStart` lower bound first, which is itself a wall-clock FILETIME
    # comparison and inherits the same non-monotonic-system-time risk round 17 found in the (now-removed)
    # upper bound. See that function's own comment for the exact scenario and why it is accepted rather
    # than fixed here, alongside gap #1 above.
    param([Parameter(Mandatory)][int] $RootProcessId, [Parameter(Mandatory)][string] $RootStart, [Parameter(Mandatory)][IntPtr] $RootHandle, [Parameter(Mandatory)][int] $MaxCount, [Parameter(Mandatory)][int] $MaxPasses)
    Initialize-GatecraftNativeProcess
    # Maps each known PID in this sweep to its own validated creation time (the root's caller-declared
    # start, or a discovered descendant's own native-handle-cross-checked start) -- this is the lower bound
    # passed to Get-ChildProcessRecords when querying that PID's own children, so a numeric ParentProcessId
    # match alone is never enough to trust a candidate as a real descendant (see Get-ChildProcessRecords'
    # own comment on the ancestry-confusion gap this closes). This bound is about the PAST (was this PID
    # number recently reused from an older, unrelated ancestor before we validated it) and is unrelated to
    # the pinning below, which is about the FUTURE (this sweep's own point forward).
    $seenStarts = [Collections.Generic.Dictionary[int, DateTime]]::new()
    $pinnedHandles = [Collections.Generic.List[IntPtr]]::new()
    $pinnedHandles.Add($RootHandle)
    $rootStartUtc = [DateTime]::Parse($RootStart, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
    $seenStarts[$RootProcessId] = $rootStartUtc
    $stoppedAny = $false
    try {
        for ($pass = 0; $pass -lt $MaxPasses; $pass++) {
            $discoveredNew = $false
            $toStop = [Collections.Generic.List[object]]::new()
            foreach ($knownPid in @($seenStarts.Keys)) {
                $children = Get-ChildProcessRecords -ParentProcessId $knownPid -MinimumStart $seenStarts[$knownPid]
                # Pin the ENTIRE batch first, in its own pass with no check that can throw, before any
                # duplicate/bound logic runs (lived: found by external review round 19 -- round 18's fix
                # pinned one child at a time interleaved with the throwing bound-check, so a batch of
                # several new children could still throw partway through, leaving any child positioned
                # AFTER the one that tripped the throw neither pinned nor closed; List.Add itself cannot
                # meaningfully throw here, so this first pass is unconditional). Every handle
                # Get-ChildProcessRecords ever hands back is now owned by $pinnedHandles before the second
                # pass below can ever throw, so the enclosing function-level `finally` closes it exactly
                # once no matter what happens next.
                foreach ($child in $children) { $pinnedHandles.Add($child.Handle) }
                foreach ($child in $children) {
                    if ($seenStarts.ContainsKey($child.ProcessId)) { continue }
                    if ($seenStarts.Count -gt $MaxCount) { throw 'worktree-holder-descendants-unbounded' }
                    $seenStarts[$child.ProcessId] = $child.StartUtc
                    $discoveredNew = $true
                    $toStop.Add($child)
                }
            }
            foreach ($descendant in $toStop) {
                # Kill through the exact handle Get-ChildProcessRecords already opened and validated for
                # this candidate during discovery above -- never reopen/re-resolve this PID by number, the
                # same discipline Resolve-ProcessLifecycle applies to the root.
                [void][Gatecraft.NativeProcess]::TerminateProcess($descendant.Handle, 1)
                if ([Gatecraft.NativeProcess]::WaitForSingleObject($descendant.Handle, 5000) -ne 0) { throw 'worktree-holder-descendant-alive' }
                [uint32]$exitCode = 0
                if (-not [Gatecraft.NativeProcess]::GetExitCodeProcess($descendant.Handle, [ref]$exitCode) -or $exitCode -eq 259) { throw 'worktree-holder-descendant-alive' }
                $stoppedAny = $true
            }
            if (-not $discoveredNew) { break }
        }
        # Final confirmation: re-query children of every PID ever seen in this sweep, including ones
        # already stopped -- a dead intermediary's own children are still reachable this way (see comment
        # above), so this is a real convergence check, not merely re-checking the root. Every ancestry-key
        # handle is still pinned open at this point (closed only in the enclosing `finally`), so this query
        # is exactly as reuse-proof as the discovery passes above.
        foreach ($knownPid in @($seenStarts.Keys)) {
            $remaining = Get-ChildProcessRecords -ParentProcessId $knownPid -MinimumStart $seenStarts[$knownPid]
            # Close immediately: whether or not $remaining is empty, this function is either returning
            # (nothing left to protect) or about to throw (aborting entirely) -- neither path needs these
            # handles held any longer.
            foreach ($record in $remaining) { [void][Gatecraft.NativeProcess]::CloseHandle($record.Handle) }
            if ($remaining.Count -gt 0) { throw 'worktree-holder-descendant-alive' }
        }
        return $stoppedAny
    }
    finally {
        # Every ancestry-key handle this function ever pinned -- the root's (opened by the caller) and
        # every discovered descendant's -- is released here exactly once, on every path (success, a
        # discovery-time throw, or a final-confirmation throw). This is the only place any of them closes.
        foreach ($handle in $pinnedHandles) { [void][Gatecraft.NativeProcess]::CloseHandle($handle) }
    }
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
    # Never honor repository config that hides dirty submodules from a foreign-change sweep.
    return ,(Invoke-GitBytes -RepositoryRoot $RepositoryRoot -Arguments @('status', '--porcelain=v1', '-z', '--untracked-files=all', '--ignore-submodules=none') -FailureCode 'git-status-failed')
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

function Assert-RegisteredWorktree {
    param([Parameter(Mandatory)][string] $RepositoryRoot, [Parameter(Mandatory)][string] $WorktreePath)
    $listBytes = Invoke-GitBytes -RepositoryRoot $RepositoryRoot -Arguments @('worktree', 'list', '--porcelain') -FailureCode 'git-worktree-list-failed'
    $listText = ([Text.UTF8Encoding]::new($false, $true).GetString($listBytes)) -replace "`r`n", "`n"
    foreach ($line in @($listText -split "`n")) {
        if (-not $line.StartsWith('worktree ', [StringComparison]::Ordinal)) { continue }
        $candidate = $line.Substring('worktree '.Length)
        try { $candidateFull = ConvertTo-LocalFullPath -DeclaredPath $candidate -InvalidCode 'git-output-invalid' -NonLocalCode 'git-output-invalid' }
        catch { continue }
        if (Test-PathEqual -Left $candidateFull -Right $WorktreePath) { return }
    }
    throw 'worktree-not-registered'
}

function Test-RegisteredWorktree {
    param([Parameter(Mandatory)][string] $RepositoryRoot, [Parameter(Mandatory)][string] $WorktreePath)
    try { Assert-RegisteredWorktree -RepositoryRoot $RepositoryRoot -WorktreePath $WorktreePath; return $true }
    catch {
        if ([string]$_.Exception.Message -ceq 'worktree-not-registered') { return $false }
        throw
    }
}

function Get-WorktreeAdminDir {
    # Resolved once, while the worktree is still fully intact, so a later torn removal attempt
    # (deregistered but not deleted — git worktree remove is not atomic on Windows) has a known-good
    # admin-dir path to restore into. Never re-derived after a failed attempt: a torn worktree can no
    # longer answer `git -C <worktree> rev-parse --git-dir` for itself.
    param([Parameter(Mandatory)][object] $Context, [Parameter(Mandatory)][string] $WorktreePath)
    $bytes = Invoke-GitBytes -RepositoryRoot $WorktreePath -Arguments @('rev-parse', '--path-format=absolute', '--git-dir') -FailureCode 'git-worktree-admin-dir-failed'
    $text = ConvertFrom-GitLine -Bytes $bytes -FailureCode 'git-output-invalid'
    $full = ConvertTo-LocalFullPath -DeclaredPath $text -InvalidCode 'git-output-invalid' -NonLocalCode 'git-output-invalid'
    $expectedParent = [IO.Path]::Combine($Context.GitCommonDir, 'worktrees')
    if (-not (Test-PathAtOrBelow -Candidate $full -Parent $expectedParent)) { throw 'git-worktree-admin-dir-unexpected' }
    Assert-SafePathComponents -FullPath $full -ReparseCode 'path-reparse'
    if (-not [IO.Directory]::Exists($full)) { throw 'git-worktree-admin-dir-missing' }
    return $full
}

function Backup-WorktreeRemovalState {
    # A failed `git worktree remove` on Windows can tear two separate things before the locked
    # file blocks the actual unlink: the shared admin dir (.git/worktrees/<name>) and the worktree's
    # own `.git` marker file (which just contains `gitdir: <admin-dir>`). Both are backed up here,
    # in memory, before every attempt, so a torn attempt can be restored to exactly its prior state.
    param([Parameter(Mandatory)][string] $AdminDir, [Parameter(Mandatory)][string] $WorktreePath)
    Assert-SafePathComponents -FullPath $AdminDir -ReparseCode 'path-reparse'
    if (-not [IO.Directory]::Exists($AdminDir)) { throw 'worktree-admin-dir-missing' }
    $files = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($AdminDir)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        Assert-NotReparsePoint -Path $directory -Code 'path-reparse'
        foreach ($entry in [IO.DirectoryInfo]::new($directory).GetFileSystemInfos()) {
            Assert-NotReparsePoint -Path $entry.FullName -Code 'path-reparse'
            if ($entry -is [IO.DirectoryInfo]) { $pending.Push($entry.FullName) }
            elseif ($entry -is [IO.FileInfo]) {
                $relative = [IO.Path]::GetRelativePath($AdminDir, $entry.FullName)
                $files.Add([pscustomobject]@{ Relative = $relative; Bytes = [IO.File]::ReadAllBytes($entry.FullName) })
            }
            else { throw 'worktree-admin-dir-unsupported-entry' }
        }
    }
    $markerPath = [IO.Path]::Combine($WorktreePath, '.git')
    Assert-NotReparsePoint -Path $markerPath -Code 'path-reparse'
    if (-not [IO.File]::Exists($markerPath)) { throw 'worktree-git-marker-missing' }
    $markerBytes = [IO.File]::ReadAllBytes($markerPath)
    return [pscustomobject]@{ AdminFiles = @($files); MarkerBytes = $markerBytes }
}

function Restore-WorktreeRemovalState {
    param([Parameter(Mandatory)][string] $AdminDir, [Parameter(Mandatory)][string] $WorktreePath, [Parameter(Mandatory)][object] $Backup)
    if ([IO.Directory]::Exists($AdminDir) -or [IO.File]::Exists($AdminDir)) { throw 'worktree-admin-dir-unexpected' }
    foreach ($file in $Backup.AdminFiles) {
        $target = [IO.Path]::GetFullPath([IO.Path]::Combine($AdminDir, $file.Relative))
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::WriteAllBytes($target, $file.Bytes)
    }
    Assert-SafePathComponents -FullPath $AdminDir -ReparseCode 'path-reparse'
    $markerPath = [IO.Path]::Combine($WorktreePath, '.git')
    if (-not [IO.File]::Exists($markerPath)) {
        if ([IO.Directory]::Exists($markerPath)) { throw 'worktree-git-marker-unexpected' }
        [IO.File]::WriteAllBytes($markerPath, $Backup.MarkerBytes)
    }
    Assert-NotReparsePoint -Path $markerPath -Code 'path-reparse'
}

function Assert-WorktreeCleanBeforeRemoval {
    # Called once, before the first removal attempt, while the worktree is still fully intact.
    # A failed Windows removal attempt can itself leave the worktree looking "dirty" afterward (it can
    # delete some tracked, unlocked files before the locked one blocks it, so git sees them as
    # missing/modified on a later attempt) even though nothing the caller did made it genuinely dirty.
    # Verifying real cleanliness up front, once, lets every attempt safely use `--force` afterward:
    # `--force` only skips git's own dirty-worktree check, and this call already proved there was
    # nothing real for that check to protect — it never bypasses the locked-file unlink itself.
    param([Parameter(Mandatory)][string] $WorktreePath)
    $statusBytes = Invoke-GitBytes -RepositoryRoot $WorktreePath -Arguments @('status', '--porcelain=v1', '-z', '--untracked-files=all', '--ignore-submodules=none') -FailureCode 'git-worktree-status-failed'
    if ($statusBytes.Length -ne 0) { throw 'worktree-dirty' }
}

function Invoke-GitWorktreeRemoveAttempt {
    param([Parameter(Mandatory)][string] $RepositoryRoot, [Parameter(Mandatory)][string] $WorktreePath)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $RepositoryRoot
    $start.Environment['GIT_OPTIONAL_LOCKS'] = '0'
    $start.ArgumentList.Add('-C')
    $start.ArgumentList.Add($RepositoryRoot)
    $start.ArgumentList.Add('worktree')
    $start.ArgumentList.Add('remove')
    # Safe only because Assert-WorktreeCleanBeforeRemoval already proved the worktree was genuinely
    # clean before the first attempt touched anything; --force here only skips re-checking that (which
    # a prior failed attempt can itself have made look dirty), never the physical locked-file unlink.
    $start.ArgumentList.Add('--force')
    $start.ArgumentList.Add('--')
    $start.ArgumentList.Add($WorktreePath)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { return $false }
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [void]$outTask.GetAwaiter().GetResult()
        [void]$errTask.GetAwaiter().GetResult()
        return ($process.ExitCode -eq 0) -and (-not [IO.Directory]::Exists($WorktreePath))
    }
    catch [ComponentModel.Win32Exception] { return $false }
    finally { $process.Dispose() }
}

function Get-TrackedRelativePaths {
    # A cheap manifest (mode + path, no content) of every tracked entry that is actually present on disk
    # right now, taken once via read-only `ls-files -s` while the worktree is still known-clean (right
    # after Assert-WorktreeCleanBeforeRemoval), so a later failed attempt can be checked against it
    # without ever having had to buffer the full worktree contents up front. The mode lets
    # Restore-MissingTrackedFiles tell a plain file (100644/100755) apart from a symlink (120000) or a
    # gitlink/submodule (160000) — the latter two are never safely reconstructable from a blob's raw
    # bytes via a plain file write, so they must not be treated the same as an ordinary tracked file.
    #
    # Deliberately presence-based, not index-metadata-based: a tracked entry the index reports but that
    # is not actually on disk right now (sparse checkout, the skip-worktree bit, or any other legitimate
    # reason) is excluded from the manifest entirely, so a later repair can never synthesize back
    # something that was never really there to begin with — it only ever restores paths this function
    # itself observed present at the exact moment the worktree was proven clean.
    param([Parameter(Mandatory)][string] $WorktreePath)
    $bytes = Invoke-GitBytes -RepositoryRoot $WorktreePath -Arguments @('ls-files', '-z', '-s') -FailureCode 'git-worktree-ls-files-failed'
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($candidate in @($text -split "`0")) {
        if ($candidate.Length -eq 0) { continue }
        if ($candidate -cnotmatch '^(?<mode>[0-7]{6}) [0-9a-f]{40,64} [0-3]\t(?<path>.+)$') { throw 'git-worktree-ls-files-failed' }
        $relative = $Matches.path
        [void](Assert-RepositoryRelativePath -Value $relative)
        $full = Assert-RepositoryPathSafe -RepositoryRoot $WorktreePath -RelativePath $relative
        if (-not [IO.File]::Exists($full) -and -not [IO.Directory]::Exists($full)) { continue }
        $entries.Add([pscustomobject]@{ Mode = $Matches.mode; Path = $relative })
    }
    return @($entries)
}

function Test-AutoCrlfSafe {
    # core.autocrlf is repository CONFIG, not a per-path attribute — when a file's `text` attribute is
    # unspecified, Git still consults this config to decide whether checkout applies CRLF translation.
    # A raw `git show` blob write bypasses that translation entirely, so any autocrlf setting other than
    # the default/false makes byte-raw restore unsafe for every plain file in this worktree, not just
    # paths with an explicit attribute — checked once, repository-wide, rather than per path.
    param([Parameter(Mandatory)][string] $WorktreePath)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $WorktreePath
    $start.ArgumentList.Add('-C')
    $start.ArgumentList.Add($WorktreePath)
    $start.ArgumentList.Add('config')
    $start.ArgumentList.Add('--get')
    $start.ArgumentList.Add('core.autocrlf')
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'git-worktree-config-failed' }
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $outTask.GetAwaiter().GetResult()
        [void]$errTask.GetAwaiter().GetResult()
        if ($process.ExitCode -eq 1) { return $true }
        if ($process.ExitCode -ne 0) { throw 'git-worktree-config-failed' }
        return ($stdout.Trim().ToLowerInvariant() -ceq 'false')
    }
    catch [ComponentModel.Win32Exception] { throw 'git-worktree-config-failed' }
    finally { $process.Dispose() }
}

function Test-SafeToAutoRestoreTrackedFile {
    # Deliberately conservative: only a plain regular file (100644/100755) with no configured Git
    # attribute that could transform its checked-out bytes — filter/text/eol (smudge/clean, LFS, EOL
    # normalization), crlf (legacy alias implying text/eol), ident ($Id$ expansion), or working-tree-
    # encoding (blob re-encoding) — is restored automatically. A symlink (120000) restored via a raw-
    # blob file write would materialize as a regular file containing the link-target *text* instead of
    # an actual symlink; a gitlink/submodule (160000) has no blob content at all to write. Anything
    # outside the safe set is deliberately left alone here — Repair-WorktreeAfterFailedAttempt's final
    # clean-status check then fails closed if it's genuinely still missing, rather than this function
    # silently fabricating incorrect content or the wrong kind of filesystem entry.
    param([Parameter(Mandatory)][string] $WorktreePath, [Parameter(Mandatory)][string] $RelativePath, [Parameter(Mandatory)][string] $Mode, [Parameter(Mandatory)][bool] $AutoCrlfSafe)
    if (-not $AutoCrlfSafe) { return $false }
    if ($Mode -cnotin @('100644', '100755')) { return $false }
    $bytes = Invoke-GitBytes -RepositoryRoot $WorktreePath -Arguments @('check-attr', 'filter', 'text', 'eol', 'crlf', 'ident', 'working-tree-encoding', '--', $RelativePath) -FailureCode 'worktree-restore-failed'
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    foreach ($line in @($text -split "`n")) {
        if ($line.Length -eq 0) { continue }
        if ($line -cnotmatch ': (?:filter|text|eol|crlf|ident|working-tree-encoding): (?<value>.+)\r?$') { throw 'worktree-restore-failed' }
        if ($Matches.value -cne 'unspecified') { return $false }
    }
    return $true
}

function Restore-MissingTrackedFiles {
    # Production guard code must never invoke a Git mutation command (see Test-ProtocolContract.ps1's
    # forbidden-mutations check) — restoring a tracked file a failed attempt deleted is done entirely
    # with read-only Git plumbing (`show` for the recorded blob content) plus direct filesystem writes,
    # never by handing Git itself a command that could rewrite the working tree wholesale.
    param([Parameter(Mandatory)][string] $WorktreePath, [Parameter(Mandatory)][object[]] $TrackedPaths, [Parameter(Mandatory)][bool] $AutoCrlfSafe)
    foreach ($entry in $TrackedPaths) {
        $full = Assert-RepositoryPathSafe -RepositoryRoot $WorktreePath -RelativePath $entry.Path
        if ([IO.File]::Exists($full) -or [IO.Directory]::Exists($full)) { continue }
        if (-not (Test-SafeToAutoRestoreTrackedFile -WorktreePath $WorktreePath -RelativePath $entry.Path -Mode $entry.Mode -AutoCrlfSafe $AutoCrlfSafe)) { continue }
        $blobBytes = Invoke-GitBytes -RepositoryRoot $WorktreePath -Arguments @('show', "HEAD:$($entry.Path)") -FailureCode 'worktree-restore-failed'
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
        [IO.File]::WriteAllBytes($full, $blobBytes)
    }
}

function Repair-WorktreeAfterFailedAttempt {
    # A failed attempt can tear more than the admin dir/marker: `git worktree remove --force` can also
    # delete other tracked-but-unlocked files before the locked one blocks it. Both callers of this
    # function — the recover path (about to retry) and the fail-closed path (about to give up and
    # report failure) — share the same requirement: a failed attempt must never silently report success
    # over undetected damage, so both repair fully rather than only the caller that happens to retry.
    #
    # Restoring missing tracked files from their recorded blob content is safe here specifically because
    # Assert-WorktreeCleanBeforeRemoval already proved, once, that the worktree matched HEAD exactly
    # before the first attempt touched anything — so every difference found now was self-inflicted by a
    # failed removal attempt, never a real caller/user change. This does not close every theoretical
    # TOCTOU window (something could in principle change the worktree in the narrow gap between that
    # check and an attempt), but that same narrow race exists in Git's own unforced clean-check-then-
    # unlink sequence. Restore-MissingTrackedFiles only ever auto-heals the subset it can prove is safe
    # (plain files with no content-transforming attribute or config); the final clean-status verification
    # below is what actually delivers the guarantee end to end — a failed attempt either ends up fully
    # repaired, or this throws `worktree-restore-failed` rather than reporting false success over an
    # entry it could not safely auto-heal (a symlink, a gitlink, or a filtered/CRLF-sensitive file).
    param([Parameter(Mandatory)][string] $RepositoryRoot, [Parameter(Mandatory)][string] $WorktreePath, [Parameter(Mandatory)][string] $AdminDir, [Parameter(Mandatory)][object] $Backup, [Parameter(Mandatory)][object[]] $TrackedPaths, [Parameter(Mandatory)][bool] $AutoCrlfSafe)
    if (-not (Test-RegisteredWorktree -RepositoryRoot $RepositoryRoot -WorktreePath $WorktreePath)) {
        Restore-WorktreeRemovalState -AdminDir $AdminDir -WorktreePath $WorktreePath -Backup $Backup
        if (-not (Test-RegisteredWorktree -RepositoryRoot $RepositoryRoot -WorktreePath $WorktreePath)) { throw 'worktree-restore-failed' }
    }
    Restore-MissingTrackedFiles -WorktreePath $WorktreePath -TrackedPaths $TrackedPaths -AutoCrlfSafe $AutoCrlfSafe
    $statusBytes = Invoke-GitBytes -RepositoryRoot $WorktreePath -Arguments @('status', '--porcelain=v1', '-z', '--untracked-files=all', '--ignore-submodules=none') -FailureCode 'worktree-restore-failed'
    if ($statusBytes.Length -ne 0) { throw 'worktree-restore-failed' }
}

function Invoke-GuardedWorktreeRemoveAttempt {
    # git worktree remove is not atomic on Windows: it can deregister the worktree from the admin
    # dir (.git/worktrees/<name>), delete its own `.git` marker file, and/or delete other tracked-but-
    # unlocked files, all before a locked file blocks the actual directory deletion — leaving a torn
    # state. Every attempt backs up the admin dir and marker first; on failure, Repair-WorktreeAfterFailedAttempt
    # either fully restores the worktree to its exact starting state or fails this closed — never both
    # reporting failure and leaving partial damage behind.
    param([Parameter(Mandatory)][string] $RepositoryRoot, [Parameter(Mandatory)][string] $WorktreePath, [Parameter(Mandatory)][string] $AdminDir, [Parameter(Mandatory)][object[]] $TrackedPaths, [Parameter(Mandatory)][bool] $AutoCrlfSafe)
    $backup = Backup-WorktreeRemovalState -AdminDir $AdminDir -WorktreePath $WorktreePath
    if (Invoke-GitWorktreeRemoveAttempt -RepositoryRoot $RepositoryRoot -WorktreePath $WorktreePath) { return $true }
    if (-not [IO.Directory]::Exists($WorktreePath)) { return $false }
    Repair-WorktreeAfterFailedAttempt -RepositoryRoot $RepositoryRoot -WorktreePath $WorktreePath -AdminDir $AdminDir -Backup $backup -TrackedPaths $TrackedPaths -AutoCrlfSafe $AutoCrlfSafe
    return $false
}

function Invoke-WorktreeRemove {
    param([object] $Context, [Collections.Generic.Dictionary[string,string]] $Options)
    $worktreePath = ConvertTo-LocalFullPath -DeclaredPath $Options['--worktree-path'] -InvalidCode 'worktree-path-invalid' -NonLocalCode 'worktree-path-nonlocal'
    Assert-SafePathComponents -FullPath $worktreePath -ReparseCode 'path-reparse'
    if (Test-PathEqual -Left $worktreePath -Right $Context.RepositoryRoot) { throw 'worktree-path-invalid' }
    $workerPid = ConvertTo-PositivePid -Value $Options['--worker-pid']
    $workerStart = ConvertTo-CanonicalProcessStart -Value $Options['--worker-process-start']
    # Test-only override (gated by GATECRAFT_GUARD_TEST_CONTROLS at the dispatcher, same as this file's
    # other test-only knobs): lets a fixture cross the descendant-count bound deterministically with a
    # handful of real processes instead of needing to spawn hundreds. Production callers never pass this;
    # the real ceiling is always 256.
    $maxDescendants = if ($Options.ContainsKey('--test-max-descendants')) { ConvertTo-PositivePid -Value $Options['--test-max-descendants'] } else { 256 }

    Assert-RegisteredWorktree -RepositoryRoot $Context.RepositoryRoot -WorktreePath $worktreePath
    if (-not [IO.Directory]::Exists($worktreePath)) { throw 'worktree-path-missing' }

    # The declared worker's liveness must be resolved, and the worker actually stopped if still alive,
    # BEFORE taking any "clean" snapshot of the worktree (Assert-WorktreeCleanBeforeRemoval and
    # Get-TrackedRelativePaths below) — that snapshot is what the eventual `--force` removal trusts as
    # ground truth. Snapshotting first and only resolving the worker afterward (the order this function
    # used through round 10) leaves a window where a still-running declared worker can legitimately write
    # to a tracked file after the snapshot but before its own termination, and the forced removal would
    # then silently discard that write along with the rest of the worktree (lived: found by external
    # review round 11, reproduced with a worker that wrote a tracked file after the clean check but before
    # termination — guard reported mode=recovered/exit=0 and the write was gone). Resolving the worker
    # first means the snapshot below can only ever observe a worktree no longer being written to by the
    # one process this command is allowed to touch: a genuinely dirty tree at that point is a real
    # pre-existing or in-flight change unrelated to the declared worker's own shutdown, and correctly
    # fails closed via Assert-WorktreeCleanBeforeRemoval's normal `worktree-dirty` rather than being
    # silently force-deleted.
    #
    # A live worker can hold no blocking handle on this worktree at the exact instant removal runs (its
    # CWD is elsewhere, or its I/O is idle) — a first removal attempt that succeeds anyway must never be
    # read as proof the worker is gone (lived: found by external review round 6). Only a binding state
    # confirmed not 'ok' (already dead, or the PID was reused by something unrelated) — or a live holder
    # this call itself just stopped and re-confirmed dead — may be followed by taking the clean snapshot
    # and declaring the worktree removed. Never discover "who else" might be locking it and never touch
    # any process but the exact declared one. `process-unverifiable` proves nothing — the declared worker
    # could still be alive and holding this worktree — so it must fail closed rather than being treated
    # like a confirmed-dead/mismatched PID (lived: found by external review round 7).
    $mode = "clean"
    $state = Get-ProcessBindingState -ProcessId $workerPid -ExpectedStart $workerStart
    if ($state -ceq 'process-unverifiable') { throw 'worktree-holder-unverifiable' }
    if ($state -ceq 'ok') {
        # Stop the exact declared worker through one native handle opened with only the rights this needs,
        # held continuously across validate+kill+confirm (see Resolve-ProcessLifecycle) -- not .NET's
        # Process.Handle/SafeHandle, whose implicit PROCESS_ALL_ACCESS request a restricted/sandboxed
        # worker's process ACL can legitimately deny even though the narrow rights actually needed here
        # are granted (lived: found by external review round 9); and not the old separate
        # validate/kill/re-check calls each opening and disposing their own handle (lived: found by
        # external review round 16). The handle is deliberately NOT closed here on success -- it stays
        # pinned open for as long as Stop-DescendantProcesses below keeps treating this PID as an ancestry
        # key, and is only released once that entire sweep is done (see its own comment for why holding
        # the handle open, not reading a wall-clock exit time off it, is what actually closes round 16/17).
        # Stopped first, before touching any descendant: TerminateProcess never implicitly kills a
        # process's children on Windows (there is no Job Object here to make that atomic), so a live
        # child could otherwise go on spawning further children indefinitely. Killing the root here first
        # means it can never start another one — every descendant left after this point already existed
        # and is therefore fully enumerable by walking ParentProcessId from here on.
        $rootLifecycle = Resolve-ProcessLifecycle -ProcessId $workerPid -ExpectedStart $workerStart -FailClosedCode 'worktree-holder-alive'
        $mode = 'recovered'

        # A child the declared worker already spawned (its own CWD elsewhere, so it never blocks a
        # removal attempt) can outlive the worker and still write a tracked change before it exits on its
        # own, reproducing the exact same data loss this bead exists to close — just one process
        # generation down (lived: found by external review round 12).
        #
        # Deliberately scoped to only run here, immediately after THIS call validated $workerPid as the
        # exact declared worker (state was 'ok' a moment ago) and then killed it itself. Round 13 tried
        # running this same sweep unconditionally (including when $state was 'process-dead' or
        # 'process-start-mismatch' — the declared worker already gone or replaced before this call even
        # started), reasoning that ParentProcessId is fixed at creation and outlives its parent. That is
        # true, but round 15 review found a sharper problem it doesn't solve: if $workerPid was reused by
        # a wholly unrelated live process U between the declared worker's actual exit and this invocation,
        # "children of $workerPid" now means U's own real, legitimate children — a creation-time lower
        # bound alone cannot tell U's child apart from the declared worker's, since both were created
        # after the declared worker's own start. Round 16 found scoping to only the just-validated branch
        # narrows that window but does not close it by itself; rounds 17-18 close it by handing
        # $rootLifecycle.Handle — still open, never re-resolved by PID number — into
        # Stop-DescendantProcesses, which keeps it (and every descendant's own handle) pinned open for its
        # entire run, structurally preventing this exact PID number from being reused by anything else for
        # as long as this sweep still treats it as an ancestry key (see that function's own comment).
        [void](Stop-DescendantProcesses -RootProcessId $workerPid -RootStart $workerStart -RootHandle $rootLifecycle.Handle -MaxCount $maxDescendants -MaxPasses 6)
    }

    Assert-WorktreeCleanBeforeRemoval -WorktreePath $worktreePath
    $adminDir = Get-WorktreeAdminDir -Context $Context -WorktreePath $worktreePath
    $trackedPaths = Get-TrackedRelativePaths -WorktreePath $worktreePath
    $autoCrlfSafe = Test-AutoCrlfSafe -WorktreePath $worktreePath

    if (Invoke-GuardedWorktreeRemoveAttempt -RepositoryRoot $Context.RepositoryRoot -WorktreePath $worktreePath -AdminDir $adminDir -TrackedPaths $trackedPaths -AutoCrlfSafe $autoCrlfSafe) {
        [Console]::Out.WriteLine("GUARD_WORKTREE_REMOVED code=worktree-removed mode=$mode")
        return
    }
    if (-not [IO.Directory]::Exists($worktreePath)) { throw 'worktree-remove-failed' }

    # A real, undeclared blocker (never the declared worker — that was already resolved above) can still
    # hold the directory open; one retry covers a handle released asynchronously between attempts.
    if (-not (Invoke-GuardedWorktreeRemoveAttempt -RepositoryRoot $Context.RepositoryRoot -WorktreePath $worktreePath -AdminDir $adminDir -TrackedPaths $trackedPaths -AutoCrlfSafe $autoCrlfSafe)) { throw 'worktree-remove-failed' }
    [Console]::Out.WriteLine('GUARD_WORKTREE_REMOVED code=worktree-removed mode=recovered')
}

function Invoke-ProbeChildWindow {
    # Test-only diagnostic (gated by GATECRAFT_GUARD_TEST_CONTROLS=1 at the dispatcher, never reachable in
    # production use): calls Get-ChildProcessRecords directly with a caller-supplied lower bound and prints
    # the accepted PIDs, closing every returned handle immediately afterward (this probe has nothing
    # further to protect once it has read the PID). Exists to exercise Get-ChildProcessRecords' real,
    # live-process discovery and $MinimumStart rejection logic deterministically -- a genuine descendant of
    # a real parent must be accepted, and a candidate whose creation predates the declared parent's own
    # start must be rejected -- without depending on real OS-level PID-reuse timing, which cannot be forced
    # on demand in a test. Never invoked by Invoke-WorktreeRemove or any other production path.
    param([object] $Context, [Collections.Generic.Dictionary[string,string]] $Options)
    [void]$Context
    $parentPid = ConvertTo-PositivePid -Value $Options['--parent-pid']
    $minimumStart = ConvertTo-CanonicalProcessStart -Value $Options['--minimum-start']
    $minimumStartUtc = [DateTime]::Parse($minimumStart, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
    $records = Get-ChildProcessRecords -ParentProcessId $parentPid -MinimumStart $minimumStartUtc
    $pids = [Collections.Generic.List[int]]::new()
    foreach ($record in $records) { $pids.Add($record.ProcessId); [void][Gatecraft.NativeProcess]::CloseHandle($record.Handle) }
    [Console]::Out.WriteLine((ConvertTo-CanonicalJson -Value @($pids)))
}

if ($PSVersionTable.PSVersion.Major -lt 7) { Stop-Guard -ExitCode 64 -Code 'powershell-version' }

try {
    $parsed = Read-GuardArguments -Tokens @($args)
    $testOptionsPresent = @(@('--test-acquire-barrier','--test-participant','--test-timeout-ms','--test-max-descendants') | Where-Object { $parsed.Values.ContainsKey($_) })
    if ($testOptionsPresent.Count -gt 0 -and [Environment]::GetEnvironmentVariable('GATECRAFT_GUARD_TEST_CONTROLS', [EnvironmentVariableTarget]::Process) -cne '1') { throw 'test-controls-disabled' }
    if ($parsed.Command -ceq 'probe-child-window' -and [Environment]::GetEnvironmentVariable('GATECRAFT_GUARD_TEST_CONTROLS', [EnvironmentVariableTarget]::Process) -cne '1') { throw 'test-controls-disabled' }
    $context = Get-RepositoryContext -DeclaredRoot $parsed.Values['--repository-root']
    switch ($parsed.Command) {
        'acquire' { Invoke-LockAcquire -Context $context -Options $parsed.Values }
        'release' { Invoke-LockRelease -Context $context -Options $parsed.Values }
        'baseline' { Invoke-BaselineCreate -Context $context -Options $parsed.Values }
        'sweep' { Invoke-BaselineSweep -Context $context -Options $parsed.Values }
        'worktree-remove' { Invoke-WorktreeRemove -Context $context -Options $parsed.Values }
        'probe-child-window' { Invoke-ProbeChildWindow -Context $context -Options $parsed.Values }
    }
    exit 0
}
catch {
    $message = [string]$_.Exception.Message
    $code = if ($message -cmatch '^(?<code>[a-z][a-z0-9.-]*)') { $Matches.code } else { 'internal-error' }
    Stop-Guard -ExitCode (Get-GuardExitCode -Code $code) -Code $code
}
