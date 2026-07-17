Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Gatecraft.Protocol.psm1') -Force

function Write-RegistryUsage {
    [Console]::Out.WriteLine(@'
Usage:
  registry.ps1 register --local-state-root <absolute-path> --owner-token <opaque-token> --gatecraft-version <semver> --debategui-range <range> --endpoint-base <http://127.0.0.1:port> [--label <safe-label>]
  registry.ps1 heartbeat --local-state-root <absolute-path> --instance-id <id> --owner-token <opaque-token> [--freshness <canonical-UTC>]
  registry.ps1 update --local-state-root <absolute-path> --instance-id <id> --owner-token <opaque-token> [--endpoint-base <http://127.0.0.1:port>] [--cursor <decimal|null>] [--lifecycle <running|stopped|stale|incompatible>] [--feed <local:v1:id>]
  registry.ps1 unregister --local-state-root <absolute-path> --instance-id <id> --owner-token <opaque-token>
  registry.ps1 sweep-stale --local-state-root <absolute-path> --threshold-seconds <60-86400>
  registry.ps1 list --local-state-root <absolute-path>
  registry.ps1 publish-event --local-state-root <absolute-path> --instance-id <id> --owner-token <opaque-token> --event-type <value> --occurred-at <RFC3339> --outcome <value> --summary <safe-text> [--event-id <id>] [--cycle-sequence <decimal>]

Owner tokens use 32-128 ASCII letters, digits, underscore, or hyphen (caller-generated, same convention as guard.ps1).

Test-only controls (require GATECRAFT_REGISTRY_TEST_CONTROLS=1):
  register --test-force-instance-id <32-char-base64url-id>   Force a specific instance ID to test collision rejection.
  heartbeat --freshness <canonical-UTC>                       Force a specific freshness to simulate a crashed/stale owner.
'@)
}

function Stop-Registry {
    param([Parameter(Mandatory)][int] $ExitCode, [Parameter(Mandatory)][string] $Code)
    [Console]::Error.WriteLine("REGISTRY_FAILED code=$Code")
    exit $ExitCode
}

function Get-RegistryExitCode {
    param([Parameter(Mandatory)][string] $Code)
    if ($Code -match '^argument-|^powershell-|^label-|^endpoint-|^semver-|^range-|^owner-token-|^cursor-|^lifecycle-|^event-.*-invalid$|^threshold-|^feed-reference-invalid$') { return 64 }
    if ($Code -match '^local-state-root-|^path-|^registry-root-|^feeds-root-|^owners-root-') { return 69 }
    if ($Code -match '^registry-contended$|^feed-contended$|^owners-contended$') { return 73 }
    if ($Code -match '^instance-id-collision$') { return 74 }
    if ($Code -match '^registry-corrupt|^owners-corrupt|^feed-corrupt') { return 75 }
    if ($Code -match '^instance-not-found$|^owner-mismatch$|^owner-token-unknown$') { return 76 }
    return 65
}

function Read-RegistryArguments {
    param([Parameter(Mandatory)][object[]] $Tokens)
    if ($Tokens.Count -eq 1 -and [string]$Tokens[0] -ceq '--help') { Write-RegistryUsage; exit 0 }
    if ($Tokens.Count -lt 1) { throw 'argument-command-required' }
    $command = [string]$Tokens[0]
    if ($command -cnotin @('register', 'heartbeat', 'update', 'unregister', 'sweep-stale', 'list', 'publish-event')) { throw 'argument-command-invalid' }
    $allowedByCommand = @{
        register = @('--local-state-root', '--owner-token', '--gatecraft-version', '--debategui-range', '--endpoint-base', '--label', '--test-force-instance-id')
        heartbeat = @('--local-state-root', '--instance-id', '--owner-token', '--freshness')
        update = @('--local-state-root', '--instance-id', '--owner-token', '--endpoint-base', '--cursor', '--lifecycle', '--feed')
        unregister = @('--local-state-root', '--instance-id', '--owner-token')
        'sweep-stale' = @('--local-state-root', '--threshold-seconds')
        list = @('--local-state-root')
        'publish-event' = @('--local-state-root', '--instance-id', '--owner-token', '--event-type', '--occurred-at', '--outcome', '--summary', '--event-id', '--cycle-sequence')
    }
    $requiredByCommand = @{
        register = @('--local-state-root', '--owner-token', '--gatecraft-version', '--debategui-range', '--endpoint-base')
        heartbeat = @('--local-state-root', '--instance-id', '--owner-token')
        update = @('--local-state-root', '--instance-id', '--owner-token')
        unregister = @('--local-state-root', '--instance-id', '--owner-token')
        'sweep-stale' = @('--local-state-root', '--threshold-seconds')
        list = @('--local-state-root')
        'publish-event' = @('--local-state-root', '--instance-id', '--owner-token', '--event-type', '--occurred-at', '--outcome', '--summary')
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
    if ($command -ceq 'update' -and -not ($values.ContainsKey('--endpoint-base') -or $values.ContainsKey('--cursor') -or $values.ContainsKey('--lifecycle') -or $values.ContainsKey('--feed'))) {
        throw 'argument-required-at-least-one'
    }
    return [pscustomobject]@{ Command = $command; Values = $values }
}

# ---- Shared filesystem primitives (mirrors gatecraft/scripts/guard.ps1 conventions) ----

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
    if ($fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) -ceq $pathRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)) { throw $InvalidCode }
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        if ($DeclaredPath.StartsWith('\\', [StringComparison]::Ordinal) -or $DeclaredPath.StartsWith('//', [StringComparison]::Ordinal) -or $DeclaredPath.StartsWith('\\?\', [StringComparison]::Ordinal) -or $DeclaredPath.StartsWith('\\.\', [StringComparison]::Ordinal)) { throw $NonLocalCode }
    }
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

function ConvertTo-CanonicalJson {
    param([Parameter(Mandatory)][object] $Value, [int] $Depth = 8)
    return ConvertTo-Json -InputObject $Value -Depth $Depth -Compress -EscapeHandling EscapeNonAscii
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

function Write-AtomicUtf8Replace {
    param([Parameter(Mandatory)][string] $Directory, [Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Text)
    Assert-NotReparsePoint -Path $Directory -Code 'path-reparse'
    if ([IO.Directory]::Exists($Path)) { throw 'path-type' }
    Assert-NotReparsePoint -Path $Path -Code 'path-reparse'
    $temporary = [IO.Path]::Combine($Directory, '.registry-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function ConvertTo-CanonicalTimestamp {
    param([Parameter(Mandatory)][string] $Value)
    if ($Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$') { throw 'timestamp-invalid' }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { throw 'timestamp-invalid' }
    return $parsed.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function Get-NowCanonicalTimestamp {
    return [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

# ---- Registry-domain validation ----

function New-InstanceId {
    $bytes = [byte[]]::new(24)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')
}

function Assert-InstanceId {
    param([Parameter(Mandatory)][string] $Value)
    if ($Value -notmatch '^[A-Za-z0-9_-]{32}$') { throw 'instance-id-invalid' }
}

function Assert-OwnerTokenFormat {
    param([Parameter(Mandatory)][string] $Value)
    if ($Value -notmatch '^[A-Za-z0-9_-]{32,128}$') { throw 'owner-token-invalid' }
}

$script:LabelAdjectives = @('amber', 'bold', 'calm', 'cedar', 'coral', 'ember', 'frost', 'lunar', 'quiet', 'swift', 'terra', 'violet')
$script:LabelNouns = @('atlas', 'beacon', 'canyon', 'falcon', 'harbor', 'meadow', 'otter', 'ridge', 'summit', 'willow', 'zephyr', 'brook')

function Get-DefaultLabel {
    $bytes = [byte[]]::new(4)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $adjective = $script:LabelAdjectives[$bytes[0] % $script:LabelAdjectives.Count]
    $noun = $script:LabelNouns[$bytes[1] % $script:LabelNouns.Count]
    $suffix = ($bytes[2] % 90) + 10
    return "$adjective-$noun-$suffix"
}

function Assert-Label {
    param([Parameter(Mandatory)][string] $Value)
    if ($Value.Length -lt 1 -or $Value.Length -gt 64) { throw 'label-invalid' }
    if (-not $Value.IsNormalized([Text.NormalizationForm]::FormC)) { throw 'label-invalid' }
    if ($Value -cne $Value.Trim()) { throw 'label-invalid' }
    # Allowlist only: letters, digits, single interior spaces, hyphen, underscore.
    # This structurally rejects paths, URLs, credentials/tokens with punctuation, and @-identifiers.
    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$') { throw 'label-invalid' }
    if ($Value.Contains('  ', [StringComparison]::Ordinal)) { throw 'label-invalid' }
}

function Assert-Semver {
    param([Parameter(Mandatory)][string] $Value)
    if ($Value -notmatch '^\d{1,5}\.\d{1,5}\.\d{1,5}$') { throw 'semver-invalid' }
}

function Assert-SemverRange {
    param([Parameter(Mandatory)][string] $Value)
    if ($Value.Length -lt 1 -or $Value.Length -gt 64) { throw 'range-invalid' }
    if ($Value -notmatch '^[0-9A-Za-z^~<>=][0-9A-Za-z.^~<>= |-]{0,63}$') { throw 'range-invalid' }
    if (-not ($Value -match '\d')) { throw 'range-invalid' }
}

function Assert-EndpointBase {
    param([Parameter(Mandatory)][string] $Value)
    $match = [regex]::Match($Value, '^http://127\.0\.0\.1:(?<port>[1-9][0-9]{0,4})$')
    if (-not $match.Success) { throw 'endpoint-base-invalid' }
    [int]$port = 0
    if (-not [int]::TryParse($match.Groups['port'].Value, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw 'endpoint-base-invalid' }
}

function Build-Endpoint {
    param([Parameter(Mandatory)][string] $EndpointBase, [Parameter(Mandatory)][string] $InstanceId)
    return "$EndpointBase/v1/instances/$InstanceId"
}

function Assert-Endpoint {
    param([Parameter(Mandatory)][string] $Value, [Parameter(Mandatory)][string] $InstanceId)
    if ($Value -notmatch "^http://127\.0\.0\.1:[1-9][0-9]{0,4}/v1/instances/$([regex]::Escape($InstanceId))`$") { throw 'endpoint-invalid' }
}

function Get-FeedReference {
    param([Parameter(Mandatory)][string] $InstanceId)
    return "local:v1:$InstanceId"
}

function Assert-FeedReference {
    param([Parameter(Mandatory)][string] $Value, [Parameter(Mandatory)][string] $InstanceId)
    if ($Value -cne (Get-FeedReference -InstanceId $InstanceId)) { throw 'feed-reference-invalid' }
}

function Assert-Cursor {
    param([AllowNull()][string] $Value)
    if ($null -eq $Value) { return }
    if ($Value -cnotin @('null') -and $Value -notmatch '^[0-9]{1,19}$') { throw 'cursor-invalid' }
}

function Assert-Lifecycle {
    param([Parameter(Mandatory)][string] $Value)
    if ($Value -cnotin @('running', 'stopped', 'stale', 'incompatible')) { throw 'lifecycle-invalid' }
}

function Assert-NoPathTraversal {
    param([Parameter(Mandatory)][string] $Value, [Parameter(Mandatory)][string] $Code)
    if ($Value.Contains('..', [StringComparison]::Ordinal) -or $Value.Contains('\', [StringComparison]::Ordinal)) { throw $Code }
    if ($Value -match '[\x00-\x1F\x7F]') { throw $Code }
}

# ---- Registry file model ----

function Get-RegistryRoot {
    param([Parameter(Mandatory)][string] $LocalStateRoot)
    return [IO.Path]::Combine($LocalStateRoot, 'debategui', 'v1')
}

function Get-RegistryPaths {
    param([Parameter(Mandatory)][string] $LocalStateRoot)
    $root = Get-RegistryRoot -LocalStateRoot $LocalStateRoot
    return [pscustomobject]@{
        Root = $root
        InstancesFile = [IO.Path]::Combine($root, 'instances.json')
        OwnersFile = [IO.Path]::Combine($root, 'owners.json')
        FeedsDirectory = [IO.Path]::Combine($root, 'feeds')
    }
}

function Assert-RegistryDirectoryEntries {
    param([Parameter(Mandatory)][string] $Directory)
    Assert-NotReparsePoint -Path $Directory -Code 'registry-root-reparse'
    foreach ($entry in [IO.DirectoryInfo]::new($Directory).GetFileSystemInfos()) {
        if ($entry.Name -cnotin @('instances.json', 'owners.json', 'feeds', '.registry.lock') -or ($entry.Name -ceq 'feeds' -and $entry -isnot [IO.DirectoryInfo])) { throw 'registry-root-unexpected-entry' }
        Assert-NotReparsePoint -Path $entry.FullName -Code 'registry-root-reparse'
    }
}

function New-InstanceRecord {
    param(
        [Parameter(Mandatory)][string[]] $Capabilities,
        [AllowNull()][AllowEmptyString()] $Cursor,
        [Parameter(Mandatory)][string] $DebateguiRange,
        [Parameter(Mandatory)][string] $Endpoint,
        [Parameter(Mandatory)][string] $Feed,
        [Parameter(Mandatory)][string] $Freshness,
        [Parameter(Mandatory)][string] $GatecraftVersion,
        [Parameter(Mandatory)][string] $InstanceId,
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][string] $Lifecycle
    )
    return [pscustomobject][ordered]@{
        capabilities = @($Capabilities)
        cursor = $Cursor
        debategui_range = $DebateguiRange
        endpoint = $Endpoint
        feed = $Feed
        freshness = $Freshness
        gatecraft_version = $GatecraftVersion
        instance_id = $InstanceId
        label = $Label
        lifecycle = $Lifecycle
        protocol = 'gatecraft-debategui/v1'
    }
}

function ConvertTo-InstanceCanonicalJson {
    param([Parameter(Mandatory)][object] $Record)
    return ConvertTo-CanonicalJson -Value $Record -Depth 4
}

function Read-InstanceElement {
    param([Text.Json.JsonElement] $Element)
    $fields = Get-ExactJsonFields -Element $Element -Names @('capabilities', 'cursor', 'debategui_range', 'endpoint', 'feed', 'freshness', 'gatecraft_version', 'instance_id', 'label', 'lifecycle', 'protocol') -FailureCode 'registry-corrupt-instance-fields'
    foreach ($name in @('debategui_range', 'endpoint', 'feed', 'freshness', 'gatecraft_version', 'instance_id', 'label', 'lifecycle', 'protocol')) {
        if ($fields[$name].ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'registry-corrupt-instance-fields' }
    }
    if ($fields['capabilities'].ValueKind -ne [Text.Json.JsonValueKind]::Array) { throw 'registry-corrupt-instance-fields' }
    $capabilities = [Collections.Generic.List[string]]::new()
    foreach ($item in $fields['capabilities'].EnumerateArray()) {
        if ($item.ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'registry-corrupt-instance-fields' }
        $capabilities.Add($item.GetString())
    }
    if (@($capabilities).Count -ne 1 -or $capabilities[0] -cne 'events.read') { throw 'registry-corrupt-capabilities' }

    $cursor = $null
    if ($fields['cursor'].ValueKind -eq [Text.Json.JsonValueKind]::String) { $cursor = $fields['cursor'].GetString() }
    elseif ($fields['cursor'].ValueKind -ne [Text.Json.JsonValueKind]::Null) { throw 'registry-corrupt-cursor' }

    $instanceId = $fields['instance_id'].GetString()
    try { Assert-InstanceId $instanceId } catch { throw 'registry-corrupt-instance-id' }
    $label = $fields['label'].GetString()
    try { Assert-Label $label } catch { throw 'registry-corrupt-label' }
    $debateguiRange = $fields['debategui_range'].GetString()
    try { Assert-SemverRange $debateguiRange } catch { throw 'registry-corrupt-range' }
    $gatecraftVersion = $fields['gatecraft_version'].GetString()
    try { Assert-Semver $gatecraftVersion } catch { throw 'registry-corrupt-semver' }
    $endpoint = $fields['endpoint'].GetString()
    try { Assert-Endpoint -Value $endpoint -InstanceId $instanceId } catch { throw 'registry-corrupt-endpoint' }
    $feed = $fields['feed'].GetString()
    try { Assert-FeedReference -Value $feed -InstanceId $instanceId } catch { throw 'registry-corrupt-feed' }
    $freshness = $fields['freshness'].GetString()
    if ($freshness -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') { throw 'registry-corrupt-freshness' }
    $lifecycle = $fields['lifecycle'].GetString()
    try { Assert-Lifecycle $lifecycle } catch { throw 'registry-corrupt-lifecycle' }
    if ($fields['protocol'].GetString() -cne 'gatecraft-debategui/v1') { throw 'registry-corrupt-protocol' }
    try { Assert-NoPathTraversal -Value $label -Code 'registry-corrupt-label' } catch { throw 'registry-corrupt-label' }

    $record = New-InstanceRecord -Capabilities @($capabilities) -Cursor $cursor -DebateguiRange $debateguiRange -Endpoint $endpoint -Feed $feed -Freshness $freshness -GatecraftVersion $gatecraftVersion -InstanceId $instanceId -Label $label -Lifecycle $lifecycle
    return $record
}

function Read-RegistryFile {
    param([Parameter(Mandatory)][string] $Path)
    if (-not [IO.File]::Exists($Path)) {
        return [pscustomobject]@{ Protocol = 'gatecraft-debategui/v1'; GeneratedAt = $null; Instances = @() }
    }
    $file = Read-StrictUtf8File -Path $Path -FailureCode 'registry-corrupt-encoding' -MaximumBytes 67108864
    try { $document = [Text.Json.JsonDocument]::Parse($file.Text) } catch { throw 'registry-corrupt-json' }
    try {
        $root = Get-ExactJsonFields -Element $document.RootElement -Names @('protocol', 'generated_at', 'instances') -FailureCode 'registry-corrupt-root-fields'
        if ($root['protocol'].ValueKind -ne [Text.Json.JsonValueKind]::String -or $root['protocol'].GetString() -cne 'gatecraft-debategui/v1') { throw 'registry-corrupt-protocol' }
        if ($root['generated_at'].ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'registry-corrupt-generated-at' }
        $generatedAt = $root['generated_at'].GetString()
        if ($generatedAt -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') { throw 'registry-corrupt-generated-at' }
        if ($root['instances'].ValueKind -ne [Text.Json.JsonValueKind]::Array) { throw 'registry-corrupt-instances' }

        $instances = [Collections.Generic.List[object]]::new()
        $seenIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($element in $root['instances'].EnumerateArray()) {
            $record = Read-InstanceElement -Element $element
            if (-not $seenIds.Add($record.instance_id)) { throw 'registry-corrupt-duplicate-id' }
            if ($instances.Count -gt 0 -and [StringComparer]::Ordinal.Compare([string]$instances[$instances.Count - 1].instance_id, [string]$record.instance_id) -ge 0) { throw 'registry-corrupt-unsorted' }
            $instances.Add($record)
        }

        $result = [pscustomobject]@{ Protocol = 'gatecraft-debategui/v1'; GeneratedAt = $generatedAt; Instances = @($instances) }
        $roundTrip = ConvertTo-RegistryCanonicalJson -Registry $result
        if ($roundTrip -cne $file.Text) { throw 'registry-corrupt-not-canonical' }
        return $result
    }
    finally { $document.Dispose() }
}

function ConvertTo-RegistryCanonicalJson {
    param([Parameter(Mandatory)][object] $Registry)
    $payload = [pscustomobject][ordered]@{
        generated_at = $Registry.GeneratedAt
        instances = @($Registry.Instances)
        protocol = $Registry.Protocol
    }
    return ConvertTo-CanonicalJson -Value $payload -Depth 6
}

function Write-RegistryFile {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Directory, [Parameter(Mandatory)][object] $Registry)
    $text = ConvertTo-RegistryCanonicalJson -Registry $Registry
    Write-AtomicUtf8Replace -Directory $Directory -Path $Path -Text $text
    $persisted = Read-StrictUtf8File -Path $Path -FailureCode 'registry-corrupt-write' -MaximumBytes 67108864
    if ($persisted.Text -cne $text) { throw 'registry-corrupt-write' }
}

# ---- Owners file model (Gatecraft-private; never exposed to DebateGUI readers) ----

function New-OwnerRecord {
    param([Parameter(Mandatory)][string] $CreatedAt, [Parameter(Mandatory)][string] $InstanceId, [Parameter(Mandatory)][string] $OwnerTokenSha256)
    return [pscustomobject][ordered]@{
        created_at = $CreatedAt
        instance_id = $InstanceId
        owner_token_sha256 = $OwnerTokenSha256
    }
}

function Read-OwnersFile {
    param([Parameter(Mandatory)][string] $Path)
    if (-not [IO.File]::Exists($Path)) {
        return [pscustomobject]@{ Protocol = 'gatecraft-debategui-owners/v1'; Owners = @() }
    }
    $file = Read-StrictUtf8File -Path $Path -FailureCode 'owners-corrupt-encoding' -MaximumBytes 67108864
    try { $document = [Text.Json.JsonDocument]::Parse($file.Text) } catch { throw 'owners-corrupt-json' }
    try {
        $root = Get-ExactJsonFields -Element $document.RootElement -Names @('protocol', 'owners') -FailureCode 'owners-corrupt-root-fields'
        if ($root['protocol'].ValueKind -ne [Text.Json.JsonValueKind]::String -or $root['protocol'].GetString() -cne 'gatecraft-debategui-owners/v1') { throw 'owners-corrupt-protocol' }
        if ($root['owners'].ValueKind -ne [Text.Json.JsonValueKind]::Array) { throw 'owners-corrupt-owners' }
        $owners = [Collections.Generic.List[object]]::new()
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($element in $root['owners'].EnumerateArray()) {
            $fields = Get-ExactJsonFields -Element $element -Names @('created_at', 'instance_id', 'owner_token_sha256') -FailureCode 'owners-corrupt-fields'
            foreach ($name in @('created_at', 'instance_id', 'owner_token_sha256')) { if ($fields[$name].ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'owners-corrupt-fields' } }
            $instanceId = $fields['instance_id'].GetString()
            try { Assert-InstanceId $instanceId } catch { throw 'owners-corrupt-instance-id' }
            $hash = $fields['owner_token_sha256'].GetString()
            if ($hash -notmatch '^[0-9a-f]{64}$') { throw 'owners-corrupt-hash' }
            $createdAt = $fields['created_at'].GetString()
            if ($createdAt -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$') { throw 'owners-corrupt-created-at' }
            if (-not $seen.Add($instanceId)) { throw 'owners-corrupt-duplicate-id' }
            if ($owners.Count -gt 0 -and [StringComparer]::Ordinal.Compare([string]$owners[$owners.Count - 1].instance_id, $instanceId) -ge 0) { throw 'owners-corrupt-unsorted' }
            $owners.Add((New-OwnerRecord -CreatedAt $createdAt -InstanceId $instanceId -OwnerTokenSha256 $hash))
        }
        $result = [pscustomobject]@{ Protocol = 'gatecraft-debategui-owners/v1'; Owners = @($owners) }
        $roundTrip = ConvertTo-OwnersCanonicalJson -Owners $result
        if ($roundTrip -cne $file.Text) { throw 'owners-corrupt-not-canonical' }
        return $result
    }
    finally { $document.Dispose() }
}

function ConvertTo-OwnersCanonicalJson {
    param([Parameter(Mandatory)][object] $Owners)
    $payload = [pscustomobject][ordered]@{ owners = @($Owners.Owners); protocol = $Owners.Protocol }
    return ConvertTo-CanonicalJson -Value $payload -Depth 4
}

function Write-OwnersFile {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Directory, [Parameter(Mandatory)][object] $Owners)
    $text = ConvertTo-OwnersCanonicalJson -Owners $Owners
    Write-AtomicUtf8Replace -Directory $Directory -Path $Path -Text $text
    $persisted = Read-StrictUtf8File -Path $Path -FailureCode 'owners-corrupt-write' -MaximumBytes 67108864
    if ($persisted.Text -cne $text) { throw 'owners-corrupt-write' }
}

function Assert-OwnerTokenMatches {
    param([Parameter(Mandatory)][object] $Owners, [Parameter(Mandatory)][string] $InstanceId, [Parameter(Mandatory)][string] $OwnerToken)
    $entry = @($Owners.Owners | Where-Object { $_.instance_id -ceq $InstanceId })
    if (@($entry).Count -ne 1) { throw 'owner-token-unknown' }
    $expected = [Text.Encoding]::ASCII.GetBytes([string]$entry[0].owner_token_sha256)
    $actual = [Text.Encoding]::ASCII.GetBytes((Get-Sha256Hex ([Text.UTF8Encoding]::new($false).GetBytes($OwnerToken))))
    if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($expected, $actual)) { throw 'owner-mismatch' }
}

# ---- Cross-process serialization for the registry root ----
# A single exclusive lock file under the registry root serializes read-modify-write
# across concurrently running registry.ps1 invocations (potentially from different
# repositories/worktrees/orchestrators sharing the same --local-state-root).

function Enter-RegistryLock {
    param([Parameter(Mandatory)][string] $Root)
    $lockPath = [IO.Path]::Combine($Root, '.registry.lock')
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            $stream = [IO.FileStream]::new($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
            return $stream
        }
        catch [IO.IOException] {
            if ($deadline.ElapsedMilliseconds -ge 15000) { throw 'registry-contended' }
            Start-Sleep -Milliseconds 20
        }
    }
}

function Exit-RegistryLock {
    param([Parameter(Mandatory)][IO.FileStream] $Lock)
    $Lock.Dispose()
}

# ---- Feed model ----

function Get-FeedPath {
    param([Parameter(Mandatory)][string] $FeedsDirectory, [Parameter(Mandatory)][string] $InstanceId)
    return [IO.Path]::Combine($FeedsDirectory, "$InstanceId.jsonl")
}

function ConvertTo-JsonStringValue {
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string] $Value)
    if ($null -eq $Value) { return 'null' }
    return ConvertTo-Json -InputObject ([string]$Value) -Compress -EscapeHandling EscapeNonAscii
}

function New-FeedEventLine {
    param(
        [AllowNull()][AllowEmptyString()] $CycleSequence,
        [Parameter(Mandatory)][string] $Cursor,
        [Parameter(Mandatory)][string] $EventId,
        [Parameter(Mandatory)][string] $EventType,
        [Parameter(Mandatory)][string] $OccurredAt,
        [Parameter(Mandatory)][string] $Outcome,
        [Parameter(Mandatory)][string] $Summary
    )
    $cycleSequenceJson = if ([string]::IsNullOrEmpty($CycleSequence)) { 'null' } else { $CycleSequence }
    return '{' +
        '"cursor":' + (ConvertTo-JsonStringValue $Cursor) + ',' +
        '"cycle_sequence":' + $cycleSequenceJson + ',' +
        '"event_id":' + (ConvertTo-JsonStringValue $EventId) + ',' +
        '"event_type":' + (ConvertTo-JsonStringValue $EventType) + ',' +
        '"occurred_at":' + (ConvertTo-JsonStringValue $OccurredAt) + ',' +
        '"outcome":' + (ConvertTo-JsonStringValue $Outcome) + ',' +
        '"protocol":"gatecraft-debategui-event/v1",' +
        '"summary":' + (ConvertTo-JsonStringValue $Summary) +
        '}'
}

function Assert-EventId {
    param([Parameter(Mandatory)][string] $Value)
    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw 'event-id-invalid' }
}

function Assert-EventType {
    param([Parameter(Mandatory)][string] $Value)
    if ($Value -notmatch '^[a-z][a-z0-9-]{0,63}$') { throw 'event-type-invalid' }
}

function Assert-SanitizedEventText {
    param([Parameter(Mandatory)][string] $Value, [Parameter(Mandatory)][string] $Code, [int] $MaximumLength = 512)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $MaximumLength) { throw $Code }
    if (-not $Value.IsNormalized([Text.NormalizationForm]::FormC)) { throw $Code }
    if ($Value -cne $Value.Trim()) { throw $Code }
    if ($Value -match '[\x00-\x1F\x7F]') { throw $Code }
    # Allowlist charset: letters, digits, space, and a minimal punctuation set. This
    # structurally excludes backslashes, '@', quotes, and most credential/URL shapes.
    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._:/+=-]*$') { throw $Code }
    if ($Value.Contains('..', [StringComparison]::Ordinal)) { throw $Code }
    if ($Value.Contains('://', [StringComparison]::Ordinal)) { throw $Code }
    if ($Value -match '(?i)[a-z]:[\\/]') { throw $Code }
}

function Get-LastFeedEventId {
    param([Parameter(Mandatory)][string] $FeedPath)
    if (-not [IO.File]::Exists($FeedPath)) { return $null }
    Assert-NotReparsePoint -Path $FeedPath -Code 'feed-corrupt-reparse'
    $bytes = [IO.File]::ReadAllBytes($FeedPath)
    if ($bytes.Length -eq 0) { return $null }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $lines = @($text.TrimEnd("`n") -split "`n" | Where-Object { $_.Length -gt 0 })
    if (@($lines).Count -eq 0) { return $null }
    $last = $lines[-1]
    try { $document = [Text.Json.JsonDocument]::Parse($last) } catch { throw 'feed-corrupt-json' }
    try {
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'feed-corrupt-json' }
        $fields = Get-ExactJsonFields -Element $document.RootElement -Names @('cursor', 'cycle_sequence', 'event_id', 'event_type', 'occurred_at', 'outcome', 'protocol', 'summary') -FailureCode 'feed-corrupt-json'
        if ($fields['event_id'].ValueKind -ne [Text.Json.JsonValueKind]::String -or $fields['cursor'].ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'feed-corrupt-json' }
        return [pscustomobject]@{ EventId = $fields['event_id'].GetString(); Cursor = $fields['cursor'].GetString() }
    }
    finally { $document.Dispose() }
}

function Add-FeedEventLine {
    param([Parameter(Mandatory)][string] $FeedPath, [Parameter(Mandatory)][string] $Directory, [Parameter(Mandatory)][string] $Line)
    Initialize-SafeDirectory -FullPath $Directory -InvalidCode 'feeds-root-invalid' -ReparseCode 'feeds-root-reparse'
    Assert-NotReparsePoint -Path $FeedPath -Code 'feed-corrupt-reparse'
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Line + "`n")
    while ($true) {
        try {
            $stream = [IO.FileStream]::new($FeedPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
            try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
            return
        }
        catch [IO.IOException] {
            if ($deadline.ElapsedMilliseconds -ge 15000) { throw 'feed-contended' }
            Start-Sleep -Milliseconds 20
        }
    }
}

# ---- Command handlers ----

function Invoke-Register {
    param([Collections.Generic.Dictionary[string,string]] $Options)
    Assert-OwnerTokenFormat $Options['--owner-token']
    Assert-Semver $Options['--gatecraft-version']
    Assert-SemverRange $Options['--debategui-range']
    Assert-EndpointBase $Options['--endpoint-base']
    $label = if ($Options.ContainsKey('--label')) { $Options['--label'] } else { Get-DefaultLabel }
    Assert-Label $label

    if ($Options.ContainsKey('--test-force-instance-id') -and [Environment]::GetEnvironmentVariable('GATECRAFT_REGISTRY_TEST_CONTROLS', [EnvironmentVariableTarget]::Process) -cne '1') {
        throw 'test-controls-disabled'
    }

    $localStateRoot = ConvertTo-LocalFullPath -DeclaredPath $Options['--local-state-root'] -InvalidCode 'local-state-root-invalid' -NonLocalCode 'local-state-root-nonlocal'
    Initialize-SafeDirectory -FullPath $localStateRoot -InvalidCode 'local-state-root-invalid' -ReparseCode 'path-reparse'
    $paths = Get-RegistryPaths -LocalStateRoot $localStateRoot
    Initialize-SafeDirectory -FullPath $paths.Root -InvalidCode 'registry-root-invalid' -ReparseCode 'path-reparse'
    $lock = Enter-RegistryLock -Root $paths.Root
    try {
        Assert-RegistryDirectoryEntries -Directory $paths.Root
        $registry = Read-RegistryFile -Path $paths.InstancesFile
        $owners = Read-OwnersFile -Path $paths.OwnersFile

        if ($Options.ContainsKey('--test-force-instance-id')) {
            # Test-only: prove the real collision-rejection path without waiting on
            # astronomically unlikely random collisions. Gated by GATECRAFT_REGISTRY_TEST_CONTROLS.
            $instanceId = $Options['--test-force-instance-id']
            Assert-InstanceId $instanceId
            if (@($registry.Instances | Where-Object { $_.instance_id -ceq $instanceId }).Count -gt 0) { throw 'instance-id-collision' }
        }
        else {
            $instanceId = New-InstanceId
            $attempts = 0
            while (@($registry.Instances | Where-Object { $_.instance_id -ceq $instanceId }).Count -gt 0) {
                $attempts++
                if ($attempts -ge 8) { throw 'instance-id-collision' }
                $instanceId = New-InstanceId
            }
        }

        $now = Get-NowCanonicalTimestamp
        $endpoint = Build-Endpoint -EndpointBase $Options['--endpoint-base'] -InstanceId $instanceId
        $feed = Get-FeedReference -InstanceId $instanceId
        $record = New-InstanceRecord -Capabilities @('events.read') -Cursor $null -DebateguiRange $Options['--debategui-range'] -Endpoint $endpoint -Feed $feed -Freshness $now -GatecraftVersion $Options['--gatecraft-version'] -InstanceId $instanceId -Label $label -Lifecycle 'running'

        $newInstances = [Collections.Generic.List[object]]::new()
        $newInstances.AddRange(@($registry.Instances))
        $newInstances.Add($record)
        # Ordinal sort (never culture-sensitive Sort-Object) for deterministic bytes across cultures.
        $orderedIds = Sort-OrdinalStrings -Values @($newInstances | ForEach-Object { [string]$_.instance_id })
        $byId = @{}
        foreach ($item in $newInstances) { $byId[[string]$item.instance_id] = $item }
        $finalInstances = [Collections.Generic.List[object]]::new()
        foreach ($id in $orderedIds) { $finalInstances.Add($byId[$id]) }

        $newRegistry = [pscustomobject]@{ Protocol = 'gatecraft-debategui/v1'; GeneratedAt = $now; Instances = @($finalInstances) }
        Write-RegistryFile -Path $paths.InstancesFile -Directory $paths.Root -Registry $newRegistry

        $newOwners = [Collections.Generic.List[object]]::new()
        $newOwners.AddRange(@($owners.Owners))
        $newOwners.Add((New-OwnerRecord -CreatedAt $now -InstanceId $instanceId -OwnerTokenSha256 (Get-Sha256Hex ([Text.UTF8Encoding]::new($false).GetBytes($Options['--owner-token'])))))
        $ownerIds = Sort-OrdinalStrings -Values @($newOwners | ForEach-Object { $_.instance_id })
        $ownerById = @{}
        foreach ($item in $newOwners) { $ownerById[[string]$item.instance_id] = $item }
        $finalOwners = [Collections.Generic.List[object]]::new()
        foreach ($id in $ownerIds) { $finalOwners.Add($ownerById[$id]) }
        Write-OwnersFile -Path $paths.OwnersFile -Directory $paths.Root -Owners ([pscustomobject]@{ Protocol = 'gatecraft-debategui-owners/v1'; Owners = @($finalOwners) })

        [Console]::Out.WriteLine("REGISTRY_REGISTERED code=registered instance_id=$instanceId label=$label endpoint=$endpoint")
    }
    finally { Exit-RegistryLock -Lock $lock }
}

function Update-InstanceFields {
    param(
        [Parameter(Mandatory)][string] $LocalStateRoot,
        [Parameter(Mandatory)][string] $InstanceId,
        [Parameter(Mandatory)][string] $OwnerToken,
        [scriptblock] $Mutate,
        [Parameter(Mandatory)][string] $SuccessLine
    )
    Assert-InstanceId $InstanceId
    Assert-OwnerTokenFormat $OwnerToken
    $localStateRootFull = ConvertTo-LocalFullPath -DeclaredPath $LocalStateRoot -InvalidCode 'local-state-root-invalid' -NonLocalCode 'local-state-root-nonlocal'
    if (-not [IO.Directory]::Exists($localStateRootFull)) { throw 'local-state-root-missing' }
    $paths = Get-RegistryPaths -LocalStateRoot $localStateRootFull
    if (-not [IO.Directory]::Exists($paths.Root)) { throw 'registry-root-missing' }
    $lock = Enter-RegistryLock -Root $paths.Root
    try {
        Assert-RegistryDirectoryEntries -Directory $paths.Root
        $owners = Read-OwnersFile -Path $paths.OwnersFile
        Assert-OwnerTokenMatches -Owners $owners -InstanceId $InstanceId -OwnerToken $OwnerToken
        $registry = Read-RegistryFile -Path $paths.InstancesFile
        $index = -1
        for ($i = 0; $i -lt $registry.Instances.Count; $i++) { if ($registry.Instances[$i].instance_id -ceq $InstanceId) { $index = $i; break } }
        if ($index -lt 0) { throw 'instance-not-found' }

        $current = $registry.Instances[$index]
        $updated = & $Mutate $current $paths
        $registry.Instances[$index] = $updated

        $now = Get-NowCanonicalTimestamp
        $newRegistry = [pscustomobject]@{ Protocol = 'gatecraft-debategui/v1'; GeneratedAt = $now; Instances = @($registry.Instances) }
        Write-RegistryFile -Path $paths.InstancesFile -Directory $paths.Root -Registry $newRegistry
        [Console]::Out.WriteLine($SuccessLine)
        return $updated
    }
    finally { Exit-RegistryLock -Lock $lock }
}

function Invoke-Heartbeat {
    param([Collections.Generic.Dictionary[string,string]] $Options)
    # Production heartbeats always advance freshness to "now". An explicit --freshness
    # override exists only to let tests simulate a crashed/stale owner deterministically.
    if ($Options.ContainsKey('--freshness') -and [Environment]::GetEnvironmentVariable('GATECRAFT_REGISTRY_TEST_CONTROLS', [EnvironmentVariableTarget]::Process) -cne '1') {
        throw 'test-controls-disabled'
    }
    $freshness = if ($Options.ContainsKey('--freshness')) { ConvertTo-CanonicalTimestamp -Value $Options['--freshness'] } else { Get-NowCanonicalTimestamp }
    [void](Update-InstanceFields -LocalStateRoot $Options['--local-state-root'] -InstanceId $Options['--instance-id'] -OwnerToken $Options['--owner-token'] -SuccessLine "REGISTRY_HEARTBEAT code=heartbeat-updated instance_id=$($Options['--instance-id'])" -Mutate {
        param($current, $paths)
        return New-InstanceRecord -Capabilities @($current.capabilities) -Cursor $current.cursor -DebateguiRange $current.debategui_range -Endpoint $current.endpoint -Feed $current.feed -Freshness $freshness -GatecraftVersion $current.gatecraft_version -InstanceId $current.instance_id -Label $current.label -Lifecycle $current.lifecycle
    })
}

function Invoke-Update {
    param([Collections.Generic.Dictionary[string,string]] $Options)
    $newEndpoint = $null
    if ($Options.ContainsKey('--endpoint-base')) { Assert-EndpointBase $Options['--endpoint-base'] }
    $newCursor = $null
    $cursorProvided = $Options.ContainsKey('--cursor')
    if ($cursorProvided) { Assert-Cursor $Options['--cursor'] }
    $newLifecycle = $null
    if ($Options.ContainsKey('--lifecycle')) { Assert-Lifecycle $Options['--lifecycle'] }
    $newFeed = $null
    if ($Options.ContainsKey('--feed')) { $newFeed = $Options['--feed'] }

    [void](Update-InstanceFields -LocalStateRoot $Options['--local-state-root'] -InstanceId $Options['--instance-id'] -OwnerToken $Options['--owner-token'] -SuccessLine "REGISTRY_UPDATED code=updated instance_id=$($Options['--instance-id'])" -Mutate {
        param($current, $paths)
        $endpoint = if ($Options.ContainsKey('--endpoint-base')) { Build-Endpoint -EndpointBase $Options['--endpoint-base'] -InstanceId $current.instance_id } else { $current.endpoint }
        $cursor = $current.cursor
        if ($cursorProvided) { $cursor = if ($Options['--cursor'] -ceq 'null') { $null } else { $Options['--cursor'] } }
        $lifecycle = if ($Options.ContainsKey('--lifecycle')) { $Options['--lifecycle'] } else { $current.lifecycle }
        $feed = $current.feed
        if ($Options.ContainsKey('--feed')) {
            Assert-FeedReference -Value $Options['--feed'] -InstanceId $current.instance_id
            $feed = $Options['--feed']
        }
        return New-InstanceRecord -Capabilities @($current.capabilities) -Cursor $cursor -DebateguiRange $current.debategui_range -Endpoint $endpoint -Feed $feed -Freshness $current.freshness -GatecraftVersion $current.gatecraft_version -InstanceId $current.instance_id -Label $current.label -Lifecycle $lifecycle
    })
}

function Invoke-Unregister {
    param([Collections.Generic.Dictionary[string,string]] $Options)
    $instanceId = $Options['--instance-id']
    Assert-InstanceId $instanceId
    Assert-OwnerTokenFormat $Options['--owner-token']
    $localStateRoot = ConvertTo-LocalFullPath -DeclaredPath $Options['--local-state-root'] -InvalidCode 'local-state-root-invalid' -NonLocalCode 'local-state-root-nonlocal'
    if (-not [IO.Directory]::Exists($localStateRoot)) { throw 'local-state-root-missing' }
    $paths = Get-RegistryPaths -LocalStateRoot $localStateRoot
    if (-not [IO.Directory]::Exists($paths.Root)) { throw 'registry-root-missing' }
    $lock = Enter-RegistryLock -Root $paths.Root
    try {
        Assert-RegistryDirectoryEntries -Directory $paths.Root
        $owners = Read-OwnersFile -Path $paths.OwnersFile
        Assert-OwnerTokenMatches -Owners $owners -InstanceId $instanceId -OwnerToken $Options['--owner-token']
        $registry = Read-RegistryFile -Path $paths.InstancesFile
        $remaining = @($registry.Instances | Where-Object { $_.instance_id -cne $instanceId })
        if ($remaining.Count -eq $registry.Instances.Count) { throw 'instance-not-found' }
        $now = Get-NowCanonicalTimestamp
        Write-RegistryFile -Path $paths.InstancesFile -Directory $paths.Root -Registry ([pscustomobject]@{ Protocol = 'gatecraft-debategui/v1'; GeneratedAt = $now; Instances = @($remaining) })

        $remainingOwners = @($owners.Owners | Where-Object { $_.instance_id -cne $instanceId })
        Write-OwnersFile -Path $paths.OwnersFile -Directory $paths.Root -Owners ([pscustomobject]@{ Protocol = 'gatecraft-debategui-owners/v1'; Owners = @($remainingOwners) })
        [Console]::Out.WriteLine("REGISTRY_UNREGISTERED code=unregistered instance_id=$instanceId")
    }
    finally { Exit-RegistryLock -Lock $lock }
}

function Invoke-SweepStale {
    param([Collections.Generic.Dictionary[string,string]] $Options)
    $thresholdText = $Options['--threshold-seconds']
    [int]$threshold = 0
    if ($thresholdText -notmatch '^[1-9][0-9]{1,5}$' -or -not [int]::TryParse($thresholdText, [ref]$threshold) -or $threshold -lt 60 -or $threshold -gt 86400) { throw 'threshold-invalid' }

    $localStateRoot = ConvertTo-LocalFullPath -DeclaredPath $Options['--local-state-root'] -InvalidCode 'local-state-root-invalid' -NonLocalCode 'local-state-root-nonlocal'
    if (-not [IO.Directory]::Exists($localStateRoot)) { throw 'local-state-root-missing' }
    $paths = Get-RegistryPaths -LocalStateRoot $localStateRoot
    if (-not [IO.Directory]::Exists($paths.Root)) { throw 'registry-root-missing' }
    $lock = Enter-RegistryLock -Root $paths.Root
    try {
        Assert-RegistryDirectoryEntries -Directory $paths.Root
        $owners = Read-OwnersFile -Path $paths.OwnersFile
        $ownedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($owner in $owners.Owners) { [void]$ownedIds.Add([string]$owner.instance_id) }

        $registry = Read-RegistryFile -Path $paths.InstancesFile
        $now = [DateTimeOffset]::UtcNow
        $markedCount = 0
        $updated = [Collections.Generic.List[object]]::new()
        foreach ($instance in $registry.Instances) {
            if (-not $ownedIds.Contains([string]$instance.instance_id) -or $instance.lifecycle -cnotin @('running')) {
                $updated.Add($instance)
                continue
            }
            $freshness = [DateTimeOffset]::ParseExact($instance.freshness, "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
            if (($now - $freshness).TotalSeconds -gt $threshold) {
                $updated.Add((New-InstanceRecord -Capabilities @($instance.capabilities) -Cursor $instance.cursor -DebateguiRange $instance.debategui_range -Endpoint $instance.endpoint -Feed $instance.feed -Freshness $instance.freshness -GatecraftVersion $instance.gatecraft_version -InstanceId $instance.instance_id -Label $instance.label -Lifecycle 'stale'))
                $markedCount++
            }
            else { $updated.Add($instance) }
        }
        $newRegistry = [pscustomobject]@{ Protocol = 'gatecraft-debategui/v1'; GeneratedAt = (Get-NowCanonicalTimestamp) ; Instances = @($updated) }
        Write-RegistryFile -Path $paths.InstancesFile -Directory $paths.Root -Registry $newRegistry
        [Console]::Out.WriteLine("REGISTRY_SWEEP_OK code=sweep-clean marked=$markedCount")
    }
    finally { Exit-RegistryLock -Lock $lock }
}

function Invoke-List {
    param([Collections.Generic.Dictionary[string,string]] $Options)
    $localStateRoot = ConvertTo-LocalFullPath -DeclaredPath $Options['--local-state-root'] -InvalidCode 'local-state-root-invalid' -NonLocalCode 'local-state-root-nonlocal'
    $paths = Get-RegistryPaths -LocalStateRoot $localStateRoot
    if (-not [IO.Directory]::Exists($paths.Root)) {
        [Console]::Out.WriteLine('REGISTRY_LIST_OK count=0')
        [Console]::Out.WriteLine('{"generated_at":null,"instances":[],"protocol":"gatecraft-debategui/v1"}')
        return
    }
    $lock = Enter-RegistryLock -Root $paths.Root
    try {
        Assert-RegistryDirectoryEntries -Directory $paths.Root
        $registry = Read-RegistryFile -Path $paths.InstancesFile
        [Console]::Out.WriteLine("REGISTRY_LIST_OK count=$($registry.Instances.Count)")
        [Console]::Out.WriteLine((ConvertTo-RegistryCanonicalJson -Registry $registry))
    }
    finally { Exit-RegistryLock -Lock $lock }
}

function Invoke-PublishEvent {
    param([Collections.Generic.Dictionary[string,string]] $Options)
    $instanceId = $Options['--instance-id']
    Assert-InstanceId $instanceId
    Assert-OwnerTokenFormat $Options['--owner-token']
    Assert-EventType $Options['--event-type']
    $occurredAt = ConvertTo-CanonicalTimestamp -Value $Options['--occurred-at']
    Assert-SanitizedEventText -Value $Options['--outcome'] -Code 'outcome-invalid' -MaximumLength 64
    $summary = Protect-GatecraftText -Text $Options['--summary'] -KnownSecret @{}
    Assert-SanitizedEventText -Value $summary -Code 'summary-invalid' -MaximumLength 512
    $eventId = if ($Options.ContainsKey('--event-id')) { $Options['--event-id'] } else { [Guid]::NewGuid().ToString('N') }
    Assert-EventId $eventId
    $cycleSequenceJson = $null
    if ($Options.ContainsKey('--cycle-sequence')) {
        if ($Options['--cycle-sequence'] -notmatch '^[1-9][0-9]{0,18}$') { throw 'cycle-sequence-invalid' }
        $cycleSequenceJson = $Options['--cycle-sequence']
    }

    $localStateRoot = ConvertTo-LocalFullPath -DeclaredPath $Options['--local-state-root'] -InvalidCode 'local-state-root-invalid' -NonLocalCode 'local-state-root-nonlocal'
    if (-not [IO.Directory]::Exists($localStateRoot)) { throw 'local-state-root-missing' }
    $paths = Get-RegistryPaths -LocalStateRoot $localStateRoot
    if (-not [IO.Directory]::Exists($paths.Root)) { throw 'registry-root-missing' }
    $lock = Enter-RegistryLock -Root $paths.Root
    try {
        Assert-RegistryDirectoryEntries -Directory $paths.Root
        $owners = Read-OwnersFile -Path $paths.OwnersFile
        Assert-OwnerTokenMatches -Owners $owners -InstanceId $instanceId -OwnerToken $Options['--owner-token']
        $registry = Read-RegistryFile -Path $paths.InstancesFile
        $index = -1
        for ($i = 0; $i -lt $registry.Instances.Count; $i++) { if ($registry.Instances[$i].instance_id -ceq $instanceId) { $index = $i; break } }
        if ($index -lt 0) { throw 'instance-not-found' }
        $current = $registry.Instances[$index]

        $feedPath = Get-FeedPath -FeedsDirectory $paths.FeedsDirectory -InstanceId $instanceId
        $last = Get-LastFeedEventId -FeedPath $feedPath
        if ($null -ne $last -and $last.EventId -ceq $eventId) {
            [Console]::Out.WriteLine("REGISTRY_EVENT_SKIPPED code=event-replayed instance_id=$instanceId cursor=$($last.Cursor)")
            return
        }

        $priorCursor = $current.cursor
        [int64]$newCursorValue = 1
        if ($null -ne $priorCursor) { $newCursorValue = [int64]::Parse($priorCursor, [Globalization.CultureInfo]::InvariantCulture) + 1 }
        $newCursor = $newCursorValue.ToString([Globalization.CultureInfo]::InvariantCulture)

        $line = New-FeedEventLine -CycleSequence $cycleSequenceJson -Cursor $newCursor -EventId $eventId -EventType $Options['--event-type'] -OccurredAt $occurredAt -Outcome $Options['--outcome'] -Summary $summary
        Add-FeedEventLine -FeedPath $feedPath -Directory $paths.FeedsDirectory -Line $line

        $updated = New-InstanceRecord -Capabilities @($current.capabilities) -Cursor $newCursor -DebateguiRange $current.debategui_range -Endpoint $current.endpoint -Feed $current.feed -Freshness (Get-NowCanonicalTimestamp) -GatecraftVersion $current.gatecraft_version -InstanceId $current.instance_id -Label $current.label -Lifecycle $current.lifecycle
        $registry.Instances[$index] = $updated
        $newRegistry = [pscustomobject]@{ Protocol = 'gatecraft-debategui/v1'; GeneratedAt = (Get-NowCanonicalTimestamp); Instances = @($registry.Instances) }
        Write-RegistryFile -Path $paths.InstancesFile -Directory $paths.Root -Registry $newRegistry

        [Console]::Out.WriteLine("REGISTRY_EVENT_PUBLISHED code=event-published instance_id=$instanceId cursor=$newCursor")
    }
    finally { Exit-RegistryLock -Lock $lock }
}

if ($PSVersionTable.PSVersion.Major -lt 7) { Stop-Registry -ExitCode 64 -Code 'powershell-version' }

try {
    $parsed = Read-RegistryArguments -Tokens @($args)
    switch ($parsed.Command) {
        'register' { Invoke-Register -Options $parsed.Values }
        'heartbeat' { Invoke-Heartbeat -Options $parsed.Values }
        'update' { Invoke-Update -Options $parsed.Values }
        'unregister' { Invoke-Unregister -Options $parsed.Values }
        'sweep-stale' { Invoke-SweepStale -Options $parsed.Values }
        'list' { Invoke-List -Options $parsed.Values }
        'publish-event' { Invoke-PublishEvent -Options $parsed.Values }
    }
    exit 0
}
catch {
    $message = [string]$_.Exception.Message
    $code = if ($message -cmatch '^(?<code>[a-z][a-z0-9.-]*)') { $Matches.code } else { 'internal-error' }
    Stop-Registry -ExitCode (Get-RegistryExitCode -Code $code) -Code $code
}
