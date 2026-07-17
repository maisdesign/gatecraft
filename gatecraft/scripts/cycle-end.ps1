Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-CycleEndUsage {
    [Console]::Out.WriteLine(@'
Usage:
  pwsh -NoProfile -File gatecraft/scripts/cycle-end.ps1 \
    --state-root <absolute-path> --event-id <stable-id> \
    --cycle-sequence <positive-decimal> --mode <attended|unattended> \
    --occurred-at <RFC3339> --outcome <value> --summary <one-line-text>

Outcomes: continue, completed, failed, quiescent, waiting-external

Test-only interruption controls:
  --failpoint <after-receipt|after-session-log|after-heartbeat|after-snapshot|after-dashboard>
  --failpoint-action <exit|pause>
  --fail-projection <session-log|heartbeat|snapshot|dashboard>
  Require GATECRAFT_CYCLE_END_TEST_CONTROLS=1 whenever any test control is supplied.

Optional automatic DebateGUI feed publication (see gatecraft/references/debategui-integration.md):
  --publish-local-state-root <absolute-path> --publish-instance-id <id> --publish-owner-token <opaque-token>
  All three or none. A publication failure never fails cycle-end; it is best-effort only.
'@)
}

function Stop-CycleEnd {
    param(
        [Parameter(Mandatory)][int] $ExitCode,
        [Parameter(Mandatory)][string] $Code,
        [Parameter(Mandatory)][string] $Message
    )

    [Console]::Error.WriteLine("CYCLE_END_FAILED code=$Code message=$Message")
    exit $ExitCode
}

function Read-ExactArguments {
    param([Parameter(Mandatory)][object[]] $Tokens)

    if ($Tokens.Count -eq 1 -and [string] $Tokens[0] -ceq '--help') {
        Write-CycleEndUsage
        exit 0
    }

    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in @(
        '--state-root', '--event-id', '--cycle-sequence', '--mode',
        '--occurred-at', '--outcome', '--summary', '--failpoint',
        '--failpoint-action', '--fail-projection',
        '--publish-local-state-root', '--publish-instance-id', '--publish-owner-token'
    )) {
        [void] $allowed.Add($name)
    }

    $values = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $index = 0
    while ($index -lt $Tokens.Count) {
        $name = [string] $Tokens[$index]
        if (-not $allowed.Contains($name)) {
            throw "argument-unknown: reject unknown or abbreviated option '$name'."
        }
        if ($values.ContainsKey($name)) {
            throw "argument-duplicate: reject duplicate option '$name'."
        }
        if ($index + 1 -ge $Tokens.Count) {
            throw "argument-missing-value: option '$name' requires one value."
        }
        $value = [string] $Tokens[$index + 1]
        if ($value.StartsWith('--', [StringComparison]::Ordinal)) {
            throw "argument-missing-value: option '$name' has no unambiguous value."
        }
        $values.Add($name, $value)
        $index += 2
    }

    foreach ($required in @(
        '--state-root', '--event-id', '--cycle-sequence', '--mode',
        '--occurred-at', '--outcome', '--summary'
    )) {
        if (-not $values.ContainsKey($required)) {
            throw "argument-required: missing required option '$required'."
        }
    }

    return $values
}

function Assert-SafeText {
    param(
        [Parameter(Mandatory)][string] $Value,
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][int] $MaximumLength
    )

    if (
        [string]::IsNullOrWhiteSpace($Value) -or
        $Value.Length -gt $MaximumLength -or
        $Value -cne $Value.Trim() -or
        -not $Value.IsNormalized([Text.NormalizationForm]::FormC) -or
        $Value -match '[\x00-\x1F\x7F]'
    ) {
        throw "$Label-invalid: require nonempty NFC text without leading/trailing whitespace or control characters (maximum $MaximumLength characters)."
    }
}

function ConvertTo-CanonicalTimestamp {
    param([Parameter(Mandatory)][string] $Value)

    if ($Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$') {
        throw 'occurred-at-invalid: require a timezone-qualified RFC3339 timestamp with seconds.'
    }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref] $parsed
    )) {
        throw 'occurred-at-invalid: reject an invalid RFC3339 timestamp.'
    }
    return $parsed.ToUniversalTime().ToString(
        "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
        [Globalization.CultureInfo]::InvariantCulture
    )
}

