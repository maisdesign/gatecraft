[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Integration/wiring gate for the model-catalog epic (gatecraft-0w7.4). The
# existing Test-ModelCatalog.ps1/Test-ModelSelection.ps1/Test-ModelDispatchPlan.ps1
# already re-test the contract and the selection algorithm in isolation; the gap
# this closes is different: (a) a realistic multi-role session sequence exercised
# through the same real modules end to end (fake catalog, fake per-launch
# availability, no reimplemented logic), and (b) a "wiring tripwire" -- SKILL.md's
# own prose must still name the canonical module/function at Step 0.2 and Step
# 1.6/1.7, so an edit that silently drops the citation fails this gate instead of
# only a stale unit test nobody re-reads against the prose.

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$skillPath = Join-Path $repoRoot 'gatecraft/SKILL.md'
Import-Module (Join-Path $repoRoot 'gatecraft/scripts/ModelDispatchPlan.psm1') -Force

$failures = [Collections.Generic.List[string]]::new()
function Add-Failure { param([Parameter(Mandatory)][string] $Message) $script:failures.Add($Message) }
function Assert-True { param([bool] $Condition, [string] $Message) if (-not $Condition) { Add-Failure $Message } }
function Assert-Equal {
    param([AllowNull()][object] $Actual, [AllowNull()][object] $Expected, [string] $Message)
    if ($null -eq $Actual -and $null -eq $Expected) { return }
    if ($null -eq $Actual -or $null -eq $Expected -or [string]$Actual -cne [string]$Expected) {
        Add-Failure "$Message Expected '$Expected'; found '$Actual'."
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('gatecraft-model-catalog-wiring-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)

function Write-CatalogFixture {
    param([string] $GeneratedAt, [switch] $Malformed)
    $path = Join-Path $testRoot ('catalog-' + [Guid]::NewGuid().ToString('N') + '.json')
    if ($Malformed) {
        [IO.File]::WriteAllText($path, '{ "protocol": "gatecraft-model-catalog/v1", "models": [ { "id": "broken" ')
        return $path
    }
    # A realistic three-model roster: a cheap dual-role (implementer+reviewer)
    # standard-quality model, a mid-cost dual-role high-quality model, and an
    # expensive sensitive-reviewer-capable high-quality model -- distinct
    # eligible sets per role, so an implementer and a sensitive-reviewer
    # dispatch in the SAME session genuinely exercise different branches of
    # the real selection algorithm, not just two calls with the same outcome.
    $catalog = [pscustomobject][ordered]@{
        protocol = 'gatecraft-model-catalog/v1'
        generated_at = $GeneratedAt
        source = 'test fixture, not a real catalog'
        # Test-GatecraftCatalogRecord requires strictly ascending ordinal model
        # IDs -- this order (cheap-dual, costly-sensitive, mid-dual-high) is the
        # correct ordinal sort, not narrative order; alphabetize any future
        # addition/rename accordingly.
        models = @(
            [pscustomobject][ordered]@{ id = 'cheap-dual'; provider = 'anthropic'; roles = @('implementer', 'reviewer'); thinking_levels = @('low', 'medium', 'high'); cost_tier = 1; quality_tier = 'standard'; deprecation_state = 'active' }
            [pscustomobject][ordered]@{ id = 'costly-sensitive'; provider = 'openai'; roles = @('sensitive-reviewer'); thinking_levels = @('low', 'medium', 'high'); cost_tier = 3; quality_tier = 'high'; deprecation_state = 'active' }
            [pscustomobject][ordered]@{ id = 'mid-dual-high'; provider = 'anthropic'; roles = @('implementer', 'reviewer', 'sensitive-reviewer'); thinking_levels = @('low', 'medium', 'high'); cost_tier = 2; quality_tier = 'high'; deprecation_state = 'active' }
        )
    }
    ($catalog | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

$now = [datetimeoffset]'2026-07-29T12:00:00Z'
$fresh = $now.AddHours(-1).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

# --- Scenario A: fresh catalog, realistic two-role session sequence ---
$freshCatalog = Write-CatalogFixture -GeneratedAt $fresh

$implementerPlan = Resolve-GatecraftDispatchPlan -CatalogPath $freshCatalog -GeneratedAtNow $now -RefreshAuthority $false `
    -Role implementer -Thinking medium -AvailableModelIds @('cheap-dual', 'mid-dual-high', 'costly-sensitive') -Provider anthropic
Assert-Equal $implementerPlan.Decision 'select' 'Implementer dispatch on a fresh catalog must select.'
Assert-Equal $implementerPlan.ModelId 'cheap-dual' 'Implementer must select the cheapest eligible model for its role.'
Assert-Equal $implementerPlan.FreshnessState 'fresh' 'A same-session catalog must be marked fresh.'

$sensitiveReviewerPlan = Resolve-GatecraftDispatchPlan -CatalogPath $freshCatalog -GeneratedAtNow $now -RefreshAuthority $false `
    -Role sensitive-reviewer -Thinking medium -AvailableModelIds @('cheap-dual', 'mid-dual-high', 'costly-sensitive') -Provider anthropic
Assert-Equal $sensitiveReviewerPlan.Decision 'select' 'Sensitive-reviewer dispatch on a fresh catalog must select.'
Assert-Equal $sensitiveReviewerPlan.ModelId 'mid-dual-high' "Sensitive-reviewer must reject the standard-quality 'cheap-dual' model despite its lower cost, and select the cheapest HIGH-quality eligible model instead."
Assert-True ($implementerPlan.ModelId -cne $sensitiveReviewerPlan.ModelId) 'Different roles with different quality requirements must resolve to genuinely different models on this fixture, proving Role is actually threaded through the real pipeline, not ignored.'

# --- Step 1.7 equivalent: the launched session reports its real effective settings ---
$implementerDriftOk = Test-GatecraftDispatchDrift -Plan $implementerPlan -ReportedModel $implementerPlan.ModelId -ReportedThinking $implementerPlan.Thinking
Assert-Equal $implementerDriftOk.Decision 'accept' 'A launched session reporting exactly the planned model/thinking must be accepted.'

$implementerDriftMismatch = Test-GatecraftDispatchDrift -Plan $implementerPlan -ReportedModel 'some-other-model' -ReportedThinking $implementerPlan.Thinking
Assert-Equal $implementerDriftMismatch.Decision 'block' 'A launched session reporting a different model than planned must block.'
Assert-Equal $implementerDriftMismatch.ReasonCode 'launch-setting-drift' 'Drift must expose the canonical launch-setting-drift reason.'

# --- Scenario B: stale catalog fail-closed / authorized-stale path ---
$staleGeneratedAt = $now.AddHours(-100).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
$staleCatalog = Write-CatalogFixture -GeneratedAt $staleGeneratedAt
$staleBlocked = Resolve-GatecraftDispatchPlan -CatalogPath $staleCatalog -GeneratedAtNow $now -RefreshAuthority $false `
    -Role implementer -Thinking medium -AvailableModelIds @('cheap-dual') -Provider anthropic
Assert-Equal $staleBlocked.Decision 'block' 'A stale catalog without refresh authority must block the dispatch outright.'
Assert-Equal $staleBlocked.ReasonCode 'stale-without-authority' 'Stale-without-authority must report its exact reason code.'

$staleAuthorized = Resolve-GatecraftDispatchPlan -CatalogPath $staleCatalog -GeneratedAtNow $now -RefreshAuthority $true `
    -Role implementer -Thinking medium -AvailableModelIds @('cheap-dual') -Provider anthropic
Assert-Equal $staleAuthorized.Decision 'select' 'An explicitly authorized stale catalog must still allow the dispatch to proceed.'
Assert-Equal $staleAuthorized.FreshnessState 'stale-with-authority' 'An authorized stale selection must remain visibly marked stale, not silently reported as fresh.'

# --- Scenario C: malformed catalog fail-closed ---
$malformedCatalog = Write-CatalogFixture -Malformed
$malformedResult = Resolve-GatecraftDispatchPlan -CatalogPath $malformedCatalog -GeneratedAtNow $now -RefreshAuthority $false `
    -Role implementer -Thinking medium -AvailableModelIds @('cheap-dual') -Provider anthropic
Assert-Equal $malformedResult.Decision 'block' 'A malformed catalog file must block the dispatch.'
Assert-Equal $malformedResult.ReasonCode 'catalog-unavailable' 'A malformed catalog must report catalog-unavailable, the same as a missing one -- callers must not need to distinguish the two to fail closed correctly.'

# --- Scenario D: missing catalog file fail-closed ---
$missingCatalogPath = Join-Path $testRoot ('missing-' + [Guid]::NewGuid().ToString('N') + '.json')
$missingResult = Resolve-GatecraftDispatchPlan -CatalogPath $missingCatalogPath -GeneratedAtNow $now -RefreshAuthority $false `
    -Role implementer -Thinking medium -AvailableModelIds @('cheap-dual') -Provider anthropic
Assert-Equal $missingResult.Decision 'block' 'A missing catalog file must block the dispatch.'
Assert-Equal $missingResult.ReasonCode 'catalog-unavailable' 'A missing catalog must report catalog-unavailable.'

# --- Wiring tripwire: SKILL.md's own prose must still cite the canonical module/function names at 0.2 and 1.6/1.7 ---
# This is what makes a future edit that silently drops the citation fail THIS
# gate, rather than leaving only a unit test that re-tests the module in
# isolation and never notices the prose stopped naming it.
if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
    Add-Failure "SKILL.md not found at $skillPath -- cannot check the wiring tripwire at all."
}
else {
    $skillText = Get-Content -LiteralPath $skillPath -Raw
    $tripwireAnchors = [ordered]@{
        'Step 0.2 must cite Test-GatecraftCatalogRecord' = 'Test-GatecraftCatalogRecord'
        'Step 0.2 must cite ModelCatalog.psm1' = 'ModelCatalog.psm1'
        'Step 0.2 must cite the model-catalog-v1/catalog.json locate convention' = 'model-catalog-v1/catalog.json'
        'Step 1.6 must cite Resolve-GatecraftDispatchPlan' = 'Resolve-GatecraftDispatchPlan'
        'Step 1.6 must cite ModelDispatchPlan.psm1' = 'ModelDispatchPlan.psm1'
        'Step 1.7 must cite Test-GatecraftDispatchDrift' = 'Test-GatecraftDispatchDrift'
    }
    foreach ($label in $tripwireAnchors.Keys) {
        $anchor = $tripwireAnchors[$label]
        if (-not $skillText.Contains($anchor, [StringComparison]::Ordinal)) {
            Add-Failure "WIRING TRIPWIRE TRIPPED: $label -- '$anchor' no longer appears anywhere in SKILL.md. The prose has silently disconnected from the real module/function; restore the citation or update this tripwire deliberately if the API genuinely changed."
        }
    }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { [Console]::Error.WriteLine("ASSERTION FAILED: $failure") }
    exit 1
}

[Console]::Out.WriteLine('Model-catalog wiring gate passed: fresh/stale-blocked/stale-authorized/malformed/missing catalog fail-closed behavior, a real two-role (implementer vs sensitive-reviewer) selection divergence, drift accept/block, and the SKILL.md 0.2/1.6/1.7 wiring tripwire are all green.')
