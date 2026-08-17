# co-review shared helpers

function Get-CoReviewRoot {
    return (Join-Path -Path $env:USERPROFILE -ChildPath ".cc-codex-pairs")
}

function Assert-ValidPairId {
    param([Parameter(Mandatory=$true)][string]$PairId)
    if ($PairId -notmatch '^pair-\d{8}-\d{6}-[0-9a-f]{4,16}$') {
        Write-Error "Invalid PairId '$PairId'. Expected format: pair-YYYYMMDD-HHMMSS-<hex>"
        exit 1
    }
}

function Get-CoReviewSignalName {
    param(
        [Parameter(Mandatory=$true)][string]$PairId,
        [Parameter(Mandatory=$true)][ValidateSet("inbox", "outbox")][string]$Channel
    )
    Assert-ValidPairId -PairId $PairId
    return "Global\co-review-$Channel-$PairId"
}

function Open-CoReviewSignal {
    param(
        [Parameter(Mandatory=$true)][string]$PairId,
        [Parameter(Mandatory=$true)][ValidateSet("inbox", "outbox")][string]$Channel
    )
    $created = $false
    return [System.Threading.EventWaitHandle]::new(
        $false,
        [System.Threading.EventResetMode]::AutoReset,
        (Get-CoReviewSignalName -PairId $PairId -Channel $Channel),
        [ref]$created
    )
}

function Signal-CoReviewChannel {
    param(
        [Parameter(Mandatory=$true)][string]$PairId,
        [Parameter(Mandatory=$true)][ValidateSet("inbox", "outbox")][string]$Channel
    )
    $signal = Open-CoReviewSignal -PairId $PairId -Channel $Channel
    try { [void]$signal.Set() } finally { $signal.Dispose() }
}

function Wait-CoReviewChannel {
    param(
        [Parameter(Mandatory=$true)]$Signal,
        [int]$TimeoutMilliseconds = 2000
    )
    if ($TimeoutMilliseconds -lt 0) { $TimeoutMilliseconds = 0 }
    return $Signal.WaitOne($TimeoutMilliseconds)
}

function Get-CoReviewSequencePath {
    param(
        [Parameter(Mandatory=$true)][string]$PairDir,
        [Parameter(Mandatory=$true)][ValidateSet("inbox", "outbox")][string]$Channel
    )
    return (Join-Path $PairDir ".$Channel.seq")
}

function Get-CoReviewSequence {
    param(
        [Parameter(Mandatory=$true)][string]$PairDir,
        [Parameter(Mandatory=$true)][ValidateSet("inbox", "outbox")][string]$Channel,
        [string]$FallbackQueuePath = ""
    )
    $path = Get-CoReviewSequencePath -PairDir $PairDir -Channel $Channel
    [long]$value = 0
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        [void][long]::TryParse(([System.IO.File]::ReadAllText($path)).Trim(), [ref]$value)
        return $value
    }
    if (-not [string]::IsNullOrWhiteSpace($FallbackQueuePath) -and (Test-Path -LiteralPath $FallbackQueuePath -PathType Leaf)) {
        $value = @([System.IO.File]::ReadLines($FallbackQueuePath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    }
    return $value
}

function Get-NextCoReviewSequence {
    param(
        [Parameter(Mandatory=$true)][string]$PairId,
        [Parameter(Mandatory=$true)][string]$PairDir,
        [Parameter(Mandatory=$true)][ValidateSet("inbox", "outbox")][string]$Channel,
        [string]$FallbackQueuePath = ""
    )
    $mutexName = Get-CoReviewMutexName -Scope "sequence-$Channel" -Key $PairId
    return Invoke-WithCoReviewMutex -Name $mutexName -ScriptBlock {
        [long]$next = (Get-CoReviewSequence -PairDir $PairDir -Channel $Channel -FallbackQueuePath $FallbackQueuePath) + 1
        $path = Get-CoReviewSequencePath -PairDir $PairDir -Channel $Channel
        [System.IO.File]::WriteAllText($path, [string]$next, [System.Text.UTF8Encoding]::new($false))
        return $next
    }
}

function Read-CoReviewJsonlTail {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [long]$Offset = 0
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [PSCustomObject]@{ records=@(); next_offset=$Offset; file_length=0 }
    }
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        if ($Offset -lt 0 -or $Offset -gt $stream.Length) { $Offset = 0 }
        [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $remaining = [int]($stream.Length - $Offset)
        if ($remaining -le 0) { return [PSCustomObject]@{ records=@(); next_offset=$Offset; file_length=$stream.Length } }
        $bytes = New-Object byte[] $remaining
        $read = $stream.Read($bytes, 0, $remaining)
        $lastNewline = -1
        for ($i = $read - 1; $i -ge 0; $i--) {
            if ($bytes[$i] -eq 10) { $lastNewline = $i; break }
        }
        if ($lastNewline -lt 0) { return [PSCustomObject]@{ records=@(); next_offset=$Offset; file_length=$stream.Length } }
        $text = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $lastNewline + 1)
        $records = New-Object System.Collections.Generic.List[object]
        [long]$cursor = $Offset
        foreach ($line in @($text -split "`n")) {
            $lineBytes = [System.Text.Encoding]::UTF8.GetByteCount($line) + 1
            $cursor += $lineBytes
            $clean = $line.TrimEnd("`r")
            if ([string]::IsNullOrWhiteSpace($clean)) { continue }
            try {
                $records.Add([PSCustomObject]@{ value=($clean | ConvertFrom-Json -ErrorAction Stop); end_offset=$cursor }) | Out-Null
            } catch {
                $records.Add([PSCustomObject]@{ value=$null; end_offset=$cursor; malformed=$true }) | Out-Null
            }
        }
        return [PSCustomObject]@{ records=$records.ToArray(); next_offset=($Offset + $lastNewline + 1); file_length=$stream.Length }
    } finally { $stream.Dispose() }
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

