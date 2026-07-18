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

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$modulePath = Join-Path $repoRoot 'gatecraft/scripts/Gatecraft.Protocol.psm1'
Import-Module $modulePath -Force -ErrorAction Stop

$artifact = 'A' * 64
$otherArtifact = 'B' * 64
$baselineArtifact = 'C' * 64
$timestamp = '2026-07-16T10:00:00Z'
$commit = 'c' * 40
$main = 'd' * 40
$externalMergeOid = 'e' * 40
$otherExternalMergeOid = 'f' * 40
$subjectId = 'gatecraft-drift-1'

function ConvertTo-RecoveryQuotedValue {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)

    return $Value.Replace('\', '\\', [StringComparison]::Ordinal).Replace('"', '\"', [StringComparison]::Ordinal)
}

function New-RecoveryRecord {
    param(
        [string] $Id = 'recovery-1',
        [string] $Mode = 'attended',
        [string] $ObservedAt = $script:timestamp,
        [string] $ExternalMergeOid = $script:externalMergeOid,
        [string] $SubjectId = $script:subjectId,
        [string] $Artifact = $script:artifact,
        [string] $MissingEvidence = 'integration/premerge and postmerge receipts were never emitted',
        [string] $UserDecision = 'Leave the external merge unqualified and schedule fresh verification',
        [string] $Protocol = 'gatecraft-recovery/v1'
    )

    $quotedMissingEvidence = ConvertTo-RecoveryQuotedValue -Value $MissingEvidence
    $quotedUserDecision = ConvertTo-RecoveryQuotedValue -Value $UserDecision
    return "RECOVERY protocol=$Protocol receipt_id=$Id mode=$Mode observed_at=$ObservedAt external_merge_oid=$ExternalMergeOid subject_id=$SubjectId artifact_sha=$Artifact missing_evidence=`"$quotedMissingEvidence`" user_decision=`"$quotedUserDecision`""
}

function New-ValidChain {
    @(
        "VERIFY_PHASE protocol=verification/v2 receipt_id=baseline-1 phase=baseline verified_by=verifier-1 verified_at=$script:timestamp artifact_sha=$script:baselineArtifact gate=`"focused-gate`" exit=0 result=observed required=`"tests`" evidence=`"tests`""
        "VERIFY_PHASE protocol=verification/v2 receipt_id=integration-1 phase=integration/premerge verified_by=verifier-1 verified_at=$script:timestamp artifact_sha=$script:artifact baseline_ref=baseline-1 gate=`"focused-gate`" exit=0 result=pass required=`"tests`" evidence=`"tests`""
        "REVIEW_PASS protocol=verification/v2 receipt_id=review-1 reviewer=reviewer-1 reviewed_at=$script:timestamp source_id=source-1 review_id=review-1 artifact_sha=$script:artifact"
        "VERIFIED protocol=verification/v2 receipt_id=postmerge-1 phase=postmerge verified_by=verifier-1 verified_at=$script:timestamp commit=$script:commit main=$script:main artifact_sha=$script:artifact baseline_ref=baseline-1 integration_ref=integration-1 review_ref=review-1 gate=`"focused-gate`" exit=0 result=pass required=`"tests`" evidence=`"tests`""
    )
}

$validChain = New-ValidChain
$control = Test-GatecraftVerificationChain -Receipt $validChain
Assert-True $control.IsValid 'The unchanged complete verification/v2 control chain must pass.'
Assert-Equal $control.Decision 'pass' 'Control chain decision.'

$validRecovery = New-RecoveryRecord
$parsed = ConvertFrom-GatecraftReceiptLine -Line $validRecovery
Assert-True $parsed.IsValid 'The production parser must accept the complete RECOVERY grammar.'
Assert-Equal $parsed.Type 'RECOVERY' 'Recovery prefix.'
Assert-Equal $parsed.Fields.protocol 'gatecraft-recovery/v1' 'Recovery protocol.'
Assert-Equal $parsed.Fields.mode 'attended' 'Recovery mode.'
Assert-Equal $parsed.Fields.external_merge_oid $externalMergeOid 'Recovery external merge subject.'
Assert-Equal $parsed.Fields.subject_id $subjectId 'Recovery bead/drift subject.'
Assert-True $parsed.Quoted.missing_evidence 'The missing-evidence reason must remain quoted.'
Assert-True $parsed.Quoted.user_decision 'The direct-user decision must remain quoted.'

