[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failures = [Collections.Generic.List[string]]::new()
$observations = [Collections.Generic.List[string]]::new()

function Add-Failure {
    param([Parameter(Mandatory)][string] $Message)
    $script:failures.Add($Message)
}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )
    if (-not $Condition) {
        Add-Failure $Message
    }
}

function Assert-Equal {
    param(
        [AllowNull()][object] $Actual,
        [AllowNull()][object] $Expected,
        [Parameter(Mandatory)][string] $Message
    )
    if ($null -eq $Expected) {
        if ($null -ne $Actual) {
            Add-Failure "$Message Expected null; found '$Actual'."
        }
        return
    }
    if ($null -eq $Actual -or $Actual -cne $Expected) {
        Add-Failure "$Message Expected '$Expected'; found '$Actual'."
    }
}

function Assert-Reason {
    param(
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)][string] $Reason,
        [Parameter(Mandatory)][string] $Message
    )
    if ($Reason -cnotin @($Result.Reasons)) {
        Add-Failure "$Message Missing reason '$Reason'; found: $(@($Result.Reasons) -join ', ')."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][string] $Message
    )
    $threw = $false
    try {
        & $Action
    }
    catch {
        $threw = $true
    }
    if (-not $threw) {
        Add-Failure $Message
    }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$modulePath = Join-Path $repoRoot 'gatecraft/scripts/Gatecraft.Protocol.psm1'
Import-Module $modulePath -Force -ErrorAction Stop

$artifact = 'A' * 64
$baselineArtifact = 'B' * 64
$otherArtifact = 'C' * 64
$commit = 'c' * 40
$main = 'd' * 40
$timestamp = '2026-07-15T10:00:00Z'

function New-ReviewPass {
    param(
        [string] $Id = 'review-pass-1',
        [string] $Reviewer = 'reviewer-original',
        [string] $Artifact = $script:artifact,
        [string] $Reference = ''
    )
    $suffix = if ([string]::IsNullOrEmpty($Reference)) { '' } else { " review_ref=$Reference" }
    return "REVIEW_PASS protocol=verification/v2 receipt_id=$Id reviewer=$Reviewer reviewed_at=$script:timestamp source_id=source-1 review_id=review-1 artifact_sha=$Artifact$suffix"
}

function New-ReviewBlock {
    param(
        [string] $Id = 'review-block-1',
        [string] $Reviewer = 'reviewer-original',
        [string] $Artifact = $script:artifact
    )
    return "REVIEW_BLOCK protocol=verification/v2 receipt_id=$Id reviewer=$Reviewer reviewed_at=$script:timestamp source_id=source-1 review_id=review-1 artifact_sha=$Artifact"
}

function New-ReviewClarify {
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $Reference,
        [string] $Reviewer = 'reviewer-original',
        [string] $Artifact = $script:artifact
    )
    return "REVIEW_CLARIFY protocol=verification/v2 receipt_id=$Id reviewer=$Reviewer reviewed_at=$script:timestamp source_id=source-1 review_id=review-1 artifact_sha=$Artifact review_ref=$Reference"
}

function New-ValidChain {
    param(
        [string[]] $ReviewLines = @((New-ReviewPass)),
        [string] $ReviewReference = 'review-pass-1',
        [string] $GateText = 'pwsh -NoProfile -File gate.ps1',
        [string] $BaselineExit = '64',
        [string] $RequiredEvidence = 'baseline-expected-gap,color,dimensions',
        [AllowEmptyString()][string] $ObservedEvidence = ''
    )

    $evidence = if ([string]::IsNullOrEmpty($ObservedEvidence)) { $RequiredEvidence } else { $ObservedEvidence }
    @(
        "VERIFY_PHASE protocol=verification/v2 receipt_id=baseline-1 phase=baseline verified_by=verifier-1 verified_at=$script:timestamp artifact_sha=$script:baselineArtifact gate=`"$GateText`" exit=$BaselineExit result=observed required=`"$RequiredEvidence`" evidence=`"$evidence`""
        "VERIFY_PHASE protocol=verification/v2 receipt_id=integration-1 phase=integration/premerge verified_by=verifier-1 verified_at=$script:timestamp artifact_sha=$script:artifact baseline_ref=baseline-1 gate=`"$GateText`" exit=0 result=pass required=`"$RequiredEvidence`" evidence=`"$evidence`""
        $ReviewLines
        "VERIFIED protocol=verification/v2 receipt_id=postmerge-1 phase=postmerge verified_by=verifier-1 verified_at=$script:timestamp commit=$script:commit main=$script:main artifact_sha=$script:artifact baseline_ref=baseline-1 integration_ref=integration-1 review_ref=$ReviewReference gate=`"$GateText`" exit=0 result=pass required=`"$RequiredEvidence`" evidence=`"$evidence`""
    )
}

