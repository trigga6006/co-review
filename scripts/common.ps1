# co-review shared helpers

function Get-CoReviewRoot {
    return (Join-Path -Path $env:USERPROFILE -ChildPath ".cc-codex-pairs")
}

function Assert-ValidPairId {
    param([Parameter(Mandatory=$true)][string]$PairId)
    if ($PairId -notmatch '^pair-\d{8}-\d{6}-[0-9a-f]{4}$') {
        Write-Error "Invalid PairId '$PairId'. Expected format: pair-YYYYMMDD-HHMMSS-xxxx"
        exit 1
    }
}

function Get-PairDir {
    param(
        [Parameter(Mandatory=$true)][string]$PairId,
        [switch]$MustExist
    )
    Assert-ValidPairId -PairId $PairId
    $root = Get-CoReviewRoot
    $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
    $pairDir = Join-Path -Path $root -ChildPath $PairId
    $pairFull = [System.IO.Path]::GetFullPath($pairDir)
    if (-not $pairFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Error "Invalid PairId '$PairId': resolved path escapes pair root"
        exit 1
    }
    if ($MustExist -and -not (Test-Path -LiteralPath $pairFull)) {
        Write-Error "Pair not found: $PairId  (dir: $pairFull)"
        exit 1
    }
    return $pairFull
}

function Assert-ValidCodexBin {
    param([Parameter(Mandatory=$true)][string]$CodexBin)
    if ([string]::IsNullOrWhiteSpace($CodexBin) -or -not (Test-Path -LiteralPath $CodexBin -PathType Leaf)) {
        Write-Error "Could not locate codex executable. Pass -CodexBin <path> or install Codex CLI."
        exit 1
    }
    $leaf = [System.IO.Path]::GetFileName($CodexBin)
    if ($leaf -notin @("codex.exe", "codex")) {
        Write-Error "Invalid CodexBin '$CodexBin'. Expected an executable named codex.exe or codex."
        exit 1
    }
}

function Get-CodexCapabilities {
    param([string]$ModelsCachePath = "", [switch]$IncludeHidden, [string]$CodexBin = "")

    if ([string]::IsNullOrWhiteSpace($ModelsCachePath)) {
        if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
            $ModelsCachePath = Join-Path -Path $env:CODEX_HOME -ChildPath "models_cache.json"
        } else {
            $userHome = $HOME
            if ([string]::IsNullOrWhiteSpace($userHome)) { $userHome = $env:USERPROFILE }
            $ModelsCachePath = Join-Path -Path (Join-Path -Path $userHome -ChildPath ".codex") -ChildPath "models_cache.json"
        }
    }

    try {
        $cachePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ModelsCachePath)
    } catch {
        $cachePath = $ModelsCachePath
    }

    $cache = $null
    $source = "missing-cache"
    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
        try {
            $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -ErrorAction Stop
            $source = "models-cache"
        } catch {
            $source = "invalid-cache"
        }
    }

    $models = @()
    if ($null -ne $cache -and $null -ne $cache.PSObject.Properties["models"]) {
        foreach ($rawModel in @($cache.models)) {
            if ($null -eq $rawModel) { continue }

            $slug = [string]$rawModel.slug
            if ([string]::IsNullOrWhiteSpace($slug)) { continue }

            $visibility = [string]$rawModel.visibility
            if ([string]::IsNullOrWhiteSpace($visibility)) { $visibility = "list" }
            if (-not $IncludeHidden -and $visibility -ne "list") { continue }

            [int]$candidatePriority = 0
            $priority = [int]::MaxValue
            if ([int]::TryParse([string]$rawModel.priority, [ref]$candidatePriority)) {
                $priority = $candidatePriority
            }

            $supportedReasoning = @()
            foreach ($rawLevel in @($rawModel.supported_reasoning_levels)) {
                if ($null -eq $rawLevel) { continue }
                $effort = [string]$rawLevel.effort
                if ([string]::IsNullOrWhiteSpace($effort)) { continue }
                $description = [string]$rawLevel.description
                if ([string]::IsNullOrWhiteSpace($description)) { $description = $effort }
                $supportedReasoning += [PSCustomObject]@{
                    effort = $effort
                    description = $description
                }
            }

            $speedTiers = @()
            foreach ($rawTier in @($rawModel.additional_speed_tiers)) {
                $tier = [string]$rawTier
                if (-not [string]::IsNullOrWhiteSpace($tier)) { $speedTiers += $tier }
            }

            $displayName = [string]$rawModel.display_name
            if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $slug }
            $models += [PSCustomObject]@{
                slug = $slug
                display_name = $displayName
                description = [string]$rawModel.description
                priority = $priority
                visibility = $visibility
                default_reasoning_level = [string]$rawModel.default_reasoning_level
                supported_reasoning_levels = @($supportedReasoning)
                additional_speed_tiers = @($speedTiers)
            }
        }
    }
    $models = @($models | Sort-Object -Property priority, slug)

    $cliVersion = $null
    $resolvedCodexBin = $CodexBin
    if ([string]::IsNullOrWhiteSpace($resolvedCodexBin)) {
        $codexCommand = Get-Command "codex" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $codexCommand) { $resolvedCodexBin = $codexCommand.Source }
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedCodexBin)) {
        try {
            $versionLine = (& $resolvedCodexBin --version 2>$null | Select-Object -First 1)
            if (-not [string]::IsNullOrWhiteSpace([string]$versionLine)) {
                if ([string]$versionLine -match '(\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?)') {
                    $cliVersion = $Matches[1]
                } else {
                    $cliVersion = [string]$versionLine
                }
            }
        } catch {
            $cliVersion = $null
        }
    }
    if ($null -eq $cliVersion -and $null -ne $cache -and $null -ne $cache.PSObject.Properties["client_version"]) {
        $cliVersion = [string]$cache.client_version
    }

    $defaultModel = "configured-default"
    $defaultReasoning = "auto"
    $defaultModels = @($models | Where-Object { $_.visibility -eq "list" })
    if ($defaultModels.Count -gt 0) {
        $defaultModel = [string]$defaultModels[0].slug
        $defaultReasoning = [string]$defaultModels[0].default_reasoning_level
    }

    return [PSCustomObject]@{
        source = $source
        cache_path = $cachePath
        cli_version = $cliVersion
        models = @($models)
        modes = @("review", "workhorse")
        sandboxes = @("read-only", "workspace-write", "danger-full-access")
        isolation = @("auto", "shared", "worktree")
        window_modes = @("Hidden", "Minimized", "Foreground")
        defaults = [PSCustomObject]@{
            model = $defaultModel
            reasoning = $defaultReasoning
            mode = "review"
            sandbox = "read-only"
            isolation = "auto"
            window_mode = "Hidden"
        }
    }
}

