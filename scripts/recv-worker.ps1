[CmdletBinding()]
param([Parameter(Mandatory=$true)][Alias("PairId")][string]$WorkerId, [string]$Since="", [switch]$Wait, [int]$TimeoutSec=600, [int]$PollIntervalSec=2)
& (Join-Path $PSScriptRoot "recv.ps1") -PairId $WorkerId -Since $Since -Wait:$Wait -TimeoutSec $TimeoutSec -PollIntervalSec $PollIntervalSec
