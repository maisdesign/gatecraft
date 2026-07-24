$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$log = Join-Path $repo ".gatecraft\update-skill.log"

Set-Location $repo
$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Add-Content -Path $log -Value "[$ts] checking for updates..."

try {
    git fetch origin 2>&1 | Add-Content -Path $log
    $status = git status -sb
    if ($status -match "behind") {
        $porcelain = git status --porcelain
        if ([string]::IsNullOrWhiteSpace($porcelain)) {
            $result = git pull --ff-only origin main 2>&1
            Add-Content -Path $log -Value $result
            Add-Content -Path $log -Value "[$ts] pulled successfully."
        } else {
            Add-Content -Path $log -Value "[$ts] SKIPPED: local changes present, not pulling."
        }
    } else {
        Add-Content -Path $log -Value "[$ts] already up to date."
    }
} catch {
    Add-Content -Path $log -Value "[$ts] ERROR: $_"
}
