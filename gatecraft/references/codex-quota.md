# Usage/quota introspection (Step 3 adapters)

Use these PowerShell examples as best-effort adapters. The copyable adapters require PowerShell 7 or later and must be run with `pwsh`, not Windows PowerShell 5.1. Re-verify them after CLI upgrades, and classify both results as capabilities discovered at bootstrap rather than as vendor-specific orchestration modes.

## Table of contents

- [Cycle rule](#cycle-rule)
- [Shared process helper](#shared-process-helper)
- [Claude usage adapter](#claude-usage-adapter)
- [Codex JSON-RPC adapter](#codex-json-rpc-adapter)
- [No-data rule](#no-data-rule)
- [Rejected alternatives](#rejected-alternatives)

## Cycle rule

Invoke each applicable adapter at most once after a complete bead cycle and before claiming another bead. Never poll, tightly repeat, or retry an adapter in the same cycle. Treat a timeout, transient backend response, malformed response, missing percentage, or process-launch failure as an explicit no-data outcome for that cycle. Never convert a missing or transient response into 0%.

Use a hard timeout of at least 15 seconds. The examples default to 20 seconds, kill the process tree on timeout, and return usedPercent = null when no trustworthy short-session reading exists. A trustworthy weekly-only Codex response is still status = ok, with the short-session capability explicitly unavailable.

## Shared process helper

Copy this helper once before either adapter. Resolve native executables, PowerShell shims, and cmd/bat shims without installing a module. Command lookup deliberately excludes aliases and functions, and cmd/bat shims receive one validated, correctly quoted `cmd /d /s /c` payload.

~~~powershell
function New-GatecraftCmdPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FilePath,

        [string[]] $ArgumentList = @()
    )

    $quotedTokens = foreach ($token in @($FilePath) + @($ArgumentList)) {
        if ($null -eq $token -or $token -match '[\x00\r\n"&|<>\^%!]') {
            throw 'A cmd/bat shim path or argument contains unsupported cmd metacharacters.'
        }
        '"' + $token + '"'
    }

    # /s strips these outer quotes; the inner quotes preserve every token boundary.
    return '"' + ($quotedTokens -join ' ') + '"'
}

function New-GatecraftCliProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Command,

        [string[]] $ArgumentList = @(),

        [hashtable] $Environment = @{}
    )

    $resolved = Get-Command $Command -CommandType Application, ExternalScript -ErrorAction Stop |
        Select-Object -First 1
    $source = $resolved.Source
    if ([string]::IsNullOrWhiteSpace($source)) {
        throw "Resolved command '$Command' has no executable source."
    }
    $extension = [IO.Path]::GetExtension($source).ToLowerInvariant()
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $appendArguments = $true

    switch ($extension) {
        '.ps1' {
            $psi.FileName = (Get-Process -Id $PID).Path
            $psi.ArgumentList.Add('-NoProfile')
            $psi.ArgumentList.Add('-File')
            $psi.ArgumentList.Add($source)
        }
        { $_ -in '.cmd', '.bat' } {
            $psi.FileName = $env:ComSpec
            $psi.Arguments = '/d /s /c ' +
                (New-GatecraftCmdPayload -FilePath $source -ArgumentList $ArgumentList)
            $appendArguments = $false
        }
        default {
            $psi.FileName = $source
        }
    }

    if ($appendArguments) {
        foreach ($argument in $ArgumentList) {
            $psi.ArgumentList.Add($argument)
        }
    }
    foreach ($name in $Environment.Keys) {
        $psi.Environment[$name] = [string] $Environment[$name]
    }

    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) {
        throw "Failed to start $Command."
    }
    return $process
}
~~~

## Claude usage adapter

Feed /usage to an interactive Claude session through stdin; never add --print. Parse only a real Current session percentage. Preserve EOF behavior by closing stdin immediately after the command.

~~~powershell
function ConvertFrom-GatecraftClaudeUsageText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    $match = [regex]::Match(
        $Text,
        '(?im)^[\t ]*Current session:\s*(?<used>\d+(?:\.\d+)?)%\s*used(?:\s*·\s*resets\b[^\r\n]*)?[\t ]*$',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $match.Success) {
        return [pscustomobject]@{
            adapter     = 'claude-usage'
            status      = 'no-data'
            usedPercent = $null
            reason      = 'percentage-missing'
        }
    }

    $usedPercent = [double]::Parse(
        $match.Groups['used'].Value,
        [Globalization.CultureInfo]::InvariantCulture
    )
    if (
        [double]::IsNaN($usedPercent) -or
        [double]::IsInfinity($usedPercent) -or
        $usedPercent -lt 0 -or
        $usedPercent -gt 100
    ) {
        return [pscustomobject]@{
            adapter     = 'claude-usage'
            status      = 'no-data'
            usedPercent = $null
            reason      = 'percentage-out-of-range'
        }
    }

    return [pscustomobject]@{
        adapter     = 'claude-usage'
        status      = 'ok'
        usedPercent = $usedPercent
        reason      = $null
    }
}