function Get-CoReviewFanoutTiers {
    return @(
        [PSCustomObject]@{ name="light"; workhorses=1; reviewers=1; description="One focused implementation stream with one final reviewer" },
        [PSCustomObject]@{ name="medium"; workhorses=2; reviewers=1; description="Two independent implementation streams with one integration reviewer" },
        [PSCustomObject]@{ name="high"; workhorses=5; reviewers=2; description="Broad multi-area work with correctness and integration reviewers" },
        [PSCustomObject]@{ name="xhigh"; workhorses=10; reviewers=3; description="Repo-wide work with an explicit decomposition and integration plan" }
    )
}

function Resolve-CodexBin {
    param([string[]]$Candidates = @())

    if ($Candidates.Count -eq 0) {
        $discovered = @()
        if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
            $npmPattern = Join-Path $env:APPDATA "npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-*\vendor\*\bin\codex.exe"
            $discovered += @(Get-ChildItem -Path $npmPattern -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        }
        if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            $discovered += (Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin\codex.exe")
        }
        $commands = @(Get-Command codex -All -ErrorAction SilentlyContinue)
        $discovered += @($commands | ForEach-Object { $_.Source })
        $Candidates = $discovered
    }

    $valid = @()
    foreach ($candidate in @($Candidates | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        if ([System.IO.Path]::GetFileName($candidate) -notin @("codex.exe", "codex")) { continue }
        try {
            $versionLine = (& $candidate --version 2>$null | Select-Object -First 1)
            if ([string]$versionLine -match '(\d+\.\d+\.\d+)') {
                $valid += [pscustomobject]@{ path = $candidate; version = [version]$Matches[1] }
            }
        } catch { }
    }

    $selected = $valid | Sort-Object version -Descending | Select-Object -First 1
    if ($null -eq $selected) {
        Write-Error "Could not locate a runnable Codex executable. Pass -CodexBin <path> or install Codex CLI."
        exit 1
    }
    return [string]$selected.path
}

function Get-CodexCapabilities {
    param([string]$ModelsCachePath = "", [switch]$IncludeHidden, [string]$CodexBin = "", [int]$MaxCacheAgeHours = 168)

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
    $cacheFetchedAt = $null
    $cacheAgeHours = $null
    $cacheStale = $false
    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
        try {
            $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -ErrorAction Stop
            $source = "models-cache"
            if ($null -ne $cache.PSObject.Properties["fetched_at"] -and -not [string]::IsNullOrWhiteSpace([string]$cache.fetched_at)) {
                $parsedFetchedAt = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse([string]$cache.fetched_at, [ref]$parsedFetchedAt)) {
                    $cacheFetchedAt = $parsedFetchedAt.ToUniversalTime().ToString("o")
                    $cacheAgeHours = [Math]::Max(0, ([DateTimeOffset]::UtcNow - $parsedFetchedAt.ToUniversalTime()).TotalHours)
                    if ($MaxCacheAgeHours -gt 0 -and $cacheAgeHours -gt $MaxCacheAgeHours) {
                        $cacheStale = $true
                        $source = "stale-models-cache"
                    }
                }
            }
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
    if (-not $cacheStale -and $defaultModels.Count -gt 0) {
        $defaultModel = [string]$defaultModels[0].slug
        $defaultReasoning = [string]$defaultModels[0].default_reasoning_level
    }

    return [PSCustomObject]@{
        source = $source
        cache_path = $cachePath
        cache_fetched_at = $cacheFetchedAt
        cache_age_hours = $cacheAgeHours
        cache_stale = $cacheStale
        cli_version = $cliVersion
        models = @($models)
        modes = @("review", "workhorse", "imagegen")
        fanout_tiers = @(Get-CoReviewFanoutTiers)
        global_worker_soft_cap = 32
        sandboxes = @("read-only", "workspace-write", "danger-full-access")
        isolation = @("auto", "shared", "worktree")
        transports = @("auto", "app-server", "legacy")
        window_modes = @("Hidden", "Minimized", "Foreground")
        defaults = [PSCustomObject]@{
            model = $defaultModel
            reasoning = $defaultReasoning
            mode = "review"
            sandbox = "read-only"
            isolation = "auto"
            window_mode = "Hidden"
            fanout_tier = "light"
            transport = "auto"
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
        if ($Capabilities.cache_stale -eq $true) {
            throw "Cannot resolve model 'auto': the discovered Codex model cache is stale"
        }
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

function Resolve-CoReviewRoleSelection {
    param(
        [Parameter(Mandatory=$true)]$Capabilities,
        [Parameter(Mandatory=$true)][ValidateSet("review", "workhorse", "imagegen")][string]$Mode,
        [string]$Model = "role-default",
        [string]$Reasoning = "role-default",
        [switch]$AllowUnknownModel
    )

    $requestedModel = $Model
    $requestedReasoning = $Reasoning
    $roleModels = @{
        review = "gpt-5.6-sol"
        workhorse = "gpt-5.6-luna"
    }

    if ($Model -eq "role-default") {
        $preferredModel = [string]$roleModels[$Mode]
        $preferredAvailable = -not [string]::IsNullOrWhiteSpace($preferredModel) -and
            $null -ne ($Capabilities.models | Where-Object { $_.slug -eq $preferredModel -and $_.visibility -eq "list" } | Select-Object -First 1)
        if ($Capabilities.cache_stale -eq $true) {
            $Model = "configured-default"
        } elseif ($preferredAvailable) {
            $Model = $preferredModel
        } else {
            $Model = "auto"
        }
    }

    if ($Reasoning -eq "role-default") {
        if ($Mode -eq "imagegen") {
            $Reasoning = "auto"
        } elseif ($Model -eq "configured-default") {
            $Reasoning = "auto"
        } else {
            $candidate = if ($Model -eq "auto") {
                $Capabilities.models | Where-Object { $_.visibility -eq "list" } | Sort-Object -Property priority, slug | Select-Object -First 1
            } else {
                $Capabilities.models | Where-Object { $_.slug -eq $Model } | Select-Object -First 1
            }
            $supported = @($candidate.supported_reasoning_levels | ForEach-Object { [string]$_.effort })
            $Reasoning = if ($supported -contains "high") { "high" } else { "auto" }
        }
    }

    $selection = Resolve-CodexSelection -Capabilities $Capabilities -Model $Model -Reasoning $Reasoning -AllowUnknownModel:$AllowUnknownModel
    if ($requestedModel -eq "role-default") { $selection.model_source = "role-default" }
    if ($requestedReasoning -eq "role-default") { $selection.reasoning_source = "role-default" }
    return $selection
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

function New-CodexTaskEnvelope {
    param(
        [Parameter(Mandatory=$true)]$Meta,
        [Parameter(Mandatory=$true)][string]$Task
    )

    $workerName = [string]$Meta.worker_name
    if ([string]::IsNullOrWhiteSpace($workerName)) { $workerName = [string]$Meta.pair_id }
    $mode = [string]$Meta.mode
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = "review" }
    $workingDirectory = [string]$Meta.project_cwd

    if ($mode -eq "workhorse") {
        $contract = @"
Implement the bounded task in the working directory, run verification appropriate to the change, and report:
- outcome
- changed files
- verification commands and results
- remaining blockers or risks
"@
        if ([string]$Meta.isolation -eq "worktree") {
            $contract += "`nThis is an isolated managed Git worktree. Commit the verified bounded change to its dedicated branch; Claude will review and integrate it.`n"
        }
    } elseif ($mode -eq "imagegen") {
        $contract = @"
Act as Codex's dedicated image-generation specialist. Invoke the installed `$imagegen skill and follow it exactly. Use the image-generation tool to create or edit the requested image; do not substitute SVG, HTML, a drawing library, or a text-only prompt unless Claude explicitly asks for that instead.

Codex can generate images in this environment. Do not reject the task based on stale product knowledge. Actually call the image-generation tool unless a required source image is unavailable. For an edit, inspect the source image first. Save the resulting image in the working directory or the exact path requested by Claude.

Report:
- outcome
- generated image path or paths
- a concise description of what was generated or edited
- remaining blockers or risks
"@
        if ([string]$Meta.isolation -eq "worktree") {
            $contract += "`nThis is an isolated managed Git worktree. Commit the generated image files to its dedicated branch so Claude can review and integrate them.`n"
        }
    } else {
        $contract = @"
Inspect the requested scope and return an evidence-backed review. You MUST NOT edit files.
Report:
- verdict
- prioritized findings with file references
- uncertainty
- recommended next actions
"@
    }

    $progressContract = ""
    if ([int]$Meta.max_progress_updates -gt 0) {
        $progressContract = @"

PROGRESS UPDATES:
If you find a high-confidence result that could change Claude's immediate direction and you will keep working, send a brief agent update beginning exactly with CO_REVIEW_PROGRESS:. Send at most $([int]$Meta.max_progress_updates) such updates. Do not report routine exploration, plans, or reassurance.
"@
    }

    return @"
CODEX LEAF WORKER
WORKER: $workerName
MODE: $mode
WORKING DIRECTORY: $workingDirectory

You are a leaf worker controlled by Claude. Do not spawn, delegate to, or coordinate other agents.
Do not broaden the task or permissions. Report blockers instead.

COMPLETION CONTRACT:
$($contract.Trim())
$progressContract

TASK FROM CLAUDE:
$Task
"@
}

function Get-NormalizedPairMetadata {
    param([Parameter(Mandatory=$true)][string]$PairDir)

    $metaPath = Join-Path $PairDir "pair.json"
    if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
        throw "pair.json not found at $metaPath"
    }
    $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    $schemaVersion = if ($meta.schema_version -ge 2) { [int]$meta.schema_version } else { 1 }
    if ($schemaVersion -eq 1) {
        $meta | Add-Member -NotePropertyName schema_version -NotePropertyValue 1 -Force
        $meta | Add-Member -NotePropertyName worker_name -NotePropertyValue ([string]$meta.pair_id) -Force
        $meta | Add-Member -NotePropertyName mode -NotePropertyValue "review" -Force
        $meta | Add-Member -NotePropertyName sandbox -NotePropertyValue "read-only" -Force
        $meta | Add-Member -NotePropertyName isolation -NotePropertyValue "shared" -Force
        $meta | Add-Member -NotePropertyName window_mode -NotePropertyValue "Minimized" -Force
        $meta | Add-Member -NotePropertyName codex_timeout_sec -NotePropertyValue 1800 -Force
        $meta | Add-Member -NotePropertyName dry_run_listener -NotePropertyValue $false -Force
        $meta | Add-Member -NotePropertyName profile -NotePropertyValue "" -Force
        $meta | Add-Member -NotePropertyName add_dirs -NotePropertyValue @() -Force
        $meta | Add-Member -NotePropertyName search_enabled -NotePropertyValue $false -Force
        $meta | Add-Member -NotePropertyName config_overrides -NotePropertyValue @() -Force
        $meta | Add-Member -NotePropertyName max_turns -NotePropertyValue 0 -Force
        $meta | Add-Member -NotePropertyName idle_timeout_sec -NotePropertyValue 0 -Force
        $meta | Add-Member -NotePropertyName max_progress_updates -NotePropertyValue 0 -Force
        $meta | Add-Member -NotePropertyName progress_min_interval_sec -NotePropertyValue 30 -Force
        $meta | Add-Member -NotePropertyName transport -NotePropertyValue "auto" -Force
        $meta | Add-Member -NotePropertyName owner_id -NotePropertyValue "legacy" -Force
    }
    if ([string]::IsNullOrWhiteSpace([string]$meta.worker_name)) {
        $meta | Add-Member -NotePropertyName worker_name -NotePropertyValue ([string]$meta.pair_id) -Force
    }
    if ($null -eq $meta.PSObject.Properties["max_turns"]) {
        # Existing workers remain unlimited for backward compatibility. New
        # workers get a bounded default through new-worker.ps1.
        $meta | Add-Member -NotePropertyName max_turns -NotePropertyValue 0 -Force
    }
    if ($null -eq $meta.PSObject.Properties["idle_timeout_sec"]) {
        # Preserve old workers exactly. Newly created workers receive a bounded
        # idle lifetime through new-pair.ps1/new-worker.ps1.
        $meta | Add-Member -NotePropertyName idle_timeout_sec -NotePropertyValue 0 -Force
    }
    if ($null -eq $meta.PSObject.Properties["max_progress_updates"]) {
        $meta | Add-Member -NotePropertyName max_progress_updates -NotePropertyValue 0 -Force
    }
    if ($null -eq $meta.PSObject.Properties["progress_min_interval_sec"]) {
        $meta | Add-Member -NotePropertyName progress_min_interval_sec -NotePropertyValue 30 -Force
    }
    if ($null -eq $meta.PSObject.Properties["transport"] -or [string]::IsNullOrWhiteSpace([string]$meta.transport)) {
        $meta | Add-Member -NotePropertyName transport -NotePropertyValue "auto" -Force
    }
    if ($null -eq $meta.PSObject.Properties["owner_id"] -or [string]::IsNullOrWhiteSpace([string]$meta.owner_id)) {
        $meta | Add-Member -NotePropertyName owner_id -NotePropertyValue "legacy" -Force
    }
    return $meta
}

function Get-CoReviewActiveWorkerCount {
    $root = Get-CoReviewRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return 0 }
    $count = 0
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "pair-*" })) {
        $listenerPid = $null
        if (Test-CoReviewListenerAlive -PairDir $dir.FullName -ListenerPid ([ref]$listenerPid)) { $count++ }
    }
    return $count
}