$audit = Test-GatecraftRecoveryRecord -Record $validRecovery
Assert-True $audit.IsValid 'A valid recovery audit observation must pass its focused grammar validator.'
Assert-Equal $audit.Decision 'audit-only' 'A valid recovery audit observation disposition.'
Assert-True (-not $audit.Qualifies) 'A valid recovery audit observation must remain non-qualifying.'
Assert-Equal $audit.QualificationReason 'recovery.audit-only' 'Stable audit-only qualification reason.'
Assert-Equal @($audit.Errors).Count 0 'A valid recovery audit observation must have no field errors.'
$observations.Add('valid recovery audit observation remains non-qualifying')

$unattended = Test-GatecraftRecoveryRecord -Record (New-RecoveryRecord -Mode 'unattended')
Assert-True (-not $unattended.IsValid) 'An unattended recovery record must fail closed.'
Assert-Equal $unattended.Decision 'block' 'Unattended recovery decision.'
Assert-True (-not $unattended.Qualifies) 'An unattended recovery record must not qualify.'
Assert-Reason -Result $unattended -Reason 'recovery.mode-not-attended' -Message 'Attended-only recovery mode.'

$wrongProtocol = Test-GatecraftRecoveryRecord -Record (New-RecoveryRecord -Protocol 'verification/v2')
Assert-True (-not $wrongProtocol.IsValid) 'A recovery record must remain domain-separated from verification/v2.'
Assert-Reason -Result $wrongProtocol -Reason 'recovery.protocol-invalid' -Message 'Recovery protocol separation.'

$badTimestamp = Test-GatecraftRecoveryRecord -Record (New-RecoveryRecord -ObservedAt '2026-07-16')
Assert-True (-not $badTimestamp.IsValid) 'A recovery record with a non-qualified timestamp must fail closed.'
Assert-Reason -Result $badTimestamp -Reason 'recovery.timestamp-invalid' -Message 'Recovery timestamp validation.'

$badHash = Test-GatecraftRecoveryRecord -Record (New-RecoveryRecord -Artifact ('a' * 64))
Assert-True (-not $badHash.IsValid) 'A recovery record with a lowercase artifact SHA must fail closed.'
Assert-Reason -Result $badHash -Reason 'recovery.artifact-hash-invalid' -Message 'Recovery artifact validation.'

$missingExternalMerge = Test-GatecraftRecoveryRecord -Record ($validRecovery -replace ' external_merge_oid=[^ ]+', '')
Assert-True (-not $missingExternalMerge.IsValid) 'A recovery record without its external merge OID must fail closed.'
Assert-Reason -Result $missingExternalMerge -Reason 'receipt.field-missing' -Message 'Required external merge subject.'
Assert-Reason -Result $missingExternalMerge -Reason 'recovery.external-merge-oid-invalid' -Message 'Missing external merge validation.'

$badExternalMerge = Test-GatecraftRecoveryRecord -Record (New-RecoveryRecord -ExternalMergeOid ('E' * 40))
Assert-True (-not $badExternalMerge.IsValid) 'A recovery record with a noncanonical external merge OID must fail closed.'
Assert-Reason -Result $badExternalMerge -Reason 'recovery.external-merge-oid-invalid' -Message 'External merge OID validation.'

$missingSubject = Test-GatecraftRecoveryRecord -Record ($validRecovery -replace ' subject_id=[^ ]+', '')
Assert-True (-not $missingSubject.IsValid) 'A recovery record without its bead/drift subject ID must fail closed.'
Assert-Reason -Result $missingSubject -Reason 'receipt.field-missing' -Message 'Required bead/drift subject.'
Assert-Reason -Result $missingSubject -Reason 'recovery.subject-id-malformed' -Message 'Missing bead/drift subject validation.'