function Assert-NotReparsePoint {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Label
    )

    $isDirectory = [IO.Directory]::Exists($Path)
    $isFile = [IO.File]::Exists($Path)
    if (-not $isDirectory -and -not $isFile) {
        return
    }
    $info = if ($isDirectory) { [IO.DirectoryInfo]::new($Path) } else { [IO.FileInfo]::new($Path) }
    if (
        ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not [string]::IsNullOrEmpty($info.LinkTarget)
    ) {
        throw "path-reparse: reject symbolic-link, junction, mount, or reparse indirection at $Label."
    }
}

function Initialize-StateRoot {
    param([Parameter(Mandatory)][string] $DeclaredPath)

    if (
        [string]::IsNullOrWhiteSpace($DeclaredPath) -or
        $DeclaredPath -match '[\x00-\x1F\x7F*?]' -or
        -not $DeclaredPath.IsNormalized([Text.NormalizationForm]::FormC) -or
        -not [IO.Path]::IsPathFullyQualified($DeclaredPath)
    ) {
        throw 'state-root-invalid: require an unambiguous absolute local path.'
    }

    $segments = @($DeclaredPath -split '[\\/]')
    foreach ($segment in $segments) {
        if ($segment -in @('.', '..') -or $segment.EndsWith(' ', [StringComparison]::Ordinal) -or $segment.EndsWith('.', [StringComparison]::Ordinal)) {
            throw 'state-root-invalid: reject dot segments and trailing dot/space path components.'
        }
    }

    $fullPath = [IO.Path]::GetFullPath($DeclaredPath)
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrEmpty($pathRoot) -or $fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) -ceq $pathRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)) {
        throw 'state-root-invalid: reject a filesystem root as the state root.'
    }
    if (
        [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows) -and
        ($pathRoot.StartsWith('\\', [StringComparison]::Ordinal) -or $pathRoot.StartsWith('//', [StringComparison]::Ordinal))
    ) {
        throw 'state-root-nonlocal: reject UNC and device paths; state must use a local filesystem root.'
    }

    $current = $pathRoot
    Assert-NotReparsePoint -Path $current -Label 'state-root filesystem root'
    $relative = $fullPath.Substring($pathRoot.Length)
    foreach ($segment in @($relative -split '[\\/]' | Where-Object { $_.Length -gt 0 })) {
        $current = [IO.Path]::Combine($current, $segment)
        if ([IO.File]::Exists($current) -and -not [IO.Directory]::Exists($current)) {
            throw 'state-root-invalid: a state-root path component is a file.'
        }
        Assert-NotReparsePoint -Path $current -Label 'state-root path component'
    }

    [void] [IO.Directory]::CreateDirectory($fullPath)
    $current = $pathRoot
    foreach ($segment in @($relative -split '[\\/]' | Where-Object { $_.Length -gt 0 })) {
        $current = [IO.Path]::Combine($current, $segment)
        if (-not [IO.Directory]::Exists($current)) {
            throw 'state-root-invalid: a created state-root component is missing or not a directory.'
        }
        Assert-NotReparsePoint -Path $current -Label 'created state-root path component'
    }
    return $fullPath
}

function Ensure-SafeDirectory {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Label
    )

    if ([IO.File]::Exists($Path) -and -not [IO.Directory]::Exists($Path)) {
        throw "path-type: $Label must be a directory."
    }
    Assert-NotReparsePoint -Path $Path -Label $Label
    [void] [IO.Directory]::CreateDirectory($Path)
    Assert-NotReparsePoint -Path $Path -Label $Label
}

function ConvertTo-JsonString {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)
    return ConvertTo-Json -InputObject ([string] $Value) -Compress -EscapeHandling EscapeNonAscii
}

