Set-StrictMode -Version Latest

function Get-GatecraftPropertyNames([object] $Object) {
    if ($null -eq $Object) { return @() }
    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Test-GatecraftCatalogSanitizedValue([object] $Value, [string] $Path) {
    # Sanitization is deliberately conservative: credential-like key names are
    # rejected anywhere, and strings resembling bearer/API keys or raw provider
    # payloads are rejected. This prevents secrets, prompts, PIDs, and probes
    # from becoming part of the persisted catalog even when nested unexpectedly.
    if ($Value -is [string]) {
        if ($Value -match '(?i)(bearer\s+[A-Za-z0-9._~-]{12,}|(?:sk|rk|gh[pousr])[-_][A-Za-z0-9_-]{12,}|api[_-]?key\s*[:=])') {
            return $false
        }
        return $true
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ([string]$key -match '(?i)(token|api[_-]?key|secret|credential|password|\bpid\b|prompt|raw[_-]?(provider[_-]?)?response)') { return $false }
            if (-not (Test-GatecraftCatalogSanitizedValue $Value[$key] "$Path.$key")) { return $false }
        }
        return $true
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -match '(?i)(token|api[_-]?key|secret|credential|password|\bpid\b|prompt|raw[_-]?(provider[_-]?)?response)') { return $false }
            if (-not (Test-GatecraftCatalogSanitizedValue $property.Value "$Path.$($property.Name)")) { return $false }
        }
        return $true
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) { if (-not (Test-GatecraftCatalogSanitizedValue $item "$Path[]")) { return $false } }
    }
    return $true
}

function Test-GatecraftCatalogRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowNull()] [object] $Catalog)

    try {
        if ($null -eq $Catalog -or $Catalog -isnot [pscustomobject]) { return $false }
        if (-not (Test-GatecraftCatalogSanitizedValue $Catalog '$')) { return $false }

        $topExpected = @('protocol', 'generated_at', 'source', 'models')
        $topNames = @(Get-GatecraftPropertyNames $Catalog)
        if ($topNames.Count -ne 4 -or @($topNames | Where-Object { $_ -notin $topExpected }).Count -gt 0 -or @($topExpected | Where-Object { $_ -notin $topNames }).Count -gt 0) { return $false }
        if ($Catalog.protocol -isnot [string] -or $Catalog.protocol -cne 'gatecraft-model-catalog/v1') { return $false }
        if ($Catalog.source -isnot [string] -or [string]::IsNullOrWhiteSpace($Catalog.source)) { return $false }
        if ($Catalog.generated_at -is [string]) {
            if ($Catalog.generated_at -notmatch '^(?:\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z|\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?[+-]\d{2}:\d{2})$') { return $false }
            $parsed = [datetimeoffset]::MinValue
            if (-not [datetimeoffset]::TryParse($Catalog.generated_at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $false }
        } elseif ($Catalog.generated_at -is [datetime]) {
            if ($Catalog.generated_at.Kind -ne [DateTimeKind]::Utc) { return $false }
        } elseif ($Catalog.generated_at -is [datetimeoffset]) {
            # DateTimeOffset carries an explicit offset and is therefore unambiguous.
            $parsed = $Catalog.generated_at
        } else { return $false }
        if ($Catalog.models -is [string] -or $Catalog.models -isnot [System.Collections.IEnumerable]) { return $false }

        $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $previousId = $null
        foreach ($model in @($Catalog.models)) {
            if ($null -eq $model -or $model -isnot [pscustomobject]) { return $false }
            $expected = @('id','provider','roles','thinking_levels','cost_tier','quality_tier','deprecation_state')
            $names = @(Get-GatecraftPropertyNames $model)
            if ($names.Count -ne 7 -or @($names | Where-Object { $_ -notin $expected }).Count -gt 0 -or @($expected | Where-Object { $_ -notin $names }).Count -gt 0) { return $false }
            if ($model.id -isnot [string] -or [string]::IsNullOrWhiteSpace($model.id) -or -not $ids.Add($model.id)) { return $false }
            if ($null -ne $previousId -and [StringComparer]::Ordinal.Compare($previousId, $model.id) -ge 0) { return $false }
            $previousId = $model.id
            if ($model.provider -isnot [string] -or [string]::IsNullOrWhiteSpace($model.provider)) { return $false }
            if ($model.roles -is [string] -or $model.roles -isnot [System.Collections.IEnumerable] -or @($model.roles).Count -eq 0 -or @($model.roles | Where-Object { $_ -isnot [string] -or $_ -notin @('implementer','reviewer','sensitive-reviewer') }).Count -gt 0) { return $false }
            if ($model.thinking_levels -is [string] -or $model.thinking_levels -isnot [System.Collections.IEnumerable] -or @($model.thinking_levels).Count -eq 0 -or @($model.thinking_levels | Where-Object { $_ -isnot [string] -or $_ -notin @('low','medium','high') }).Count -gt 0) { return $false }
            if ($model.cost_tier -isnot [int] -and $model.cost_tier -isnot [long] -and $model.cost_tier -isnot [decimal]) { return $false }
            if ([decimal]$model.cost_tier -lt 0) { return $false }
            if ($model.quality_tier -isnot [string] -or $model.quality_tier -notin @('standard','high')) { return $false }
            if ($model.deprecation_state -isnot [string] -or $model.deprecation_state -notin @('active','deprecated')) { return $false }
        }
        return $true
    } catch { return $false }
}

function Write-GatecraftCatalogAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Catalog,
        [Parameter(Mandatory)] [string] $Path
    )
    if (-not (Test-GatecraftCatalogRecord $Catalog)) { throw 'Catalog is invalid and was not written.' }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    if (-not [IO.Directory]::Exists($directory)) { throw "Catalog directory does not exist: $directory" }
    $tempPath = Join-Path $directory ('.catalog-{0}-{1}.tmp' -f [guid]::NewGuid().ToString('N'), [IO.Path]::GetFileName($fullPath))
    try {
        $json = $Catalog | ConvertTo-Json -Depth 10
        [IO.File]::WriteAllText($tempPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($tempPath, $fullPath, $true)
    } finally {
        if ([IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
    }
    return $fullPath
}

Export-ModuleMember -Function 'Test-GatecraftCatalogRecord', 'Write-GatecraftCatalogAtomic'
