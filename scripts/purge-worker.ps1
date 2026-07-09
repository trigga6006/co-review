[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]
param([Parameter(Mandatory=$true)][Alias("PairId")][string]$WorkerId, [switch]$Force)
& (Join-Path $PSScriptRoot "purge-pair.ps1") -PairId $WorkerId -Force:$Force
