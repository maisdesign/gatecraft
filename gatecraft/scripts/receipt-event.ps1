Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Gatecraft.Protocol.psm1') -Force

function Write-ReceiptEventUsage {
    [Console]::Out.WriteLine(@'
Usage:
  receipt-event.ps1 --receipt-line <raw-receipt-line> \
    --local-state-root <absolute-path> --instance-id <id> --owner-token <opaque-token> \
    [--cycle-sequence <positive-decimal>]

Converts one VERIFIED/VERIFY_PHASE receipt line (protocol verification/v2) into a
sanitized gatecraft-debategui/v1 feed event and publishes it via registry.ps1.

This command is the automatic-publication hook described in
gatecraft/references/debategui-integration.md: it never blocks or fails the caller
on a registry/DebateGUI problem (absent registry, unknown instance, contention, ...).
It fails closed only on invalid arguments. A receipt line that is not a final
VERIFIED/VERIFY_PHASE pass/fail decision is a documented no-op, not a failure.
'@)
}

function Stop-ReceiptEvent {
    param([Parameter(Mandatory)][int] $ExitCode, [Parameter(Mandatory)][string] $Code)
    [Console]::Error.WriteLine("RECEIPT_EVENT_FAILED code=$Code")
    exit $ExitCode
}

if ($PSVersionTable.PSVersion.Major -lt 7) { Stop-ReceiptEvent -ExitCode 64 -Code 'powershell-version' }

try {
    $tokens = @($args)
    if ($tokens.Count -eq 1 -and [string]$tokens[0] -ceq '--help') { Write-ReceiptEventUsage; exit 0 }

    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in @('--receipt-line', '--local-state-root', '--instance-id', '--owner-token', '--cycle-sequence')) { [void]$allowed.Add($name) }
    $values = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $index = 0
    while ($index -lt $tokens.Count) {
        $name = [string]$tokens[$index]
        if (-not $allowed.Contains($name)) { throw 'argument-unknown' }
        if ($values.ContainsKey($name)) { throw 'argument-duplicate' }
        if ($index + 1 -ge $tokens.Count) { throw 'argument-missing-value' }
        $values.Add($name, [string]$tokens[$index + 1])
        $index += 2
    }
    foreach ($required in @('--receipt-line', '--local-state-root', '--instance-id', '--owner-token')) {
        if (-not $values.ContainsKey($required)) { throw 'argument-required' }
    }

    $cycleSequence = if ($values.ContainsKey('--cycle-sequence')) {
        if ($values['--cycle-sequence'] -notmatch '^[1-9][0-9]{0,18}$') { throw 'cycle-sequence-invalid' }
        $values['--cycle-sequence']
    } else { $null }

    $event = ConvertTo-GatecraftSanitizedFeedEvent -Line $values['--receipt-line'] -CycleSequence $cycleSequence

    if (-not $event.IsApplicable) {
        [Console]::Out.WriteLine("RECEIPT_EVENT_SKIPPED code=$($event.Reason)")
        exit 0
    }

    $registryScript = Join-Path $PSScriptRoot 'registry.ps1'
    $publishArguments = [Collections.Generic.List[string]]::new()
    $publishArguments.AddRange([string[]]@(
        'publish-event',
        '--local-state-root', $values['--local-state-root'],
        '--instance-id', $values['--instance-id'],
        '--owner-token', $values['--owner-token'],
        '--event-type', $event.EventType,
        '--occurred-at', $event.OccurredAt,
        '--outcome', $event.Outcome,
        '--summary', $event.Summary,
        '--event-id', $event.EventId
    ))
    if (-not [string]::IsNullOrEmpty($event.CycleSequence)) {
        $publishArguments.Add('--cycle-sequence')
        $publishArguments.Add($event.CycleSequence)
    }

    try {
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
        [void]$child.Start()
        $stderrTask = $child.StandardError.ReadToEndAsync()
        [void]$child.StandardOutput.ReadToEndAsync()
        if (-not $child.WaitForExit(30000)) {
            try { $child.Kill($true) } catch { }
            [Console]::Error.WriteLine('RECEIPT_EVENT_PUBLISH_WARNING code=registry-publish-timeout')
        }
        elseif ($child.ExitCode -ne 0) {
            [Console]::Error.WriteLine("RECEIPT_EVENT_PUBLISH_WARNING code=registry-publish-failed exit=$($child.ExitCode) detail=$($stderrTask.GetAwaiter().GetResult())")
        }
        else {
            [Console]::Out.WriteLine("RECEIPT_EVENT_PUBLISHED code=event-published event_type=$($event.EventType) outcome=$($event.Outcome)")
        }
        $child.Dispose()
    }
    catch {
        # A UI/registry failure is never a Gatecraft failure (see the ADR). Best-effort only.
        [Console]::Error.WriteLine('RECEIPT_EVENT_PUBLISH_WARNING code=registry-publish-unavailable')
    }
    exit 0
}
catch {
    $message = [string]$_.Exception.Message
    $code = if ($message -cmatch '^(?<code>[a-z][a-z0-9.-]*)') { $Matches.code } else { 'internal-error' }
    Stop-ReceiptEvent -ExitCode 64 -Code $code
}