function Copy-Chain {
    param([Parameter(Mandatory)][string[]] $Chain)
    return @($Chain | ForEach-Object { [string] $_ })
}

$validChain = New-ValidChain
$validResult = Test-GatecraftVerificationChain -Receipt $validChain
Assert-True $validResult.IsValid 'A complete direct-review verification/v2 chain must pass.'
Assert-Equal $validResult.Decision 'pass' 'Valid chain decision.'
$parsedBaseline = ConvertFrom-GatecraftReceiptLine -Line $validChain[0]
Assert-True $parsedBaseline.IsValid 'The exported parser must accept the valid baseline fixture.'
Assert-Equal $parsedBaseline.Fields.exit '64' 'The baseline receipt must retain the actual red exit code.'
Assert-Equal $parsedBaseline.Fields.result 'observed' 'The baseline receipt must be an observation rather than a pass claim.'
foreach ($receiptLine in @($validChain[0], $validChain[1], $validChain[-1])) {
    $parsedEvidenceReceipt = ConvertFrom-GatecraftReceiptLine -Line $receiptLine
    Assert-Equal $parsedEvidenceReceipt.Fields.required 'baseline-expected-gap,color,dimensions' 'A red chain must preserve the unchanged expected-gap requirement set.'
    Assert-Equal $parsedEvidenceReceipt.Fields.evidence 'baseline-expected-gap,color,dimensions' 'A red chain must preserve the unchanged expected-gap evidence set.'
}
$greenBaselineChain = New-ValidChain -BaselineExit '00' -RequiredEvidence 'color,dimensions'
$greenBaselineResult = Test-GatecraftVerificationChain -Receipt $greenBaselineChain
Assert-True $greenBaselineResult.IsValid 'A zero baseline token with no expected-gap marker must pass after green later phases.'
Assert-Equal (ConvertFrom-GatecraftReceiptLine -Line $greenBaselineChain[0]).Fields.exit '00' 'The zero baseline fixture must preserve its leading-zero token.'
$leadingZeroRedChain = New-ValidChain -BaselineExit '00064'
Assert-True (Test-GatecraftVerificationChain -Receipt $leadingZeroRedChain).IsValid 'A leading-zero nonzero baseline with the expected-gap marker must pass after green later phases.'
$badEscape = ConvertFrom-GatecraftReceiptLine -Line ($validChain[0] -replace 'gate="[^"]+"', 'gate="bad\qescape"')
Assert-True (-not $badEscape.IsValid) 'The exported parser must reject an unsupported quoted escape.'
Assert-Reason -Result ([pscustomobject]@{ Reasons = @($badEscape.Errors.Code) }) -Reason 'receipt.escape-malformed' -Message 'Malformed escaping parser reason.'
$observations.Add("direct-pass receipts=$($validResult.Receipts.Count) decision=$($validResult.Decision)")

$block = New-ReviewBlock
$clarify = New-ReviewClarify -Id 'review-clarify-1' -Reference 'review-block-1'
$clarifiedPass = New-ReviewPass -Id 'review-pass-2' -Reference 'review-clarify-1'
$clarifiedChain = New-ValidChain -ReviewLines @($block, $clarify, $clarifiedPass) -ReviewReference 'review-pass-2'
$admissibleReviewFixtures = @(
    [pscustomobject]@{ Name = 'valid single same-reviewer clarification'; Chain = $clarifiedChain; Receipts = 6 }
)
foreach ($fixture in $admissibleReviewFixtures) {
    $result = Test-GatecraftVerificationChain -Receipt @($fixture.Chain)
    Assert-True $result.IsValid "$($fixture.Name) must be admissible."
    Assert-Equal $result.Decision 'pass' "$($fixture.Name) decision."
    Assert-Equal $result.Receipts.Count $fixture.Receipts "$($fixture.Name) receipt count."
}
$observations.Add("clarified-pass fixtures=$($admissibleReviewFixtures.Count) decision=pass")

$missingBaseline = @($validChain | Select-Object -Skip 1)

$malformedPass = Copy-Chain $validChain
$malformedPass[2] = $malformedPass[2] -replace " artifact_sha=$artifact", ''

$unresolvedBlock = New-ValidChain -ReviewLines @((New-ReviewBlock)) -ReviewReference 'review-block-1'

$malformedBlock = New-ValidChain -ReviewLines @(
    "REVIEW_BLOCK protocol=verification/v2 receipt_id=malformed-block reviewer=`"$artifact"
) -ReviewReference 'malformed-block'

