[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]
param([Parameter(Mandatory=$true)][string]$PairId, [switch]$Force)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")
$pairDir = Get-PairDir -PairId $PairId -MustExist
$meta = Get-NormalizedPairMetadata -PairDir $pairDir
$listenerPid = $null
if (Test-CoReviewListenerAlive -PairDir $pairDir -ListenerPid ([ref]$listenerPid)) { throw "Worker $PairId still has a live listener. Run end-pair.ps1 first." }
if ($Force -or $PSCmdlet.ShouldProcess($pairDir, "Delete co-review worker directory")) {
    if ([string]$meta.mode -eq "workhorse") { Release-WriterLease -PairId $PairId -WorkingDirectory ([string]$meta.project_cwd) }
    Remove-Item -LiteralPath $pairDir -Recurse -Force
    Write-Host "[co-review] Deleted worker $PairId"
}
