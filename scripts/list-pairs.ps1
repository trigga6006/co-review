# List legacy pairs and schema-v2 workers.
[CmdletBinding()]
param([switch]$IncludeArchived, [switch]$Json)
$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "common.ps1")
$root = Get-CoReviewRoot
if (-not (Test-Path -LiteralPath $root)) {
    if ($Json) { Write-Output "[]" } else { Write-Host "[co-review] No workers yet." }
    return
}
$results = @()
foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "pair-*" })) {
    try { $meta = Get-NormalizedPairMetadata -PairDir $dir.FullName } catch { continue }
    try { $state = Get-Content -LiteralPath (Join-Path $dir.FullName "state.json") -Raw | ConvertFrom-Json } catch { $state = $null }
    $listenerPid = $null
    $alive = Test-CoReviewListenerAlive -PairDir $dir.FullName -ListenerPid ([ref]$listenerPid)
    $activeTurn = $null
    $activeTurnPath = Join-Path $dir.FullName "active-turn.json"
    if (Test-Path -LiteralPath $activeTurnPath -PathType Leaf) {
        try { $activeTurn = Get-Content -LiteralPath $activeTurnPath -Raw | ConvertFrom-Json } catch { $activeTurn = $null }
    }
    $repliedTo = @{}
    $replyPath = Join-Path $dir.FullName "to-claude.jsonl"
    if (Test-Path -LiteralPath $replyPath -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $replyPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            try { $replyObj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ([string]$replyObj.type -in @("response", "error") -and -not [string]::IsNullOrWhiteSpace([string]$replyObj.in_reply_to)) { $repliedTo[[string]$replyObj.in_reply_to] = $true }
        }
    }
    $pendingIds = @()
    $requestPath = Join-Path $dir.FullName "to-codex.jsonl"
    if (Test-Path -LiteralPath $requestPath -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $requestPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            try { $requestObj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if (-not $repliedTo.ContainsKey([string]$requestObj.id)) { $pendingIds += [string]$requestObj.id }
        }
    }
    $status = if (-not $alive) { "dead" } elseif (Test-Path -LiteralPath (Join-Path $dir.FullName "shutdown")) { "shutdown-pending" } elseif ($null -ne $activeTurn) { "busy" } else { "idle" }
    $activeElapsedSec = 0
    if ($null -ne $activeTurn) {
        try { $activeElapsedSec = [Math]::Max(0, [Math]::Round(((Get-Date) - [DateTimeOffset]::Parse([string]$activeTurn.started_at).LocalDateTime).TotalSeconds)) } catch { $activeElapsedSec = 0 }
    }
    $progress = $null
    $progressPath = Join-Path $dir.FullName "progress.json"
    if (Test-Path -LiteralPath $progressPath -PathType Leaf) {
        try { $progress = Get-Content -LiteralPath $progressPath -Raw | ConvertFrom-Json } catch { $progress = $null }
    }
    $leasePath = $null
    $hasLease = $false
    if ([string]$meta.mode -in @("workhorse", "imagegen") -and (Test-Path -LiteralPath ([string]$meta.project_cwd) -PathType Container)) {
        $leasePath = Get-WriterLeasePath -WorkingDirectory ([string]$meta.project_cwd)
        if (Test-Path -LiteralPath $leasePath) {
            try { $lease = Get-Content -LiteralPath $leasePath -Raw | ConvertFrom-Json; $hasLease = ([string]$lease.pair_id -eq $dir.Name) } catch {}
        }
    }
    $lastActivity = [string]$meta.created_at
    foreach ($fileName in @("to-codex.jsonl", "to-claude.jsonl", "listener.log")) {
        $file = Get-Item -LiteralPath (Join-Path $dir.FullName $fileName) -ErrorAction SilentlyContinue
        if ($null -ne $file -and $file.LastWriteTimeUtc -gt [DateTime]::Parse($lastActivity).ToUniversalTime()) { $lastActivity = $file.LastWriteTimeUtc.ToString("o") }
    }
    $results += [PSCustomObject]@{
        pair_id=$dir.Name; pair_dir=$dir.FullName; worker_name=[string]$meta.worker_name; schema_version=[int]$meta.schema_version
        created_at=[string]$meta.created_at; project_cwd=[string]$meta.project_cwd; source_project_cwd=[string]$meta.source_project_cwd
        task_hint=[string]$meta.task_hint; mode=[string]$meta.mode; sandbox=[string]$meta.sandbox; isolation=[string]$meta.isolation
        codex_model=[string]$meta.codex_model; codex_reasoning=[string]$meta.codex_reasoning; listener_pid=$listenerPid; status=$status
        codex_session_id=if($state){[string]$state.codex_session_id}else{""}; writer_lease=$hasLease; last_activity=$lastActivity
        active_message_id=if($activeTurn){[string]$activeTurn.message_id}else{""}; active_elapsed_sec=$activeElapsedSec
        queue_depth=$pendingIds.Count; pending_message_ids=@($pendingIds); completed_turns=if($state -and $null -ne $state.PSObject.Properties['completed_turns']){[int]$state.completed_turns}else{0}; max_turns=[int]$meta.max_turns
        progress_count=if($progress){[int]$progress.count}else{0}; last_progress_at=if($progress){[string]$progress.last_progress_at}else{""}; last_progress=if($progress){[string]$progress.last_progress}else{""}
        max_progress_updates=[int]$meta.max_progress_updates
    }
}
$results = @($results | Sort-Object created_at -Descending)
if ($Json) { ConvertTo-Json -InputObject $results -Depth 8 }
else { $results | Format-Table pair_id,worker_name,mode,isolation,codex_model,codex_reasoning,status,queue_depth -AutoSize }