function Get-CoReviewReservationRoot {
    $path = Join-Path (Get-CoReviewRoot) ".reservations"
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Get-CoReviewPendingWorkerReservationCount {
    $root = Get-CoReviewReservationRoot
    $count = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Filter "*.json" -ErrorAction SilentlyContinue)) {
        try { $reservation = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop } catch { $reservation = $null }
        $valid = $false
        if ($null -ne $reservation) {
            [int]$ownerPid = 0
            $created = [DateTimeOffset]::MinValue
            $valid = [int]::TryParse([string]$reservation.owner_pid, [ref]$ownerPid) -and
                [DateTimeOffset]::TryParse([string]$reservation.created_at, [ref]$created) -and
                ([DateTimeOffset]::Now - $created).TotalMinutes -lt 5 -and
                $null -ne (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)
        }
        if ($valid) { $count++ }
        else { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
    }
    return $count
}

function New-CoReviewWorkerReservation {
    $id = [guid]::NewGuid().ToString("N")
    $path = Join-Path (Get-CoReviewReservationRoot) "$id.json"
    $reservation = [ordered]@{ id=$id; owner_pid=$PID; created_at=(Get-Date).ToString("o") }
    [System.IO.File]::WriteAllText($path, ($reservation | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Get-CoReviewMutexName {
    param(
        [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9-]+$')][string]$Scope,
        [Parameter(Mandatory=$true)][string]$Key
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Key.ToLowerInvariant())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    return "Global\co-review-$Scope-$hash"
}

function Invoke-WithCoReviewMutex {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock,
        [int]$TimeoutMs = 30000
    )
    $mutex = New-Object System.Threading.Mutex($false, $Name)
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne($TimeoutMs) }
        catch [System.Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw "Timed out waiting for co-review lock '$Name'" }
        & $ScriptBlock
    } finally {
        if ($locked) { $mutex.ReleaseMutex() | Out-Null }
        $mutex.Dispose()
    }
}

