# co-review: low-level backward-compatible worker creation.
[CmdletBinding()]
param(
    [string]$Task = "",
    [string]$ProjectCwd = "",
    [string]$CodexBin = "",
    [string]$CodexModel = "gpt-5.5",
    [string]$CodexReasoning = "medium",
    [int]$CodexTimeoutSec = 1800,
    [ValidateRange(0, 1000)][int]$MaxTurns = 0,
    [ValidateRange(0, 86400)][int]$IdleTimeoutSec = 900,
    [ValidateRange(0, 10)][int]$MaxProgressUpdates = 0,
    [ValidateRange(0, 3600)][int]$ProgressMinIntervalSec = 30,
    [ValidateSet("Minimized", "Hidden", "Foreground")][string]$WindowMode = "Minimized",
    [ValidateSet("auto", "app-server", "legacy")][string]$Transport = "auto",
    [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$OwnerId = "",
    [ValidateSet("review", "workhorse", "imagegen")][string]$Mode = "review",
    [string]$WorkerName = "",
    [ValidateSet("auto", "shared", "worktree")][string]$Isolation = "shared",
    [ValidateSet("", "read-only", "workspace-write", "danger-full-access")][string]$Sandbox = "",
    [switch]$ConfirmDangerFullAccess,
    [string[]]$ConfigOverride = @(),
    [string]$Profile = "",
    [string[]]$AddDir = @(),
    [switch]$Search,
    [switch]$AllowDirtyBase,
    [switch]$NoSpawn,
    [switch]$DryRunListener
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")
. (Join-Path $PSScriptRoot "worktrees.ps1")

$effective = Get-ExecutionPolicy
if ($effective -in @('Restricted', 'AllSigned')) {
    throw "PowerShell execution policy '$effective' blocks local listener scripts. Use CurrentUser RemoteSigned."
}

if ([string]::IsNullOrWhiteSpace($ProjectCwd)) { $ProjectCwd = (Get-Location).Path }
$sourceProjectCwd = Get-CanonicalDirectory -Path $ProjectCwd

if ([string]::IsNullOrWhiteSpace($CodexBin)) {
    $CodexBin = Resolve-CodexBin
}
Assert-ValidCodexBin -CodexBin $CodexBin
Assert-SafeCodexConfigOverrides -Overrides $ConfigOverride

if ([string]::IsNullOrWhiteSpace($Sandbox)) { $Sandbox = if ($Mode -eq "review") { "read-only" } else { "workspace-write" } }
if ($Mode -eq "review" -and $Sandbox -ne "read-only") { throw "Review workers must use the read-only sandbox" }
if ($Mode -eq "imagegen" -and $Sandbox -eq "read-only") { throw "Imagegen workers require a writable sandbox" }
if ($Sandbox -eq "danger-full-access" -and -not $ConfirmDangerFullAccess) { throw "danger-full-access requires -ConfirmDangerFullAccess" }
if ($Mode -eq "review" -and $Isolation -eq "worktree") { throw "Review workers do not need worktree isolation" }

$resolvedAddDirs = @()
foreach ($dir in $AddDir) { $resolvedAddDirs += (Get-CanonicalDirectory -Path $dir) }

$requestedCodexModel = $CodexModel
$requestedCodexReasoning = $CodexReasoning
$capabilities = Get-CodexCapabilities -CodexBin $CodexBin
$selection = Resolve-CodexSelection -Capabilities $capabilities -Model $CodexModel -Reasoning $CodexReasoning -AllowUnknownModel
$CodexModel = [string]$selection.model
$CodexReasoning = [string]$selection.reasoning

$timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$randHex = [guid]::NewGuid().ToString("N").Substring(0, 12)
$pairId = "pair-$timestamp-$randHex"
if ([string]::IsNullOrWhiteSpace($WorkerName)) { $WorkerName = $pairId }
if ([string]::IsNullOrWhiteSpace($OwnerId)) { $OwnerId = "owner-" + [guid]::NewGuid().ToString("N").Substring(0, 12) }

$root = Get-CoReviewRoot
$pairDir = Join-Path $root $pairId
New-Item -ItemType Directory -Path $pairDir -Force | Out-Null
$actualProjectCwd = $sourceProjectCwd
$resolvedIsolation = if ($Mode -eq "review") { "shared" } else { $Isolation }
$lease = $null
$managedWorktree = $null

try {
    if ($Mode -in @("workhorse", "imagegen")) {
        if ($Isolation -eq "worktree") {
            $managedWorktree = New-CoReviewManagedWorktree -PairId $pairId -SourcePath $sourceProjectCwd -AllowDirtyBase:$AllowDirtyBase
            $actualProjectCwd = [string]$managedWorktree.worktree_path
            $resolvedIsolation = "worktree"
            $lease = Acquire-WriterLease -PairId $pairId -PairDir $pairDir -WorkingDirectory $actualProjectCwd
        } elseif ($Isolation -eq "shared") {
            $resolvedIsolation = "shared"
            $lease = Acquire-WriterLease -PairId $pairId -PairDir $pairDir -WorkingDirectory $actualProjectCwd
        } else {
            $leaseAttempt = Try-AcquireWriterLease -PairId $pairId -PairDir $pairDir -WorkingDirectory $actualProjectCwd
            if ($leaseAttempt.acquired) {
                $lease = $leaseAttempt
                $resolvedIsolation = "shared"
            } else {
                $gitInfo = Get-CoReviewGitInfo -Path $sourceProjectCwd
                if ($gitInfo.dirty -and -not $AllowDirtyBase) {
                    throw "Source repository has uncommitted changes; automatic parallel writer isolation is unsafe. Serialize the writable worker or commit/stash the changes first."
                }
                $managedWorktree = New-CoReviewManagedWorktree -PairId $pairId -SourcePath $sourceProjectCwd -AllowDirtyBase:$AllowDirtyBase
                $actualProjectCwd = [string]$managedWorktree.worktree_path
                $resolvedIsolation = "worktree"
                $lease = Acquire-WriterLease -PairId $pairId -PairDir $pairDir -WorkingDirectory $actualProjectCwd
            }
        }
    }

    [System.IO.File]::WriteAllText((Join-Path $pairDir "to-codex.jsonl"), "", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $pairDir "to-claude.jsonl"), "", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $pairDir ".inbox.seq"), "0", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $pairDir ".outbox.seq"), "0", [System.Text.UTF8Encoding]::new($false))
    $state = @{ last_processed = $null; codex_session_id = $null; codex_thread_id = $null; inbox_offset = 0; msg_counter = 0; completed_turns = 0 } | ConvertTo-Json
    [System.IO.File]::WriteAllText((Join-Path $pairDir "state.json"), $state, [System.Text.UTF8Encoding]::new($false))

    $meta = [ordered]@{
        schema_version = 2
        pair_id = $pairId
        worker_name = $WorkerName
        owner_id = $OwnerId
        created_at = (Get-Date).ToString("o")
        source_project_cwd = $sourceProjectCwd
        project_cwd = $actualProjectCwd
        task_hint = $Task
        mode = $Mode
        sandbox = $Sandbox
        isolation = $resolvedIsolation
        requested_isolation = $Isolation
        codex_bin = $CodexBin
        requested_model = $requestedCodexModel
        codex_model = $CodexModel
        requested_reasoning = $requestedCodexReasoning
        codex_reasoning = $CodexReasoning
        config_overrides = @($ConfigOverride)
        profile = $Profile
        add_dirs = @($resolvedAddDirs)
        search_enabled = [bool]$Search
        codex_timeout_sec = $CodexTimeoutSec
        max_turns = $MaxTurns
        idle_timeout_sec = $IdleTimeoutSec
        max_progress_updates = $MaxProgressUpdates
        progress_min_interval_sec = $ProgressMinIntervalSec
        transport = $Transport
        window_mode = $WindowMode
        dry_run_listener = [bool]$DryRunListener
        worktree_path = if ($null -ne $managedWorktree) { [string]$managedWorktree.worktree_path } else { "" }
        worktree_branch = if ($null -ne $managedWorktree) { [string]$managedWorktree.worktree_branch } else { "" }
        source_repo = if ($null -ne $managedWorktree) { [string]$managedWorktree.source_repo } else { "" }
    }
    $metaJson = $meta | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText((Join-Path $pairDir "pair.json"), $metaJson, [System.Text.UTF8Encoding]::new($false))

    $spawned = $false
    $spawnDetail = "no-spawn (caller passed -NoSpawn)"
    $listenerPid = $null
    $listenerStdoutLog = ""
    $listenerStderrLog = ""
    if (-not $NoSpawn) {
        $started = Start-CoReviewListener -PairId $pairId -PairDir $pairDir -WindowMode $WindowMode
        $spawned = $true
        $spawnDetail = [string]$started.spawn_detail
        $listenerPid = $started.listener_pid
        $listenerStdoutLog = [string]$started.listener_stdout_log
        $listenerStderrLog = [string]$started.listener_stderr_log
    }

    Write-Host "[co-review] Created worker: $WorkerName ($pairId)"
    Write-Host "[co-review] Mode:           $Mode / $Sandbox / $resolvedIsolation"
    Write-Host "[co-review] Working dir:    $actualProjectCwd"
    Write-Host "[co-review] Codex model:    $CodexModel ($CodexReasoning reasoning)"
    Write-Host "[co-review] Window:         $spawnDetail"
    Write-Host ""

    [PSCustomObject]@{
        worker_id = $pairId
        pair_id = $pairId
        name = $WorkerName
        worker_name = $WorkerName
        owner_id = $OwnerId
        pair_dir = $pairDir
        project_cwd = $actualProjectCwd
        source_project_cwd = $sourceProjectCwd
        window_spawned = $spawned
        spawn_detail = $spawnDetail
        listener_pid = $listenerPid
        listener_stdout_log = $listenerStdoutLog
        listener_stderr_log = $listenerStderrLog
        codex_bin = $CodexBin
        codex_model = $CodexModel
        codex_reasoning = $CodexReasoning
        codex_timeout_sec = $CodexTimeoutSec
        max_turns = $MaxTurns
        idle_timeout_sec = $IdleTimeoutSec
        max_progress_updates = $MaxProgressUpdates
        progress_min_interval_sec = $ProgressMinIntervalSec
        transport = $Transport
        mode = $Mode
        sandbox = $Sandbox
        isolation = $resolvedIsolation
        schema_version = 2
    } | ConvertTo-Json -Compress -Depth 10
} catch {
    if ($null -ne $lease) { Release-WriterLease -PairId $pairId -WorkingDirectory $actualProjectCwd }
    if ($null -ne $managedWorktree -and (Test-Path -LiteralPath $managedWorktree.worktree_path)) {
        try { Remove-CoReviewManagedWorktree -SourceRepo $managedWorktree.source_repo -WorktreePath $managedWorktree.worktree_path } catch {}
    }
    if (Test-Path -LiteralPath $pairDir) { Remove-Item -LiteralPath $pairDir -Recurse -Force -ErrorAction SilentlyContinue }
    throw
}