function New-CanonicalReceipt {
    param(
        [Parameter(Mandatory)][long] $Sequence,
        [Parameter(Mandatory)][string] $EventId,
        [Parameter(Mandatory)][string] $Mode,
        [Parameter(Mandatory)][string] $OccurredAt,
        [Parameter(Mandatory)][string] $Outcome,
        [Parameter(Mandatory)][string] $Summary
    )

    $canonical = '{' +
        '"cycle_sequence":' + $Sequence.ToString([Globalization.CultureInfo]::InvariantCulture) + ',' +
        '"event_id":' + (ConvertTo-JsonString $EventId) + ',' +
        '"event_type":"cycle-end",' +
        '"mode":' + (ConvertTo-JsonString $Mode) + ',' +
        '"occurred_at":' + (ConvertTo-JsonString $OccurredAt) + ',' +
        '"outcome":' + (ConvertTo-JsonString $Outcome) + ',' +
        '"protocol":"gatecraft-cycle/v1",' +
        '"summary":' + (ConvertTo-JsonString $Summary) +
        '}'

    return [pscustomobject][ordered]@{
        CycleSequence = $Sequence
        EventId = $EventId
        EventType = 'cycle-end'
        Mode = $Mode
        OccurredAt = $OccurredAt
        Outcome = $Outcome
        Protocol = 'gatecraft-cycle/v1'
        Summary = $Summary
        Canonical = $canonical
    }
}

function Read-CanonicalReceipt {
    param([Parameter(Mandatory)][string] $Path)

    Assert-NotReparsePoint -Path $Path -Label 'canonical receipt'
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) {
        throw 'receipt-corrupt: reject an empty canonical receipt.'
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'receipt-corrupt: reject a UTF-8 BOM in a canonical receipt.'
    }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if ($text.Contains("`r", [StringComparison]::Ordinal) -or $text.Contains("`n", [StringComparison]::Ordinal)) {
        throw 'receipt-corrupt: a canonical receipt must be exactly one JSON value with no trailing newline.'
    }

    $document = [Text.Json.JsonDocument]::Parse($text)
    try {
        $root = $document.RootElement
        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw 'receipt-corrupt: canonical receipt root must be an object.'
        }

        $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($name in @('cycle_sequence', 'event_id', 'event_type', 'mode', 'occurred_at', 'outcome', 'protocol', 'summary')) {
            [void] $allowed.Add($name)
        }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $fields = [Collections.Generic.Dictionary[string,Text.Json.JsonElement]]::new([StringComparer]::Ordinal)
        foreach ($property in $root.EnumerateObject()) {
            if (-not $allowed.Contains($property.Name) -or -not $seen.Add($property.Name)) {
                throw "receipt-corrupt: reject unknown or duplicate property '$($property.Name)'."
            }
            $fields.Add($property.Name, $property.Value.Clone())
        }
        if ($seen.Count -ne $allowed.Count) {
            throw 'receipt-corrupt: canonical receipt fields are incomplete.'
        }

        [long] $sequence = 0
        if ($fields['cycle_sequence'].ValueKind -ne [Text.Json.JsonValueKind]::Number -or -not $fields['cycle_sequence'].TryGetInt64([ref] $sequence)) {
            throw 'receipt-corrupt: cycle_sequence must be an integer.'
        }
        foreach ($name in @('event_id', 'event_type', 'mode', 'occurred_at', 'outcome', 'protocol', 'summary')) {
            if ($fields[$name].ValueKind -ne [Text.Json.JsonValueKind]::String) {
                throw "receipt-corrupt: property '$name' must be a string."
            }
        }

        $persistedEventId = $fields['event_id'].GetString()
        $persistedMode = $fields['mode'].GetString()
        $persistedOccurredAt = $fields['occurred_at'].GetString()
        $persistedOutcome = $fields['outcome'].GetString()
        $persistedSummary = $fields['summary'].GetString()
        if ($sequence -lt 1 -or $persistedEventId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
            throw 'receipt-corrupt: reject an invalid persisted sequence or event ID.'
        }
        if ($persistedMode -cnotin @('attended', 'unattended') -or $persistedOutcome -cnotin @('continue', 'completed', 'failed', 'quiescent', 'waiting-external')) {
            throw 'receipt-corrupt: reject an invalid persisted mode or outcome.'
        }
        Assert-SafeText -Value $persistedSummary -Label 'receipt-summary' -MaximumLength 2048
        if ((ConvertTo-CanonicalTimestamp -Value $persistedOccurredAt) -cne $persistedOccurredAt) {
            throw 'receipt-corrupt: persisted timestamp is not in canonical UTC form.'
        }

        $receipt = New-CanonicalReceipt -Sequence $sequence -EventId $persistedEventId -Mode $persistedMode -OccurredAt $persistedOccurredAt -Outcome $persistedOutcome -Summary $persistedSummary

        if ($fields['event_type'].GetString() -cne 'cycle-end' -or $fields['protocol'].GetString() -cne 'gatecraft-cycle/v1') {
            throw 'receipt-corrupt: reject an unknown event type or protocol.'
        }
        if ($receipt.Canonical -cne $text) {
            throw 'receipt-corrupt: receipt bytes are not in canonical UTF-8 JSON form.'
        }
        return $receipt
    }
    finally {
        $document.Dispose()
    }
}

