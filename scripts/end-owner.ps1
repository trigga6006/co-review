[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')]
    [string]$OwnerId,
    [switch]$Archive,
    [switch]$Delete,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

if ($Archive -and $Delete) { throw "Use either -Archive or -Delete, not both" }

$root = Get-CoReviewRoot
$results = @()
if (Test-Path -LiteralPath $root -PathType Container) {
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -Filter "pair-*" -ErrorAction SilentlyContinue)) {
        try { $meta = Get-NormalizedPairMetadata -PairDir $dir.FullName } catch { continue }
        if ([string]$meta.owner_id -ne $OwnerId) { continue }
        try {
            & (Join-Path $PSScriptRoot "end-pair.ps1") -PairId $dir.Name -Archive:$Archive -Delete:$Delete | Out-Null
            $results += [PSCustomObject]@{ worker_id=$dir.Name; status="stopped"; error="" }
        } catch {
            $results += [PSCustomObject]@{ worker_id=$dir.Name; status="error"; error=$_.Exception.Message }
        }
    }
}

$failed = @($results | Where-Object { $_.status -eq "error" })
if ($Json) { ConvertTo-Json -InputObject @($results) -Depth 5 }
else { Write-Host "[co-review] Stopped $(@($results | Where-Object { $_.status -eq 'stopped' }).Count) worker(s) owned by $OwnerId." }
if ($failed.Count -gt 0) { throw "Failed to stop $($failed.Count) worker(s) owned by $OwnerId" }
