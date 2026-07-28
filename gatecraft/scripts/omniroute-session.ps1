[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('status', 'onboarding', 'get-preferences', 'set-preferences', 'get-project-policy', 'set-project-policy', 'resolve-policy', 'discover-adapters', 'discover-source', 'preflight', 'register-adapter', 'start', 'build-plan', 'build', 'install-plan', 'install', 'install-health')]
    [string] $Command,

    [string] $Endpoint,
    [string] $PreferencePath,
    [string] $StartupAdapterPath,
    [string] $RepositoryRoot,
    [ValidateSet('ask', 'never')][string] $InstallPrompt,
    [ValidateSet('ask', 'always')][string] $GlobalUsePolicy,
    [ValidateSet('inherit', 'ask', 'always', 'never')][string] $ProjectPolicy,
    [ValidateSet('none', 'use', 'skip')][string] $SessionChoice = 'none',
    [ValidateSet('native-cli', 'docker-existing', 'source-checkout', 'desktop-app', 'systemd-user')][string] $Adapter,
    [ValidateSet('default', 'start', 'dev')][string] $Mode = 'default',
    [string] $Target,
    [string[]] $SearchRoots,
    [string[]] $DesktopPaths,
    [string] $Version,
    [string] $ExpectedRunnerSha256,
    [string] $ExpectedNodeSha256,
    [switch] $UserConfirmed,
    [switch] $IncludeModelIds,
    [ValidateRange(5, 180)][int] $ReadyTimeoutSeconds = 60,
    [ValidateRange(60, 1800)][int] $BuildTimeoutSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require-Value([string] $Value, [string] $Name) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "omniroute-argument-required:$Name" }
}

