[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module = Join-Path $PSScriptRoot '../scripts/ModelCatalog.psm1'
Import-Module $module -Force

function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Equal($Actual, $Expected, [string] $Message) { if ($Actual -ne $Expected) { throw "$Message Expected=$Expected Actual=$Actual" } }
function New-ValidCatalog {
    [pscustomobject][ordered]@{
        protocol='gatecraft-model-catalog/v1'; generated_at='2026-07-24T10:00:00Z'; source='user-approved static catalog'
        models=@([pscustomobject][ordered]@{ id='alpha'; provider='openai'; roles=@('implementer','reviewer'); thinking_levels=@('low','medium','high'); cost_tier=1; quality_tier='standard'; deprecation_state='active' })
    }
}

$valid = New-ValidCatalog
Assert-True (Test-GatecraftCatalogRecord $valid) 'A complete catalog must be accepted.'
$unknownTop = $valid | ConvertTo-Json -Depth 10 | ConvertFrom-Json
Add-Member -InputObject $unknownTop -NotePropertyName extra -NotePropertyValue 'reject-me'
Assert-True (-not (Test-GatecraftCatalogRecord $unknownTop)) 'Unknown top-level fields must be rejected.'
$unknownModel = New-ValidCatalog
Add-Member -InputObject $unknownModel.models[0] -NotePropertyName extra -NotePropertyValue 'reject-me'
Assert-True (-not (Test-GatecraftCatalogRecord $unknownModel)) 'Unknown model fields must be rejected.'
$duplicate = New-ValidCatalog
$duplicate.models = @($duplicate.models[0], $duplicate.models[0] | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
Assert-True (-not (Test-GatecraftCatalogRecord $duplicate)) 'Duplicate model IDs must be rejected.'
$unsupportedThinking = New-ValidCatalog
$unsupportedThinking.models[0].thinking_levels = @('low','extreme')
Assert-True (-not (Test-GatecraftCatalogRecord $unsupportedThinking)) 'Unsupported thinking levels must be rejected.'
$missingSource = New-ValidCatalog
$missingSource.source = ' '
Assert-True (-not (Test-GatecraftCatalogRecord $missingSource)) 'Missing or empty source must be rejected.'
$nonUtc = New-ValidCatalog
$nonUtc.generated_at = '2026-07-24T10:00:00'
Assert-True (-not (Test-GatecraftCatalogRecord $nonUtc)) 'Timestamps without an explicit UTC designator must be rejected.'
$credential = New-ValidCatalog
$credential.models[0].provider = 'Bearer definitely-not-a-real-token'
Assert-True (-not (Test-GatecraftCatalogRecord $credential)) 'Credential-like fields must be rejected.'
$rawResponse = New-ValidCatalog
Add-Member -InputObject $rawResponse.models[0] -NotePropertyName raw_response -NotePropertyValue 'provider payload'
Assert-True (-not (Test-GatecraftCatalogRecord $rawResponse)) 'Raw provider response fields must be rejected.'

$tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ('gatecraft-catalog-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempDirectory) | Out-Null
$target = Join-Path $tempDirectory 'catalog.json'
$old = New-ValidCatalog
$new = New-ValidCatalog
$new.generated_at = '2026-07-24T11:00:00Z'
Write-GatecraftCatalogAtomic -Catalog $old -Path $target | Out-Null
$oldText = [IO.File]::ReadAllText($target)
for ($i = 0; $i -lt 25; $i++) {
    Write-GatecraftCatalogAtomic -Catalog $new -Path $target | Out-Null
    $observed = [IO.File]::ReadAllText($target)
    Assert-True ($observed -eq $oldText -or $observed -eq ($new | ConvertTo-Json -Depth 10) + [Environment]::NewLine) 'Atomic writes must expose only complete old or complete new content.'
}
Assert-Equal ([IO.File]::ReadAllText($target).Length -gt 0) $true 'Atomic write must leave a non-empty target.'
[IO.Directory]::Delete($tempDirectory, $true)
Write-Host 'Model catalog validation gate passed: closed schema, sanitization, UTC, duplicates, thinking levels, and atomic writes.'
