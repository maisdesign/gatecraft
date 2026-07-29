[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Installs gatecraft's real git-hook enforcement (gatecraft-7dq): sets
# core.hooksPath to this skill copy's gatecraft/githooks/ directory so git
# itself invokes pre-merge-commit/pre-push automatically, instead of
# enforcement depending only on the orchestrator remembering to call
# enforce-gate.ps1 as a separate step. Idempotent: safe to run again.
#
# This REPLACES any existing core.hooksPath for the repository -- if the
# host project already uses its own hooks directory for other purposes,
# installing gatecraft's here will shadow it. Ask before running this on a
# repository with pre-existing hooks the user cares about; there is no
# multi-hooks-directory chaining in plain git.

$repoRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$topLevel = (& git -C $repoRoot rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$topLevel)) {
    throw "'$repoRoot' is not inside a git repository."
}
$topLevel = [IO.Path]::GetFullPath([string]$topLevel)

$hooksDir = Join-Path $topLevel 'gatecraft/githooks'
if (-not (Test-Path -LiteralPath $hooksDir -PathType Container)) {
    throw "Expected githooks directory not found at $hooksDir -- is the gatecraft skill folder present at the repository root?"
}
foreach ($hookName in @('pre-merge-commit', 'pre-push')) {
    $hookPath = Join-Path $hooksDir $hookName
    if (-not (Test-Path -LiteralPath $hookPath -PathType Leaf)) {
        throw "Expected hook script not found: $hookPath"
    }
}

$existing = (& git -C $topLevel config --get core.hooksPath 2>$null)
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$existing) -and [string]$existing -cne 'gatecraft/githooks') {
    [Console]::Error.WriteLine("GATECRAFT_GITHOOKS_INSTALL_FAILED code=hooks-path-conflict detail=`"core.hooksPath is already set to '$existing'; refusing to silently overwrite a pre-existing hooks directory. Confirm with the user before re-running.`"")
    exit 1
}

& git -C $topLevel config core.hooksPath 'gatecraft/githooks'
if ($LASTEXITCODE -ne 0) { throw 'git config core.hooksPath failed.' }

[Console]::Out.WriteLine("GATECRAFT_GITHOOKS_INSTALLED path=$hooksDir")