function Get-ClaudeQuotaSnapshot {
    [CmdletBinding()]
    param(
        [string] $ClaudeConfigDir,

        [ValidateRange(15, 300)]
        [int] $TimeoutSeconds = 20
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        return [pscustomobject]@{
            adapter     = 'claude-usage'
            status      = 'no-data'
            usedPercent = $null
            reason      = 'powershell-version-unsupported'
        }
    }

    $environment = @{}
    if ($ClaudeConfigDir) {
        $environment.CLAUDE_CONFIG_DIR = $ClaudeConfigDir
    }

    $process = $null
    try {
        $process = New-GatecraftCliProcess -Command 'claude' -Environment $environment
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $process.StandardInput.WriteLine('/usage')
        $process.StandardInput.Close()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            return [pscustomobject]@{
                adapter     = 'claude-usage'
                status      = 'no-data'
                usedPercent = $null
                reason      = 'hard-timeout'
            }
        }

        $text = $stdoutTask.GetAwaiter().GetResult() +
            [Environment]::NewLine +
            $stderrTask.GetAwaiter().GetResult()

        if ($process.ExitCode -ne 0) {
            return [pscustomobject]@{
                adapter     = 'claude-usage'
                status      = 'no-data'
                usedPercent = $null
                reason      = "exit-$($process.ExitCode)"
            }
        }

        return ConvertFrom-GatecraftClaudeUsageText -Text $text
    }
    catch {
        return [pscustomobject]@{
            adapter     = 'claude-usage'
            status      = 'no-data'
            usedPercent = $null
            reason      = 'launch-or-protocol-error'
        }
    }
    finally {
        if ($process) {
            if (-not $process.HasExited) {
                $process.Kill($true)
                $process.WaitForExit()
            }
            $process.Dispose()
        }
    }
}

# Call once at the Step 1 cycle boundary.
$claudeQuota = Get-ClaudeQuotaSnapshot -ClaudeConfigDir 'C:\Users\me\.claude-profile' -TimeoutSeconds 20
$claudeQuota | ConvertTo-Json -Compress
~~~

A successful call returns the true subscription percentage reported by Claude Code. A rapid or incomplete render can omit the percentage even while other text appears; return no-data and wait until the next bead cycle instead of retrying.

## Codex JSON-RPC adapter

Drive the official-experimental Codex app-server over newline-delimited JSON-RPC. Send initialize, await its ID-matched response, send initialized, then request account/rateLimits/read. Ignore interleaved notifications. Treat primary and secondary as transport slots only: classify each trustworthy window by windowDurationMins, where 300 is the five-hour session and 10080 is the weekly window. The provider may omit a window or return the windows in either order.

