Set-StrictMode -Version Latest

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Gatecraft.Protocol requires PowerShell 7 or later.'
}

function Protect-GatecraftText {
    [CmdletBinding()]
    param(
        [AllowNull()][object] $Text,
        [hashtable] $KnownSecret = @{}
    )

    if ($null -eq $Text) {
        return $null
    }

    $safe = [string] $Text
    $entries = foreach ($key in $KnownSecret.Keys) {
        $value = [string] $KnownSecret[$key]
        if (-not [string]::IsNullOrEmpty($value)) {
            $type = ([string] $key).ToUpperInvariant() -replace '[^A-Z0-9_]', '_'
            if ([string]::IsNullOrEmpty($type)) {
                $type = 'SECRET'
            }
            [pscustomobject]@{ Value = $value; Marker = "[REDACTED_$type]" }
        }
    }

    $orderedEntries = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($entries)) {
        $orderedEntries.Add($entry)
    }
    $orderedEntries.Sort([Comparison[object]] {
        param($left, $right)
        $lengthOrder = $right.Value.Length.CompareTo($left.Value.Length)
        if ($lengthOrder -ne 0) {
            return $lengthOrder
        }
        return [StringComparer]::Ordinal.Compare($left.Marker, $right.Marker)
    })
    foreach ($entry in $orderedEntries) {
        $safe = $safe.Replace($entry.Value, $entry.Marker, [StringComparison]::Ordinal)
    }
    return $safe
}

function New-GatecraftProtocolIssue {
    param(
        [Parameter(Mandatory)][string] $Code,
        [Parameter(Mandatory)][string] $Message,
        [int] $Line = 0,
        [hashtable] $KnownSecret = @{}
    )

    [pscustomobject][ordered]@{
        Code = $Code
        Message = Protect-GatecraftText -Text $Message -KnownSecret $KnownSecret
        Line = $Line
    }
}

function Get-GatecraftReceiptSchema {
    param([Parameter(Mandatory)][string] $Type)

    switch ($Type) {
        'VERIFY_PHASE' {
            return [pscustomobject]@{
                Required = @(
                    'protocol', 'receipt_id', 'phase', 'verified_by', 'verified_at',
                    'artifact_sha', 'gate', 'exit', 'result', 'required', 'evidence'
                )
                Allowed = @(
                    'protocol', 'receipt_id', 'phase', 'verified_by', 'verified_at',
                    'artifact_sha', 'baseline_ref', 'gate', 'exit', 'result',
                    'required', 'evidence'
                )
            }
        }
        'VERIFIED' {
            return [pscustomobject]@{
                Required = @(
                    'protocol', 'receipt_id', 'phase', 'verified_by', 'verified_at',
                    'commit', 'main', 'artifact_sha', 'baseline_ref', 'integration_ref',
                    'review_ref', 'gate', 'exit', 'result', 'required', 'evidence'
                )
                Allowed = @(
                    'protocol', 'receipt_id', 'phase', 'verified_by', 'verified_at',
                    'commit', 'main', 'artifact_sha', 'baseline_ref', 'integration_ref',
                    'review_ref', 'gate', 'exit', 'result', 'required', 'evidence'
                )
            }
        }
        'RECOVERY' {
            return [pscustomobject]@{
                Required = @(
                    'protocol', 'receipt_id', 'mode', 'observed_at', 'external_merge_oid',
                    'subject_id', 'artifact_sha', 'missing_evidence', 'user_decision'
                )
                Allowed = @(
                    'protocol', 'receipt_id', 'mode', 'observed_at', 'external_merge_oid',
                    'subject_id', 'artifact_sha', 'missing_evidence', 'user_decision'
                )
            }
        }
        { $_ -in @('REVIEW_PASS', 'REVIEW_BLOCK', 'REVIEW_INCONCLUSIVE') } {
            $allowed = @(
                'protocol', 'receipt_id', 'reviewer', 'reviewed_at', 'source_id',
                'review_id', 'artifact_sha'
            )
            if ($Type -eq 'REVIEW_PASS') {
                $allowed += 'review_ref'
            }
            return [pscustomobject]@{
                Required = @(
                    'protocol', 'receipt_id', 'reviewer', 'reviewed_at', 'source_id',
                    'review_id', 'artifact_sha'
                )
                Allowed = $allowed
            }
        }
        'REVIEW_CLARIFY' {
            return [pscustomobject]@{
                Required = @(
                    'protocol', 'receipt_id', 'reviewer', 'reviewed_at', 'source_id',
                    'review_id', 'artifact_sha', 'review_ref'
                )
                Allowed = @(
                    'protocol', 'receipt_id', 'reviewer', 'reviewed_at', 'source_id',
                    'review_id', 'artifact_sha', 'review_ref'
                )
            }
        }
        default { return $null }
    }
}

