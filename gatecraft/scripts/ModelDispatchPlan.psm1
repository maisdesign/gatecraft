Set-StrictMode -Version Latest

$catalogModule = Join-Path $PSScriptRoot 'ModelCatalog.psm1'
$selectionModule = Join-Path $PSScriptRoot 'ModelSelection.psm1'
Import-Module $catalogModule -Force -ErrorAction Stop
Import-Module $selectionModule -Force -ErrorAction Stop

function New-GatecraftDispatchResult {
    param(
        [string] $Decision,
        [string] $ReasonCode,
        [string] $FreshnessState,
        [AllowNull()] [string] $ModelId,
        [AllowNull()] [string] $Thinking,
        [AllowEmptyCollection()] [object[]] $LaunchArguments,
        [string] $Provider
    )

    return [pscustomobject][ordered]@{
        Decision = $Decision
        ReasonCode = $ReasonCode
        FreshnessState = $FreshnessState
        ModelId = $ModelId
        Thinking = $Thinking
        LaunchArguments = @($LaunchArguments)
        Provider = $Provider
    }
}

function ConvertTo-GatecraftCatalogObject {
    param([Parameter(Mandatory)] [string] $CatalogPath)

    try {
        if (-not [IO.File]::Exists($CatalogPath)) { return $null }
        return [IO.File]::ReadAllText($CatalogPath) | ConvertFrom-Json -Depth 20 -ErrorAction Stop
    } catch {
        return $null
    }
}

function Get-GatecraftCatalogGeneratedAtUtc {
    param([Parameter(Mandatory)] [object] $Catalog)

    try {
        if ($Catalog.generated_at -is [string]) {
            $parsed = [datetimeoffset]::MinValue
            if (-not [datetimeoffset]::TryParse($Catalog.generated_at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $null }
            return $parsed.UtcDateTime
        }
        if ($Catalog.generated_at -is [datetime]) {
            return $Catalog.generated_at.ToUniversalTime()
        }
        if ($Catalog.generated_at -is [datetimeoffset]) {
            return $Catalog.generated_at.UtcDateTime
        }
    } catch { return $null }
    return $null
}

function Get-GatecraftProviderLaunchArguments {
    param(
        [Parameter(Mandatory)] [string] $Provider,
        [Parameter(Mandatory)] [string] $ModelId,
        [Parameter(Mandatory)] [string] $Thinking
    )

    if ([String]::Equals($Provider, 'openai', [StringComparison]::Ordinal)) {
        return @('--model', $ModelId, '--config', ('model_reasoning_effort="{0}"' -f $Thinking))
    }
    if ([String]::Equals($Provider, 'anthropic', [StringComparison]::Ordinal)) {
        return @('--model', $ModelId, '--effort', $Thinking)
    }
    return $null
}

function Resolve-GatecraftDispatchPlan {
    [CmdletBinding()]
    param(
        # CatalogPath is the local JSON catalog file; the module parses and validates it.
        [Parameter(Mandatory)] [string] $CatalogPath,
        [Parameter(Mandatory)] [datetimeoffset] $GeneratedAtNow,
        [Parameter(Mandatory)] [bool] $RefreshAuthority,
        [Parameter(Mandatory)][ValidateSet('implementer', 'reviewer', 'sensitive-reviewer')][string] $Role,
        [Parameter(Mandatory)][ValidateSet('low', 'medium', 'high')][string] $Thinking,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $AvailableModelIds,
        [Parameter(Mandatory)] [string] $Provider,
        [string] $OverrideModelId
    )

    $catalog = ConvertTo-GatecraftCatalogObject -CatalogPath $CatalogPath
    if ($null -eq $catalog -or -not (Test-GatecraftCatalogRecord -Catalog $catalog)) {
        return New-GatecraftDispatchResult -Decision 'block' -ReasonCode 'catalog-unavailable' -FreshnessState 'unavailable' -ModelId $null -Thinking $null -LaunchArguments @() -Provider $Provider
    }

    $generatedAtUtc = Get-GatecraftCatalogGeneratedAtUtc -Catalog $catalog
    if ($null -eq $generatedAtUtc) {
        return New-GatecraftDispatchResult -Decision 'block' -ReasonCode 'catalog-unavailable' -FreshnessState 'unavailable' -ModelId $null -Thinking $null -LaunchArguments @() -Provider $Provider
    }
    $freshnessState = if (($GeneratedAtNow.UtcDateTime - $generatedAtUtc).TotalHours -le 72) { 'fresh' } else { 'stale-with-authority' }
    if ($freshnessState -eq 'stale-with-authority' -and -not $RefreshAuthority) {
        return New-GatecraftDispatchResult -Decision 'block' -ReasonCode 'stale-without-authority' -FreshnessState 'stale-without-authority' -ModelId $null -Thinking $null -LaunchArguments @() -Provider $Provider
    }

    $selection = Resolve-GatecraftModelSelection -Models @($catalog.models) -Role $Role -Thinking $Thinking -AvailableModelIds $AvailableModelIds -OverrideModelId $OverrideModelId
    if ($selection.Decision -cne 'select') {
        return New-GatecraftDispatchResult -Decision $selection.Decision -ReasonCode $selection.ReasonCode -FreshnessState $freshnessState -ModelId $selection.ModelId -Thinking $selection.Thinking -LaunchArguments @() -Provider $Provider
    }

    $launchArguments = Get-GatecraftProviderLaunchArguments -Provider $Provider -ModelId $selection.ModelId -Thinking $selection.Thinking
    if ($null -eq $launchArguments) {
        return New-GatecraftDispatchResult -Decision 'block' -ReasonCode 'unsupported-provider-adapter' -FreshnessState $freshnessState -ModelId $selection.ModelId -Thinking $selection.Thinking -LaunchArguments @() -Provider $Provider
    }
    return New-GatecraftDispatchResult -Decision 'select' -ReasonCode $selection.ReasonCode -FreshnessState $freshnessState -ModelId $selection.ModelId -Thinking $selection.Thinking -LaunchArguments $launchArguments -Provider $Provider
}

function Test-GatecraftDispatchDrift {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Plan,
        [Parameter(Mandatory)] [string] $ReportedModel,
        [Parameter(Mandatory)] [string] $ReportedThinking
    )

    return Test-GatecraftEffectiveModelSelection -Selection $Plan -ReportedModel $ReportedModel -ReportedThinking $ReportedThinking
}

Export-ModuleMember -Function 'Resolve-GatecraftDispatchPlan', 'Test-GatecraftDispatchDrift'
