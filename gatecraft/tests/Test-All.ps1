[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    [Console]::Error.WriteLine('Test-All requires PowerShell 7 or newer.')
    exit 1
}

$tests = @('Test-RecoveryProtocol.ps1', 'Test-ReceiptProtocol.ps1', 'Test-ProtocolContract.ps1', 'Test-ModelCatalog.ps1', 'Test-ModelCatalogValidation.ps1', 'Test-ModelSelection.ps1', 'Test-ModelDispatchPlan.ps1', 'Test-CycleEnd.ps1', 'Test-Guard.ps1')
foreach ($test in $tests) {
    & pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot $test)
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("Test-All failed: $test exit=$LASTEXITCODE")
        exit $LASTEXITCODE
    }
}

[Console]::Out.WriteLine("Test-All passed: $($tests.Count) Gatecraft gates.")
