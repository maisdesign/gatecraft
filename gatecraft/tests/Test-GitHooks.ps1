[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    [Console]::Error.WriteLine('Test-GitHooks requires PowerShell 7 or newer.')
    exit 1
}

# Integration gate for gatecraft's real git-hook enforcement (gatecraft-7dq).
# Exercises the ACTUAL gatecraft/githooks/pre-merge-commit and pre-push
# scripts through real `git merge`/`git push` invocations against scratch
# fixture repos -- not a re-test of enforce-gate.ps1's own logic (already
# covered by Test-EnforceGate.ps1), but proof that git itself invokes the
# hook and respects its exit code, and that the GATECRAFT_BEAD_ID /
# GATECRAFT_AUTOMATED_PUSH opt-in signals are honored exactly as designed:
# absent -> untouched (never breaks ordinary git usage); present -> a
# failing enforce-gate check genuinely aborts the git operation.

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$realHooksDir = Join-Path $repoRoot 'gatecraft/githooks'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$fixturePrefix = 'gatecraft-githooks-tests-'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ($fixturePrefix + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)

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

function Remove-FixtureRoot {
    param([Parameter(Mandatory)][string] $Path)
    if (-not [IO.Directory]::Exists($Path)) { return }
    try {
        $declared = [IO.Path]::GetFullPath($Path)
        $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).ProviderPath)
        $leaf = [IO.Path]::GetFileName($resolved)
        $parent = [IO.Path]::GetDirectoryName($resolved).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        if ($resolved -cne $declared -or $parent -cne $tempRoot -or -not $leaf.StartsWith($fixturePrefix, [StringComparison]::Ordinal)) {
            throw "Refuse fixture cleanup outside the exact unique temp root: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
        if ([IO.Directory]::Exists($resolved)) { throw "Fixture cleanup did not remove $resolved" }
    }
    catch { Add-Failure "Cleanup failure for ${Path}: $($_.Exception.Message)" }
}
trap { Remove-FixtureRoot -Path $testRoot }

function Invoke-GitAsEnv {
    # Runs `git @Arguments` with a clean, controlled environment: only the
    # named GATECRAFT_* variables are set (or entirely absent), so a value
    # left over in the test RUNNER's own environment can never leak into
    # the hook's decision -- the exact bug class this project has hit
    # before with PowerShell/env-var assumptions.
    param([Parameter(Mandatory)][string] $RepositoryPath, [Parameter(Mandatory)][string[]] $Arguments, [hashtable] $EnvVars = @{})
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = @(Get-Command git -CommandType Application)[0].Source
    $info.WorkingDirectory = $RepositoryPath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($name in @('GATECRAFT_BEAD_ID', 'GATECRAFT_ARTIFACT_SHA', 'GATECRAFT_LOW_RISK_NO_REVIEW_REQUIRED', 'GATECRAFT_AUTOMATED_PUSH')) {
        [void]$info.Environment.Remove($name)
    }
    foreach ($name in $EnvVars.Keys) { $info.Environment[$name] = [string]$EnvVars[$name] }
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Could not start git child process.' }
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'git child process exceeded its hard timeout.'
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $outTask.GetAwaiter().GetResult(); Error = $errorTask.GetAwaiter().GetResult() }
    }
    finally { $process.Dispose() }
}

function New-TestRepository {
    param([string] $Name)
    $path = Join-Path $testRoot $Name
    [void][IO.Directory]::CreateDirectory($path)
    Invoke-GitAsEnv -RepositoryPath $path -Arguments @('init', '--quiet', '-b', 'main') | Out-Null
    Invoke-GitAsEnv -RepositoryPath $path -Arguments @('config', 'user.email', 'test@example.com') | Out-Null
    Invoke-GitAsEnv -RepositoryPath $path -Arguments @('config', 'user.name', 'Test') | Out-Null
    [IO.File]::WriteAllText((Join-Path $path 'README.md'), "seed`n")
    Invoke-GitAsEnv -RepositoryPath $path -Arguments @('add', '-A') | Out-Null
    Invoke-GitAsEnv -RepositoryPath $path -Arguments @('commit', '-m', 'seed', '--quiet') | Out-Null
    $installResult = Invoke-GitAsEnv -RepositoryPath $path -Arguments @('config', 'core.hooksPath', $realHooksDir)
    Assert-Equal $installResult.ExitCode 0 "core.hooksPath must install cleanly for fixture repo $Name."
    return $path
}