function Test-CoReviewListenerAlive {
    param(
        [Parameter(Mandatory=$true)][string]$PairDir,
        [ref]$ListenerPid
    )

    if ($null -ne $ListenerPid) { $ListenerPid.Value = $null }
    $pidFile = Join-Path $PairDir "listener.pid"
    if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) { return $false }
    try {
        $raw = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction Stop).Trim()
        if ($raw -notmatch '^\d+$') { return $false }
        $pidValue = [int]$raw
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $pidValue" -ErrorAction SilentlyContinue
        if ($null -eq $proc) { return $false }
        $pairId = Split-Path $PairDir -Leaf
        $commandLine = [string]$proc.CommandLine
        if ($commandLine -notmatch 'codex-listener\.ps1' -or $commandLine -notmatch [regex]::Escape($pairId)) {
            return $false
        }
        if ($null -ne $ListenerPid) { $ListenerPid.Value = $pidValue }
        return $true
    } catch {
        return $false
    }
}

function Resolve-CoReviewWindowStyle {
    param([Parameter(Mandatory=$true)][string]$WindowMode)
    switch ($WindowMode) {
        "Hidden" { return "Hidden" }
        "Minimized" { return "Minimized" }
        "Foreground" { return "Normal" }
        default { throw "Invalid window mode '$WindowMode'" }
    }
}

