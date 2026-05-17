# co-review: end-pair.ps1
# Drop a 'shutdown' file so the listener exits cleanly on next poll.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PairId,
    [switch]$Archive,  # move pair dir to ~/.cc-codex-pairs/archive/
    [switch]$Delete
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$pairDir = Get-PairDir -PairId $PairId -MustExist
if ($Archive -and $Delete) {
    Write-Error "Use either -Archive or -Delete, not both."
    exit 1
}

$shutdownFile = Join-Path $pairDir "shutdown"
"" | Out-File -FilePath $shutdownFile -Encoding ascii -NoNewline
Write-Host "[co-review] Shutdown signaled for $PairId" -ForegroundColor Yellow
Write-Host "[co-review] The listener will exit within a few seconds."

if ($Archive -or $Delete) {
    Start-Sleep -Seconds 4  # give listener time to exit
}

if ($Delete) {
    try {
        Remove-Item -LiteralPath $pairDir -Recurse -Force
        Write-Host "[co-review] Deleted pair dir $pairDir" -ForegroundColor DarkGray
    } catch {
        Write-Host "[co-review] Delete failed (file may still be locked by listener): $($_.Exception.Message)" -ForegroundColor Red
    }
} elseif ($Archive) {
    $archiveRoot = Join-Path -Path (Get-CoReviewRoot) -ChildPath "archive"
    New-Item -ItemType Directory -Path $archiveRoot -Force | Out-Null
    $dest = Join-Path -Path $archiveRoot -ChildPath $PairId
    try {
        Move-Item -LiteralPath $pairDir -Destination $dest -Force
        Write-Host "[co-review] Archived to $dest" -ForegroundColor DarkGray
    } catch {
        Write-Host "[co-review] Archive failed (file may still be locked by listener): $($_.Exception.Message)" -ForegroundColor Red
    }
}