$inconclusive = New-ValidChain -ReviewLines @(
    "REVIEW_INCONCLUSIVE protocol=verification/v2 receipt_id=review-inc-1 reviewer=reviewer-original reviewed_at=$timestamp source_id=source-1 review_id=review-1 artifact_sha=$artifact"
) -ReviewReference 'review-inc-1'

$secondClarification = New-ValidChain -ReviewLines @(
    (New-ReviewBlock),
    (New-ReviewClarify -Id 'review-clarify-1' -Reference 'review-block-1'),
    (New-ReviewClarify -Id 'review-clarify-2' -Reference 'review-clarify-1'),
    (New-ReviewPass -Id 'review-pass-2' -Reference 'review-clarify-2')
) -ReviewReference 'review-pass-2'

$reviewerSwap = New-ValidChain -ReviewLines @(
    (New-ReviewBlock),
    (New-ReviewClarify -Id 'review-clarify-1' -Reference 'review-block-1' -Reviewer 'reviewer-swapped'),
    (New-ReviewPass -Id 'review-pass-2' -Reference 'review-clarify-1')
) -ReviewReference 'review-pass-2'

$artifactMismatch = New-ValidChain -ReviewLines @(
    (New-ReviewPass -Artifact $otherArtifact)
)

$duplicateField = Copy-Chain $validChain
$duplicateField[-1] = $duplicateField[-1] -replace ' exit=0 result=pass', ' exit=0 exit=0 result=pass'

$invalidFinalExit = Copy-Chain $validChain
$invalidFinalExit[-1] = $invalidFinalExit[-1] -replace ' exit=0 result=pass', ' exit=9 result=pass'

$baselinePassClaim = Copy-Chain $validChain
$baselinePassClaim[0] = $baselinePassClaim[0] -replace 'exit=64 result=observed', 'exit=64 result=pass'

$baselineSignedExit = Copy-Chain $validChain
$baselineSignedExit[0] = $baselineSignedExit[0] -replace 'exit=64 result=observed', 'exit=-64 result=observed'

$baselineMalformedExit = Copy-Chain $validChain
$baselineMalformedExit[0] = $baselineMalformedExit[0] -replace 'exit=64 result=observed', 'exit=not-a-number result=observed'

$redWithoutExpectedGap = New-ValidChain -RequiredEvidence 'color,dimensions'

$integrationObserved = Copy-Chain $validChain
$integrationObserved[1] = $integrationObserved[1] -replace 'exit=0 result=pass', 'exit=0 result=observed'

$integrationNonzero = Copy-Chain $validChain
$integrationNonzero[1] = $integrationNonzero[1] -replace 'exit=0 result=pass', 'exit=9 result=pass'

$incompleteEvidence = Copy-Chain $validChain
$incompleteEvidence[1] = $incompleteEvidence[1] -replace 'evidence="baseline-expected-gap,color,dimensions"', 'evidence="baseline-expected-gap,color"'

$unknownField = Copy-Chain $validChain
$unknownField[0] += ' surprise=value'

$invalidTimestamp = Copy-Chain $validChain
$invalidTimestamp[0] = $invalidTimestamp[0] -replace $timestamp, '2026-07-15 10:00:00'

$invalidHash = Copy-Chain $validChain
$invalidHash[1] = $invalidHash[1] -replace $artifact, ('a' * 64)

$invalidGitHash = Copy-Chain $validChain
$invalidGitHash[-1] = $invalidGitHash[-1] -replace $commit, ('C' * 40)

$wrongPhase = Copy-Chain $validChain
$wrongPhase[0] = $wrongPhase[0] -replace 'phase=baseline', 'phase=wrong'

$brokenReference = Copy-Chain $validChain
$brokenReference[-1] = $brokenReference[-1] -replace 'review_ref=review-pass-1', 'review_ref=missing-review'

$referencedDirectPass = New-ValidChain -ReviewLines @(
    (New-ReviewPass -Reference 'integration-1')
)

$malformedQuote = Copy-Chain $validChain
$malformedQuote[0] = "VERIFY_PHASE protocol=verification/v2 receipt_id=baseline-1 phase=baseline verified_by=verifier-1 verified_at=$timestamp artifact_sha=$baselineArtifact gate=`"unterminated"

$conflictingReceipts = @(
    $validChain[0]
    ($validChain[0] -replace 'receipt_id=baseline-1', 'receipt_id=baseline-2')
    $validChain | Select-Object -Skip 1
)

