[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PairId, [switch]$Json)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")
$pairDir = Get-PairDir -PairId $PairId -MustExist
$mutexName = Get-CoReviewMutexName -Scope "lifecycle" -Key $PairId
$result = Invoke-WithCoReviewMutex -Name $mutexName -ScriptBlock {
    $meta = Get-NormalizedPairMetadata -PairDir $pairDir
    $statePath = Join-Path $pairDir "state.json"
    if ([int]$meta.max_turns -gt 0 -and (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $completedTurns = if ($null -ne $state.PSObject.Properties["completed_turns"]) { [int]$state.completed_turns } else { 0 }
        if ($completedTurns -ge [int]$meta.max_turns) {
            throw "Worker $PairId reached its turn limit ($($meta.max_turns)) and has retired. Start a fresh worker for a new responsibility."
        }
    }
    $listenerPid = $null
    if (Test-CoReviewListenerAlive -PairDir $pairDir -ListenerPid ([ref]$listenerPid)) {
        return [PSCustomObject]@{ worker_id=$PairId; pair_id=$PairId; status="active"; restarted=$false; listener_pid=$listenerPid; pair_dir=$pairDir }
    }

    $leaseAcquired = $false
    try {
        if ([string]$meta.mode -in @("workhorse", "imagegen")) {
            Acquire-WriterLease -PairId $PairId -PairDir $pairDir -WorkingDirectory ([string]$meta.project_cwd) | Out-Null
            $leaseAcquired = $true
        }
        Remove-Item -LiteralPath (Join-Path $pairDir "listener.pid") -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $pairDir "shutdown") -Force -ErrorAction SilentlyContinue
        $started = Start-CoReviewListener -PairId $PairId -PairDir $pairDir -WindowMode ([string]$meta.window_mode)
        return [PSCustomObject]@{ worker_id=$PairId; pair_id=$PairId; status="active"; restarted=$true; listener_pid=$started.listener_pid; pair_dir=$pairDir; listener_stdout_log=$started.listener_stdout_log; listener_stderr_log=$started.listener_stderr_log }
    } catch {
        if ($leaseAcquired) { Release-WriterLease -PairId $PairId -WorkingDirectory ([string]$meta.project_cwd) }
        throw
    }
}
if (-not $Json) { Write-Host "[co-review] Worker $PairId is $($result.status) (restarted=$($result.restarted))" }
$result | ConvertTo-Json -Compress