function ConvertFrom-GatecraftReceiptLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Line,
        [ValidateRange(1, [int]::MaxValue)][int] $LineNumber = 1,
        [hashtable] $KnownSecret = @{}
    )

    $issues = [Collections.Generic.List[object]]::new()
    $fields = [ordered]@{}
    $quoted = [ordered]@{}

    if ([string]::IsNullOrWhiteSpace($Line)) {
        $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.empty' -Message "Line $LineNumber is empty." -Line $LineNumber -KnownSecret $KnownSecret))
        return [pscustomobject]@{
            IsValid = $false; Type = ''; Fields = $fields; Quoted = $quoted
            LineNumber = $LineNumber; Errors = @($issues)
        }
    }
    if ($Line.IndexOfAny([char[]] "`r`n`t") -ge 0) {
        $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.control-character' -Message "Line $LineNumber contains a forbidden control character." -Line $LineNumber -KnownSecret $KnownSecret))
    }

    $typeMatch = [regex]::Match($Line, '^(?<type>[A-Z][A-Z_]*)')
    if (-not $typeMatch.Success) {
        $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.prefix-malformed' -Message "Line $LineNumber has a malformed receipt prefix." -Line $LineNumber -KnownSecret $KnownSecret))
        return [pscustomobject]@{
            IsValid = $false; Type = ''; Fields = $fields; Quoted = $quoted
            LineNumber = $LineNumber; Errors = @($issues)
        }
    }

    $type = $typeMatch.Groups['type'].Value
    $schema = Get-GatecraftReceiptSchema -Type $type
    if ($null -eq $schema) {
        $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.prefix-unknown' -Message "Line $LineNumber uses unknown prefix '$type'." -Line $LineNumber -KnownSecret $KnownSecret))
    }

    $cursor = $typeMatch.Length
    $length = $Line.Length
    if ($cursor -lt $length -and $Line[$cursor] -ne ' ') {
        $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.separator-malformed' -Message "Line $LineNumber must separate its prefix and fields with an ASCII space." -Line $LineNumber -KnownSecret $KnownSecret))
    }

    while ($cursor -lt $length) {
        if ($Line[$cursor] -ne ' ') {
            $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.separator-malformed' -Message "Line $LineNumber has malformed field separation near character $($cursor + 1)." -Line $LineNumber -KnownSecret $KnownSecret))
            break
        }
        while ($cursor -lt $length -and $Line[$cursor] -eq ' ') {
            $cursor++
        }
        if ($cursor -ge $length) {
            $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.trailing-space' -Message "Line $LineNumber has trailing whitespace." -Line $LineNumber -KnownSecret $KnownSecret))
            break
        }

        $keyStart = $cursor
        while ($cursor -lt $length -and $Line[$cursor] -match '[a-z0-9_]') {
            $cursor++
        }
        $key = $Line.Substring($keyStart, $cursor - $keyStart)
        if ([string]::IsNullOrEmpty($key) -or $key -notmatch '^[a-z][a-z0-9_]*$') {
            $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.field-name-malformed' -Message "Line $LineNumber has a malformed field name near character $($keyStart + 1)." -Line $LineNumber -KnownSecret $KnownSecret))
            break
        }
        if ($cursor -ge $length -or $Line[$cursor] -ne '=') {
            $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.assignment-malformed' -Message "Line $LineNumber field '$key' is not followed by '='." -Line $LineNumber -KnownSecret $KnownSecret))
            break
        }
        $cursor++

        $wasQuoted = $false
        $value = ''
        if ($cursor -lt $length -and $Line[$cursor] -eq '"') {
            $wasQuoted = $true
            $cursor++
            $builder = [Text.StringBuilder]::new()
            $closed = $false
            while ($cursor -lt $length) {
                $character = $Line[$cursor]
                if ($character -eq '"') {
                    $closed = $true
                    $cursor++
                    break
                }
                if ($character -eq '\') {
                    $cursor++
                    if ($cursor -ge $length -or $Line[$cursor] -notin @('"', '\')) {
                        $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.escape-malformed' -Message "Line $LineNumber field '$key' uses an unsupported escape; allow only escaped quote or backslash." -Line $LineNumber -KnownSecret $KnownSecret))
                        break
                    }
                    [void] $builder.Append($Line[$cursor])
                    $cursor++
                    continue
                }
                if ([char]::IsControl($character)) {
                    $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.quoted-control-character' -Message "Line $LineNumber field '$key' contains a forbidden control character." -Line $LineNumber -KnownSecret $KnownSecret))
                    break
                }
                [void] $builder.Append($character)
                $cursor++
            }
            if (-not $closed) {
                $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.quote-unclosed' -Message "Line $LineNumber field '$key' has an unclosed quoted value." -Line $LineNumber -KnownSecret $KnownSecret))
            }
            $value = $builder.ToString()
        }
        else {
            $valueStart = $cursor
            while ($cursor -lt $length -and $Line[$cursor] -ne ' ') {
                $cursor++
            }
            $value = $Line.Substring($valueStart, $cursor - $valueStart)
            if ($value -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$') {
                $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.token-malformed' -Message "Line $LineNumber field '$key' has a malformed unquoted token." -Line $LineNumber -KnownSecret $KnownSecret))
            }
        }

        if ($fields.Contains($key)) {
            $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.field-duplicate' -Message "Line $LineNumber repeats singleton field '$key'." -Line $LineNumber -KnownSecret $KnownSecret))
        }
        else {
            $fields[$key] = $value
            $quoted[$key] = $wasQuoted
        }

        if ($cursor -lt $length -and $Line[$cursor] -ne ' ') {
            $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.value-termination-malformed' -Message "Line $LineNumber field '$key' is not followed by a valid separator." -Line $LineNumber -KnownSecret $KnownSecret))
            break
        }
    }

    if ($null -ne $schema) {
        foreach ($key in $fields.Keys) {
            if ($key -notin $schema.Allowed) {
                $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.field-unknown' -Message "Line $LineNumber field '$key' is not allowed for $type." -Line $LineNumber -KnownSecret $KnownSecret))
            }
        }
        foreach ($key in $schema.Required) {
            if (-not $fields.Contains($key)) {
                $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.field-missing' -Message "Line $LineNumber is missing required field '$key'." -Line $LineNumber -KnownSecret $KnownSecret))
            }
        }
    }

    [pscustomobject]@{
        IsValid = ($issues.Count -eq 0)
        Type = $type
        Fields = $fields
        Quoted = $quoted
        LineNumber = $LineNumber
        Errors = @($issues)
    }
}

function Test-GatecraftIso8601 {
    param([AllowNull()][string] $Value)

    if ($Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})$') {
        return $false
    }
    $parsed = [DateTimeOffset]::MinValue
    return [DateTimeOffset]::TryParse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref] $parsed
    )
}

function Get-GatecraftEvidenceList {
    param([AllowNull()][string] $Value)

    if ([string]::IsNullOrEmpty($Value) -or $Value -cnotmatch '^[a-z0-9][a-z0-9._:-]*(?:,[a-z0-9][a-z0-9._:-]*)*$') {
        return $null
    }
    $items = @($Value -split ',')
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $items) {
        if (-not $seen.Add($item)) {
            return $null
        }
    }
    return ,$items
}

function Get-GatecraftField {
    param(
        [Parameter(Mandatory)] $Receipt,
        [Parameter(Mandatory)][string] $Name
    )

    if ($Receipt.Fields.Contains($Name)) {
        return [string] $Receipt.Fields[$Name]
    }
    return $null
}

function Test-GatecraftRecoveryQuotedText {
    param([AllowNull()][string] $Value)

    if (
        [string]::IsNullOrWhiteSpace($Value) -or
        $Value.Length -gt 2048 -or
        $Value -cne $Value.Trim()
    ) {
        return $false
    }

    try {
        if (-not $Value.IsNormalized([Text.NormalizationForm]::FormC)) {
            return $false
        }
    }
    catch {
        return $false
    }

    $offset = 0
    while ($offset -lt $Value.Length) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($Value, $offset)
        if (
            $category -eq [Globalization.UnicodeCategory]::Control -or
            $category -eq [Globalization.UnicodeCategory]::Format -or
            $category -eq [Globalization.UnicodeCategory]::LineSeparator -or
            $category -eq [Globalization.UnicodeCategory]::ParagraphSeparator -or
            $category -eq [Globalization.UnicodeCategory]::Surrogate
        ) {
            return $false
        }

        if ([char]::IsHighSurrogate($Value[$offset])) {
            if ($offset + 1 -ge $Value.Length -or -not [char]::IsLowSurrogate($Value[$offset + 1])) {
                return $false
            }
            $offset += 2
        }
        elseif ([char]::IsLowSurrogate($Value[$offset])) {
            return $false
        }
        else {
            $offset++
        }
    }

    return $true
}

function Add-GatecraftRecoveryIssues {
    param(
        [Parameter(Mandatory)] $Record,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Issues,
        [hashtable] $KnownSecret = @{}
    )

    if ((Get-GatecraftField -Receipt $Record -Name 'protocol') -cne 'gatecraft-recovery/v1') {
        $Issues.Add((New-GatecraftProtocolIssue -Code 'recovery.protocol-invalid' -Message "Line $($Record.LineNumber) must declare protocol gatecraft-recovery/v1." -Line $Record.LineNumber -KnownSecret $KnownSecret))
    }

    $id = Get-GatecraftField -Receipt $Record -Name 'receipt_id'
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$') {
        $Issues.Add((New-GatecraftProtocolIssue -Code 'recovery.id-malformed' -Message "Line $($Record.LineNumber) has a malformed recovery receipt_id." -Line $Record.LineNumber -KnownSecret $KnownSecret))
    }

    if ((Get-GatecraftField -Receipt $Record -Name 'mode') -cne 'attended') {
        $Issues.Add((New-GatecraftProtocolIssue -Code 'recovery.mode-not-attended' -Message "Line $($Record.LineNumber) recovery records are permitted only with mode=attended." -Line $Record.LineNumber -KnownSecret $KnownSecret))
    }

    $observedAt = Get-GatecraftField -Receipt $Record -Name 'observed_at'
    if (-not (Test-GatecraftIso8601 -Value $observedAt)) {
        $Issues.Add((New-GatecraftProtocolIssue -Code 'recovery.timestamp-invalid' -Message "Line $($Record.LineNumber) observed_at is not a valid timezone-qualified ISO-8601 timestamp." -Line $Record.LineNumber -KnownSecret $KnownSecret))
    }

    $externalMergeOid = Get-GatecraftField -Receipt $Record -Name 'external_merge_oid'
    if ($externalMergeOid -cnotmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
        $Issues.Add((New-GatecraftProtocolIssue -Code 'recovery.external-merge-oid-invalid' -Message "Line $($Record.LineNumber) external_merge_oid must be a full lowercase Git object ID." -Line $Record.LineNumber -KnownSecret $KnownSecret))
    }

    $subjectId = Get-GatecraftField -Receipt $Record -Name 'subject_id'
    if ($subjectId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$') {
        $Issues.Add((New-GatecraftProtocolIssue -Code 'recovery.subject-id-malformed' -Message "Line $($Record.LineNumber) subject_id must identify the exact bead or external-merge drift subject." -Line $Record.LineNumber -KnownSecret $KnownSecret))
    }

    $artifactHash = Get-GatecraftField -Receipt $Record -Name 'artifact_sha'
    if ($artifactHash -cnotmatch '^[0-9A-F]{64}$') {
        $Issues.Add((New-GatecraftProtocolIssue -Code 'recovery.artifact-hash-invalid' -Message "Line $($Record.LineNumber) artifact_sha must be exactly 64 uppercase hexadecimal characters." -Line $Record.LineNumber -KnownSecret $KnownSecret))
    }

    foreach ($field in @('missing_evidence', 'user_decision')) {
        if (-not $Record.Quoted.Contains($field) -or -not $Record.Quoted[$field]) {
            $Issues.Add((New-GatecraftProtocolIssue -Code 'recovery.quoting-required' -Message "Line $($Record.LineNumber) field '$field' must be quoted." -Line $Record.LineNumber -KnownSecret $KnownSecret))
        }
        $value = Get-GatecraftField -Receipt $Record -Name $field
        if (-not (Test-GatecraftRecoveryQuotedText -Value $value)) {
            $Issues.Add((New-GatecraftProtocolIssue -Code 'recovery.text-invalid' -Message "Line $($Record.LineNumber) field '$field' must be nonempty, trimmed NFC text of at most 2048 characters without controls, Unicode format characters, or line/paragraph separators." -Line $Record.LineNumber -KnownSecret $KnownSecret))
        }
    }
}

