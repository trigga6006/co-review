[CmdletBinding()]
param([Parameter(Mandatory=$true)][Alias("PairId")][string]$WorkerId, [switch]$Json)
& (Join-Path $PSScriptRoot "ensure-pair.ps1") -PairId $WorkerId -Json:$Json
