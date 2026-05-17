# co-review: list-pairs.ps1
# Show all pair dirs with status. Useful for recovery if Claude lost the pair ID.
[CmdletBinding()]
param(
    [switch]$IncludeArchived,
    [switch]$Json
)

$ErrorActionPreference = "Continue"
$root = Join-Path -Path $env:USERPROFILE -ChildPath ".cc-codex-pairs"

if (-not (Test-Path $root)) {
    Write-Host "[co-review] No pairs yet (no $root directory)." -ForegroundColor DarkGray
    if ($Json) { Write-Output "[]" }
    return
}

$dirs = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -like "pair-*"
}

$results = @()
foreach ($d in $dirs) {
    $meta = $null
    $metaFile = Join-Path $d.FullName "pair.json"
    if (Test-Path $metaFile) {
        try { $meta = Get-Content $metaFile -Raw | ConvertFrom-Json } catch {}
    }
    $toCodex = Join-Path $d.FullName "to-codex.jsonl"
    $toClaude = Join-Path $d.FullName "to-claude.jsonl"
    $shutdown = Join-Path $d.FullName "shutdown"
    $logFile = Join-Path $d.FullName "listener.log"
    $pidFile = Join-Path $d.FullName "listener.pid"

    $sentCount = 0
    $replyCount = 0
    if (Test-Path $toCodex)  { $sentCount  = (@(Get-Content $toCodex  -ErrorAction SilentlyContinue) | Where-Object { $_ -and $_.Trim() }).Count }
    if (Test-Path $toClaude) { $replyCount = (@(Get-Content $toClaude -ErrorAction SilentlyContinue) | Where-Object { $_ -and $_.Trim() }).Count }

    $lastLog = "(no log)"
    if (Test-Path $logFile) {
        # Cast to [string] - PS5.1 attaches PSPath/PSDrive/PSProvider note properties
        # to Get-Content output that pollute ConvertTo-Json with PowerShell metadata.
        $lastLine = [string](Get-Content $logFile -Tail 1 -ErrorAction SilentlyContinue)
        if (-not [string]::IsNullOrWhiteSpace($lastLine)) { $lastLog = $lastLine }
    }

    # Liveness: check listener PID is still alive
    $listenerPid = $null
    $listenerAlive = $false
    if (Test-Path $pidFile) {
        try {
            $raw = (Get-Content $pidFile -Raw -ErrorAction Stop).Trim()
            if ($raw -match '^\d+$') {
                $listenerPid = [int]$raw
                $proc = Get-Process -Id $listenerPid -ErrorAction SilentlyContinue
                if ($proc) { $listenerAlive = $true }
            }
        } catch {}
    }

    $status = if (-not $listenerAlive) { "dead" }
              elseif (Test-Path $shutdown) { "shutdown-pending" }
              else { "active" }

    $results += [PSCustomObject]@{
        pair_id      = $d.Name
        pair_dir     = $d.FullName
        created      = if ($meta) { $meta.created_at } else { $d.CreationTime.ToString("o") }
        project_cwd  = if ($meta) { $meta.project_cwd } else { "" }
        task_hint    = if ($meta) { $meta.task_hint } else { "" }
        sent_to_codex   = $sentCount
        replies_from_codex = $replyCount
        listener_pid = $listenerPid
        status       = $status
        last_log     = $lastLog
    }
}

# Sort newest first
$results = $results | Sort-Object created -Descending

if ($Json) {
    $results | ConvertTo-Json -Depth 5
} else {
    if ($results.Count -eq 0) {
        Write-Host "[co-review] No pairs found." -ForegroundColor DarkGray
        return
    }
    Write-Host ""
    Write-Host "=== co-review pairs ===" -ForegroundColor Cyan
    foreach ($r in $results) {
        Write-Host ""
        Write-Host "  $($r.pair_id)" -ForegroundColor Yellow -NoNewline
        $color = switch ($r.status) { "active" { "Green" } "dead" { "Red" } default { "Yellow" } }
        Write-Host "  [$($r.status)]" -ForegroundColor $color
        Write-Host "    created:    $($r.created)"
        Write-Host "    project:    $($r.project_cwd)"
        Write-Host "    task:       $($r.task_hint)"
        Write-Host "    listener:   pid=$($r.listener_pid) status=$($r.status)"
        Write-Host "    traffic:    claude->codex=$($r.sent_to_codex)  codex->claude=$($r.replies_from_codex)"
        Write-Host "    last log:   $($r.last_log)" -ForegroundColor DarkGray
    }
    Write-Host ""
}