function Test-GatecraftRecoveryRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Record,
        [hashtable] $KnownSecret = @{}
    )

    $issues = [Collections.Generic.List[object]]::new()
    $parsed = ConvertFrom-GatecraftReceiptLine -Line $Record -KnownSecret $KnownSecret
    foreach ($errorItem in $parsed.Errors) {
        $issues.Add($errorItem)
    }

    if ($parsed.Type -cne 'RECOVERY') {
        $issues.Add((New-GatecraftProtocolIssue -Code 'recovery.prefix-invalid' -Message 'The supplied line is not a RECOVERY record.' -Line 1 -KnownSecret $KnownSecret))
    }
    else {
        Add-GatecraftRecoveryIssues -Record $parsed -Issues $issues -KnownSecret $KnownSecret
    }

    $safeFields = [ordered]@{}
    foreach ($key in $parsed.Fields.Keys) {
        $safeFields[$key] = Protect-GatecraftText -Text $parsed.Fields[$key] -KnownSecret $KnownSecret
    }
    $isValid = ($issues.Count -eq 0)

    [pscustomobject][ordered]@{
        Protocol = 'gatecraft-recovery/v1'
        IsValid = $isValid
        Decision = if ($isValid) { 'audit-only' } else { 'block' }
        Qualifies = $false
        QualificationReason = 'recovery.audit-only'
        Reasons = @($issues | ForEach-Object { $_.Code })
        Errors = @($issues)
        Record = [pscustomobject][ordered]@{
            Prefix = $parsed.Type
            Line = $parsed.LineNumber
            IsValid = $parsed.IsValid
            Fields = $safeFields
        }
    }
}

function ConvertTo-GatecraftRecoveryProjection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ValidationResult,
        [hashtable] $KnownSecret = @{}
    )

    $record = $ValidationResult.Record
    $fieldProjection = [ordered]@{}
    foreach ($key in @('receipt_id', 'mode', 'observed_at', 'external_merge_oid', 'subject_id', 'artifact_sha')) {
        if ($null -ne $record -and $null -ne $record.Fields -and $record.Fields.Contains($key)) {
            $fieldProjection[$key] = Protect-GatecraftText -Text $record.Fields[$key] -KnownSecret $KnownSecret
        }
    }

    $reasonProjection = foreach ($reason in @($ValidationResult.Reasons)) {
        Protect-GatecraftText -Text $reason -KnownSecret $KnownSecret
    }
    $projection = [ordered]@{
        protocol = 'gatecraft-recovery/v1'
        decision = if ([bool] $ValidationResult.IsValid) { 'audit-only' } else { 'block' }
        valid = [bool] $ValidationResult.IsValid
        qualifies = $false
        qualification_reason = 'recovery.audit-only'
        reasons = @($reasonProjection)
        record = [ordered]@{
            prefix = if ($null -ne $record -and $record.Prefix -ceq 'RECOVERY') { 'RECOVERY' } else { '' }
            line = if ($null -ne $record) { [int] $record.Line } else { 0 }
            fields = $fieldProjection
            omitted_fields = @('missing_evidence', 'user_decision')
        }
    }

    $json = $projection | ConvertTo-Json -Depth 8 -Compress
    return Protect-GatecraftText -Text $json -KnownSecret $KnownSecret
}