function ConvertTo-CoReviewCommandLineArgument {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    for ($i = 0; $i -lt $Value.Length; $i++) {
        $backslashes = 0
        while ($i -lt $Value.Length -and $Value[$i] -eq '\') { $backslashes++; $i++ }
        if ($i -eq $Value.Length) {
            [void]$sb.Append('\' * ($backslashes * 2))
            break
        } elseif ($Value[$i] -eq '"') {
            [void]$sb.Append('\' * ($backslashes * 2 + 1))
            [void]$sb.Append('"')
        } else {
            [void]$sb.Append('\' * $backslashes)
            [void]$sb.Append($Value[$i])
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Stop-CoReviewProcessTree {
    param([Parameter(Mandatory=$true)][int]$ProcessId, [int]$TimeoutSec = 5)
    if ($null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return }

    $snapshot = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $treeIds = New-Object System.Collections.Generic.List[int]
    $pending = New-Object System.Collections.Generic.Queue[int]
    $pending.Enqueue($ProcessId)
    while ($pending.Count -gt 0) {
        $parentId = $pending.Dequeue()
        foreach ($child in @($snapshot | Where-Object { $_.ParentProcessId -eq $parentId })) {
            $childId = [int]$child.ProcessId
            if (-not $treeIds.Contains($childId)) {
                $treeIds.Add($childId)
                $pending.Enqueue($childId)
            }
        }
    }
    $treeIds.Add($ProcessId)

    $taskkillExitCode = 1
    try {
        & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null
        $taskkillExitCode = $LASTEXITCODE
    } catch {
        # The process can exit between the initial liveness check and taskkill.
        # The explicit remaining-process check below is authoritative.
        $taskkillExitCode = 1
    }
    $remainingIds = @($treeIds | Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) })
    if ($taskkillExitCode -ne 0 -or $remainingIds.Count -gt 0) {
        $killIds = @($treeIds.ToArray())
        [Array]::Reverse($killIds)
        foreach ($id in $killIds) {
            Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($id in $treeIds) { Wait-Process -Id $id -Timeout $TimeoutSec -ErrorAction SilentlyContinue }
    $remainingIds = @($treeIds | Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) })
    if ($remainingIds.Count -gt 0) {
        throw "Could not stop process tree rooted at PID $ProcessId; remaining PIDs: $($remainingIds -join ', ')"
    }
}

function Start-CoReviewListener {
    param(
        [Parameter(Mandatory=$true)][string]$PairId,
        [Parameter(Mandatory=$true)][string]$PairDir,
        [string]$WindowMode = "",
        [int]$StartupWaitSec = 10
    )

    $meta = Get-NormalizedPairMetadata -PairDir $PairDir
    if ([string]::IsNullOrWhiteSpace($WindowMode)) { $WindowMode = [string]$meta.window_mode }
    $processWindowStyle = Resolve-CoReviewWindowStyle -WindowMode $WindowMode
    $projectCwd = [string]$meta.project_cwd
    if ([string]::IsNullOrWhiteSpace($projectCwd) -or -not (Test-Path -LiteralPath $projectCwd -PathType Container)) {
        throw "Worker working directory does not exist: $projectCwd"
    }
    Assert-ValidCodexBin -CodexBin ([string]$meta.codex_bin)
    $listenerPath = Join-Path $PSScriptRoot "codex-listener.ps1"
    $arguments = @("-NoProfile", "-File", $listenerPath, "-PairId", $PairId, "-CodexBin", [string]$meta.codex_bin)
    if ($meta.dry_run_listener -eq $true) { $arguments += "-DryRun" }
    $argumentString = ($arguments | ForEach-Object { ConvertTo-CoReviewCommandLineArgument -Value $_ }) -join " "
    $listenerStdoutLog = ""
    $listenerStderrLog = ""
    $startParams = @{
        FilePath = "powershell.exe"
        ArgumentList = $argumentString
        WorkingDirectory = $projectCwd
        WindowStyle = $processWindowStyle
        PassThru = $true
        ErrorAction = "Stop"
    }
    if ($WindowMode -eq "Hidden") {
        # A hidden listener must not inherit Claude Code's tool stdout/stderr
        # handles. Inherited background handles can make a successful tool use
        # appear as an error after the foreground creation command has returned.
        $listenerStdoutLog = Join-Path $PairDir "listener.stdout.log"
        $listenerStderrLog = Join-Path $PairDir "listener.stderr.log"
        $startParams.RedirectStandardOutput = $listenerStdoutLog
        $startParams.RedirectStandardError = $listenerStderrLog
    }
    $process = Start-Process @startParams

    $listenerPid = $null
    $deadline = (Get-Date).AddSeconds($StartupWaitSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-CoReviewListenerAlive -PairDir $PairDir -ListenerPid ([ref]$listenerPid)) { break }
        if ($process.HasExited) {
            $process.Dispose()
            throw "Listener process exited during startup for $PairId"
        }
        Start-Sleep -Milliseconds 200
    }
    if (-not (Test-CoReviewListenerAlive -PairDir $PairDir -ListenerPid ([ref]$listenerPid))) {
        if (-not $process.HasExited) { Stop-CoReviewProcessTree -ProcessId $process.Id }
        $process.Dispose()
        throw "Listener did not report a validated PID within ${StartupWaitSec}s for $PairId"
    }
    $processId = $process.Id
    # Start-Process keeps the redirect file handles on its Process object.
    # Release the parent-side handles now; disposing the wrapper does not stop
    # the independently running listener.
    $process.Dispose()
    return [PSCustomObject]@{
        spawned = $true
        spawn_detail = if ($WindowMode -eq "Hidden") { "powershell (Hidden, detached logs)" } else { "powershell ($WindowMode)" }
        listener_pid = $listenerPid
        process_id = $processId
        listener_stdout_log = $listenerStdoutLog
        listener_stderr_log = $listenerStderrLog
    }
}

function Get-CanonicalDirectory {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Directory does not exist: $Path" }
    return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path).TrimEnd('\').ToLowerInvariant()
}

function Get-WriterLeasePath {
    param([Parameter(Mandatory=$true)][string]$WorkingDirectory)
    $canonical = Get-CanonicalDirectory -Path $WorkingDirectory
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $leaseRoot = Join-Path (Get-CoReviewRoot) ".leases"
    return (Join-Path $leaseRoot "$hash.json")
}

function Test-WriterLeaseOwnerLive {
    param([Parameter(Mandatory=$true)]$Lease)
    $ownerPairDir = [string]$Lease.pair_dir
    if ([string]::IsNullOrWhiteSpace($ownerPairDir) -or -not (Test-Path -LiteralPath $ownerPairDir -PathType Container)) { return $false }
    $listenerPid = $null
    if (Test-CoReviewListenerAlive -PairDir $ownerPairDir -ListenerPid ([ref]$listenerPid)) { return $true }
    try {
        $created = [DateTimeOffset]::Parse([string]$Lease.created_at)
        if (([DateTimeOffset]::Now - $created).TotalSeconds -lt 15) { return $true }
    } catch {}
    return $false
}

function Try-AcquireWriterLeaseUnlocked {
    param(
        [Parameter(Mandatory=$true)][string]$PairId,
        [Parameter(Mandatory=$true)][string]$PairDir,
        [Parameter(Mandatory=$true)][string]$WorkingDirectory
    )

    $canonical = Get-CanonicalDirectory -Path $WorkingDirectory
    $leasePath = Get-WriterLeasePath -WorkingDirectory $canonical
    New-Item -ItemType Directory -Path (Split-Path $leasePath -Parent) -Force | Out-Null
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        if (Test-Path -LiteralPath $leasePath -PathType Leaf) {
            try { $existing = Get-Content -LiteralPath $leasePath -Raw | ConvertFrom-Json } catch { $existing = $null }
            if ($null -ne $existing -and [string]$existing.pair_id -eq $PairId) {
                return [PSCustomObject]@{ acquired = $true; lease_path = $leasePath; owner = $existing }
            }
            if ($null -ne $existing -and (Test-WriterLeaseOwnerLive -Lease $existing)) {
                return [PSCustomObject]@{ acquired = $false; lease_path = $leasePath; owner = $existing }
            }
            Remove-Item -LiteralPath $leasePath -Force -ErrorAction SilentlyContinue
        }

        $lease = [ordered]@{
            pair_id = $PairId
            pair_dir = $PairDir
            working_directory = $canonical
            created_at = (Get-Date).ToString("o")
        }
        $json = $lease | ConvertTo-Json -Compress
        try {
            $stream = [System.IO.File]::Open($leasePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $data = [System.Text.Encoding]::UTF8.GetBytes($json)
                $stream.Write($data, 0, $data.Length)
            } finally { $stream.Dispose() }
            return [PSCustomObject]@{ acquired = $true; lease_path = $leasePath; owner = [PSCustomObject]$lease }
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 50
        }
    }
    throw "Could not acquire writer lease for $canonical"
}

function Try-AcquireWriterLease {
    param(
        [Parameter(Mandatory=$true)][string]$PairId,
        [Parameter(Mandatory=$true)][string]$PairDir,
        [Parameter(Mandatory=$true)][string]$WorkingDirectory
    )
    $canonical = Get-CanonicalDirectory -Path $WorkingDirectory
    $mutexName = Get-CoReviewMutexName -Scope "writer-lease" -Key $canonical
    Invoke-WithCoReviewMutex -Name $mutexName -ScriptBlock {
        Try-AcquireWriterLeaseUnlocked -PairId $PairId -PairDir $PairDir -WorkingDirectory $canonical
    }
}

function Acquire-WriterLease {
    param(
        [Parameter(Mandatory=$true)][string]$PairId,
        [Parameter(Mandatory=$true)][string]$PairDir,
        [Parameter(Mandatory=$true)][string]$WorkingDirectory
    )
    $result = Try-AcquireWriterLease -PairId $PairId -PairDir $PairDir -WorkingDirectory $WorkingDirectory
    if (-not $result.acquired) {
        throw "Writer lease conflict for '$WorkingDirectory': owned by $([string]$result.owner.pair_id)"
    }
    return $result
}

function Release-WriterLeaseUnlocked {
    param([Parameter(Mandatory=$true)][string]$PairId, [Parameter(Mandatory=$true)][string]$WorkingDirectory)
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory) -or -not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) { return }
    $leasePath = Get-WriterLeasePath -WorkingDirectory $WorkingDirectory
    if (-not (Test-Path -LiteralPath $leasePath -PathType Leaf)) { return }
    try { $lease = Get-Content -LiteralPath $leasePath -Raw | ConvertFrom-Json } catch { return }
    if ([string]$lease.pair_id -eq $PairId) { Remove-Item -LiteralPath $leasePath -Force -ErrorAction SilentlyContinue }
}

function Release-WriterLease {
    param([Parameter(Mandatory=$true)][string]$PairId, [Parameter(Mandatory=$true)][string]$WorkingDirectory)
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory) -or -not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) { return }
    $canonical = Get-CanonicalDirectory -Path $WorkingDirectory
    $mutexName = Get-CoReviewMutexName -Scope "writer-lease" -Key $canonical
    Invoke-WithCoReviewMutex -Name $mutexName -ScriptBlock {
        Release-WriterLeaseUnlocked -PairId $PairId -WorkingDirectory $canonical
    }
}
