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

    return @"
CODEX LEAF WORKER
WORKER: $workerName
MODE: $mode
WORKING DIRECTORY: $workingDirectory

You are a leaf worker controlled by Claude. Do not spawn, delegate to, or coordinate other agents.
Do not broaden the task or permissions. Report blockers instead.

COMPLETION CONTRACT:
$($contract.Trim())

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
    }
    if ([string]::IsNullOrWhiteSpace([string]$meta.worker_name)) {
        $meta | Add-Member -NotePropertyName worker_name -NotePropertyValue ([string]$meta.pair_id) -Force
    }
    return $meta
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

function Start-CoReviewListener {
    param(
        [Parameter(Mandatory=$true)][string]$PairId,
        [Parameter(Mandatory=$true)][string]$PairDir,
        [string]$WindowMode = "",
        [int]$StartupWaitSec = 10
    )

    $meta = Get-NormalizedPairMetadata -PairDir $PairDir
    if ([string]::IsNullOrWhiteSpace($WindowMode)) { $WindowMode = [string]$meta.window_mode }
    if ($WindowMode -notin @("Hidden", "Minimized", "Foreground")) { throw "Invalid window mode '$WindowMode'" }
    $projectCwd = [string]$meta.project_cwd
    if ([string]::IsNullOrWhiteSpace($projectCwd) -or -not (Test-Path -LiteralPath $projectCwd -PathType Container)) {
        throw "Worker working directory does not exist: $projectCwd"
    }
    Assert-ValidCodexBin -CodexBin ([string]$meta.codex_bin)
    $listenerPath = Join-Path $PSScriptRoot "codex-listener.ps1"
    $arguments = @("-NoProfile", "-File", $listenerPath, "-PairId", $PairId, "-CodexBin", [string]$meta.codex_bin)
    if ($meta.dry_run_listener -eq $true) { $arguments += "-DryRun" }
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WorkingDirectory $projectCwd -WindowStyle $WindowMode -PassThru -ErrorAction Stop

    $listenerPid = $null
    $deadline = (Get-Date).AddSeconds($StartupWaitSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-CoReviewListenerAlive -PairDir $PairDir -ListenerPid ([ref]$listenerPid)) { break }
        if ($process.HasExited) { throw "Listener process exited during startup for $PairId" }
        Start-Sleep -Milliseconds 200
    }
    return [PSCustomObject]@{
        spawned = $true
        spawn_detail = "powershell ($WindowMode)"
        listener_pid = $listenerPid
        process_id = $process.Id
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

function Try-AcquireWriterLease {
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

function Release-WriterLease {
    param([Parameter(Mandatory=$true)][string]$PairId, [Parameter(Mandatory=$true)][string]$WorkingDirectory)
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory) -or -not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) { return }
    $leasePath = Get-WriterLeasePath -WorkingDirectory $WorkingDirectory
    if (-not (Test-Path -LiteralPath $leasePath -PathType Leaf)) { return }
    try { $lease = Get-Content -LiteralPath $leasePath -Raw | ConvertFrom-Json } catch { return }
    if ([string]$lease.pair_id -eq $PairId) { Remove-Item -LiteralPath $leasePath -Force -ErrorAction SilentlyContinue }
}