function Test-GatecraftVerificationChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Receipt,
        [hashtable] $KnownSecret = @{}
    )

    $issues = [Collections.Generic.List[object]]::new()
    $parsed = [Collections.Generic.List[object]]::new()

    for ($index = 0; $index -lt $Receipt.Count; $index++) {
        $item = ConvertFrom-GatecraftReceiptLine -Line $Receipt[$index] -LineNumber ($index + 1) -KnownSecret $KnownSecret
        $item | Add-Member -NotePropertyName Index -NotePropertyValue ($index + 1)
        $parsed.Add($item)
        foreach ($errorItem in $item.Errors) {
            $issues.Add($errorItem)
        }
        if (-not $item.IsValid -and $Receipt[$index].StartsWith('REVIEW_BLOCK', [StringComparison]::Ordinal)) {
            $issues.Add((New-GatecraftProtocolIssue -Code 'review.block-malformed' -Message "Line $($index + 1) is a malformed REVIEW_BLOCK and therefore blocks." -Line ($index + 1) -KnownSecret $KnownSecret))
        }
    }

    $idMap = @{}
    foreach ($item in $parsed) {
        $id = Get-GatecraftField -Receipt $item -Name 'receipt_id'
        if ($null -eq $id) {
            continue
        }
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$') {
            $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.id-malformed' -Message "Line $($item.LineNumber) has a malformed receipt_id." -Line $item.LineNumber -KnownSecret $KnownSecret))
        }
        if ($idMap.ContainsKey($id)) {
            $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.id-duplicate' -Message "Line $($item.LineNumber) duplicates receipt_id '$id'." -Line $item.LineNumber -KnownSecret $KnownSecret))
        }
        else {
            $idMap[$id] = $item
        }
    }

    foreach ($item in $parsed) {
        if ($item.Type -ceq 'RECOVERY') {
            Add-GatecraftRecoveryIssues -Record $item -Issues $issues -KnownSecret $KnownSecret
            continue
        }

        $protocol = Get-GatecraftField -Receipt $item -Name 'protocol'
        if ($null -ne $protocol -and $protocol -cne 'verification/v2') {
            $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.protocol-invalid' -Message "Line $($item.LineNumber) does not declare protocol verification/v2." -Line $item.LineNumber -KnownSecret $KnownSecret))
        }

        foreach ($timestampField in @('verified_at', 'reviewed_at')) {
            $timestamp = Get-GatecraftField -Receipt $item -Name $timestampField
            if ($null -ne $timestamp -and -not (Test-GatecraftIso8601 -Value $timestamp)) {
                $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.timestamp-invalid' -Message "Line $($item.LineNumber) field '$timestampField' is not a valid timezone-qualified ISO-8601 timestamp." -Line $item.LineNumber -KnownSecret $KnownSecret))
            }
        }

        $artifactHash = Get-GatecraftField -Receipt $item -Name 'artifact_sha'
        if ($null -ne $artifactHash -and $artifactHash -cnotmatch '^[0-9A-F]{64}$') {
            $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.artifact-hash-invalid' -Message "Line $($item.LineNumber) artifact_sha must be exactly 64 uppercase hexadecimal characters." -Line $item.LineNumber -KnownSecret $KnownSecret))
        }

        foreach ($gitField in @('commit', 'main')) {
            $gitHash = Get-GatecraftField -Receipt $item -Name $gitField
            if ($null -ne $gitHash -and $gitHash -cnotmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
                $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.git-hash-invalid' -Message "Line $($item.LineNumber) field '$gitField' must be a full lowercase Git SHA." -Line $item.LineNumber -KnownSecret $KnownSecret))
            }
        }

        foreach ($identityField in @('verified_by', 'reviewer', 'source_id', 'review_id')) {
            $identity = Get-GatecraftField -Receipt $item -Name $identityField
            if ($null -ne $identity -and $identity -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$') {
                $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.identity-invalid' -Message "Line $($item.LineNumber) field '$identityField' is malformed." -Line $item.LineNumber -KnownSecret $KnownSecret))
            }
        }

        foreach ($referenceField in @('baseline_ref', 'integration_ref', 'review_ref')) {
            $reference = Get-GatecraftField -Receipt $item -Name $referenceField
            if ($null -eq $reference) {
                continue
            }
            if (-not $idMap.ContainsKey($reference)) {
                $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.reference-missing' -Message "Line $($item.LineNumber) field '$referenceField' names an unknown receipt." -Line $item.LineNumber -KnownSecret $KnownSecret))
            }
            elseif ($idMap[$reference].Index -ge $item.Index) {
                $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.reference-forward' -Message "Line $($item.LineNumber) field '$referenceField' must reference an earlier receipt." -Line $item.LineNumber -KnownSecret $KnownSecret))
            }
        }
    }

    $phaseReceipts = @($parsed | Where-Object { $_.Type -eq 'VERIFY_PHASE' })
    $baselines = @($phaseReceipts | Where-Object { (Get-GatecraftField -Receipt $_ -Name 'phase') -ceq 'baseline' })
    $integrations = @($phaseReceipts | Where-Object { (Get-GatecraftField -Receipt $_ -Name 'phase') -ceq 'integration/premerge' })
    $finals = @($parsed | Where-Object { $_.Type -eq 'VERIFIED' })
    $reviews = @($parsed | Where-Object { $_.Type -in @('REVIEW_PASS', 'REVIEW_BLOCK', 'REVIEW_INCONCLUSIVE', 'REVIEW_CLARIFY') })
    $recoveries = @($parsed | Where-Object { $_.Type -eq 'RECOVERY' })

    foreach ($item in $recoveries) {
        $issues.Add((New-GatecraftProtocolIssue -Code 'verification.recovery-nonqualifying' -Message "Line $($item.LineNumber) is an audit-only RECOVERY record and cannot participate in or repair verification/v2." -Line $item.LineNumber -KnownSecret $KnownSecret))
    }

    if ($baselines.Count -ne 1) {
        $issues.Add((New-GatecraftProtocolIssue -Code 'verification.baseline-count' -Message "Require exactly one baseline observation receipt; found $($baselines.Count)." -KnownSecret $KnownSecret))
    }
    if ($integrations.Count -ne 1) {
        $issues.Add((New-GatecraftProtocolIssue -Code 'verification.integration-count' -Message "Require exactly one integration/premerge pass receipt; found $($integrations.Count)." -KnownSecret $KnownSecret))
    }
    if ($finals.Count -ne 1) {
        $issues.Add((New-GatecraftProtocolIssue -Code 'verification.final-count' -Message "Require exactly one postmerge VERIFIED receipt; found $($finals.Count)." -KnownSecret $KnownSecret))
    }

    foreach ($item in $phaseReceipts) {
        $phase = Get-GatecraftField -Receipt $item -Name 'phase'
        if ($phase -notin @('baseline', 'integration/premerge')) {
            $issues.Add((New-GatecraftProtocolIssue -Code 'verification.phase-invalid' -Message "Line $($item.LineNumber) uses an invalid supporting phase." -Line $item.LineNumber -KnownSecret $KnownSecret))
        }
        $exit = Get-GatecraftField -Receipt $item -Name 'exit'
        $result = Get-GatecraftField -Receipt $item -Name 'result'
        if ($phase -ceq 'baseline') {
            if ($exit -cnotmatch '^[0-9]+$' -or $result -cne 'observed') {
                $issues.Add((New-GatecraftProtocolIssue -Code 'verification.baseline-not-observed' -Message "Line $($item.LineNumber) baseline must carry the actual unsigned decimal exit token and result=observed." -Line $item.LineNumber -KnownSecret $KnownSecret))
            }
            if ($exit -cmatch '^[0-9]+$' -and $exit -cmatch '[1-9]') {
                $requiredItems = Get-GatecraftEvidenceList -Value (Get-GatecraftField -Receipt $item -Name 'required')
                $observedItems = Get-GatecraftEvidenceList -Value (Get-GatecraftField -Receipt $item -Name 'evidence')
                if (
                    $null -eq $requiredItems -or
                    $null -eq $observedItems -or
                    'baseline-expected-gap' -cnotin @($requiredItems) -or
                    'baseline-expected-gap' -cnotin @($observedItems)
                ) {
                    $issues.Add((New-GatecraftProtocolIssue -Code 'verification.baseline-expected-gap-missing' -Message "Line $($item.LineNumber) nonzero baseline must declare and observe evidence identifier 'baseline-expected-gap'." -Line $item.LineNumber -KnownSecret $KnownSecret))
                }
            }
        }
        elseif ($phase -ceq 'integration/premerge' -and ($exit -cne '0' -or $result -cne 'pass')) {
            $issues.Add((New-GatecraftProtocolIssue -Code 'verification.phase-not-pass' -Message "Line $($item.LineNumber) integration/premerge receipt must carry exit=0 and result=pass." -Line $item.LineNumber -KnownSecret $KnownSecret))
        }
        foreach ($quotedField in @('gate', 'required', 'evidence')) {
            if (-not $item.Quoted.Contains($quotedField) -or -not $item.Quoted[$quotedField]) {
                $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.quoting-required' -Message "Line $($item.LineNumber) field '$quotedField' must be quoted." -Line $item.LineNumber -KnownSecret $KnownSecret))
            }
        }
        if ([string]::IsNullOrWhiteSpace((Get-GatecraftField -Receipt $item -Name 'gate'))) {
            $issues.Add((New-GatecraftProtocolIssue -Code 'verification.gate-empty' -Message "Line $($item.LineNumber) has an empty gate." -Line $item.LineNumber -KnownSecret $KnownSecret))
        }
    }

    foreach ($item in $finals) {
        if ((Get-GatecraftField -Receipt $item -Name 'phase') -cne 'postmerge') {
            $issues.Add((New-GatecraftProtocolIssue -Code 'verification.final-phase-invalid' -Message "Line $($item.LineNumber) VERIFIED receipt must declare phase=postmerge." -Line $item.LineNumber -KnownSecret $KnownSecret))
        }
        if ((Get-GatecraftField -Receipt $item -Name 'exit') -cne '0' -or (Get-GatecraftField -Receipt $item -Name 'result') -cne 'pass') {
            $issues.Add((New-GatecraftProtocolIssue -Code 'verification.final-not-pass' -Message "Line $($item.LineNumber) VERIFIED receipt must carry exit=0 and result=pass." -Line $item.LineNumber -KnownSecret $KnownSecret))
        }
        foreach ($quotedField in @('gate', 'required', 'evidence')) {
            if (-not $item.Quoted.Contains($quotedField) -or -not $item.Quoted[$quotedField]) {
                $issues.Add((New-GatecraftProtocolIssue -Code 'receipt.quoting-required' -Message "Line $($item.LineNumber) field '$quotedField' must be quoted." -Line $item.LineNumber -KnownSecret $KnownSecret))
            }
        }
        if ([string]::IsNullOrWhiteSpace((Get-GatecraftField -Receipt $item -Name 'gate'))) {
            $issues.Add((New-GatecraftProtocolIssue -Code 'verification.gate-empty' -Message "Line $($item.LineNumber) has an empty gate." -Line $item.LineNumber -KnownSecret $KnownSecret))
        }
        if ($item.Index -ne $parsed.Count) {
            $issues.Add((New-GatecraftProtocolIssue -Code 'verification.final-not-last' -Message "Line $($item.LineNumber) postmerge VERIFIED receipt must be the final receipt." -Line $item.LineNumber -KnownSecret $KnownSecret))
        }
    }

    $evidenceReceipts = @($phaseReceipts + $finals)
    $expectedRequired = $null
    foreach ($item in $evidenceReceipts) {
        $requiredItems = Get-GatecraftEvidenceList -Value (Get-GatecraftField -Receipt $item -Name 'required')
        $observedItems = Get-GatecraftEvidenceList -Value (Get-GatecraftField -Receipt $item -Name 'evidence')
        if ($null -eq $requiredItems) {
            $issues.Add((New-GatecraftProtocolIssue -Code 'verification.required-malformed' -Message "Line $($item.LineNumber) has malformed or duplicate required evidence identifiers." -Line $item.LineNumber -KnownSecret $KnownSecret))
            continue
        }
        if ($null -eq $observedItems) {
            $issues.Add((New-GatecraftProtocolIssue -Code 'verification.evidence-malformed' -Message "Line $($item.LineNumber) has malformed or duplicate observed evidence identifiers." -Line $item.LineNumber -KnownSecret $KnownSecret))
            continue
        }
        $requiredSorted = [string[]] @($requiredItems)
        [Array]::Sort($requiredSorted, [StringComparer]::Ordinal)
        $requiredCanonical = $requiredSorted -join ','
        if ($null -eq $expectedRequired) {
            $expectedRequired = $requiredCanonical
        }
        elseif ($requiredCanonical -cne $expectedRequired) {
            $issues.Add((New-GatecraftProtocolIssue -Code 'verification.requirements-conflict' -Message "Line $($item.LineNumber) changes the declared evidence requirements." -Line $item.LineNumber -KnownSecret $KnownSecret))
        }
        foreach ($requiredItem in $requiredItems) {
            if ($requiredItem -cnotin $observedItems) {
                $issues.Add((New-GatecraftProtocolIssue -Code 'verification.evidence-incomplete' -Message "Line $($item.LineNumber) omits required evidence '$requiredItem'." -Line $item.LineNumber -KnownSecret $KnownSecret))
            }
        }
    }

    $baseline = if ($baselines.Count -eq 1) { $baselines[0] } else { $null }
    $integration = if ($integrations.Count -eq 1) { $integrations[0] } else { $null }
    $final = if ($finals.Count -eq 1) { $finals[0] } else { $null }

    if ($null -ne $baseline -and $baseline.Fields.Contains('baseline_ref')) {
        $issues.Add((New-GatecraftProtocolIssue -Code 'verification.baseline-self-reference' -Message "Line $($baseline.LineNumber) baseline receipt must not contain baseline_ref." -Line $baseline.LineNumber -KnownSecret $KnownSecret))
    }
    if ($null -ne $integration -and $null -ne $baseline) {
        if ((Get-GatecraftField -Receipt $integration -Name 'baseline_ref') -cne (Get-GatecraftField -Receipt $baseline -Name 'receipt_id')) {
            $issues.Add((New-GatecraftProtocolIssue -Code 'verification.baseline-reference-broken' -Message "Line $($integration.LineNumber) does not reference the exact baseline receipt." -Line $integration.LineNumber -KnownSecret $KnownSecret))
        }
        if ($baseline.Index -ge $integration.Index) {
            $issues.Add((New-GatecraftProtocolIssue -Code 'verification.phase-order-invalid' -Message 'Place the baseline receipt before integration/premerge.' -KnownSecret $KnownSecret))
        }
    }

    $reviewPasses = @($reviews | Where-Object { $_.Type -eq 'REVIEW_PASS' })
    $reviewBlocks = @($reviews | Where-Object { $_.Type -eq 'REVIEW_BLOCK' })
    $reviewInconclusive = @($reviews | Where-Object { $_.Type -eq 'REVIEW_INCONCLUSIVE' })
    $reviewClarifications = @($reviews | Where-Object { $_.Type -eq 'REVIEW_CLARIFY' })
    $terminalReviewPass = $null

    if ($reviews.Count -eq 0) {
        $issues.Add((New-GatecraftProtocolIssue -Code 'review.missing' -Message 'Require an admissible SHA-bound review outcome.' -KnownSecret $KnownSecret))
    }
    if ($reviewInconclusive.Count -gt 0) {
        $issues.Add((New-GatecraftProtocolIssue -Code 'review.inconclusive' -Message 'REVIEW_INCONCLUSIVE never unblocks a final pass.' -Line $reviewInconclusive[0].LineNumber -KnownSecret $KnownSecret))
    }
    if ($reviewClarifications.Count -gt 1) {
        $issues.Add((New-GatecraftProtocolIssue -Code 'review.clarification-limit' -Message 'Permit at most one clarification in a review identity.' -Line $reviewClarifications[1].LineNumber -KnownSecret $KnownSecret))
    }

    if ($reviews.Count -gt 0) {
        $original = $reviews[0]
        foreach ($item in $reviews) {
            foreach ($identityField in @('source_id', 'review_id', 'artifact_sha')) {
                if ((Get-GatecraftField -Receipt $item -Name $identityField) -cne (Get-GatecraftField -Receipt $original -Name $identityField)) {
                    $issues.Add((New-GatecraftProtocolIssue -Code 'review.identity-conflict' -Message "Line $($item.LineNumber) changes '$identityField' within one review chain." -Line $item.LineNumber -KnownSecret $KnownSecret))
                }
            }
            if ((Get-GatecraftField -Receipt $item -Name 'reviewer') -cne (Get-GatecraftField -Receipt $original -Name 'reviewer')) {
                $issues.Add((New-GatecraftProtocolIssue -Code 'review.reviewer-swap' -Message "Line $($item.LineNumber) changes the original reviewer." -Line $item.LineNumber -KnownSecret $KnownSecret))
            }
        }

        if ($reviews.Count -eq 1 -and $reviews[0].Type -eq 'REVIEW_PASS' -and -not $reviews[0].Fields.Contains('review_ref')) {
            $terminalReviewPass = $reviews[0]
        }
        elseif (
            $reviews.Count -eq 3 -and
            $reviews[0].Type -eq 'REVIEW_BLOCK' -and
            $reviews[1].Type -eq 'REVIEW_CLARIFY' -and
            $reviews[2].Type -eq 'REVIEW_PASS' -and
            (Get-GatecraftField -Receipt $reviews[1] -Name 'review_ref') -ceq (Get-GatecraftField -Receipt $reviews[0] -Name 'receipt_id') -and
            (Get-GatecraftField -Receipt $reviews[2] -Name 'review_ref') -ceq (Get-GatecraftField -Receipt $reviews[1] -Name 'receipt_id')
        ) {
            $terminalReviewPass = $reviews[2]
        }
        else {
            if ($reviewBlocks.Count -gt 0) {
                $issues.Add((New-GatecraftProtocolIssue -Code 'review.block-unresolved' -Message 'A REVIEW_BLOCK is unresolved unless one same-identity clarification leads to a linked REVIEW_PASS.' -Line $reviewBlocks[0].LineNumber -KnownSecret $KnownSecret))
            }
            if ($reviewClarifications.Count -gt 0) {
                $issues.Add((New-GatecraftProtocolIssue -Code 'review.clarification-invalid' -Message 'Link the single clarification from a block to a same-reviewer terminal pass.' -Line $reviewClarifications[0].LineNumber -KnownSecret $KnownSecret))
            }
            if ($reviewPasses.Count -gt 1 -or ($reviewPasses.Count -eq 1 -and $reviews.Count -ne 1)) {
                $issues.Add((New-GatecraftProtocolIssue -Code 'review.receipts-conflict' -Message 'Review receipts conflict and cannot produce an admissible outcome.' -KnownSecret $KnownSecret))
            }
        }
    }

    if ($reviews.Count -gt 0 -and $null -eq $terminalReviewPass) {
        $issues.Add((New-GatecraftProtocolIssue -Code 'review.outcome-inadmissible' -Message 'The supplied review receipts do not produce one admissible terminal REVIEW_PASS.' -KnownSecret $KnownSecret))
    }

    if ($null -ne $integration -and $null -ne $terminalReviewPass) {
        if ((Get-GatecraftField -Receipt $terminalReviewPass -Name 'artifact_sha') -cne (Get-GatecraftField -Receipt $integration -Name 'artifact_sha')) {
            $issues.Add((New-GatecraftProtocolIssue -Code 'review.artifact-mismatch' -Message 'Bind the review outcome to the exact integration/premerge artifact SHA.' -Line $terminalReviewPass.LineNumber -KnownSecret $KnownSecret))
        }
        if ($integration.Index -ge $terminalReviewPass.Index) {
            $issues.Add((New-GatecraftProtocolIssue -Code 'review.order-invalid' -Message 'Place the review outcome after integration/premerge and before postmerge.' -KnownSecret $KnownSecret))
        }
    }

    if ($null -ne $final) {
        if ($null -ne $baseline -and (Get-GatecraftField -Receipt $final -Name 'baseline_ref') -cne (Get-GatecraftField -Receipt $baseline -Name 'receipt_id')) {
            $issues.Add((New-GatecraftProtocolIssue -Code 'verification.final-baseline-reference-broken' -Message 'Bind the final receipt to the exact baseline receipt.' -Line $final.LineNumber -KnownSecret $KnownSecret))
        }
        if ($null -ne $integration) {
            if ((Get-GatecraftField -Receipt $final -Name 'integration_ref') -cne (Get-GatecraftField -Receipt $integration -Name 'receipt_id')) {
                $issues.Add((New-GatecraftProtocolIssue -Code 'verification.final-integration-reference-broken' -Message 'Bind the final receipt to the exact integration/premerge receipt.' -Line $final.LineNumber -KnownSecret $KnownSecret))
            }
            if ((Get-GatecraftField -Receipt $final -Name 'artifact_sha') -cne (Get-GatecraftField -Receipt $integration -Name 'artifact_sha')) {
                $issues.Add((New-GatecraftProtocolIssue -Code 'verification.final-artifact-mismatch' -Message 'Bind the postmerge final receipt to the exact reviewed artifact SHA.' -Line $final.LineNumber -KnownSecret $KnownSecret))
            }
        }
        if ($null -ne $terminalReviewPass -and (Get-GatecraftField -Receipt $final -Name 'review_ref') -cne (Get-GatecraftField -Receipt $terminalReviewPass -Name 'receipt_id')) {
            $issues.Add((New-GatecraftProtocolIssue -Code 'verification.final-review-reference-broken' -Message 'Bind the final receipt to the admissible terminal REVIEW_PASS.' -Line $final.LineNumber -KnownSecret $KnownSecret))
        }
    }

    $safeReceipts = foreach ($item in $parsed) {
        $safeFields = [ordered]@{}
        foreach ($key in $item.Fields.Keys) {
            $safeFields[$key] = Protect-GatecraftText -Text $item.Fields[$key] -KnownSecret $KnownSecret
        }
        [pscustomobject][ordered]@{
            Prefix = $item.Type
            Line = $item.LineNumber
            IsValid = $item.IsValid
            Fields = $safeFields
        }
    }

    [pscustomobject][ordered]@{
        Protocol = 'verification/v2'
        IsValid = ($issues.Count -eq 0)
        Decision = if ($issues.Count -eq 0) { 'pass' } else { 'block' }
        Reasons = @($issues | ForEach-Object { $_.Code })
        Errors = @($issues)
        Receipts = @($safeReceipts)
    }
}