$negativeFixtures = @(
    [pscustomobject]@{ Name = 'missing baseline'; Chain = $missingBaseline; Reason = 'verification.baseline-count' }
    [pscustomobject]@{ Name = 'malformed REVIEW_PASS'; Chain = $malformedPass; Reason = 'receipt.field-missing' }
    [pscustomobject]@{ Name = 'unresolved REVIEW_BLOCK'; Chain = $unresolvedBlock; Reason = 'review.block-unresolved' }
    [pscustomobject]@{ Name = 'malformed REVIEW_BLOCK'; Chain = $malformedBlock; Reason = 'review.block-malformed' }
    [pscustomobject]@{ Name = 'REVIEW_INCONCLUSIVE'; Chain = $inconclusive; Reason = 'review.inconclusive' }
    [pscustomobject]@{ Name = 'second clarification'; Chain = $secondClarification; Reason = 'review.clarification-limit' }
    [pscustomobject]@{ Name = 'reviewer swap'; Chain = $reviewerSwap; Reason = 'review.reviewer-swap' }
    [pscustomobject]@{ Name = 'artifact SHA mismatch'; Chain = $artifactMismatch; Reason = 'review.artifact-mismatch' }
    [pscustomobject]@{ Name = 'duplicate singleton field'; Chain = $duplicateField; Reason = 'receipt.field-duplicate' }
    [pscustomobject]@{ Name = 'invalid final exit'; Chain = $invalidFinalExit; Reason = 'verification.final-not-pass' }
    [pscustomobject]@{ Name = 'baseline labelled as pass'; Chain = $baselinePassClaim; Reason = 'verification.baseline-not-observed' }
    [pscustomobject]@{ Name = 'baseline signed exit'; Chain = $baselineSignedExit; Reason = 'verification.baseline-not-observed' }
    [pscustomobject]@{ Name = 'baseline malformed exit'; Chain = $baselineMalformedExit; Reason = 'verification.baseline-not-observed' }
    [pscustomobject]@{ Name = 'nonzero baseline without expected-gap marker'; Chain = $redWithoutExpectedGap; Reason = 'verification.baseline-expected-gap-missing' }
    [pscustomobject]@{ Name = 'integration labelled as observed'; Chain = $integrationObserved; Reason = 'verification.phase-not-pass' }
    [pscustomobject]@{ Name = 'integration nonzero exit'; Chain = $integrationNonzero; Reason = 'verification.phase-not-pass' }
    [pscustomobject]@{ Name = 'visual color without dimensions'; Chain = $incompleteEvidence; Reason = 'verification.evidence-incomplete' }
    [pscustomobject]@{ Name = 'unknown field'; Chain = $unknownField; Reason = 'receipt.field-unknown' }
    [pscustomobject]@{ Name = 'invalid ISO-8601 timestamp'; Chain = $invalidTimestamp; Reason = 'receipt.timestamp-invalid' }
    [pscustomobject]@{ Name = 'invalid aggregate hash'; Chain = $invalidHash; Reason = 'receipt.artifact-hash-invalid' }
    [pscustomobject]@{ Name = 'invalid Git hash'; Chain = $invalidGitHash; Reason = 'receipt.git-hash-invalid' }
    [pscustomobject]@{ Name = 'wrong phase'; Chain = $wrongPhase; Reason = 'verification.phase-invalid' }
    [pscustomobject]@{ Name = 'broken receipt reference'; Chain = $brokenReference; Reason = 'receipt.reference-missing' }
    [pscustomobject]@{ Name = 'direct REVIEW_PASS with forbidden reference'; Chain = $referencedDirectPass; Reason = 'review.outcome-inadmissible' }
    [pscustomobject]@{ Name = 'malformed quoting'; Chain = $malformedQuote; Reason = 'receipt.quote-unclosed' }
    [pscustomobject]@{ Name = 'conflicting phase receipts'; Chain = $conflictingReceipts; Reason = 'verification.baseline-count' }
)

foreach ($fixture in $negativeFixtures) {
    $result = Test-GatecraftVerificationChain -Receipt @($fixture.Chain)
    Assert-True (-not $result.IsValid) "$($fixture.Name) must fail closed."
    Assert-Equal $result.Decision 'block' "$($fixture.Name) decision."
    Assert-Reason -Result $result -Reason $fixture.Reason -Message "$($fixture.Name) reason."
}
$observations.Add("negative-receipts fixtures=$($negativeFixtures.Count) all=blocked")

$legacyPattern = '^VERIFIED\b.*result=pass'
Assert-True ([regex]::IsMatch($validChain[-1], $legacyPattern)) 'The final verification/v2 line must match the historic bd-mission-control compatibility regex.'
foreach ($supportingReceipt in $validChain[0..($validChain.Count - 2)]) {
    Assert-True (-not [regex]::IsMatch($supportingReceipt, $legacyPattern)) 'Supporting receipts must not match the historic final-pass regex.'
}
foreach ($legacyField in @('verified_by=', 'verified_at=', 'commit=', 'main=', 'gate="', 'exit=0', 'result=pass')) {
    Assert-True $validChain[-1].Contains($legacyField, [StringComparison]::Ordinal) "Final receipt must retain legacy field $legacyField."
}
$observations.Add('legacy-regex final=match supporting=no-match')