$badSubject = Test-GatecraftRecoveryRecord -Record (New-RecoveryRecord -SubjectId '../private/drift')
Assert-True (-not $badSubject.IsValid) 'A path-like recovery subject ID must fail closed.'
Assert-Reason -Result $badSubject -Reason 'recovery.subject-id-malformed' -Message 'Bead/drift subject validation.'

$unquoted = $validRecovery -replace 'missing_evidence="[^"]+"', 'missing_evidence=integration-missing'
$unquotedResult = Test-GatecraftRecoveryRecord -Record $unquoted
Assert-True (-not $unquotedResult.IsValid) 'An unquoted missing-evidence reason must fail closed.'
Assert-Reason -Result $unquotedResult -Reason 'recovery.quoting-required' -Message 'Recovery quoted text validation.'

$emptyDecision = Test-GatecraftRecoveryRecord -Record (New-RecoveryRecord -UserDecision '')
Assert-True (-not $emptyDecision.IsValid) 'An empty direct-user decision must fail closed.'
Assert-Reason -Result $emptyDecision -Reason 'recovery.text-invalid' -Message 'Recovery decision content validation.'

$lineSeparator = [string] [char] 0x2028
$paragraphSeparator = [string] [char] 0x2029
$rightToLeftOverride = [string] [char] 0x202E
$leftToRightIsolate = [string] [char] 0x2066
$unsafeQuotedTextFixtures = @(
    [pscustomobject]@{ Name = 'U+2028 in missing_evidence'; MissingEvidence = "missing${lineSeparator}evidence"; UserDecision = 'Keep the merge unqualified' },
    [pscustomobject]@{ Name = 'U+2028 in user_decision'; MissingEvidence = 'missing evidence'; UserDecision = "Keep${lineSeparator}unqualified" },
    [pscustomobject]@{ Name = 'U+2029 in missing_evidence'; MissingEvidence = "missing${paragraphSeparator}evidence"; UserDecision = 'Keep the merge unqualified' },
    [pscustomobject]@{ Name = 'U+2029 in user_decision'; MissingEvidence = 'missing evidence'; UserDecision = "Keep${paragraphSeparator}unqualified" },
    [pscustomobject]@{ Name = 'U+202E format control'; MissingEvidence = "missing${rightToLeftOverride}evidence"; UserDecision = 'Keep the merge unqualified' },
    [pscustomobject]@{ Name = 'U+2066 format control'; MissingEvidence = 'missing evidence'; UserDecision = "Keep${leftToRightIsolate}unqualified" }
)
foreach ($fixture in $unsafeQuotedTextFixtures) {
    $result = Test-GatecraftRecoveryRecord -Record (New-RecoveryRecord -MissingEvidence $fixture.MissingEvidence -UserDecision $fixture.UserDecision)
    Assert-True (-not $result.IsValid) "Quoted recovery fixture '$($fixture.Name)' must fail closed."
    Assert-Reason -Result $result -Reason 'recovery.text-invalid' -Message "Quoted recovery fixture '$($fixture.Name)'."
}
$observations.Add("quoted separator/format-control fixtures=$($unsafeQuotedTextFixtures.Count) all=blocked")

$phaseLookalike = Test-GatecraftRecoveryRecord -Record "$validRecovery phase=integration/premerge result=pass"
Assert-True (-not $phaseLookalike.IsValid) 'Recovery text cannot acquire an integration phase or pass result.'
Assert-Reason -Result $phaseLookalike -Reason 'receipt.field-unknown' -Message 'Recovery replacement fields.'

# Recovery text used as integration/postmerge substitute must expose the ordinary
# missing phase plus the permanent recovery non-qualification reason.
$integrationSubstitute = @(
    $validChain[0]
    $validRecovery
    $validChain[2]
    ($validChain[3] -replace 'integration_ref=integration-1', 'integration_ref=recovery-1')
)
$integrationSubstituteResult = Test-GatecraftVerificationChain -Receipt $integrationSubstitute
Assert-True (-not $integrationSubstituteResult.IsValid) 'Recovery text used as an integration/premerge substitute must block.'
Assert-Reason -Result $integrationSubstituteResult -Reason 'verification.integration-count' -Message 'Integration substitute missing phase.'
Assert-Reason -Result $integrationSubstituteResult -Reason 'verification.recovery-nonqualifying' -Message 'Integration substitute audit boundary.'