~~~powershell
function ConvertTo-GatecraftCodexQuotaSnapshot {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $RateLimits
    )

    $readProperty = {
        param(
            [AllowNull()]
            [object] $InputObject,

            [Parameter(Mandatory)]
            [string] $Name
        )

        if ($null -eq $InputObject) {
            return $null
        }
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -eq $property) {
            return $null
        }
        return $property.Value
    }

    $isNumeric = {
        param([AllowNull()][object] $Value)

        return (
            $Value -is [byte] -or
            $Value -is [sbyte] -or
            $Value -is [int16] -or
            $Value -is [uint16] -or
            $Value -is [int32] -or
            $Value -is [uint32] -or
            $Value -is [int64] -or
            $Value -is [uint64] -or
            $Value -is [single] -or
            $Value -is [double] -or
            $Value -is [decimal]
        )
    }

    $primary = & $readProperty $RateLimits 'primary'
    $secondary = & $readProperty $RateLimits 'secondary'
    $primaryUsedPercent = & $readProperty $primary 'usedPercent'
    $primaryWindowDurationMins = & $readProperty $primary 'windowDurationMins'
    $primaryResetsAt = & $readProperty $primary 'resetsAt'
    $secondaryUsedPercent = & $readProperty $secondary 'usedPercent'
    $secondaryWindowDurationMins = & $readProperty $secondary 'windowDurationMins'
    $secondaryResetsAt = & $readProperty $secondary 'resetsAt'

    $sessionCandidates = @()
    $weeklyCandidates = @()
    foreach ($window in @($primary, $secondary)) {
        if ($null -eq $window) {
            continue
        }

        $usedPercent = & $readProperty $window 'usedPercent'
        $windowDurationMins = & $readProperty $window 'windowDurationMins'
        $resetsAt = & $readProperty $window 'resetsAt'
        if (
            -not (& $isNumeric $usedPercent) -or
            -not (& $isNumeric $windowDurationMins) -or
            -not (& $isNumeric $resetsAt)
        ) {
            continue
        }

        $usedPercentNumber = [double] $usedPercent
        $durationNumber = [double] $windowDurationMins
        $resetsAtNumber = [double] $resetsAt
        if (
            [double]::IsNaN($usedPercentNumber) -or
            [double]::IsInfinity($usedPercentNumber) -or
            $usedPercentNumber -lt 0 -or
            $usedPercentNumber -gt 100 -or
            [double]::IsNaN($durationNumber) -or
            [double]::IsInfinity($durationNumber) -or
            ($durationNumber -ne 300 -and $durationNumber -ne 10080) -or
            [double]::IsNaN($resetsAtNumber) -or
            [double]::IsInfinity($resetsAtNumber) -or
            $resetsAtNumber -lt 0 -or
            $resetsAtNumber % 1 -ne 0
        ) {
            continue
        }

        $candidate = [pscustomobject]@{
            usedPercent = $usedPercentNumber
            resetsAt = $resetsAt
        }
        if ($durationNumber -eq 300) {
            $sessionCandidates += $candidate
        } else {
            $weeklyCandidates += $candidate
        }
    }

    # Duplicate windows of the same duration are ambiguous, so neither slot wins.
    $sessionAvailable = $sessionCandidates.Count -eq 1
    $weeklyAvailable = $weeklyCandidates.Count -eq 1
    $sessionUsedPercent = if ($sessionAvailable) {
        $sessionCandidates[0].usedPercent
    } else {
        $null
    }
    $weeklyUsedPercent = if ($weeklyAvailable) {
        $weeklyCandidates[0].usedPercent
    } else {
        $null
    }

    return [pscustomobject]@{
        adapter                      = 'codex-json-rpc'
        status                       = if ($sessionAvailable -or $weeklyAvailable) { 'ok' } else { 'no-data' }
        primaryUsedPercent           = $primaryUsedPercent
        primaryWindowDurationMins    = $primaryWindowDurationMins
        primaryResetsAt              = $primaryResetsAt
        secondaryUsedPercent         = $secondaryUsedPercent
        secondaryWindowDurationMins  = $secondaryWindowDurationMins
        secondaryResetsAt            = $secondaryResetsAt
        sessionAvailable             = $sessionAvailable
        sessionUsedPercent           = $sessionUsedPercent
        sessionResetsAt              = if ($sessionAvailable) { $sessionCandidates[0].resetsAt } else { $null }
        weeklyAvailable              = $weeklyAvailable
        weeklyUsedPercent            = $weeklyUsedPercent
        weeklyResetsAt               = if ($weeklyAvailable) { $weeklyCandidates[0].resetsAt } else { $null }
        usedPercent                  = $sessionUsedPercent
        planType                     = & $readProperty $RateLimits 'planType'
        reason                       = if ($sessionAvailable -or $weeklyAvailable) { $null } else { 'no-trustworthy-rate-limit-windows' }
    }
}

function Read-GatecraftJsonRpcResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Diagnostics.Process] $Process,

        [Parameter(Mandatory)]
        [long] $Id,

        [Parameter(Mandatory)]
        [datetime] $DeadlineUtc
    )

    while ([datetime]::UtcNow -lt $DeadlineUtc) {
        $remaining = [Math]::Ceiling(
            ($DeadlineUtc - [datetime]::UtcNow).TotalMilliseconds
        )
        if ($remaining -le 0) {
            return $null
        }

        try {
            $readTask = $Process.StandardOutput.ReadLineAsync()
            if (-not $readTask.Wait([int] $remaining)) {
                return $null
            }
            $line = $readTask.GetAwaiter().GetResult()
        }
        catch {
            return $null
        }

        if ($null -eq $line) {
            return $null
        }

        try {
            $message = $line | ConvertFrom-Json -Depth 100
        }
        catch {
            continue
        }

        if (
            $message.PSObject.Properties.Name -contains 'id' -and
            [long] $message.id -eq $Id
        ) {
            return $message
        }
    }

    return $null
}