function Write-AtomicUtf8 {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Text,
        [switch] $CreateOnly
    )

    $directory = [IO.Path]::GetDirectoryName($Path)
    Assert-NotReparsePoint -Path $directory -Label 'write parent directory'
    if ([IO.Directory]::Exists($Path)) {
        throw 'path-type: output path is an existing directory.'
    }
    Assert-NotReparsePoint -Path $Path -Label 'output file'

    $temporary = [IO.Path]::Combine($directory, '.cycle-end-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        $stream = [IO.FileStream]::new(
            $temporary,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough
        )
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }

        if ($CreateOnly) {
            [IO.File]::Move($temporary, $Path, $false)
        }
        else {
            [IO.File]::Move($temporary, $Path, $true)
        }
    }
    finally {
        if ([IO.File]::Exists($temporary)) {
            [IO.File]::Delete($temporary)
        }
    }
}

function Get-CanonicalLedger {
    param([Parameter(Mandatory)][string] $ReceiptDirectory)

    Assert-NotReparsePoint -Path $ReceiptDirectory -Label 'receipt directory'
    $entries = @([IO.DirectoryInfo]::new($ReceiptDirectory).GetFileSystemInfos() | Sort-Object -Property Name)
    $receipts = [Collections.Generic.List[object]]::new()
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [long] $expected = 1

    foreach ($entry in $entries) {
        if ($entry -isnot [IO.FileInfo] -or $entry.Name -notmatch '^(?<sequence>[0-9]{19})--(?<id>[A-Za-z0-9][A-Za-z0-9._-]{0,127})\.json$') {
            throw "receipt-directory-corrupt: reject unexpected entry '$($entry.Name)' in the canonical receipt directory."
        }
        $filenameMatch = [regex]::Match($entry.Name, '^(?<sequence>[0-9]{19})--(?<id>[A-Za-z0-9][A-Za-z0-9._-]{0,127})\.json$', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
        Assert-NotReparsePoint -Path $entry.FullName -Label 'canonical receipt entry'
        [long] $fileSequence = 0
        if (-not [long]::TryParse($filenameMatch.Groups['sequence'].Value, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref] $fileSequence)) {
            throw 'receipt-directory-corrupt: receipt filename sequence is outside Int64.'
        }
        $receipt = Read-CanonicalReceipt -Path $entry.FullName
        if (
            $receipt.CycleSequence -ne $fileSequence -or
            $receipt.EventId -cne $filenameMatch.Groups['id'].Value -or
            $receipt.CycleSequence -ne $expected -or
            -not $ids.Add($receipt.EventId)
        ) {
            throw 'receipt-ledger-invalid: canonical receipts must have unique IDs and contiguous positive sequences beginning at one.'
        }
        $receipts.Add($receipt)
        $expected++
    }

    return @($receipts)
}

function Invoke-WriteBoundaryFailpoint {
    param(
        [Parameter(Mandatory)][string] $Boundary,
        [AllowNull()][string] $Selected,
        [Parameter(Mandatory)][string] $Action
    )

    $name = "after-$Boundary"
    if ([string]::IsNullOrEmpty($Selected) -or $Selected -cne $name) {
        return
    }

    [Console]::Out.WriteLine("CYCLE_END_FAILPOINT boundary=$name action=$Action")
    [Console]::Out.Flush()
    if ($Action -ceq 'exit') {
        [Console]::Error.WriteLine("CYCLE_END_FAILED code=failpoint-triggered message=deterministic interruption after durable boundary $name")
        exit 86
    }
    while ($true) {
        Start-Sleep -Milliseconds 250
    }
}

