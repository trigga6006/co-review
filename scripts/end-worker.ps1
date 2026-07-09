[CmdletBinding()]
param([Parameter(Mandatory=$true)][Alias("PairId")][string]$WorkerId, [switch]$Archive, [switch]$Delete, [switch]$RemoveWorktree, [switch]$ConfirmRemoveWorktree)
& (Join-Path $PSScriptRoot "end-pair.ps1") -PairId $WorkerId -Archive:$Archive -Delete:$Delete -RemoveWorktree:$RemoveWorktree -ConfirmRemoveWorktree:$ConfirmRemoveWorktree
