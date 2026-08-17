[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][Alias("PairId")][string]$WorkerId,
    [string]$MessageId = "",
    [ValidateRange(1, 30)][int]$TurnIdWaitSec = 10,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")
. (Join-Path $PSScriptRoot "app-server.ps1")

$pairDir = Get-PairDir -PairId $WorkerId -MustExist
$activePath = Join-Path $pairDir "active-turn.json"
$active = $null
if (Test-Path -LiteralPath $activePath -PathType Leaf) {
    try { $active = Get-Content -LiteralPath $activePath -Raw | ConvertFrom-Json } catch { $active = $null }
}

if ([string]::IsNullOrWhiteSpace($MessageId) -and $null -ne $active) {
    $MessageId = [string]$active.message_id
}
if ($MessageId -notmatch '^msg-\d+$') {
    throw "No active message was found. Pass -MessageId msg-NNNN to cancel a queued turn."
}

$cancelDir = Join-Path $pairDir "cancelled"
New-Item -ItemType Directory -Path $cancelDir -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $cancelDir ($MessageId + ".cancel")), (Get-Date).ToString("o"), [System.Text.UTF8Encoding]::new($false))

$stopped = $false
$cancellationUnconfirmed = $false
if ($null -ne $active -and [string]$active.message_id -eq $MessageId) {
    if ([string]$active.backend -eq "app-server" -and [string]$active.connection_mode -eq "shared") {
        # turn/start is asynchronous, so cancellation can race the response that supplies
        # the turn id. Wait for that durable marker instead of issuing an invalid interrupt.
        $turnIdDeadline = (Get-Date).AddSeconds($TurnIdWaitSec)
        while ([string]::IsNullOrWhiteSpace([string]$active.turn_id) -and (Get-Date) -lt $turnIdDeadline) {
            Start-Sleep -Milliseconds 100
            try {
                $candidate = Get-Content -LiteralPath $activePath -Raw | ConvertFrom-Json -ErrorAction Stop
                if ([string]$candidate.message_id -ne $MessageId) { break }
                $active = $candidate
            } catch {}
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$active.turn_id)) {
            $meta = Get-NormalizedPairMetadata -PairDir $pairDir
            Interrupt-CoReviewAppServerTurn -CodexBin ([string]$active.codex_bin) -WorkingDirectory ([string]$meta.project_cwd) -ThreadId ([string]$active.thread_id) -TurnId ([string]$active.turn_id)
            $stopped = $true
        } else {
            # Do not claim success or kill the listener while the shared broker may still
            # be running an unaddressable turn. The shutdown/cancel markers remain durable,
            # so the bounded listener will retire as soon as the start resolves or times out.
            $cancellationUnconfirmed = $true
        }
    } else {
        [int]$processId = 0
        if ([int]::TryParse([string]$active.process_pid, [ref]$processId) -and $processId -gt 0 -and $null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
            Stop-CoReviewProcessTree -ProcessId $processId
            $stopped = $true
        }
    }
}
Signal-CoReviewChannel -PairId $WorkerId -Channel "inbox"

$result = [PSCustomObject]@{
    worker_id = $WorkerId
    message_id = $MessageId
    active_process_stopped = $stopped
    status = if ($stopped) { "cancelling-active" } elseif ($cancellationUnconfirmed) { "cancellation-unconfirmed" } else { "cancelled-queued" }
}
if ($Json) { $result | ConvertTo-Json -Compress } else { $result }