function New-DivergentBranch {
    param([string] $RepositoryPath, [string] $BranchName)
    Invoke-GitAsEnv -RepositoryPath $RepositoryPath -Arguments @('checkout', '-b', $BranchName, '--quiet') | Out-Null
    [IO.File]::WriteAllText((Join-Path $RepositoryPath 'feature.txt'), "feature change`n")
    Invoke-GitAsEnv -RepositoryPath $RepositoryPath -Arguments @('add', '-A') | Out-Null
    Invoke-GitAsEnv -RepositoryPath $RepositoryPath -Arguments @('commit', '-m', 'feature change', '--quiet') | Out-Null
    Invoke-GitAsEnv -RepositoryPath $RepositoryPath -Arguments @('checkout', 'main', '--quiet') | Out-Null
}

# --- pre-merge-commit: unmarked merge (no GATECRAFT_BEAD_ID) is never touched ---
$unmarkedMergeRepo = New-TestRepository 'unmarked-merge-repo'
New-DivergentBranch -RepositoryPath $unmarkedMergeRepo -BranchName 'feature-unmarked'
$unmarkedMergeResult = Invoke-GitAsEnv -RepositoryPath $unmarkedMergeRepo -Arguments @('merge', '--no-ff', 'feature-unmarked', '-m', 'merge unmarked')
Assert-Equal $unmarkedMergeResult.ExitCode 0 "An unmarked merge (no GATECRAFT_BEAD_ID) must succeed untouched. stdout=$($unmarkedMergeResult.Output) stderr=$($unmarkedMergeResult.Error)"

# --- pre-merge-commit: marked merge with a deliberately incomplete check-merge call must be BLOCKED ---
# (no --artifact-sha and no --low-risk-no-review-required -> enforce-gate.ps1
# fails deterministically at argument-artifact-sha-required, exit 64, without
# needing a real local-guard/baseline fixture -- this proves the hook wiring
# itself, which is the point of this test, not enforce-gate.ps1's own logic.)
$markedBlockedRepo = New-TestRepository 'marked-blocked-merge-repo'
New-DivergentBranch -RepositoryPath $markedBlockedRepo -BranchName 'feature-marked-blocked'
$markedBlockedResult = Invoke-GitAsEnv -RepositoryPath $markedBlockedRepo -Arguments @('merge', '--no-ff', 'feature-marked-blocked', '-m', 'merge marked blocked') -EnvVars @{ GATECRAFT_BEAD_ID = 'test-bead-1' }
Assert-True ($markedBlockedResult.ExitCode -ne 0) "A marked merge (GATECRAFT_BEAD_ID set) with a failing enforce-gate check must be BLOCKED by the hook. stdout=$($markedBlockedResult.Output) stderr=$($markedBlockedResult.Error)"
$mergeStateAfterBlock = Invoke-GitAsEnv -RepositoryPath $markedBlockedRepo -Arguments @('rev-parse', '--verify', '-q', 'MERGE_HEAD')
Assert-Equal $mergeStateAfterBlock.ExitCode 0 'A hook-blocked merge must leave MERGE_HEAD in place (git treats a rejected pre-merge-commit like an unresolved conflict), not silently complete or discard the attempt.'
Invoke-GitAsEnv -RepositoryPath $markedBlockedRepo -Arguments @('merge', '--abort') | Out-Null

