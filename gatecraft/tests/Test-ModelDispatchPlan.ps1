[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module = Join-Path $PSScriptRoot '../scripts/ModelDispatchPlan.psm1'
Import-Module $module -Force

function Assert-Equal($Actual, $Expected, [string] $Message) { if ($Actual -ne $Expected) { throw "$Message Expected=$Expected Actual=$Actual" } }
function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function New-ValidCatalog([string] $GeneratedAt) {
    [pscustomobject][ordered]@{
        protocol='gatecraft-model-catalog/v1'; generated_at=$GeneratedAt; source='user-approved static catalog'
        models=@([pscustomobject][ordered]@{ id='alpha'; provider='openai'; roles=@('implementer','reviewer'); thinking_levels=@('low','medium','high'); cost_tier=1; quality_tier='standard'; deprecation_state='active' })
    }
}
function Write-Catalog([object] $Catalog) {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('gatecraft-dispatch-' + [guid]::NewGuid().ToString('N') + '.json')
    $Catalog | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

$now = [datetimeoffset]'2026-07-24T12:00:00Z'
$freshPath = Write-Catalog (New-ValidCatalog '2026-07-24T10:00:00Z')
$openai = Resolve-GatecraftDispatchPlan -CatalogPath $freshPath -GeneratedAtNow $now -RefreshAuthority $false -Role implementer -Thinking medium -AvailableModelIds @('alpha') -Provider openai
$anthropic = Resolve-GatecraftDispatchPlan -CatalogPath $freshPath -GeneratedAtNow $now -RefreshAuthority $false -Role implementer -Thinking medium -AvailableModelIds @('alpha') -Provider anthropic
Assert-Equal $openai.Decision 'select' 'Fresh OpenAI catalog must select.'
Assert-Equal $openai.ModelId 'alpha' 'OpenAI selection must use the selected model.'
Assert-Equal ($openai.LaunchArguments -join ' ') '--model alpha --config model_reasoning_effort="medium"' 'OpenAI adapter flags must be explicit.'
Assert-Equal ($anthropic.LaunchArguments -join ' ') '--model alpha --effort medium' 'Anthropic adapter flags must be explicit.'
Assert-Equal $openai.FreshnessState 'fresh' 'Fresh catalog must be marked fresh.'

$stalePath = Write-Catalog (New-ValidCatalog '2026-07-21T11:59:59Z')
$staleBlocked = Resolve-GatecraftDispatchPlan -CatalogPath $stalePath -GeneratedAtNow $now -RefreshAuthority $false -Role implementer -Thinking medium -AvailableModelIds @('alpha') -Provider openai
Assert-Equal $staleBlocked.Decision 'block' 'Stale catalog without authority must block.'
Assert-Equal $staleBlocked.ReasonCode 'stale-without-authority' 'Stale block must expose its reason.'
$staleAuthorized = Resolve-GatecraftDispatchPlan -CatalogPath $stalePath -GeneratedAtNow $now -RefreshAuthority $true -Role implementer -Thinking medium -AvailableModelIds @('alpha') -Provider openai
Assert-Equal $staleAuthorized.Decision 'select' 'Stale catalog with authority must proceed.'
Assert-Equal $staleAuthorized.FreshnessState 'stale-with-authority' 'Authorized stale selection must remain marked stale.'

$invalidPath = Write-Catalog ([pscustomobject]@{ malformed='yes' })
$invalid = Resolve-GatecraftDispatchPlan -CatalogPath $invalidPath -GeneratedAtNow $now -RefreshAuthority $false -Role implementer -Thinking medium -AvailableModelIds @('alpha') -Provider openai
Assert-Equal $invalid.ReasonCode 'catalog-unavailable' 'Malformed catalog must be unavailable.'
$missing = Resolve-GatecraftDispatchPlan -CatalogPath (Join-Path ([IO.Path]::GetTempPath()) ('gatecraft-dispatch-missing-' + [guid]::NewGuid().ToString('N') + '.json')) -GeneratedAtNow $now -RefreshAuthority $false -Role implementer -Thinking medium -AvailableModelIds @('alpha') -Provider openai
Assert-Equal $missing.ReasonCode 'catalog-unavailable' 'Missing catalog must be unavailable.'

$noMatch = Resolve-GatecraftDispatchPlan -CatalogPath $freshPath -GeneratedAtNow $now -RefreshAuthority $false -Role implementer -Thinking medium -AvailableModelIds @('other') -Provider openai
Assert-Equal $noMatch.Decision 'block' 'Selection block must pass through.'
Assert-Equal $noMatch.ReasonCode 'no-explicit-supported-selection' 'Selection reason must pass through unchanged.'
$unsupported = Resolve-GatecraftDispatchPlan -CatalogPath $freshPath -GeneratedAtNow $now -RefreshAuthority $false -Role implementer -Thinking medium -AvailableModelIds @('alpha') -Provider other
Assert-Equal $unsupported.ReasonCode 'unsupported-provider-adapter' 'Unknown providers must block without guessed flags.'

$driftMatch = Test-GatecraftDispatchDrift -Plan $openai -ReportedModel alpha -ReportedThinking medium
$driftMismatch = Test-GatecraftDispatchDrift -Plan $openai -ReportedModel Alpha -ReportedThinking medium
Assert-Equal $driftMatch.Decision 'accept' 'Matching launch settings must be accepted.'
Assert-Equal $driftMismatch.Decision 'block' 'Mismatched launch settings must block.'
Assert-Equal $driftMismatch.ReasonCode 'launch-setting-drift' 'Drift must expose the canonical reason.'

[IO.File]::Delete($freshPath)
[IO.File]::Delete($stalePath)
[IO.File]::Delete($invalidPath)
Write-Host 'Model dispatch plan gate passed: freshness, selection, OpenAI/Anthropic adapters, unsupported providers, and drift.'