function ConvertTo-GatecraftDashboardProjection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ValidationResult,
        [hashtable] $KnownSecret = @{}
    )

    $receiptProjection = foreach ($receipt in @($ValidationResult.Receipts)) {
        $fields = [ordered]@{}
        foreach ($key in @('receipt_id', 'phase', 'reviewer', 'source_id', 'review_id', 'artifact_sha', 'gate', 'result')) {
            if ($receipt.Fields.Contains($key)) {
                $fields[$key] = Protect-GatecraftText -Text $receipt.Fields[$key] -KnownSecret $KnownSecret
            }
        }
        [ordered]@{ prefix = $receipt.Prefix; line = $receipt.Line; fields = $fields }
    }
    $projection = [ordered]@{
        protocol = 'verification/v2'
        decision = $ValidationResult.Decision
        valid = [bool] $ValidationResult.IsValid
        reasons = @($ValidationResult.Reasons)
        receipts = @($receiptProjection)
    }
    $json = $projection | ConvertTo-Json -Depth 8 -Compress
    return Protect-GatecraftText -Text $json -KnownSecret $KnownSecret
}

function Get-GatecraftAggregateFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $PathList
    )

    if ($PathList.Count -eq 0) {
        throw 'Declare at least one path before computing an artifact fingerprint.'
    }
    $rootPath = [IO.Path]::GetFullPath($Root)
    if (-not [IO.Directory]::Exists($rootPath)) {
        throw 'Fingerprint root does not exist or is not a directory.'
    }
    $rootInfo = [IO.DirectoryInfo]::new($rootPath)
    if (
        ($rootInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not [string]::IsNullOrEmpty($rootInfo.LinkTarget)
    ) {
        throw 'Reject a symlink or reparse-point fingerprint root.'
    }
    $rootPrefix = $rootPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $entries = [Collections.Generic.List[object]]::new()

    foreach ($declaredPath in $PathList) {
        if (
            [string]::IsNullOrWhiteSpace($declaredPath) -or
            $declaredPath.IndexOfAny([char[]] "`t`r`n") -ge 0 -or
            $declaredPath.Contains('\') -or
            [IO.Path]::IsPathRooted($declaredPath) -or
            $declaredPath -match '[\x00-\x1F\x7F:]' -or
            -not $declaredPath.IsNormalized([Text.NormalizationForm]::FormC)
        ) {
            throw "Reject ambiguous declared path '$declaredPath'."
        }
        $segments = @($declaredPath -split '/')
        $ambiguousSegments = @($segments | Where-Object {
            $_ -in @('', '.', '..') -or
            $_.EndsWith('.', [StringComparison]::Ordinal) -or
            $_.EndsWith(' ', [StringComparison]::Ordinal) -or
            $_ -match '^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'
        })
        if ($segments.Count -eq 0 -or $ambiguousSegments.Count -gt 0) {
            throw "Reject ambiguous declared path '$declaredPath'."
        }
        if (-not $seen.Add($declaredPath)) {
            throw "Reject duplicate declared path '$declaredPath'."
        }

        $fullPath = $rootPath
        for ($segmentIndex = 0; $segmentIndex -lt $segments.Count; $segmentIndex++) {
            $fullPath = [IO.Path]::GetFullPath([IO.Path]::Combine($fullPath, $segments[$segmentIndex]))
            if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Reject path outside the fingerprint root: '$declaredPath'."
            }

            $isDirectory = [IO.Directory]::Exists($fullPath)
            $isFile = [IO.File]::Exists($fullPath)
            if (-not $isDirectory -and -not $isFile) {
                throw "Fingerprint path component is missing: '$declaredPath'."
            }

            $componentInfo = if ($isDirectory) { [IO.DirectoryInfo]::new($fullPath) } else { [IO.FileInfo]::new($fullPath) }
            if (
                ($componentInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                -not [string]::IsNullOrEmpty($componentInfo.LinkTarget)
            ) {
                throw "Reject a symbolic link, junction, mount, or reparse-point fingerprint path component: '$declaredPath'."
            }

            $isFinal = ($segmentIndex -eq $segments.Count - 1)
            if ((-not $isFinal -and -not $isDirectory) -or ($isFinal -and -not $isFile)) {
                throw "Fingerprint path is missing or not a file: '$declaredPath'."
            }
        }

        $bytes = [IO.File]::ReadAllBytes($fullPath)
        $fileHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $entries.Add([pscustomobject][ordered]@{ Path = $declaredPath; Hash = $fileHash })
    }

    $lines = @($entries | ForEach-Object { "$($_.Path)`t$($_.Hash)" })
    $payload = $lines -join "`n"
    $payloadBytes = [Text.UTF8Encoding]::new($false).GetBytes($payload)
    $aggregate = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payloadBytes))

    [pscustomobject][ordered]@{
        Algorithm = 'SHA256'
        AggregateHash = $aggregate
        CanonicalPayload = $payload
        Entries = @($entries)
    }
}