try {
    Import-Module (Join-Path $PSScriptRoot 'OmniRoute.psm1') -Force -ErrorAction Stop
    $preferenceArguments = @{}
    if (-not [string]::IsNullOrWhiteSpace($PreferencePath)) { $preferenceArguments.Path = $PreferencePath }
    $adapterArguments = @{}
    if (-not [string]::IsNullOrWhiteSpace($StartupAdapterPath)) { $adapterArguments.Path = $StartupAdapterPath }
    $preferences = Read-GatecraftOmniRoutePreferences @preferenceArguments
    $invalidPreferenceFallbackCommands = @('status', 'onboarding', 'get-preferences', 'set-preferences', 'get-project-policy', 'set-project-policy', 'resolve-policy', 'discover-adapters', 'discover-source', 'preflight', 'build-plan', 'install-plan', 'install-health')
    if (-not $preferences.Valid -and $Command -cnotin $invalidPreferenceFallbackCommands) { throw 'omniroute-preferences-invalid' }
    $effectiveEndpoint = if (-not [string]::IsNullOrWhiteSpace($Endpoint)) { $Endpoint } elseif ($preferences.Valid) { $preferences.Endpoint } else { 'http://localhost:20128' }

    $result = switch ($Command) {
        'status' {
            $runtimeIdentity = Get-GatecraftOmniRouteRuntimeIdentity
            $statusArguments = @{ Endpoint = $effectiveEndpoint }
            if (-not [string]::IsNullOrWhiteSpace($StartupAdapterPath)) { $statusArguments.StartupAdapterPath = $StartupAdapterPath }
            $status = Get-GatecraftOmniRouteStatus @statusArguments
            $projection = [ordered]@{
                state = $status.State
                endpoint_origin = $status.Endpoint
                probe_state = $status.Probe.ProbeState
                reason_code = $status.Probe.ReasonCode
                model_count = $status.Probe.ModelIds.Count
                adapter = $status.Adapter
                registered_adapter_exists = $status.StartupAdapter.Exists
                registered_adapter_valid = $status.StartupAdapter.Valid
                discovered_adapter_count = $status.DiscoveredAdapters.Count
                discovered_adapter_types = @($status.DiscoveredAdapters | ForEach-Object { $_.Type } | Sort-Object -Unique)
                preferences_valid = $preferences.Valid
                preference_reason = $preferences.ReasonCode
                runtime_protocol = $runtimeIdentity.Protocol
                runtime_module_sha256 = $runtimeIdentity.ModuleSha256
                runtime_entrypoint_sha256 = $runtimeIdentity.EntryPointSha256
                runtime_process_host_sha256 = $runtimeIdentity.ProcessHostSha256
            }
            if ($IncludeModelIds) { $projection.model_ids = @($status.Probe.ModelIds) }
            [pscustomobject]$projection
        }
        'onboarding' {
            $statusArguments = @{ Endpoint = $effectiveEndpoint }
            if (-not [string]::IsNullOrWhiteSpace($StartupAdapterPath)) { $statusArguments.StartupAdapterPath = $StartupAdapterPath }
            $status = Get-GatecraftOmniRouteStatus @statusArguments

            # Security warnings and bootstrap state exist only for a source checkout.
            # Prefer an explicit -Target, else the registered adapter when it is one;
            # otherwise the projection reports what it can and says nothing it cannot
            # observe.
            $onboardingWarnings = @()
            $onboardingSetupState = 'unknown'
            $preflightTarget = $Target
            if ([string]::IsNullOrWhiteSpace($preflightTarget) -and
                $status.StartupAdapter.Exists -and $status.StartupAdapter.Valid -and
                $status.StartupAdapter.Record.type -ceq 'source-checkout') {
                $preflightTarget = $status.StartupAdapter.Record.target
            }
            if (-not [string]::IsNullOrWhiteSpace($preflightTarget)) {
                $preflightMode = if ($Mode -cin @('start', 'dev')) { $Mode } else { 'start' }
                if (Test-GatecraftOmniRouteSourceCheckout -Path $preflightTarget -Mode $preflightMode) {
                    $sourcePreflight = Get-GatecraftOmniRouteSourcePreflight -Target $preflightTarget -Mode $preflightMode
                    $onboardingWarnings = @($sourcePreflight.SecurityWarnings)
                    # SetupState is not part of the current preflight contract; read it
                    # only when present so this stays correct if it is added later,
                    # instead of throwing under Set-StrictMode.
                    $setupStateProperty = $sourcePreflight.PSObject.Properties['SetupState']
                    if ($null -ne $setupStateProperty -and $setupStateProperty.Value -cin @('configured', 'unconfigured', 'unknown')) {
                        $onboardingSetupState = $setupStateProperty.Value
                    }
                }
            }

            $installPrompt = if ($preferences.Valid) { $preferences.InstallPrompt } else { 'ask' }
            $onboarding = Get-GatecraftOmniRouteOnboarding -Status $status -SecurityWarnings $onboardingWarnings -SetupState $onboardingSetupState -InstallPrompt $installPrompt
            [pscustomobject][ordered]@{
                stage = $onboarding.Stage
                state = $onboarding.State
                endpoint_origin = $onboarding.Endpoint
                reason_code = $onboarding.ReasonCode
                model_count = $onboarding.ModelCount
                dashboard_url = $onboarding.DashboardUrl
                next_actions = @($onboarding.NextActions)
                adapter_authority = $onboarding.AdapterAuthority
                setup_state = $onboarding.SetupState
                security_warnings = @($onboarding.SecurityWarnings)
                configuration_owner = $onboarding.ConfigurationOwner
                install_prompt = $installPrompt
                preferences_valid = $preferences.Valid
            }
        }
        'get-preferences' { $preferences }
        'set-preferences' {
            Require-Value $InstallPrompt 'InstallPrompt'
            Require-Value $GlobalUsePolicy 'GlobalUsePolicy'
            Write-GatecraftOmniRoutePreferences @preferenceArguments -InstallPrompt $InstallPrompt -GlobalUsePolicy $GlobalUsePolicy -Endpoint $effectiveEndpoint -Confirm:$false
        }
        'get-project-policy' {
            Require-Value $RepositoryRoot 'RepositoryRoot'
            [pscustomobject]@{ policy = Get-GatecraftOmniRouteProjectPolicy -RepositoryRoot $RepositoryRoot }
        }
        'set-project-policy' {
            Require-Value $RepositoryRoot 'RepositoryRoot'
            Require-Value $ProjectPolicy 'ProjectPolicy'
            [pscustomobject]@{ policy = Set-GatecraftOmniRouteProjectPolicy -RepositoryRoot $RepositoryRoot -Policy $ProjectPolicy -Confirm:$false }
        }
        'resolve-policy' {
            $resolvedProjectPolicy = if (-not [string]::IsNullOrWhiteSpace($ProjectPolicy)) { $ProjectPolicy } elseif (-not [string]::IsNullOrWhiteSpace($RepositoryRoot)) { Get-GatecraftOmniRouteProjectPolicy -RepositoryRoot $RepositoryRoot } else { 'inherit' }
            if (-not $preferences.Valid) {
                $resolution = Resolve-GatecraftOmniRouteUsePolicy -SessionChoice $SessionChoice -ProjectPolicy $resolvedProjectPolicy -GlobalUsePolicy ask
                $resolutionSource = if ($resolution.Source -ceq 'global') { 'invalid-preferences' } else { $resolution.Source }
                [pscustomobject]@{ decision = $resolution.Decision; source = $resolutionSource; session_choice = $SessionChoice; project_policy = $resolvedProjectPolicy; global_use_policy = 'ask'; endpoint_origin = $effectiveEndpoint; preferences_valid = $false }
            } else {
                $resolution = Resolve-GatecraftOmniRouteUsePolicy -SessionChoice $SessionChoice -ProjectPolicy $resolvedProjectPolicy -GlobalUsePolicy $preferences.GlobalUsePolicy
                [pscustomobject]@{ decision = $resolution.Decision; source = $resolution.Source; session_choice = $SessionChoice; project_policy = $resolvedProjectPolicy; global_use_policy = $preferences.GlobalUsePolicy; endpoint_origin = $effectiveEndpoint; preferences_valid = $true }
            }
        }
        'discover-source' { @(Find-GatecraftOmniRouteSourceCheckouts -SearchRoots $SearchRoots) }
        'discover-adapters' { @(Find-GatecraftOmniRouteStartupAdapters -SearchRoots $SearchRoots -DesktopPaths $DesktopPaths) }
        'preflight' {
            Require-Value $Adapter 'Adapter'
            if ($Adapter -cne 'source-checkout') { throw 'omniroute-preflight-adapter-unsupported' }
            Require-Value $Target 'Target'
            if ($Mode -cnotin @('start', 'dev')) { throw 'omniroute-source-mode-invalid' }
            Get-GatecraftOmniRouteSourcePreflight -Target $Target -Mode $Mode
        }
        'register-adapter' {
            Require-Value $Adapter 'Adapter'
            Register-GatecraftOmniRouteStartupAdapter @adapterArguments -Type $Adapter -Target $Target -Mode $Mode -UserConfirmed:$UserConfirmed.IsPresent -Confirm:$false
        }
        'start' {
            Require-Value $Adapter 'Adapter'
            $startArguments = @{ Adapter = $Adapter; Endpoint = $effectiveEndpoint; ReadyTimeoutSeconds = $ReadyTimeoutSeconds; UserConfirmedUnregistered = $UserConfirmed.IsPresent; Target = $Target; Mode = $Mode }
            if (-not [string]::IsNullOrWhiteSpace($StartupAdapterPath)) { $startArguments.StartupAdapterPath = $StartupAdapterPath }
            Start-GatecraftOmniRoute @startArguments -Confirm:$false
        }
        'build-plan' {
            Require-Value $Target 'Target'
            New-GatecraftOmniRouteSourceBuildPlan -Target $Target
        }
        'build' {
            Require-Value $Target 'Target'
            Require-Value $ExpectedRunnerSha256 'ExpectedRunnerSha256'
            Require-Value $ExpectedNodeSha256 'ExpectedNodeSha256'
            Build-GatecraftOmniRouteSourceCheckout -Target $Target -ExpectedRunnerSha256 $ExpectedRunnerSha256 -ExpectedNodeSha256 $ExpectedNodeSha256 -UserConfirmed:$UserConfirmed.IsPresent -TimeoutSeconds $BuildTimeoutSeconds -Confirm:$false
        }
        'install-plan' {
            Require-Value $Version 'Version'
            New-GatecraftOmniRouteInstallPlan -Version $Version
        }
        'install' {
            Require-Value $Version 'Version'
            Install-GatecraftOmniRoute -Version $Version -UserConfirmed:$UserConfirmed.IsPresent -Confirm:$false
        }
        'install-health' {
            $healthRoot = if (-not [string]::IsNullOrWhiteSpace($Target)) { $Target } else { Get-GatecraftOmniRouteInstallRoot }
            Test-GatecraftOmniRouteInstallHealth -PackageRoot $healthRoot -ExpectedVersion $Version
        }
    }
    $result | ConvertTo-Json -Depth 12
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