function Resolve-CodexSelection {
    param(
        [Parameter(Mandatory=$true)]$Capabilities,
        [string]$Model = "auto",
        [string]$Reasoning = "auto",
        [switch]$AllowUnknownModel
    )

    $availableModels = @($Capabilities.models)
    $selectedModel = $null
    $resolvedModel = $Model
    $modelSource = "explicit"

    if ($Model -eq "auto") {
        $visibleModels = @($availableModels | Where-Object { $_.visibility -eq "list" })
        if ($visibleModels.Count -eq 0) {
            throw "Cannot resolve model 'auto': no visible models were discovered"
        }
        $selectedModel = $visibleModels | Sort-Object -Property priority, slug | Select-Object -First 1
        $resolvedModel = [string]$selectedModel.slug
        $modelSource = "auto"
    } elseif ($Model -eq "configured-default") {
        $modelSource = "configured-default"
    } else {
        $selectedModel = $availableModels | Where-Object { $_.slug -eq $Model } | Select-Object -First 1
        if ($null -eq $selectedModel) {
            if (-not $AllowUnknownModel) {
                throw "Unknown Codex model '$Model'. Pass -AllowUnknownModel to use an undiscovered model"
            }
            $modelSource = "explicit-unknown"
        }
    }

    $resolvedReasoning = $Reasoning
    $reasoningSource = "explicit"
    if ($Reasoning -eq "auto") {
        if ($null -ne $selectedModel) {
            $resolvedReasoning = [string]$selectedModel.default_reasoning_level
            if ([string]::IsNullOrWhiteSpace($resolvedReasoning)) {
                throw "Model '$resolvedModel' does not advertise a default reasoning level"
            }
            $reasoningSource = "model-default"
        } else {
            $reasoningSource = "configured-default"
        }
    }
    if ($null -ne $selectedModel) {
        $supported = @($selectedModel.supported_reasoning_levels | ForEach-Object { [string]$_.effort })
        if ($supported -notcontains $resolvedReasoning) {
            throw "Model '$resolvedModel' does not support reasoning level '$resolvedReasoning'. Supported levels: $($supported -join ', ')"
        }
    }

    return [PSCustomObject]@{
        model = $resolvedModel
        reasoning = $resolvedReasoning
        model_source = $modelSource
        reasoning_source = $reasoningSource
    }
}

function Assert-SafeCodexConfigOverrides {
    param([string[]]$Overrides = @())
    $reserved = @('model','model_reasoning_effort','sandbox_mode','approval_policy','cwd','output_last_message','features.multi_agent')
    foreach ($override in $Overrides) {
        if ($override -notmatch '^[A-Za-z0-9_.-]+=.+$') { throw "Invalid Codex config override: $override" }
        $key = ($override -split '=', 2)[0]
        if ($reserved -contains $key) { throw "Codex config '$key' has a dedicated guarded option" }
    }
}