function Get-CodexQuotaSnapshot {
    [CmdletBinding()]
    param(
        [ValidateRange(15, 300)]
        [int] $TimeoutSeconds = 20
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        $snapshot = ConvertTo-GatecraftCodexQuotaSnapshot -RateLimits $null
        $snapshot.reason = 'powershell-version-unsupported'
        return $snapshot
    }

    $process = $null
    try {
        $process = New-GatecraftCliProcess -Command 'codex' -ArgumentList @('app-server', '--stdio')

        $stderrTask = $process.StandardError.ReadToEndAsync()
        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)

        $initialize = @{
            jsonrpc = '2.0'
            id = 1
            method = 'initialize'
            params = @{
                clientInfo = @{
                    name = 'gatecraft'
                    version = '1.0.0'
                }
                capabilities = @{
                    experimentalApi = $true
                }
            }
        } | ConvertTo-Json -Compress -Depth 10
        $process.StandardInput.WriteLine($initialize)
        $process.StandardInput.Flush()

        $initializedResponse = Read-GatecraftJsonRpcResponse -Process $process -Id 1 -DeadlineUtc $deadline
        if (
            $null -eq $initializedResponse -or
            $initializedResponse.PSObject.Properties.Name -contains 'error'
        ) {
            $snapshot = ConvertTo-GatecraftCodexQuotaSnapshot -RateLimits $null
            $snapshot.reason = 'initialize-missing-or-error'
            return $snapshot
        }

        $initialized = @{
            jsonrpc = '2.0'
            method = 'initialized'
        } | ConvertTo-Json -Compress -Depth 10
        $process.StandardInput.WriteLine($initialized)
        $process.StandardInput.Flush()
        Start-Sleep -Milliseconds 500

        $request = @{
            jsonrpc = '2.0'
            id = 2
            method = 'account/rateLimits/read'
        } | ConvertTo-Json -Compress -Depth 10
        $process.StandardInput.WriteLine($request)
        $process.StandardInput.Flush()

        $response = Read-GatecraftJsonRpcResponse -Process $process -Id 2 -DeadlineUtc $deadline
        if (
            $null -eq $response -or
            $response.PSObject.Properties.Name -contains 'error'
        ) {
            $snapshot = ConvertTo-GatecraftCodexQuotaSnapshot -RateLimits $null
            $snapshot.reason = 'rate-limit-response-missing-or-error'
            return $snapshot
        }

        return ConvertTo-GatecraftCodexQuotaSnapshot -RateLimits $response.result.rateLimits
    }
    catch {
        $snapshot = ConvertTo-GatecraftCodexQuotaSnapshot -RateLimits $null
        $snapshot.reason = 'launch-or-protocol-error'
        return $snapshot
    }
    finally {
        if ($process) {
            if (-not $process.HasExited) {
                $process.Kill($true)
                $process.WaitForExit()
            }
            $process.Dispose()
        }
    }
}

# Call once at the Step 1 cycle boundary.
$codexQuota = Get-CodexQuotaSnapshot -TimeoutSeconds 20
$codexQuota | ConvertTo-Json -Compress
~~~

The pure ConvertTo-GatecraftCodexQuotaSnapshot function can be loaded and fixture-tested without launching Codex. It preserves the raw usedPercent, windowDurationMins, and resetsAt values from both transport slots, then classifies only trustworthy windows: usedPercent must be numeric and within 0–100, windowDurationMins must be numeric and exactly 300 or 10080, and resetsAt must be a non-negative integral Unix timestamp. Missing, malformed, out-of-range, unrecognized, or duplicate-duration windows remain unavailable and are never synthesized as 0.

Interpret percentages as used, not left. sessionUsedPercent and weeklyUsedPercent are normalized by duration, with sessionAvailable and weeklyAvailable exposing each capability explicitly. The backward-compatible usedPercent is always identical to sessionUsedPercent. A weekly-only payload therefore returns status = ok, weeklyAvailable = true, sessionAvailable = false, sessionUsedPercent = null, and usedPercent = null. Apply Step 3's 95% short-session threshold only when sessionAvailable = true; never substitute a weekly value into that decision.

A backend 503, eventual-consistency flap, timeout, missing response, or malformed JSON produces no-data for the current cycle. Do not retry in that cycle and do not synthesize a zero.

Discover the installed app-server schema with codex app-server generate-json-schema --experimental when validating a CLI upgrade; perform that local check during bootstrap, never by adding a network dependency to the cycle adapter.

## No-data rule

Return and record an explicit object with status = no-data, usedPercent = null, and a reason when no trustworthy window exists. A trustworthy weekly-only Codex payload is not no-data: it is status = ok with sessionAvailable = false. Keep Step 3 non-blocking when the short-session reading is unavailable: refresh the handoff snapshot, preserve usage-independent succession readiness, and continue or stop only under the attended/unattended contract and persisted policies. Never compare a null reading or weeklyUsedPercent to the 95% short-session threshold.

## Rejected alternatives

- Reject echo /usage piped to claude --print because --print treats the slash command as literal prompt text.
- Reject Codex /status through codex exec because it becomes a literal prompt, and reject piping it into the TUI because stdin is not a terminal.
- Reject Content-Length framing for Codex app-server because this adapter requires one JSON object per line.
- Reject codex doctor, codex login status, and per-call codex exec --json token usage as account-quota sources.
- Prefer the direct app-server call over third-party wrappers that touch auth material or undocumented endpoints.
