[CmdletBinding(DefaultParameterSetName="Inline")]
param(
    [Parameter(Mandatory=$true)][Alias("PairId")][string]$WorkerId,
    [Parameter(Mandatory=$true, ParameterSetName="Inline")][string]$Message,
    [Parameter(Mandatory=$true, ParameterSetName="File")][string]$MessageFile,
    [string]$Type = "request", [string]$Model = "", [string]$Reasoning = "", [int]$TurnTimeoutSec = 0
)
$params = @{ PairId=$WorkerId; Type=$Type; Model=$Model; Reasoning=$Reasoning; TurnTimeoutSec=$TurnTimeoutSec }
if ($PSCmdlet.ParameterSetName -eq "File") { $params.MessageFile = $MessageFile } else { $params.Message = $Message }
& (Join-Path $PSScriptRoot "send.ps1") @params