function Get-GatecraftEventProperty {
    param(
        [Parameter(Mandatory)] $Event,
        [Parameter(Mandatory)][string] $Name
    )

    $property = $Event.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Resolve-GatecraftRetrySequence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Event,
        [hashtable] $KnownSecret = @{}
    )

    $issues = [Collections.Generic.List[object]]::new()
    $reserved = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $reservedOrder = [Collections.Generic.List[string]]::new()
    $repairableFailures = @{}
    $taskFailures = @{}
    $currentAttempt = $null
    $awaitingOutcome = $false
    $mode = 'reserve'
    $decision = 'reserve-attempt'
    $spawnCount = 0
    $taskAttemptCount = 0

    for ($index = 0; $index -lt $Event.Count; $index++) {
        $line = $index + 1
        $item = $Event[$index]
        $kind = [string] (Get-GatecraftEventProperty -Event $item -Name 'kind')
        $attemptId = [string] (Get-GatecraftEventProperty -Event $item -Name 'attempt_id')
        if ($kind -notin @('reserve', 'spawn', 'outcome')) {
            $issues.Add((New-GatecraftProtocolIssue -Code 'retry.event-kind-invalid' -Message "Retry event $line has an invalid kind." -Line $line -KnownSecret $KnownSecret))
            $mode = 'stop'
            $decision = 'stop-invalid-sequence'
            continue
        }
        if ($attemptId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$') {
            $issues.Add((New-GatecraftProtocolIssue -Code 'retry.attempt-id-invalid' -Message "Retry event $line has a malformed attempt_id." -Line $line -KnownSecret $KnownSecret))
            $mode = 'stop'
            $decision = 'stop-invalid-sequence'
            continue
        }

        $allowedProperties = switch ($kind) {
            'reserve' { @('kind', 'attempt_id') }
            'spawn' { @('kind', 'attempt_id', 'worker_id') }
            'outcome' { @('kind', 'attempt_id', 'class', 'process_state', 'failure_id', 'workspace_state') }
        }
        foreach ($property in $item.PSObject.Properties.Name) {
            if ($property -notin $allowedProperties) {
                $issues.Add((New-GatecraftProtocolIssue -Code 'retry.event-field-unknown' -Message "Retry event $line contains unknown field '$property'." -Line $line -KnownSecret $KnownSecret))
                $mode = 'stop'
                $decision = 'stop-invalid-sequence'
            }
        }

        switch ($kind) {
            'reserve' {
                if ($mode -ne 'reserve' -or $awaitingOutcome) {
                    $issues.Add((New-GatecraftProtocolIssue -Code 'retry.reserve-not-allowed' -Message "Retry event $line cannot reserve a new attempt in the current state." -Line $line -KnownSecret $KnownSecret))
                    $mode = 'stop'
                    $decision = 'stop-invalid-sequence'
                    continue
                }
                if (-not $reserved.Add($attemptId)) {
                    $issues.Add((New-GatecraftProtocolIssue -Code 'retry.attempt-id-duplicate' -Message "Retry event $line reuses a previously reserved attempt ID." -Line $line -KnownSecret $KnownSecret))
                    $mode = 'stop'
                    $decision = 'stop-invalid-sequence'
                    continue
                }
                $reservedOrder.Add($attemptId)
                $currentAttempt = $attemptId
                $mode = 'spawn'
                $decision = 'spawn-reserved-attempt'
            }
            'spawn' {
                $workerId = [string] (Get-GatecraftEventProperty -Event $item -Name 'worker_id')
                if ($workerId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$') {
                    $issues.Add((New-GatecraftProtocolIssue -Code 'retry.worker-id-invalid' -Message "Retry event $line must bind the spawn to a valid worker_id." -Line $line -KnownSecret $KnownSecret))
                    $mode = 'stop'
                    $decision = 'stop-invalid-sequence'
                    continue
                }
                if ($mode -eq 'stop') {
                    $issues.Add((New-GatecraftProtocolIssue -Code 'retry.spawn-after-stop' -Message "Retry event $line attempts a spawn after a fail-closed stop." -Line $line -KnownSecret $KnownSecret))
                    continue
                }
                if ($awaitingOutcome -or $mode -notin @('spawn', 'spawn-same') -or $attemptId -cne $currentAttempt -or -not $reserved.Contains($attemptId)) {
                    $issues.Add((New-GatecraftProtocolIssue -Code 'retry.spawn-without-reservation' -Message "Retry event $line does not match a reserved spawnable attempt." -Line $line -KnownSecret $KnownSecret))
                    $mode = 'stop'
                    $decision = 'stop-invalid-sequence'
                    continue
                }
                if ($spawnCount -ge 3) {
                    $issues.Add((New-GatecraftProtocolIssue -Code 'retry.spawn-cap' -Message 'Reject every worker spawn beyond the global cap of three.' -Line $line -KnownSecret $KnownSecret))
                    $mode = 'stop'
                    $decision = 'stop-global-spawn-cap'
                    continue
                }
                $spawnCount++
                $awaitingOutcome = $true
                $mode = 'outcome'
                $decision = 'await-outcome'
            }
            'outcome' {
                if (-not $awaitingOutcome -or $mode -ne 'outcome' -or $attemptId -cne $currentAttempt) {
                    $issues.Add((New-GatecraftProtocolIssue -Code 'retry.outcome-without-spawn' -Message "Retry event $line does not match an active spawned attempt." -Line $line -KnownSecret $KnownSecret))
                    $mode = 'stop'
                    $decision = 'stop-invalid-sequence'
                    continue
                }
                $awaitingOutcome = $false
                $class = [string] (Get-GatecraftEventProperty -Event $item -Name 'class')
                $processState = [string] (Get-GatecraftEventProperty -Event $item -Name 'process_state')
                if ($class -notin @('task', 'infrastructure/pre-start-repairable', 'crash/post-start-systemic', 'quota')) {
                    $issues.Add((New-GatecraftProtocolIssue -Code 'retry.class-invalid' -Message "Retry event $line has an invalid post-hoc class." -Line $line -KnownSecret $KnownSecret))
                    $mode = 'stop'
                    $decision = 'stop-invalid-sequence'
                    continue
                }
                if ($processState -in @('alive', 'unknown', 'children-alive')) {
                    $issues.Add((New-GatecraftProtocolIssue -Code 'retry.process-tree-active' -Message "Retry event $line cannot declare completion while the worker process tree is not confirmed stopped." -Line $line -KnownSecret $KnownSecret))
                    $mode = 'stop'
                    $decision = 'stop-process-tree-active'
                    continue
                }
                if ($class -in @('infrastructure/pre-start-repairable', 'quota') -and $processState -cne 'not-started') {
                    $issues.Add((New-GatecraftProtocolIssue -Code 'retry.pre-start-state-invalid' -Message "Retry event $line classifies a pre-start outcome without process_state=not-started." -Line $line -KnownSecret $KnownSecret))
                    $mode = 'stop'
                    $decision = 'stop-invalid-sequence'
                    continue
                }
                if ($class -in @('task', 'crash/post-start-systemic') -and $processState -cne 'exited') {
                    $issues.Add((New-GatecraftProtocolIssue -Code 'retry.post-start-state-invalid' -Message "Retry event $line classifies a post-start outcome without process_state=exited." -Line $line -KnownSecret $KnownSecret))
                    $mode = 'stop'
                    $decision = 'stop-invalid-sequence'
                    continue
                }

                switch ($class) {
                    'quota' {
                        $mode = 'spawn-same'
                        $decision = 'retry-same-attempt-after-quota-policy'
                    }
                    'infrastructure/pre-start-repairable' {
                        $count = if ($repairableFailures.ContainsKey($attemptId)) { [int] $repairableFailures[$attemptId] + 1 } else { 1 }
                        $repairableFailures[$attemptId] = $count
                        if ($count -eq 1) {
                            $mode = 'spawn-same'
                            $decision = 'relaunch-same-attempt-once'
                        }
                        else {
                            $mode = 'stop'
                            $decision = 'stop-repairable-relaunch-exhausted'
                        }
                    }
                    'crash/post-start-systemic' {
                        $taskAttemptCount++
                        $mode = 'stop'
                        $decision = 'stop-systemic-post-start-crash'
                    }
                    'task' {
                        $taskAttemptCount++
                        $failureId = [string] (Get-GatecraftEventProperty -Event $item -Name 'failure_id')
                        if ([string]::IsNullOrEmpty($failureId)) {
                            $failureId = 'task'
                        }
                        $failureCount = if ($taskFailures.ContainsKey($failureId)) { [int] $taskFailures[$failureId] + 1 } else { 1 }
                        $taskFailures[$failureId] = $failureCount
                        if ($taskAttemptCount -ge 3) {
                            $mode = 'stop'
                            $decision = 'stop-task-attempt-cap'
                        }
                        elseif ($failureCount -ge 2) {
                            $mode = 'stop'
                            $decision = 'stop-repeated-task-failure'
                        }
                        else {
                            $currentAttempt = $null
                            $mode = 'reserve'
                            $decision = 'reserve-new-task-attempt'
                        }
                    }
                }

                if ($spawnCount -ge 3 -and $mode -ne 'stop') {
                    $mode = 'stop'
                    $decision = 'stop-global-spawn-cap'
                }
            }
        }
    }

    [pscustomobject][ordered]@{
        IsValid = ($issues.Count -eq 0)
        Decision = $decision
        TaskAttemptCount = $taskAttemptCount
        TotalSpawnCount = $spawnCount
        AwaitingOutcome = $awaitingOutcome
        ReservedAttempts = @($reservedOrder)
        Reasons = @($issues | ForEach-Object { $_.Code })
        Errors = @($issues)
    }
}

