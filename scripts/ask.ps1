# co-review: ask.ps1
# Convenience: send a message and block until Codex replies. Prints the reply.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PairId,
    [Parameter(Mandatory=$true, ParameterSetName="Inline")][string]$Message,
    [Parameter(Mandatory=$true, ParameterSetName="File")][string]$MessageFile,
    [string]$Type = "request",
    [int]$TimeoutSec = 600,
    [int]$PollIntervalSec = 2,
    [string]$Model = "",
    # Optional per-turn overrides. TurnTimeoutSec is separate from the wait timeout above.
    [string]$Reasoning = "",
    [int]$TurnTimeoutSec = 0,
    [switch]$RawJson
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir "common.ps1")
$sendPath = Join-Path $scriptDir "send.ps1"
Assert-ValidPairId -PairId $PairId

# Invoke send.ps1 in-process via the call operator (no subshell, no exec-policy flag).
if ($PSCmdlet.ParameterSetName -eq "File") {
    $msgId = (& $sendPath -PairId $PairId -Type $Type -MessageFile $MessageFile -Model $Model -Reasoning $Reasoning -TurnTimeoutSec $TurnTimeoutSec | Select-Object -Last 1).ToString().Trim()
} else {
    $msgId = (& $sendPath -PairId $PairId -Type $Type -Message $Message -Model $Model -Reasoning $Reasoning -TurnTimeoutSec $TurnTimeoutSec | Select-Object -Last 1).ToString().Trim()
}
if ([string]::IsNullOrWhiteSpace($msgId)) {
    Write-Error "send.ps1 did not return a message id"
    exit 1
}

Write-Host "[co-review] Sent $msgId. Waiting for Codex (timeout ${TimeoutSec}s)..." -ForegroundColor Cyan

# Receive: scan the entire to-claude.jsonl for a reply whose in_reply_to matches our msgId.
# This is race-free - it doesn't matter whether the reply lands before or after we start polling.
$pairDir = Get-PairDir -PairId $PairId -MustExist
$toClaude = Join-Path -Path $pairDir -ChildPath "to-claude.jsonl"

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$reply = $null

while ($true) {
    if (Test-Path $toClaude) {
        $lines = @(Get-Content $toClaude -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() -ne "" })
        foreach ($line in $lines) {
            try { $obj = $line | ConvertFrom-Json } catch { continue }
            if ($obj.in_reply_to -eq $msgId) { $reply = $obj; break }
        }
        if ($reply) { break }
    }
    if ((Get-Date) -ge $deadline) {
        Write-Error "Timeout after ${TimeoutSec}s waiting for reply to $msgId"
        exit 2
    }
    Start-Sleep -Seconds $PollIntervalSec
}

if ($RawJson) {
    Write-Output ($reply | ConvertTo-Json -Compress -Depth 10)
} else {
    Write-Host ""
    Write-Host "=== Codex reply ($($reply.id), in reply to $($reply.in_reply_to)) ===" -ForegroundColor Green
    Write-Host "ts: $($reply.ts)"
    if ($reply.error) { Write-Host "ERROR: $($reply.error)" -ForegroundColor Red }
    Write-Host ""
    Write-Output $reply.content
}