# --- pre-push: unmarked push (no GATECRAFT_AUTOMATED_PUSH) is never touched, even with no push-policy file at all ---
$unmarkedPushRepo = New-TestRepository 'unmarked-push-repo'
$unmarkedPushRemote = Join-Path $testRoot 'unmarked-push-remote.git'
Invoke-GitAsEnv -RepositoryPath $testRoot -Arguments @('init', '--quiet', '--bare', $unmarkedPushRemote) | Out-Null
Invoke-GitAsEnv -RepositoryPath $unmarkedPushRepo -Arguments @('remote', 'add', 'origin', $unmarkedPushRemote) | Out-Null
$unmarkedPushResult = Invoke-GitAsEnv -RepositoryPath $unmarkedPushRepo -Arguments @('push', 'origin', 'main')
Assert-Equal $unmarkedPushResult.ExitCode 0 "An unmarked push (no GATECRAFT_AUTOMATED_PUSH) must succeed untouched even without any push-policy file. stdout=$($unmarkedPushResult.Output) stderr=$($unmarkedPushResult.Error)"

# --- pre-push: marked push with no push-policy file at all must be BLOCKED, and the remote must not move ---
$markedBlockedPushRepo = New-TestRepository 'marked-blocked-push-repo'
$markedBlockedPushRemote = Join-Path $testRoot 'marked-blocked-push-remote.git'
Invoke-GitAsEnv -RepositoryPath $testRoot -Arguments @('init', '--quiet', '--bare', $markedBlockedPushRemote) | Out-Null
Invoke-GitAsEnv -RepositoryPath $markedBlockedPushRepo -Arguments @('remote', 'add', 'origin', $markedBlockedPushRemote) | Out-Null
$markedBlockedPushResult = Invoke-GitAsEnv -RepositoryPath $markedBlockedPushRepo -Arguments @('push', 'origin', 'main') -EnvVars @{ GATECRAFT_AUTOMATED_PUSH = '1' }
Assert-True ($markedBlockedPushResult.ExitCode -ne 0) "A marked push (GATECRAFT_AUTOMATED_PUSH=1) with no push-policy file must be BLOCKED. stdout=$($markedBlockedPushResult.Output) stderr=$($markedBlockedPushResult.Error)"
$remoteMainAfterBlock = Invoke-GitAsEnv -RepositoryPath $markedBlockedPushRepo -Arguments @('ls-remote', 'origin', 'refs/heads/main')
Assert-Equal $remoteMainAfterBlock.Output.Trim() '' 'A hook-blocked push must never move the remote ref -- the bare fixture remote must still have no main branch at all.'

# --- pre-push: marked push WITH a valid matching branch-only push-policy must SUCCEED end-to-end ---
$markedPassingPushRepo = New-TestRepository 'marked-passing-push-repo'
$markedPassingPushRemote = Join-Path $testRoot 'marked-passing-push-remote.git'
Invoke-GitAsEnv -RepositoryPath $testRoot -Arguments @('init', '--quiet', '--bare', $markedPassingPushRemote) | Out-Null
Invoke-GitAsEnv -RepositoryPath $markedPassingPushRepo -Arguments @('remote', 'add', 'origin', $markedPassingPushRemote) | Out-Null
[void][IO.Directory]::CreateDirectory((Join-Path $markedPassingPushRepo '.beads'))
(@{ protocol = 'gatecraft-push-policy/v1'; mode = 'branch-only'; authorized_branch = 'main' } | ConvertTo-Json) |
    Set-Content -LiteralPath (Join-Path $markedPassingPushRepo '.beads/gatecraft-push-policy.json') -Encoding utf8
$markedPassingPushResult = Invoke-GitAsEnv -RepositoryPath $markedPassingPushRepo -Arguments @('push', 'origin', 'main') -EnvVars @{ GATECRAFT_AUTOMATED_PUSH = '1' }
Assert-Equal $markedPassingPushResult.ExitCode 0 "A marked push matching an explicit branch-only push-policy must SUCCEED end-to-end through the real hook. stdout=$($markedPassingPushResult.Output) stderr=$($markedPassingPushResult.Error)"
$remoteMainAfterPass = Invoke-GitAsEnv -RepositoryPath $markedPassingPushRepo -Arguments @('ls-remote', 'origin', 'refs/heads/main')
Assert-True ($remoteMainAfterPass.Output.Trim() -ne '') 'A successfully hook-approved push must actually move the remote ref.'