function Invoke-BestEffortCycleEndPublish {
    <#
    .SYNOPSIS
        Best-effort automatic publication of one sanitized gatecraft-debategui/v1 feed
        event for this cycle-end completion. See gatecraft/references/debategui-integration.md:
        "Gatecraft remains fully functional when DebateGUI is absent... A UI failure is
        never a Gatecraft failure." This function therefore NEVER throws and NEVER
        changes cycle-end's exit code; every failure path is a stderr warning only.
    #>
    param(
        [Parameter(Mandatory)][string] $LocalStateRoot,
        [Parameter(Mandatory)][string] $InstanceId,
        [Parameter(Mandatory)][string] $OwnerToken,
        [Parameter(Mandatory)][string] $EventId,
        [Parameter(Mandatory)][long] $Sequence,
        [Parameter(Mandatory)][string] $OccurredAt,
        [Parameter(Mandatory)][string] $Outcome,
        [Parameter(Mandatory)][string] $Summary
    )

    try {
        $registryScript = Join-Path $PSScriptRoot 'registry.ps1'
        $publishArguments = [Collections.Generic.List[string]]::new()
        $publishArguments.AddRange([string[]]@(
            'publish-event',
            '--local-state-root', $LocalStateRoot,
            '--instance-id', $InstanceId,
            '--owner-token', $OwnerToken,
            '--event-type', 'cycle-end',
            '--occurred-at', $OccurredAt,
            '--outcome', $Outcome,
            '--summary', $Summary,
            '--event-id', "cycle-$EventId",
            '--cycle-sequence', ([string] $Sequence)
        ))

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = 'pwsh'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.ArgumentList.Add('-NoLogo')
        $startInfo.ArgumentList.Add('-NoProfile')
        $startInfo.ArgumentList.Add('-File')
        $startInfo.ArgumentList.Add($registryScript)
        foreach ($argument in $publishArguments) { $startInfo.ArgumentList.Add($argument) }
        $child = [Diagnostics.Process]::new()
        $child.StartInfo = $startInfo
        [void] $child.Start()
        $stderrTask = $child.StandardError.ReadToEndAsync()
        [void] $child.StandardOutput.ReadToEndAsync()
        if (-not $child.WaitForExit(30000)) {
            try { $child.Kill($true) } catch { }
            [Console]::Error.WriteLine('CYCLE_END_PUBLISH_WARNING code=registry-publish-timeout')
        }
        elseif ($child.ExitCode -ne 0) {
            [Console]::Error.WriteLine("CYCLE_END_PUBLISH_WARNING code=registry-publish-failed exit=$($child.ExitCode) detail=$($stderrTask.GetAwaiter().GetResult())")
        }
        else {
            [Console]::Out.WriteLine('CYCLE_END_PUBLISHED code=event-published')
        }
        $child.Dispose()
    }
    catch {
        [Console]::Error.WriteLine('CYCLE_END_PUBLISH_WARNING code=registry-publish-unavailable')
    }
}

function Write-ProjectionFailure {
    param(
        [Parameter(Mandatory)][string] $Mode,
        [Parameter(Mandatory)][string] $EventId,
        [Parameter(Mandatory)][long] $Sequence,
        [Parameter(Mandatory)][string] $Message
    )

    [Console]::Error.WriteLine("CYCLE_END_FAILED code=projection-incomplete event_id=$EventId sequence=$Sequence message=$Message")
    if ($Mode -ceq 'attended') {
        [Console]::Error.WriteLine("CYCLE_END_MANUAL_FALLBACK event_id=$EventId sequence=$Sequence automatic_completion=false")
        [Console]::Error.WriteLine('  1. Resolve the local projection write problem; do not edit the canonical receipt.')
        [Console]::Error.WriteLine('  2. Re-run the exact same event ID, sequence, mode, timestamp, outcome, and summary.')
        [Console]::Error.WriteLine('  3. Require a zero exit with projections=complete before claiming cycle-end completion.')
    }
    else {
        [Console]::Error.WriteLine('Unattended mode fails closed. Re-run the exact same event only after the local projection problem is resolved.')
    }
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Stop-CycleEnd -ExitCode 64 -Code 'powershell-version' -Message 'PowerShell 7 or newer is required.'
}

