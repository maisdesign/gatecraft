Set-StrictMode -Version Latest

function Resolve-GatecraftModelSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]] $Models,
        [Parameter(Mandatory)][ValidateSet('implementer', 'reviewer', 'sensitive-reviewer')][string] $Role,
        [Parameter(Mandatory)][ValidateSet('low', 'medium', 'high')][string] $Thinking,
        [Parameter(Mandatory)][string[]] $AvailableModelIds,
        [string] $OverrideModelId
    )

    $requiredQuality = if ($Role -eq 'sensitive-reviewer') { 'high' } else { 'standard' }
    $eligible = @($Models | Where-Object {
        $properties = $_.PSObject.Properties
        if (-not ($properties['id'] -and $properties['roles'] -and $properties['thinking_levels'] -and $properties['cost_tier'] -and $properties['quality_tier'] -and $properties['deprecation_state'])) { return $false }
        $modelId = $properties['id'].Value
        $qualityTier = $properties['quality_tier'].Value
        $deprecationState = $properties['deprecation_state'].Value
        if ($modelId -isnot [string] -or $qualityTier -isnot [string] -or $deprecationState -isnot [string]) { return $false }
        @($AvailableModelIds | Where-Object { [String]::Equals($_, $modelId, [StringComparison]::Ordinal) }).Count -gt 0 -and
        $_.roles -ccontains $Role -and
        $_.thinking_levels -ccontains $Thinking -and
        $deprecationState -ceq 'active' -and
        ($requiredQuality -ceq 'standard' -or $qualityTier -ceq 'high')
    })
    if ($OverrideModelId) {
        $eligible = @($eligible | Where-Object { $_.id -ceq $OverrideModelId })
    }
    if ($eligible.Count -eq 0) {
        return [pscustomobject][ordered]@{ Decision = 'block'; ReasonCode = 'no-explicit-supported-selection'; ModelId = $null; Thinking = $null }
    }
    $minimumCost = @($eligible | Measure-Object -Property cost_tier -Minimum).Minimum
    $costEligible = @($eligible | Where-Object { $_.cost_tier -eq $minimumCost })
    $bestQuality = if (@($costEligible | Where-Object { $_.quality_tier -ceq 'high' }).Count -gt 0) { 'high' } else { 'standard' }
    $ids = [Collections.Generic.List[string]]::new()
    foreach ($candidate in @($costEligible | Where-Object { $_.quality_tier -ceq $bestQuality })) { $ids.Add($candidate.id) }
    $ids.Sort([StringComparer]::Ordinal)
    $selected = @($costEligible | Where-Object { $_.id -ceq $ids[0] })[0]
    return [pscustomobject][ordered]@{ Decision = 'select'; ReasonCode = if ($OverrideModelId) { 'explicit-override' } else { 'role-policy' }; ModelId = $selected.id; Thinking = $Thinking; LaunchArguments = @('--model', $selected.id, '--config', "model_reasoning_effort=`"$Thinking`"") }
}

function Test-GatecraftEffectiveModelSelection {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Selection, [Parameter(Mandatory)][string] $ReportedModel, [Parameter(Mandatory)][string] $ReportedThinking)
    if ($null -eq $Selection) { return [pscustomobject]@{ Decision = 'block'; ReasonCode = 'selection-unavailable' } }
    $properties = $Selection.PSObject.Properties
    if (-not ($properties['Decision'] -and $properties['ModelId'] -and $properties['Thinking'])) { return [pscustomobject]@{ Decision = 'block'; ReasonCode = 'selection-unavailable' } }
    if ($Selection.Decision -cne 'select') { return [pscustomobject]@{ Decision = 'block'; ReasonCode = 'selection-unavailable' } }
    if (-not [String]::Equals($ReportedModel, $Selection.ModelId, [StringComparison]::Ordinal) -or -not [String]::Equals($ReportedThinking, $Selection.Thinking, [StringComparison]::Ordinal)) { return [pscustomobject]@{ Decision = 'block'; ReasonCode = 'launch-setting-drift' } }
    return [pscustomobject]@{ Decision = 'accept'; ReasonCode = 'effective-settings-match' }
}

Export-ModuleMember -Function 'Resolve-GatecraftModelSelection', 'Test-GatecraftEffectiveModelSelection'
