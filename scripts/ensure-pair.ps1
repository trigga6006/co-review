[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PairId, [switch]$Json)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")
$pairDir = Get-PairDir -PairId $PairId -MustExist
$meta = Get-NormalizedPairMetadata -PairDir $pairDir
$listenerPid = $null
if (Test-CoReviewListenerAlive -PairDir $pairDir -ListenerPid ([ref]$listenerPid)) {
    $result = [PSCustomObject]@{ worker_id=$PairId; pair_id=$PairId; status="active"; restarted=$false; listener_pid=$listenerPid; pair_dir=$pairDir }
} else {
    if ([string]$meta.mode -eq "workhorse") { Acquire-WriterLease -PairId $PairId -PairDir $pairDir -WorkingDirectory ([string]$meta.project_cwd) | Out-Null }
    Remove-Item -LiteralPath (Join-Path $pairDir "listener.pid") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $pairDir "shutdown") -Force -ErrorAction SilentlyContinue
    $started = Start-CoReviewListener -PairId $PairId -PairDir $pairDir -WindowMode ([string]$meta.window_mode)
    $result = [PSCustomObject]@{ worker_id=$PairId; pair_id=$PairId; status="active"; restarted=$true; listener_pid=$started.listener_pid; pair_dir=$pairDir }
}
if (-not $Json) { Write-Host "[co-review] Worker $PairId is $($result.status) (restarted=$($result.restarted))" }
$result | ConvertTo-Json -Compress
