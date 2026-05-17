# co-review: purge-pair.ps1
# Permanently delete a stopped pair directory and its retained message logs.
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]
param(
    [Parameter(Mandatory=$true)][string]$PairId,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$pairDir = Get-PairDir -PairId $PairId -MustExist
$pidFile = Join-Path $pairDir "listener.pid"
if (Test-Path -LiteralPath $pidFile) {
    $raw = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if ($raw -match '^\d+$' -and (Get-Process -Id ([int]$raw) -ErrorAction SilentlyContinue)) {
        Write-Error "Pair $PairId still has a live listener process. Run end-pair.ps1 first."
        exit 1
    }
}

if ($Force -or $PSCmdlet.ShouldProcess($pairDir, "Delete co-review pair directory")) {
    Remove-Item -LiteralPath $pairDir -Recurse -Force
    Write-Host "[co-review] Deleted pair dir $pairDir" -ForegroundColor Yellow
}
