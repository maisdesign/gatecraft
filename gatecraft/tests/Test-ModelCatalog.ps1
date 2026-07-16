[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Get-Freshness([datetime] $GeneratedAt, [datetime] $Now) { if (($Now - $GeneratedAt).TotalHours -le 72) { 'fresh' } else { 'stale' } }
function Get-Decision([string] $State, [bool] $Authority, [bool] $Online) {
    if ($State -eq 'fresh') { return 'use' }
    if ($State -eq 'stale' -and $Authority -and $Online) { return 'offer-startup-refresh' }
    if ($State -eq 'stale') { return 'require-per-launch-availability' }
    return 'stop-automatic-selection'
}

function Resolve-Refresh([string] $Result) { if ($Result -eq 'valid') { 'replace' } else { 'preserve-last-valid' } }
$reference = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../references/model-catalog.md'))
$origin = [datetime]'2026-07-16T00:00:00Z'
Assert-True ((Get-Freshness $origin $origin.AddHours(72)) -eq 'fresh') 'Catalog must remain fresh exactly at 72 hours.'
Assert-True ((Get-Freshness $origin $origin.AddHours(72.0001)) -eq 'stale') 'Catalog must become stale after 72 hours.'
Assert-True ((Get-Decision fresh $false $false) -eq 'use') 'Fresh catalog must be usable offline.'
Assert-True ((Get-Decision stale $true $true) -eq 'offer-startup-refresh') 'Only authorized online stale catalog may offer refresh.'
Assert-True ((Get-Decision stale $false $true) -eq 'require-per-launch-availability') 'Stale catalog without authority must not refresh.'
Assert-True ((Get-Decision unavailable $true $true) -eq 'stop-automatic-selection') 'Unavailable catalog must fail closed.'
Assert-True ((Get-Decision malformed $true $true) -eq 'stop-automatic-selection') 'Malformed catalog must fail closed.'
Assert-True ((Get-Decision source-conflict $true $true) -eq 'stop-automatic-selection') 'Conflicting sources must fail closed.'
Assert-True ((Resolve-Refresh failed) -eq 'preserve-last-valid') 'Refresh failure must preserve the last valid catalog.'
Assert-True ($reference -match 'background timer' -and $reference -match 'Network data is never trusted directly') 'Catalog contract must prohibit timer and direct-network trust.'
Assert-True ($reference -match 'credentials, prompts, tokens, PIDs, or raw provider responses') 'Catalog contract must define sanitization exclusions.'
Write-Host 'Model catalog gate passed: 72-hour boundary, stale, malformed, conflict, refresh failure, sanitization, and authority fixtures are deterministic.'
