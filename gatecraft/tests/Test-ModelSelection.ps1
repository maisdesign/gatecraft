[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$module = Join-Path $PSScriptRoot '../scripts/ModelSelection.psm1'
Import-Module $module -Force
function Assert-Equal($Actual, $Expected, $Message) { if ($Actual -ne $Expected) { throw "$Message Expected=$Expected Actual=$Actual" } }
$models = @(
    [pscustomobject]@{ id='economy'; roles=@('implementer','reviewer','sensitive-reviewer'); thinking_levels=@('low','medium','high'); cost_tier=1; quality_tier='standard'; deprecation_state='active' },
    [pscustomobject]@{ id='expert'; roles=@('implementer','reviewer','sensitive-reviewer'); thinking_levels=@('medium','high'); cost_tier=3; quality_tier='high'; deprecation_state='active' },
    [pscustomobject]@{ id='retired'; roles=@('implementer'); thinking_levels=@('high'); cost_tier=0; quality_tier='high'; deprecation_state='deprecated' }
)
$implementer = Resolve-GatecraftModelSelection -Models $models -Role implementer -Thinking medium -AvailableModelIds @('economy','expert')
Assert-Equal $implementer.ModelId 'economy' 'Role policy must choose the lowest cost eligible model.'
Assert-Equal ($implementer.LaunchArguments -join ' ') '--model economy --config model_reasoning_effort="medium"' 'Launch must carry explicit model and thinking arguments.'
Assert-Equal (Test-GatecraftEffectiveModelSelection -Selection $implementer -ReportedModel economy -ReportedThinking medium).Decision 'accept' 'Reported effective settings must match selection.'
Assert-Equal (Test-GatecraftEffectiveModelSelection -Selection $implementer -ReportedModel expert -ReportedThinking medium).ReasonCode 'launch-setting-drift' 'Model drift must carry an explicit reason code.'
Assert-Equal (Test-GatecraftEffectiveModelSelection -Selection $implementer -ReportedModel Economy -ReportedThinking medium).ReasonCode 'launch-setting-drift' 'Model identity must be ordinal and case-sensitive.'
Assert-Equal (Test-GatecraftEffectiveModelSelection -Selection ([pscustomobject]@{ Decision='select' }) -ReportedModel economy -ReportedThinking medium).Decision 'block' 'Malformed selection evidence must fail closed.'
Assert-Equal (Test-GatecraftEffectiveModelSelection -Selection ([pscustomobject]@{ Decision='select'; ModelId=7; Thinking='medium' }) -ReportedModel 7 -ReportedThinking medium).Decision 'block' 'Non-string selection evidence must fail closed.'
Assert-Equal (Resolve-GatecraftModelSelection -Models $models -Role sensitive-reviewer -Thinking high -AvailableModelIds @('economy','expert')).ModelId 'expert' 'Sensitive review must require high quality.'
Assert-Equal (Resolve-GatecraftModelSelection -Models $models -Role implementer -Thinking low -AvailableModelIds @('expert')).Decision 'block' 'Unsupported thinking must fail closed.'
Assert-Equal (Resolve-GatecraftModelSelection -Models $models -Role reviewer -Thinking medium -AvailableModelIds @()).Decision 'block' 'Missing per-launch availability must fail closed.'
Assert-Equal (Resolve-GatecraftModelSelection -Models @($models[0]) -Role implementer -Thinking medium -AvailableModelIds @('expert')).Decision 'block' 'An active catalog model absent from availability must fail closed.'
Assert-Equal (Resolve-GatecraftModelSelection -Models $models -Role implementer -Thinking medium -AvailableModelIds @('economy','expert') -OverrideModelId expert).ModelId 'expert' 'A supported explicit override must be preserved.'
Assert-Equal (Resolve-GatecraftModelSelection -Models $models -Role reviewer -Thinking high -AvailableModelIds @('retired') -OverrideModelId retired).Decision 'block' 'Unsupported override must fail closed.'
Assert-Equal (Resolve-GatecraftModelSelection -Models $models -Role implementer -Thinking high -AvailableModelIds @('retired')).Decision 'block' 'Deprecated models must not be selected.'
Assert-Equal (Resolve-GatecraftModelSelection -Models @([pscustomobject]@{ id='incomplete'; roles=@('implementer'); thinking_levels=@('high'); cost_tier=1; quality_tier='standard' }) -Role implementer -Thinking high -AvailableModelIds @('incomplete')).Decision 'block' 'Incomplete catalog records must fail closed without a StrictMode error.'
Assert-Equal (Resolve-GatecraftModelSelection -Models @([pscustomobject]@{ id='ambiguous'; roles=@('implementer'); thinking_levels=@('high'); cost_tier=1; quality_tier='standard'; deprecation_state=@('active','deprecated') }) -Role implementer -Thinking high -AvailableModelIds @('ambiguous')).Decision 'block' 'Non-scalar deprecation state must fail closed.'
Assert-Equal (Resolve-GatecraftModelSelection -Models @([pscustomobject]@{ id='bad-cost'; roles=@('implementer'); thinking_levels=@('high'); cost_tier='free'; quality_tier='standard'; deprecation_state='active' }) -Role implementer -Thinking high -AvailableModelIds @('bad-cost')).Decision 'block' 'Malformed cost tier must fail closed.'
Write-Host 'Model selection gate passed: role policy, sensitive quality, unsupported override, and deprecation fail closed.'