function ConvertTo-GatecraftSanitizedFeedEvent {
    <#
    .SYNOPSIS
        Converts a VERIFIED/VERIFY_PHASE receipt line into the minimal sanitized fields
        needed to publish one gatecraft-debategui/v1 feed event via registry.ps1 publish-event.

    .DESCRIPTION
        Implements the evidence-hygiene "minimize by construction" boundary control
        (see gatecraft/references/evidence-hygiene.md): the sanitized event is built
        ONLY from a fixed allowlist of already-schema-validated scalar receipt fields
        (receipt_id, phase, gate, exit, result, verified_at). Free-text/quoted fields
        such as "evidence" are never read and never cross into the sanitized event.
        Every incorporated field is re-validated against the strict unquoted receipt
        token grammar regardless of how it was originally written, so a maliciously or
        carelessly quoted value cannot smuggle raw content through. Protect-GatecraftText
        is still applied as a final defensive pass for any caller-supplied known secret.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Line,
        [hashtable] $KnownSecret = @{},
        [AllowNull()] $CycleSequence = $null
    )

    $tokenPattern = '^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$'
    # Gate is often a quoted command line (e.g. "pwsh -NoProfile -File gate.ps1"), so it
    # uses the broader sanitized-fragment allowlist instead of the single-token pattern.
    # This is the exact charset registry.ps1's Assert-SanitizedEventText accepts for a
    # feed summary, so a gate value that passes here will also pass at publish time.
    $fragmentPattern = '^[A-Za-z0-9][A-Za-z0-9 ._:/+=-]{0,127}$'
    $parsed = ConvertFrom-GatecraftReceiptLine -Line $Line -KnownSecret $KnownSecret

    if (-not $parsed.IsValid -or $parsed.Type -cnotin @('VERIFIED', 'VERIFY_PHASE')) {
        return [pscustomobject][ordered]@{
            IsApplicable = $false
            Reason = 'event.not-applicable'
            EventType = $null; Outcome = $null; OccurredAt = $null; Summary = $null; EventId = $null; CycleSequence = $null
        }
    }

    $receiptId = Get-GatecraftField -Receipt $parsed -Name 'receipt_id'
    $phase = Get-GatecraftField -Receipt $parsed -Name 'phase'
    $gate = Get-GatecraftField -Receipt $parsed -Name 'gate'
    $exit = Get-GatecraftField -Receipt $parsed -Name 'exit'
    $result = Get-GatecraftField -Receipt $parsed -Name 'result'
    $verifiedAt = Get-GatecraftField -Receipt $parsed -Name 'verified_at'

    foreach ($candidate in @($receiptId, $phase, $exit, $result)) {
        if ($null -eq $candidate -or $candidate -cnotmatch $tokenPattern) {
            return [pscustomobject][ordered]@{
                IsApplicable = $false
                Reason = 'event.unsafe-field'
                EventType = $null; Outcome = $null; OccurredAt = $null; Summary = $null; EventId = $null; CycleSequence = $null
            }
        }
    }
    if ($null -eq $gate -or $gate -cnotmatch $fragmentPattern -or $gate.Contains('..', [StringComparison]::Ordinal) -or $gate.Contains('://', [StringComparison]::Ordinal) -or $gate -match '(?i)[a-z]:[\\/]') {
        return [pscustomobject][ordered]@{
            IsApplicable = $false
            Reason = 'event.unsafe-field'
            EventType = $null; Outcome = $null; OccurredAt = $null; Summary = $null; EventId = $null; CycleSequence = $null
        }
    }
    if ($result -cnotin @('pass', 'fail')) {
        return [pscustomobject][ordered]@{
            IsApplicable = $false
            Reason = 'event.result-unknown'
            EventType = $null; Outcome = $null; OccurredAt = $null; Summary = $null; EventId = $null; CycleSequence = $null
        }
    }
    if (-not (Test-GatecraftIso8601 -Value $verifiedAt)) {
        return [pscustomobject][ordered]@{
            IsApplicable = $false
            Reason = 'event.timestamp-invalid'
            EventType = $null; Outcome = $null; OccurredAt = $null; Summary = $null; EventId = $null; CycleSequence = $null
        }
    }

    $eventType = if ($parsed.Type -ceq 'VERIFIED') { 'verification' } else { 'verify-phase' }
    $outcome = if ($result -ceq 'pass') { 'verified' } else { 'verification-failed' }
    $summary = Protect-GatecraftText -Text "receipt=$receiptId phase=$phase gate=$gate exit=$exit result=$result" -KnownSecret $KnownSecret
    $eventIdSeed = [Text.UTF8Encoding]::new($false).GetBytes("$($parsed.Type)|$receiptId")
    $eventId = 'receipt-' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($eventIdSeed)).ToLowerInvariant().Substring(0, 32)

    return [pscustomobject][ordered]@{
        IsApplicable = $true
        Reason = 'event.applicable'
        EventType = $eventType
        Outcome = $outcome
        OccurredAt = $verifiedAt
        Summary = $summary
        EventId = $eventId
        CycleSequence = $CycleSequence
    }
}

Export-ModuleMember -Function @(
    'Protect-GatecraftText',
    'ConvertFrom-GatecraftReceiptLine',
    'Test-GatecraftRecoveryRecord',
    'ConvertTo-GatecraftRecoveryProjection',
    'Test-GatecraftVerificationChain',
    'ConvertTo-GatecraftDashboardProjection',
    'Get-GatecraftAggregateFingerprint',
    'Resolve-GatecraftRetrySequence',
    'ConvertTo-GatecraftSanitizedFeedEvent'
)
