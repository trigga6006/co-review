# co-review: recv.ps1
# Read messages from Codex (to-claude.jsonl). Optionally wait for new ones.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PairId,
    [string]$Since = "",
    [switch]$Wait,
    [int]$TimeoutSec = 600,
    [int]$PollIntervalSec = 2,
    [string]$InReplyTo = "",
    [switch]$IncludeProgress,
    [switch]$UntilFinal
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$pairDir = Get-PairDir -PairId $PairId -MustExist

$toClaude = Join-Path $pairDir "to-claude.jsonl"

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$signal = Open-CoReviewSignal -PairId $PairId -Channel "outbox"
[long]$offset = 0
$initialPass = $true
$collected = New-Object System.Collections.Generic.List[object]

try {
    while ($true) {
        $tail = Read-CoReviewJsonlTail -Path $toClaude -Offset $offset
        $offset = [long]$tail.next_offset
        $batch = @($tail.records | Where-Object { $null -ne $_.value } | ForEach-Object { $_.value })
        if ($initialPass -and -not [string]::IsNullOrWhiteSpace($Since)) {
            $after = -1
            for ($i = 0; $i -lt $batch.Count; $i++) { if ([string]$batch[$i].id -eq $Since) { $after = $i; break } }
            if ($after -ge 0) {
                $batch = if ($after -lt ($batch.Count - 1)) { @($batch[($after + 1)..($batch.Count - 1)]) } else { @() }
            }
            # Preserve the prior safe behavior: an unknown Since id returns all.
        }
        $initialPass = $false
        foreach ($item in $batch) {
            if (-not [string]::IsNullOrWhiteSpace($InReplyTo) -and [string]$item.in_reply_to -ne $InReplyTo) { continue }
            $collected.Add($item) | Out-Null
        }
        $all = @($collected.ToArray())
        $terminal = @($all | Where-Object { [string]($_.type) -in @("response", "error") })
        $visible = if ($IncludeProgress.IsPresent) { @($all) } else { @($terminal) }
        $ready = @($visible).Count -gt 0
        if ($UntilFinal.IsPresent) { $ready = @($terminal).Count -gt 0 }
        if ($ready) {
            foreach ($m in $visible) { Write-Output ($m | ConvertTo-Json -Compress -Depth 10) }
            return
        }
        if (-not $Wait) { return }
        if ((Get-Date) -ge $deadline) {
            Write-Error "Timeout after ${TimeoutSec}s waiting for new message from Codex"
            exit 2
        }
        $remainingMs = [int][Math]::Max(1, ($deadline - (Get-Date)).TotalMilliseconds)
        $fallbackMs = [Math]::Max(50, $PollIntervalSec * 1000)
        [void](Wait-CoReviewChannel -Signal $signal -TimeoutMilliseconds ([Math]::Min($remainingMs, $fallbackMs)))
    }
} finally { $signal.Dispose() }