try {
    $options = Read-ExactArguments -Tokens @($args)

    $testControlsRequested =
        $options.ContainsKey('--failpoint') -or
        $options.ContainsKey('--failpoint-action') -or
        $options.ContainsKey('--fail-projection')
    if (
        $testControlsRequested -and
        [Environment]::GetEnvironmentVariable('GATECRAFT_CYCLE_END_TEST_CONTROLS', [EnvironmentVariableTarget]::Process) -cne '1'
    ) {
        throw 'test-controls-disabled: test controls require GATECRAFT_CYCLE_END_TEST_CONTROLS to equal exactly 1.'
    }

    $eventId = $options['--event-id']
    if ($eventId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
        throw 'event-id-invalid: require [A-Za-z0-9][A-Za-z0-9._-]{0,127}.'
    }

    $sequenceText = $options['--cycle-sequence']
    [long] $sequence = 0
    if ($sequenceText -notmatch '^[1-9][0-9]{0,18}$' -or -not [long]::TryParse(
        $sequenceText,
        [Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref] $sequence
    )) {
        throw 'cycle-sequence-invalid: require a positive canonical decimal Int64 without a sign or leading zero.'
    }

    $mode = $options['--mode']
    if ($mode -cnotin @('attended', 'unattended')) {
        throw 'mode-invalid: mode must be exactly attended or unattended.'
    }

    $outcome = $options['--outcome']
    if ($outcome -cnotin @('continue', 'completed', 'failed', 'quiescent', 'waiting-external')) {
        throw 'outcome-invalid: reject an unknown cycle outcome.'
    }

    $summary = $options['--summary']
    Assert-SafeText -Value $summary -Label 'summary' -MaximumLength 2048
    $occurredAt = ConvertTo-CanonicalTimestamp -Value $options['--occurred-at']

    $failpoint = if ($options.ContainsKey('--failpoint')) { $options['--failpoint'] } else { $null }
    if ($null -ne $failpoint -and $failpoint -cnotin @('after-receipt', 'after-session-log', 'after-heartbeat', 'after-snapshot', 'after-dashboard')) {
        throw 'failpoint-invalid: reject an unknown write boundary.'
    }
    $failpointAction = if ($options.ContainsKey('--failpoint-action')) { $options['--failpoint-action'] } else { 'exit' }
    if ($failpointAction -cnotin @('exit', 'pause')) {
        throw 'failpoint-action-invalid: require exit or pause.'
    }
    if ($options.ContainsKey('--failpoint-action') -and $null -eq $failpoint) {
        throw 'failpoint-action-ambiguous: failpoint action requires a failpoint.'
    }

    $failProjection = if ($options.ContainsKey('--fail-projection')) { $options['--fail-projection'] } else { $null }
    if ($null -ne $failProjection -and $failProjection -cnotin @('session-log', 'heartbeat', 'snapshot', 'dashboard')) {
        throw 'fail-projection-invalid: reject an unknown projection.'
    }

    $publishKeys = @('--publish-local-state-root', '--publish-instance-id', '--publish-owner-token')
    $publishPresent = @($publishKeys | Where-Object { $options.ContainsKey($_) })
    if ($publishPresent.Count -gt 0 -and $publishPresent.Count -ne $publishKeys.Count) {
        throw 'publish-arguments-incomplete: require all of --publish-local-state-root, --publish-instance-id, and --publish-owner-token together, or none.'
    }
    $publishEnabled = $publishPresent.Count -eq $publishKeys.Count

    $stateRoot = Initialize-StateRoot -DeclaredPath $options['--state-root']
    $cycleRoot = [IO.Path]::Combine($stateRoot, 'cycle-end')
    $receiptDirectory = [IO.Path]::Combine($cycleRoot, 'receipts')
    Ensure-SafeDirectory -Path $cycleRoot -Label 'cycle-end state directory'
    Ensure-SafeDirectory -Path $receiptDirectory -Label 'canonical receipt directory'

    $incoming = New-CanonicalReceipt -Sequence $sequence -EventId $eventId -Mode $mode -OccurredAt $occurredAt -Outcome $outcome -Summary $summary
    $ledger = @(Get-CanonicalLedger -ReceiptDirectory $receiptDirectory)
    $sameId = @($ledger | Where-Object { $_.EventId -ceq $eventId })
    $sameSequence = @($ledger | Where-Object { $_.CycleSequence -eq $sequence })
    $receiptDisposition = 'new'

    if ($sameId.Count -gt 0) {
        if ($sameId.Count -ne 1 -or $sameId[0].Canonical -cne $incoming.Canonical) {
            throw 'event-id-conflict: the event ID already names a different canonical payload.'
        }
        $receiptDisposition = 'replayed'
    }
    elseif ($sameSequence.Count -gt 0) {
        throw 'sequence-reused: the cycle sequence is already bound to another event ID.'
    }
    else {
        [long] $expectedSequence = $ledger.Count + 1
        if ($sequence -ne $expectedSequence) {
            throw "sequence-gap: expected cycle sequence $expectedSequence; received $sequence."
        }
        $receiptName = $sequence.ToString('D19', [Globalization.CultureInfo]::InvariantCulture) + "--$eventId.json"
        $receiptPath = [IO.Path]::Combine($receiptDirectory, $receiptName)
        Write-AtomicUtf8 -Path $receiptPath -Text $incoming.Canonical -CreateOnly
        $ledger = @(Get-CanonicalLedger -ReceiptDirectory $receiptDirectory)
    }

    Invoke-WriteBoundaryFailpoint -Boundary 'receipt' -Selected $failpoint -Action $failpointAction

    $latest = $ledger[-1]
    $sessionLog = (@($ledger | ForEach-Object { $_.Canonical }) -join "`n") + "`n"
    $heartbeat = '{' +
        '"cycle_sequence":' + $latest.CycleSequence.ToString([Globalization.CultureInfo]::InvariantCulture) + ',' +
        '"event_id":' + (ConvertTo-JsonString $latest.EventId) + ',' +
        '"last_confirmation":' + (ConvertTo-JsonString $latest.OccurredAt) + ',' +
        '"protocol":"gatecraft-cycle/heartbeat-v1"}'
    $snapshot = '{' +
        '"cycle_sequence":' + $latest.CycleSequence.ToString([Globalization.CultureInfo]::InvariantCulture) + ',' +
        '"event_id":' + (ConvertTo-JsonString $latest.EventId) + ',' +
        '"mode":' + (ConvertTo-JsonString $latest.Mode) + ',' +
        '"occurred_at":' + (ConvertTo-JsonString $latest.OccurredAt) + ',' +
        '"outcome":' + (ConvertTo-JsonString $latest.Outcome) + ',' +
        '"protocol":"gatecraft-cycle/snapshot-v1",' +
        '"summary":' + (ConvertTo-JsonString $latest.Summary) + '}'
    $dashboard = '{' +
        '"cycle_count":' + $ledger.Count.ToString([Globalization.CultureInfo]::InvariantCulture) + ',' +
        '"latest":' + $latest.Canonical + ',' +
        '"protocol":"gatecraft-cycle/dashboard-v1"}'

    $projections = @(
        [pscustomobject]@{ Name = 'session-log'; File = 'session-log.jsonl'; Content = $sessionLog },
        [pscustomobject]@{ Name = 'heartbeat'; File = 'heartbeat.json'; Content = $heartbeat },
        [pscustomobject]@{ Name = 'snapshot'; File = 'snapshot.json'; Content = $snapshot },
        [pscustomobject]@{ Name = 'dashboard'; File = 'dashboard.json'; Content = $dashboard }
    )

    try {
        foreach ($projection in $projections) {
            if ($failProjection -ceq $projection.Name) {
                throw "forced projection failure at $($projection.Name)"
            }
            $projectionPath = [IO.Path]::Combine($cycleRoot, $projection.File)
            Write-AtomicUtf8 -Path $projectionPath -Text $projection.Content
            Invoke-WriteBoundaryFailpoint -Boundary $projection.Name -Selected $failpoint -Action $failpointAction
        }
    }
    catch {
        Write-ProjectionFailure -Mode $mode -EventId $eventId -Sequence $sequence -Message $_.Exception.Message
        exit 74
    }

    if ($publishEnabled) {
        Invoke-BestEffortCycleEndPublish -LocalStateRoot $options['--publish-local-state-root'] -InstanceId $options['--publish-instance-id'] -OwnerToken $options['--publish-owner-token'] -EventId $eventId -Sequence $sequence -OccurredAt $occurredAt -Outcome $outcome -Summary $summary
    }

    [Console]::Out.WriteLine("CYCLE_END_COMPLETE event_id=$eventId sequence=$sequence receipt=$receiptDisposition projections=complete")
    exit 0
}
catch {
    $message = $_.Exception.Message.Replace("`r", ' ').Replace("`n", ' ')
    $code = if ($message -match '^(?:event-id-conflict|sequence-reused|sequence-gap):') { 'event-conflict' } else { 'input-or-state-invalid' }
    $exitCode = if ($code -ceq 'event-conflict') { 65 } else { 64 }
    Stop-CycleEnd -ExitCode $exitCode -Code $code -Message $message
}