# --- install-githooks.ps1: sets core.hooksPath, is idempotent, and refuses to silently overwrite a pre-existing different hooksPath ---
# install-githooks.ps1 expects the TARGET repo to carry its own gatecraft/
# skill-folder copy (the real deployment shape for a host project), so each
# fresh fixture repo below gets a copy of the real hook files under its own
# gatecraft/githooks/ -- this sub-test is about install-githooks.ps1's own
# git-config behavior, not about re-exercising the hooks' own logic again.
$installScript = Join-Path $repoRoot 'gatecraft/scripts/install-githooks.ps1'
function New-InstallTargetRepository {
    param([string] $Name)
    $path = Join-Path $testRoot $Name
    [void][IO.Directory]::CreateDirectory($path)
    Invoke-GitAsEnv -RepositoryPath $path -Arguments @('init', '--quiet', '-b', 'main') | Out-Null
    $copiedHooksDir = Join-Path $path 'gatecraft/githooks'
    [void][IO.Directory]::CreateDirectory($copiedHooksDir)
    Copy-Item -LiteralPath (Join-Path $realHooksDir 'pre-merge-commit') -Destination (Join-Path $copiedHooksDir 'pre-merge-commit')
    Copy-Item -LiteralPath (Join-Path $realHooksDir 'pre-push') -Destination (Join-Path $copiedHooksDir 'pre-push')
    return $path
}
$installTargetRepoPath = New-InstallTargetRepository 'install-target-repo'
$installTargetRepo = [pscustomobject]@{ FullName = $installTargetRepoPath }
$installFirstRun = & pwsh -NoLogo -NoProfile -File $installScript -RepositoryRoot $installTargetRepo.FullName 2>&1
$installFirstExit = $LASTEXITCODE
Assert-Equal $installFirstExit 0 "install-githooks.ps1 must succeed on a repository with no existing core.hooksPath. Output=$installFirstRun"
$hooksPathAfterInstall = (Invoke-GitAsEnv -RepositoryPath $installTargetRepo.FullName -Arguments @('config', '--get', 'core.hooksPath')).Output.Trim()
Assert-Equal $hooksPathAfterInstall 'gatecraft/githooks' 'install-githooks.ps1 must set core.hooksPath to the relative gatecraft/githooks path.'

$installSecondRun = & pwsh -NoLogo -NoProfile -File $installScript -RepositoryRoot $installTargetRepo.FullName 2>&1
$installSecondExit = $LASTEXITCODE
Assert-Equal $installSecondExit 0 "install-githooks.ps1 must be idempotent -- re-running on an already-installed repository must still succeed. Output=$installSecondRun"

# A repository with a genuinely different pre-existing core.hooksPath must not be silently overwritten.
$conflictRepoPath = New-InstallTargetRepository 'install-conflict-repo'
Invoke-GitAsEnv -RepositoryPath $conflictRepoPath -Arguments @('config', 'core.hooksPath', 'some-other-hooks-dir') | Out-Null
& pwsh -NoLogo -NoProfile -File $installScript -RepositoryRoot $conflictRepoPath > $null 2>&1
$installConflictExit = $LASTEXITCODE
Assert-True ($installConflictExit -ne 0) 'install-githooks.ps1 must refuse to overwrite a pre-existing different core.hooksPath.'
$hooksPathAfterConflict = (Invoke-GitAsEnv -RepositoryPath $conflictRepoPath -Arguments @('config', '--get', 'core.hooksPath')).Output.Trim()
Assert-Equal $hooksPathAfterConflict 'some-other-hooks-dir' 'A refused install must leave the pre-existing core.hooksPath completely untouched.'

Remove-FixtureRoot -Path $testRoot

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { [Console]::Error.WriteLine("ASSERTION FAILED: $failure") }
    exit 1
}

[Console]::Out.WriteLine('Git-hooks gate passed: unmarked merge/push untouched, marked-and-failing merge/push blocked with the underlying git state left correct (MERGE_HEAD retained / remote ref unmoved), a marked-and-passing push succeeds end-to-end through the real pre-push hook, and install-githooks.ps1 installs/is idempotent/refuses to overwrite a conflicting core.hooksPath.')