$postmergeSubstitute = @($validChain[0], $validChain[1], $validChain[2], $validRecovery)
$postmergeSubstituteResult = Test-GatecraftVerificationChain -Receipt $postmergeSubstitute
Assert-True (-not $postmergeSubstituteResult.IsValid) 'Recovery text used as a postmerge substitute must block.'
Assert-Reason -Result $postmergeSubstituteResult -Reason 'verification.final-count' -Message 'Postmerge substitute missing final.'
Assert-Reason -Result $postmergeSubstituteResult -Reason 'verification.recovery-nonqualifying' -Message 'Postmerge substitute audit boundary.'

$reviewSubstitute = @(
    $validChain[0]
    $validChain[1]
    $validRecovery
    ($validChain[3] -replace 'review_ref=review-1', 'review_ref=recovery-1')
)
$reviewSubstituteResult = Test-GatecraftVerificationChain -Receipt $reviewSubstitute
Assert-True (-not $reviewSubstituteResult.IsValid) 'Recovery text used as a REVIEW_PASS substitute must block.'
Assert-Reason -Result $reviewSubstituteResult -Reason 'review.missing' -Message 'Review substitute missing review.'
Assert-Reason -Result $reviewSubstituteResult -Reason 'verification.recovery-nonqualifying' -Message 'Review substitute audit boundary.'

$mismatchedRecovery = New-RecoveryRecord -Artifact $otherArtifact
$mismatchAudit = Test-GatecraftRecoveryRecord -Record $mismatchedRecovery
Assert-True $mismatchAudit.IsValid 'A well-formed current-artifact observation may differ from the candidate SHA.'
Assert-True (-not $mismatchAudit.Qualifies) 'A SHA-mismatched recovery observation remains non-qualifying.'

$sameArtifactOtherMerge = New-RecoveryRecord -Id 'recovery-2' -ExternalMergeOid $otherExternalMergeOid
$otherMergeAudit = Test-GatecraftRecoveryRecord -Record $sameArtifactOtherMerge
Assert-True $otherMergeAudit.IsValid 'A second external merge with the same artifact must remain a valid distinct audit subject.'
Assert-Equal $otherMergeAudit.Record.Fields.artifact_sha $audit.Record.Fields.artifact_sha 'Same-artifact merge fixture.'
Assert-True ($otherMergeAudit.Record.Fields.external_merge_oid -cne $audit.Record.Fields.external_merge_oid) 'Same artifact content must not collapse different external merge OIDs.'
Assert-Equal $otherMergeAudit.Record.Fields.subject_id $audit.Record.Fields.subject_id 'The same bead/drift subject may name different external merges without losing the merge binding.'
$observations.Add('same artifact/different external merge remained distinctly bound')

