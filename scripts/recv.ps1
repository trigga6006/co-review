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

function Read-NewMessages {
    param([string]$File, [string]$SinceId)
    if (-not (Test-Path $File)) { return @() }
    $raw = Get-Content $File -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $raw) { return @() }
    $msgs = @()
    foreach ($line in $raw) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $msgs += ($line | ConvertFrom-Json)
        } catch {
            # skip malformed line
        }
    }
    if ([string]::IsNullOrWhiteSpace($SinceId)) { return $msgs }
    $afterIdx = -1
    for ($i = 0; $i -lt $msgs.Count; $i++) {
        if ($msgs[$i].id -eq $SinceId) { $afterIdx = $i; break }
    }
    if ($afterIdx -lt 0) { return $msgs }  # SinceId not found, return all (safer than nothing)
    if ($afterIdx -ge ($msgs.Count - 1)) { return @() }
    return $msgs[($afterIdx + 1)..($msgs.Count - 1)]
}

$deadline = (Get-Date).AddSeconds($TimeoutSec)

while ($true) {
    $new = @(Read-NewMessages -File $toClaude -SinceId $Since)
    if (-not [string]::IsNullOrWhiteSpace($InReplyTo)) { $new = @($new | Where-Object { [string]($_.in_reply_to) -eq $InReplyTo }) }
    $terminal = @($new | Where-Object { [string]($_.type) -in @("response", "error") })
    $visible = @()
    if ($IncludeProgress.IsPresent) { $visible = @($new) } else { $visible = @($terminal) }
    $ready = $visible.Count -gt 0
    if ($UntilFinal.IsPresent) { $ready = $terminal.Count -gt 0 }
    if ($ready) {
        # Output as JSON, one message per line so callers can grep easily
        foreach ($m in $visible) {
            $line = $m | ConvertTo-Json -Compress -Depth 10
            Write-Output $line
        }
        return
    }
    if (-not $Wait) { return }
    if ((Get-Date) -ge $deadline) {
        Write-Error "Timeout after ${TimeoutSec}s waiting for new message from Codex"
        exit 2
    }
    Start-Sleep -Seconds $PollIntervalSec
}
