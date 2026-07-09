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
    $status = if (-not $alive) { "dead" } elseif (Test-Path -LiteralPath (Join-Path $dir.FullName "shutdown")) { "shutdown-pending" } else { "active" }
    $leasePath = $null
    $hasLease = $false
    if ([string]$meta.mode -eq "workhorse" -and (Test-Path -LiteralPath ([string]$meta.project_cwd) -PathType Container)) {
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
    }
}
$results = @($results | Sort-Object created_at -Descending)
if ($Json) { ConvertTo-Json -InputObject $results -Depth 8 }
else { $results | Format-Table pair_id,worker_name,mode,isolation,codex_model,codex_reasoning,status -AutoSize }