$scratch = Join-Path $PSScriptRoot ".receipt-protocol-scratch-$PID"
try {
    [void] [IO.Directory]::CreateDirectory((Join-Path $scratch 'nested'))
    [IO.File]::WriteAllBytes((Join-Path $scratch 'a.bin'), [byte[]](0, 1, 2, 3))
    [IO.File]::WriteAllBytes(
        (Join-Path $scratch 'nested/b.txt'),
        [Text.UTF8Encoding]::new($false).GetBytes("Gatecraft`n")
    )

    $fingerprint1 = Get-GatecraftAggregateFingerprint -Root $scratch -PathList @('a.bin', 'nested/b.txt')
    $fingerprint2 = Get-GatecraftAggregateFingerprint -Root $scratch -PathList @('a.bin', 'nested/b.txt')
    $fingerprintReversed = Get-GatecraftAggregateFingerprint -Root $scratch -PathList @('nested/b.txt', 'a.bin')
    $expectedPayload = "a.bin`t054edec1d0211f624fed0cbca9d4f9400b0e491c43742af2c5b0abebf0c990d8`nnested/b.txt`te9a8f768503863beca988e703cfd6855ace5fd172d323f3b90835d9a7ba87572"

    Assert-Equal $fingerprint1.AggregateHash '4BEEAD1964F03EED66D1FCB23A90E9BC6125EBDA822098211FA7102F56CE6418' 'Known raw-byte aggregate fixture.'
    Assert-Equal $fingerprint1.CanonicalPayload $expectedPayload 'Canonical payload must use path, TAB, lowercase file hash, LF, and no trailing LF.'
    Assert-Equal $fingerprint1.AggregateHash $fingerprint2.AggregateHash 'The same bytes and order must reproduce the same aggregate.'
    Assert-True ($fingerprint1.AggregateHash -cne $fingerprintReversed.AggregateHash) 'Changing declared path order must change the aggregate.'
    Assert-Equal $fingerprint1.Entries[1].Path 'nested/b.txt' 'A normal nested directory path must remain hashable.'
    Assert-True ($fingerprint1.Entries[0].Hash -cmatch '^[0-9a-f]{64}$') 'Per-file hashes must render lowercase.'
    Assert-True ($fingerprint1.AggregateHash -cmatch '^[0-9A-F]{64}$') 'Aggregate hash must render uppercase.'
    Assert-True (-not $fingerprint1.CanonicalPayload.EndsWith("`n", [StringComparison]::Ordinal)) 'Canonical payload must not have a trailing LF.'

    Assert-Throws -Action {
        Get-GatecraftAggregateFingerprint -Root $scratch -PathList @('a.bin', 'A.bin') | Out-Null
    } -Message 'Case-colliding duplicate declared paths must be rejected.'
    Assert-Throws -Action {
        Get-GatecraftAggregateFingerprint -Root $scratch -PathList @('nested/../a.bin') | Out-Null
    } -Message 'Traversal-bearing ambiguous paths must be rejected.'
    Assert-Throws -Action {
        Get-GatecraftAggregateFingerprint -Root $scratch -PathList @('nested\b.txt') | Out-Null
    } -Message 'Backslash path spellings must be rejected as ambiguous.'
    $observations.Add("fingerprint aggregate=$($fingerprint1.AggregateHash) reproducible=true order-sensitive=true")
}
finally {
    if ([IO.Directory]::Exists($scratch)) {
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}

$linkFixture = Join-Path ([IO.Path]::GetTempPath()) ("gatecraft-reparse-$PID-$([guid]::NewGuid().ToString('N'))")
$fingerprintRoot = Join-Path $linkFixture 'root'
$externalRoot = Join-Path $linkFixture 'external'
$linkPath = Join-Path $fingerprintRoot 'link'
$externalPayload = Join-Path $externalRoot 'payload.txt'
$externalBytes = [Text.UTF8Encoding]::new($false).GetBytes("outside-root`n")
$linkCreated = $false
try {
    [void] [IO.Directory]::CreateDirectory($fingerprintRoot)
    [void] [IO.Directory]::CreateDirectory($externalRoot)
    [IO.File]::WriteAllBytes($externalPayload, $externalBytes)

    try {
        if ($IsWindows) {
            [void] (New-Item -ItemType Junction -Path $linkPath -Target $externalRoot -ErrorAction Stop)
        }
        else {
            [void] (New-Item -ItemType SymbolicLink -Path $linkPath -Target $externalRoot -ErrorAction Stop)
        }
        $linkCreated = $true
    }
    catch {
        if ($IsWindows) {
            Add-Failure "Windows junction regression fixture could not be created: $($_.Exception.Message)"
        }
        else {
            $observations.Add("reparse-guard symbolic-link-fixture=unsupported detail=$($_.Exception.GetType().Name)")
        }
    }

    if ($linkCreated) {
        $guardThrew = $false
        try {
            Get-GatecraftAggregateFingerprint -Root $fingerprintRoot -PathList @('link/payload.txt') | Out-Null
        }
        catch {
            $guardThrew = $true
            Assert-True $_.Exception.Message.Contains('path component', [StringComparison]::Ordinal) 'The reparse guard must reject the intermediate component before hashing.'
        }
        Assert-True $guardThrew 'An intermediate junction or symbolic link must throw before hashing an external target.'
        Assert-Equal ([Convert]::ToHexString([IO.File]::ReadAllBytes($externalPayload))) ([Convert]::ToHexString($externalBytes)) 'The rejected external target bytes must remain unchanged.'
        $observations.Add("reparse-guard link-type=$(if ($IsWindows) { 'junction' } else { 'symbolic-link' }) followed=false external-unchanged=true")
    }
}
finally {
    if ([IO.Directory]::Exists($linkPath) -or [IO.File]::Exists($linkPath)) {
        Remove-Item -LiteralPath $linkPath -Force
    }
    if ([IO.Directory]::Exists($linkFixture)) {
        Remove-Item -LiteralPath $linkFixture -Recurse -Force
    }
}

$fakeSecret = 'GATECRAFT_FAKE_TOKEN_7f3d9c_DO_NOT_USE'
$knownSecret = @{ TOKEN = $fakeSecret }
$sanitized = Protect-GatecraftText -Text "before=$fakeSecret after" -KnownSecret $knownSecret

$secretErrorChain = Copy-Chain $validChain
$secretErrorChain[0] += " leak=`"$fakeSecret`""
$secretErrorResult = Test-GatecraftVerificationChain -Receipt $secretErrorChain -KnownSecret $knownSecret
$validationSurface = $secretErrorResult | ConvertTo-Json -Depth 10 -Compress

$secretChain = New-ValidChain -GateText "gate --token $fakeSecret"
$secretResult = Test-GatecraftVerificationChain -Receipt $secretChain -KnownSecret $knownSecret
Assert-True $secretResult.IsValid 'A fake secret in a syntactically valid gate fixture must not alter receipt validity.'
$dashboard = ConvertTo-GatecraftDashboardProjection -ValidationResult $secretResult -KnownSecret $knownSecret
$sanitizationFixtures = @(
    [pscustomobject]@{ Name = 'sanitized output'; Text = $sanitized }
    [pscustomobject]@{ Name = 'validation errors and machine result'; Text = $validationSurface }
    [pscustomobject]@{ Name = 'dashboard-safe projection'; Text = $dashboard }
)
foreach ($fixture in $sanitizationFixtures) {
    Assert-True (-not $fixture.Text.Contains($fakeSecret, [StringComparison]::Ordinal)) "$($fixture.Name) must not propagate the known fake secret."
    Assert-True $fixture.Text.Contains('[REDACTED_TOKEN]', [StringComparison]::Ordinal) "$($fixture.Name) must replace the fake secret with a typed marker."
}
$observations.Add("sanitization fixtures=$($sanitizationFixtures.Count) fake-token=absent marker=[REDACTED_TOKEN]")

$retryFixtures = @(
    [pscustomobject]@{
        Name = 'task failure reserves a new attempt'
        Events = @(
            [pscustomobject]@{ kind = 'reserve'; attempt_id = 'a1' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'worker-1' }
            [pscustomobject]@{ kind = 'outcome'; attempt_id = 'a1'; class = 'task'; process_state = 'exited'; failure_id = 'gate-red' }
        )
        Valid = $true; Decision = 'reserve-new-task-attempt'; Attempts = 1; Spawns = 1; Reason = $null
    }
    [pscustomobject]@{
        Name = 'repairable pre-start infrastructure relaunches one reserved attempt'
        Events = @(
            [pscustomobject]@{ kind = 'reserve'; attempt_id = 'a1' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'unsupported-model' }
            [pscustomobject]@{ kind = 'outcome'; attempt_id = 'a1'; class = 'infrastructure/pre-start-repairable'; process_state = 'not-started'; workspace_state = 'empty' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'supported-model' }
            [pscustomobject]@{ kind = 'outcome'; attempt_id = 'a1'; class = 'task'; process_state = 'exited'; failure_id = 'task-bug' }
        )
        Valid = $true; Decision = 'reserve-new-task-attempt'; Attempts = 1; Spawns = 2; Reason = $null
    }
    [pscustomobject]@{
        Name = 'systemic post-start crash with partial worktree never auto-retries'
        Events = @(
            [pscustomobject]@{ kind = 'reserve'; attempt_id = 'a1' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'worker-1' }
            [pscustomobject]@{ kind = 'outcome'; attempt_id = 'a1'; class = 'crash/post-start-systemic'; process_state = 'exited'; workspace_state = 'partial' }
        )
        Valid = $true; Decision = 'stop-systemic-post-start-crash'; Attempts = 1; Spawns = 1; Reason = $null
    }
    [pscustomobject]@{
        Name = 'quota launch consumes no task attempt'
        Events = @(
            [pscustomobject]@{ kind = 'reserve'; attempt_id = 'a1' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'quota-seat' }
            [pscustomobject]@{ kind = 'outcome'; attempt_id = 'a1'; class = 'quota'; process_state = 'not-started'; workspace_state = 'empty' }
        )
        Valid = $true; Decision = 'retry-same-attempt-after-quota-policy'; Attempts = 0; Spawns = 1; Reason = $null
    }
    [pscustomobject]@{
        Name = 'second repairable pre-start failure exhausts relaunch'
        Events = @(
            [pscustomobject]@{ kind = 'reserve'; attempt_id = 'a1' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'worker-a1' }
            [pscustomobject]@{ kind = 'outcome'; attempt_id = 'a1'; class = 'infrastructure/pre-start-repairable'; process_state = 'not-started' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'worker-a1' }
            [pscustomobject]@{ kind = 'outcome'; attempt_id = 'a1'; class = 'infrastructure/pre-start-repairable'; process_state = 'not-started' }
        )
        Valid = $true; Decision = 'stop-repairable-relaunch-exhausted'; Attempts = 0; Spawns = 2; Reason = $null
    }
    [pscustomobject]@{
        Name = 'second repeated task failure stops early'
        Events = @(
            [pscustomobject]@{ kind = 'reserve'; attempt_id = 'a1' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'worker-a1' }
            [pscustomobject]@{ kind = 'outcome'; attempt_id = 'a1'; class = 'task'; process_state = 'exited'; failure_id = 'same-gate' }
            [pscustomobject]@{ kind = 'reserve'; attempt_id = 'a2' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a2'; worker_id = 'worker-a2' }
            [pscustomobject]@{ kind = 'outcome'; attempt_id = 'a2'; class = 'task'; process_state = 'exited'; failure_id = 'same-gate' }
        )
        Valid = $true; Decision = 'stop-repeated-task-failure'; Attempts = 2; Spawns = 2; Reason = $null
    }
    [pscustomobject]@{
        Name = 'three distinct task failures reach task-attempt cap'
        Events = @(
            [pscustomobject]@{ kind = 'reserve'; attempt_id = 'a1' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'worker-a1' }
            [pscustomobject]@{ kind = 'outcome'; attempt_id = 'a1'; class = 'task'; process_state = 'exited'; failure_id = 'failure-1' }
            [pscustomobject]@{ kind = 'reserve'; attempt_id = 'a2' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a2'; worker_id = 'worker-a2' }
            [pscustomobject]@{ kind = 'outcome'; attempt_id = 'a2'; class = 'task'; process_state = 'exited'; failure_id = 'failure-2' }
            [pscustomobject]@{ kind = 'reserve'; attempt_id = 'a3' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a3'; worker_id = 'worker-a3' }
            [pscustomobject]@{ kind = 'outcome'; attempt_id = 'a3'; class = 'task'; process_state = 'exited'; failure_id = 'failure-3' }
        )
        Valid = $true; Decision = 'stop-task-attempt-cap'; Attempts = 3; Spawns = 3; Reason = $null
    }
    [pscustomobject]@{
        Name = 'mixed quota infrastructure and task reaches global spawn cap'
        Events = @(
            [pscustomobject]@{ kind = 'reserve'; attempt_id = 'a1' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'worker-a1' }
            [pscustomobject]@{ kind = 'outcome'; attempt_id = 'a1'; class = 'quota'; process_state = 'not-started' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'worker-a1' }
            [pscustomobject]@{ kind = 'outcome'; attempt_id = 'a1'; class = 'infrastructure/pre-start-repairable'; process_state = 'not-started' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'worker-a1' }
            [pscustomobject]@{ kind = 'outcome'; attempt_id = 'a1'; class = 'task'; process_state = 'exited'; failure_id = 'gate-red' }
        )
        Valid = $true; Decision = 'stop-global-spawn-cap'; Attempts = 1; Spawns = 3; Reason = $null
    }
    [pscustomobject]@{
        Name = 'fourth quota-discovering launch is rejected at three accepted spawns'
        Events = @(
            [pscustomobject]@{ kind = 'reserve'; attempt_id = 'a1' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'worker-a1' }
            [pscustomobject]@{ kind = 'outcome'; attempt_id = 'a1'; class = 'quota'; process_state = 'not-started' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'worker-a1' }
            [pscustomobject]@{ kind = 'outcome'; attempt_id = 'a1'; class = 'quota'; process_state = 'not-started' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'worker-a1' }
            [pscustomobject]@{ kind = 'outcome'; attempt_id = 'a1'; class = 'quota'; process_state = 'not-started' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'worker-a1' }
        )
        Valid = $false; Decision = 'stop-global-spawn-cap'; Attempts = 0; Spawns = 3; Reason = 'retry.spawn-after-stop'
    }
    [pscustomobject]@{
        Name = 'double-background completion with live children fails closed'
        Events = @(
            [pscustomobject]@{ kind = 'reserve'; attempt_id = 'a1' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'worker-a1' }
            [pscustomobject]@{ kind = 'outcome'; attempt_id = 'a1'; class = 'task'; process_state = 'children-alive'; workspace_state = 'partial' }
        )
        Valid = $false; Decision = 'stop-process-tree-active'; Attempts = 0; Spawns = 1; Reason = 'retry.process-tree-active'
    }
    [pscustomobject]@{
        Name = 'spawn missing worker identity fails closed before acceptance'
        Events = @(
            [pscustomobject]@{ kind = 'reserve'; attempt_id = 'a1' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1' }
        )
        Valid = $false; Decision = 'stop-invalid-sequence'; Attempts = 0; Spawns = 0; Reason = 'retry.worker-id-invalid'
    }
    [pscustomobject]@{
        Name = 'spawn malformed worker identity fails closed before acceptance'
        Events = @(
            [pscustomobject]@{ kind = 'reserve'; attempt_id = 'a1' }
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'bad worker!' }
        )
        Valid = $false; Decision = 'stop-invalid-sequence'; Attempts = 0; Spawns = 0; Reason = 'retry.worker-id-invalid'
    }
    [pscustomobject]@{
        Name = 'spawn without reserved attempt fails closed'
        Events = @(
            [pscustomobject]@{ kind = 'spawn'; attempt_id = 'a1'; worker_id = 'worker-a1' }
        )
        Valid = $false; Decision = 'stop-invalid-sequence'; Attempts = 0; Spawns = 0; Reason = 'retry.spawn-without-reservation'
    }
    [pscustomobject]@{
        Name = 'second outstanding reservation fails closed'
        Events = @(
            [pscustomobject]@{ kind = 'reserve'; attempt_id = 'a1' }
            [pscustomobject]@{ kind = 'reserve'; attempt_id = 'a2' }
        )
        Valid = $false; Decision = 'stop-invalid-sequence'; Attempts = 0; Spawns = 0; Reason = 'retry.reserve-not-allowed'
    }
)

foreach ($fixture in $retryFixtures) {
    $result = Resolve-GatecraftRetrySequence -Event @($fixture.Events)
    Assert-Equal $result.IsValid $fixture.Valid "$($fixture.Name) validity."
    Assert-Equal $result.Decision $fixture.Decision "$($fixture.Name) decision."
    Assert-Equal $result.TaskAttemptCount $fixture.Attempts "$($fixture.Name) task-attempt count."
    Assert-Equal $result.TotalSpawnCount $fixture.Spawns "$($fixture.Name) total-spawn count."
    Assert-True ($result.TotalSpawnCount -le 3) "$($fixture.Name) must never accept more than three total spawns."
    if ($null -ne $fixture.Reason) {
        Assert-Reason -Result $result -Reason $fixture.Reason -Message "$($fixture.Name) reason."
    }
}
$observations.Add("retry fixtures=$($retryFixtures.Count) max-spawns=3 worker-identity=mandatory quota-attempts=0 systemic-auto-retry=false")

if ($failures.Count -gt 0) {
    [Console]::Error.WriteLine("Receipt protocol gate failed with $($failures.Count) issue(s):")
    foreach ($failure in $failures) {
        [Console]::Error.WriteLine(" - $failure")
    }
    exit 1
}

Write-Host "Receipt protocol gate passed: $($negativeFixtures.Count) negative receipt fixtures, $($retryFixtures.Count) retry fixtures."
foreach ($observation in $observations) {
    Write-Host " - $observation"
}
exit 0
