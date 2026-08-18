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
    [switch]$RawJson,
    [switch]$Queue,
    [switch]$LeaveRunning,
    [switch]$AllowErrorReply
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot
. (Join-Path $scriptDir "common.ps1")
$sendPath = Join-Path $scriptDir "send.ps1"
Assert-ValidPairId -PairId $PairId
$pairDir = Get-PairDir -PairId $PairId -MustExist
$toClaude = Join-Path -Path $pairDir -ChildPath "to-claude.jsonl"
[long]$outboxOffset = 0
if (Test-Path -LiteralPath $toClaude -PathType Leaf) { $outboxOffset = (Get-Item -LiteralPath $toClaude).Length }

# Invoke send.ps1 in-process via the call operator (no subshell, no exec-policy flag).
if ($PSCmdlet.ParameterSetName -eq "File") {
    $msgId = (& $sendPath -PairId $PairId -Type $Type -MessageFile $MessageFile -Model $Model -Reasoning $Reasoning -TurnTimeoutSec $TurnTimeoutSec -Queue:$Queue | Select-Object -Last 1).ToString().Trim()
} else {
    $msgId = (& $sendPath -PairId $PairId -Type $Type -Message $Message -Model $Model -Reasoning $Reasoning -TurnTimeoutSec $TurnTimeoutSec -Queue:$Queue | Select-Object -Last 1).ToString().Trim()
}
if ([string]::IsNullOrWhiteSpace($msgId)) {
    Write-Error "send.ps1 did not return a message id"
    exit 1
}

Write-Host "[co-review] Sent $msgId. Waiting for Codex (timeout ${TimeoutSec}s)..." -ForegroundColor Cyan

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$reply = $null
$seenProgress = @{}
$signal = Open-CoReviewSignal -PairId $PairId -Channel "outbox"

try {
    while ($true) {
        $tail = Read-CoReviewJsonlTail -Path $toClaude -Offset $outboxOffset
        $outboxOffset = [long]$tail.next_offset
        foreach ($record in @($tail.records)) {
            $obj = $record.value
            if ($null -eq $obj) { continue }
            if ($obj.in_reply_to -ne $msgId) { continue }
            if ($obj.type -eq "progress" -and -not $seenProgress.ContainsKey([string]$obj.id)) {
                $seenProgress[[string]$obj.id] = $true
                Write-Host "[co-review] Codex progress: $($obj.content)" -ForegroundColor DarkCyan
            } elseif ($obj.type -in @("response", "error")) { $reply = $obj; break }
        }
        if ($reply) { break }
        if ((Get-Date) -ge $deadline) {
            $cancelResult = $null
            $cancelError = ""
            if (-not $LeaveRunning) {
                try { $cancelResult = & (Join-Path $scriptDir "cancel-worker.ps1") -WorkerId $PairId -MessageId $msgId -Json | ConvertFrom-Json }
                catch { $cancelError = $_.Exception.Message }
            }
            $suffix = if ($LeaveRunning) {
                " The Codex turn was left running."
            } elseif (-not [string]::IsNullOrWhiteSpace($cancelError) -or [string]$cancelResult.status -eq "cancellation-unconfirmed") {
                $detail = if ([string]::IsNullOrWhiteSpace($cancelError)) { "the shared turn has not supplied an interruptible turn id" } else { $cancelError }
                " Cancellation is unconfirmed ($detail). The bounded listener remains responsible for interrupting or timing out the turn; it was not killed or reported as cancelled."
            } else {
                " Cancellation was requested to prevent hidden background work (status=$([string]$cancelResult.status))."
            }
            throw "Timeout after ${TimeoutSec}s waiting for reply to $msgId.$suffix"
        }
        $remainingMs = [int][Math]::Max(1, ($deadline - (Get-Date)).TotalMilliseconds)
        $fallbackMs = [Math]::Max(50, $PollIntervalSec * 1000)
        [void](Wait-CoReviewChannel -Signal $signal -TimeoutMilliseconds ([Math]::Min($remainingMs, $fallbackMs)))
    }
} finally { $signal.Dispose() }

if ($reply.error -and -not $AllowErrorReply) {
    throw "Codex turn $msgId failed: $($reply.error)"
} elseif ($RawJson) {
    Write-Output ($reply | ConvertTo-Json -Compress -Depth 10)
} else {
    Write-Host ""
    Write-Host "=== Codex reply ($($reply.id), in reply to $($reply.in_reply_to)) ===" -ForegroundColor Green
    Write-Host "ts: $($reply.ts)"
    if ($reply.error) { Write-Host "ERROR: $($reply.error)" -ForegroundColor Red }
    Write-Host ""
    Write-Output $reply.content
}
