[CmdletBinding(DefaultParameterSetName="Inline")]
param(
    [Parameter(Mandatory=$true)][Alias("PairId")][string]$WorkerId,
    [Parameter(Mandatory=$true, ParameterSetName="Inline")][string]$Message,
    [Parameter(Mandatory=$true, ParameterSetName="File")][string]$MessageFile,
    [string]$Type = "request", [int]$TimeoutSec = 600, [int]$PollIntervalSec = 2,
    [string]$Model = "", [string]$Reasoning = "", [int]$TurnTimeoutSec = 0, [switch]$RawJson
)
$params = @{ PairId=$WorkerId; Type=$Type; TimeoutSec=$TimeoutSec; PollIntervalSec=$PollIntervalSec; Model=$Model; Reasoning=$Reasoning; TurnTimeoutSec=$TurnTimeoutSec; RawJson=$RawJson }
if ($PSCmdlet.ParameterSetName -eq "File") { $params.MessageFile = $MessageFile } else { $params.Message = $Message }
& (Join-Path $PSScriptRoot "ask.ps1") @params