$fakeSensitiveValue = 'FAKE-RECOVERY-SECRET-7f6c'
$privatePath = 'C:\Users\fixture\private-recovery-path-marker.txt'
$sensitiveRecovery = New-RecoveryRecord -Id 'recovery-sensitive' -MissingEvidence "missing proof mentions $fakeSensitiveValue" -UserDecision "Keep the raw note at $privatePath local"
$sensitiveAudit = Test-GatecraftRecoveryRecord -Record $sensitiveRecovery
Assert-True $sensitiveAudit.IsValid 'The safe-projection fixture must begin as a valid local recovery record.'
Assert-True $sensitiveAudit.Record.Fields.missing_evidence.Contains($fakeSensitiveValue, [StringComparison]::Ordinal) 'The local validation fixture must actually contain the fake sensitive value.'
Assert-True $sensitiveAudit.Record.Fields.user_decision.Contains('private-recovery-path-marker', [StringComparison]::Ordinal) 'The local validation fixture must actually contain path-like text.'
$safeProjection = ConvertTo-GatecraftRecoveryProjection -ValidationResult $sensitiveAudit
$safeProjectionObject = $safeProjection | ConvertFrom-Json -Depth 20
$projectedFieldNames = @($safeProjectionObject.record.fields.PSObject.Properties.Name)
Assert-True (-not $safeProjection.Contains($fakeSensitiveValue, [StringComparison]::Ordinal)) 'The default durable recovery projection must not persist sensitive free text.'
Assert-True (-not $safeProjection.Contains('private-recovery-path-marker', [StringComparison]::Ordinal)) 'The default durable recovery projection must not persist path-like free text.'
Assert-True ('missing_evidence' -cnotin $projectedFieldNames) 'The default durable recovery projection must omit missing_evidence.'
Assert-True ('user_decision' -cnotin $projectedFieldNames) 'The default durable recovery projection must omit user_decision.'
Assert-Equal $safeProjectionObject.record.fields.external_merge_oid $externalMergeOid 'The safe projection must retain the external merge subject.'
Assert-Equal $safeProjectionObject.record.fields.subject_id $subjectId 'The safe projection must retain the bead/drift subject.'
Assert-Equal (@($safeProjectionObject.record.omitted_fields) -join ',') 'missing_evidence,user_decision' 'The safe projection must declare both omitted narrative fields.'
$observations.Add('durable-safe recovery projection omitted sensitive and path-like free text')

$reorderedFixtures = @(
    [pscustomobject]@{ Name = 'before baseline'; Chain = @($mismatchedRecovery) + $validChain },
    [pscustomobject]@{ Name = 'between integration and review'; Chain = @($validChain[0], $validChain[1], $mismatchedRecovery, $validChain[2], $validChain[3]) },
    [pscustomobject]@{ Name = 'between review and postmerge'; Chain = @($validChain[0], $validChain[1], $validChain[2], $validRecovery, $validChain[3]) },
    [pscustomobject]@{ Name = 'after postmerge'; Chain = @($validChain + $mismatchedRecovery) }
)
foreach ($fixture in $reorderedFixtures) {
    $result = Test-GatecraftVerificationChain -Receipt $fixture.Chain
    Assert-True (-not $result.IsValid) "Reordered/SHA-mismatched recovery variant '$($fixture.Name)' must block."
    Assert-Equal $result.Decision 'block' "Reordered recovery variant '$($fixture.Name)' decision."
    Assert-Reason -Result $result -Reason 'verification.recovery-nonqualifying' -Message "Reordered recovery variant '$($fixture.Name)'."
}
Assert-Reason -Result (Test-GatecraftVerificationChain -Receipt $reorderedFixtures[-1].Chain) -Reason 'verification.final-not-last' -Message 'Recovery after postmerge must not extend the ordered chain.'
$observations.Add("substitution fixtures=3 reordered variants=$($reorderedFixtures.Count) all=blocked")

$recoveryOnly = Test-GatecraftVerificationChain -Receipt @($validRecovery)
Assert-True (-not $recoveryOnly.IsValid) 'A valid recovery observation alone must not qualify.'
Assert-Equal $recoveryOnly.Decision 'block' 'Recovery-only verification decision.'
foreach ($reason in @(
    'verification.recovery-nonqualifying',
    'verification.baseline-count',
    'verification.integration-count',
    'verification.final-count',
    'review.missing'
)) {
    Assert-Reason -Result $recoveryOnly -Reason $reason -Message 'Recovery-only chain completeness.'
}

if ($failures.Count -gt 0) {
    [Console]::Error.WriteLine("Recovery protocol gate failed with $($failures.Count) issue(s):")
    foreach ($failure in $failures) {
        [Console]::Error.WriteLine(" - $failure")
    }
    exit 1
}

foreach ($observation in $observations) {
    Write-Host " - $observation"
}
Write-Host "Recovery protocol gate passed: subject binding, Unicode rejection, safe projection, 3 substitutions, and $($reorderedFixtures.Count) reordered/SHA variants held."
exit 0
