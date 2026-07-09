# co-review: new-pair.ps1
# Creates a new pair dir under ~/.cc-codex-pairs/ and spawns a background
# powershell window running codex-listener.ps1. Default window mode is
# minimized so the listener never steals focus. Prints a JSON line with
# the pair_id on stdout.
[CmdletBinding()]
param(
    [string]$Task = "",
    [string]$ProjectCwd = "",
    [string]$CodexBin = "",
    [string]$CodexModel = "gpt-5.5",
    [string]$CodexReasoning = "medium",
    [int]$CodexTimeoutSec = 1800,
    [ValidateSet("Minimized", "Hidden", "Foreground")]
    [string]$WindowMode = "Minimized",
    [ValidateSet("review", "workhorse")][string]$Mode = "review",
    [string]$WorkerName = "",
    [ValidateSet("auto", "shared", "worktree")][string]$Isolation = "shared",
    [ValidateSet("", "read-only", "workspace-write", "danger-full-access")][string]$Sandbox = "",
    [switch]$ConfirmDangerFullAccess,
    [string[]]$ConfigOverride = @(),
    [string]$Profile = "",
    [string[]]$AddDir = @(),
    [switch]$Search,
    [switch]$NoSpawn,
    [switch]$DryRunListener  # pass -DryRun to the listener (echo only, no codex)
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

# Preflight: PowerShell execution policy. The listener runs as a child process
# of wt.exe / powershell.exe, so the user's CurrentUser policy must allow it.
$effective = Get-ExecutionPolicy
if ($effective -in @('Restricted', 'AllSigned')) {
    Write-Host "[co-review] FATAL: PowerShell execution policy is '$effective', which blocks local scripts." -ForegroundColor Red
    Write-Host "          Fix once with:" -ForegroundColor Yellow
    Write-Host "              Set-ExecutionPolicy -Scope CurrentUser RemoteSigned" -ForegroundColor Cyan
    Write-Host "          Then re-run." -ForegroundColor Yellow
    exit 1
}

# Resolve project cwd: caller-provided, else current dir
if ([string]::IsNullOrWhiteSpace($ProjectCwd)) {
    $ProjectCwd = (Get-Location).Path
}
if (-not (Test-Path $ProjectCwd)) {
    Write-Error "ProjectCwd does not exist: $ProjectCwd"
    exit 1
}

# Resolve codex.exe
if ([string]::IsNullOrWhiteSpace($CodexBin)) {
    $candidates = @(
        "$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe",
        "$env:USERPROFILE\AppData\Local\OpenAI\Codex\bin\codex.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $CodexBin = $c; break }
    }
    if ([string]::IsNullOrWhiteSpace($CodexBin)) {
        $cmd = Get-Command codex -ErrorAction SilentlyContinue
        if ($cmd) { $CodexBin = $cmd.Source }
    }
}
Assert-ValidCodexBin -CodexBin $CodexBin

Assert-SafeCodexConfigOverrides -Overrides $ConfigOverride

if ([string]::IsNullOrWhiteSpace($Sandbox)) {
    $Sandbox = if ($Mode -eq "workhorse") { "workspace-write" } else { "read-only" }
}
if ($Mode -eq "review" -and $Sandbox -ne "read-only") {
    throw "Review workers must use the read-only sandbox"
}
if ($Sandbox -eq "danger-full-access" -and -not $ConfirmDangerFullAccess) {
    throw "danger-full-access requires -ConfirmDangerFullAccess"
}

$resolvedAddDirs = @()
foreach ($dir in $AddDir) {
    if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) {
        throw "AddDir does not exist or is not a directory: $dir"
    }
    $resolvedAddDirs += (Resolve-Path -LiteralPath $dir).Path
}

$requestedCodexModel = $CodexModel
$requestedCodexReasoning = $CodexReasoning
$capabilities = Get-CodexCapabilities -CodexBin $CodexBin
$selection = Resolve-CodexSelection -Capabilities $capabilities -Model $requestedCodexModel -Reasoning $requestedCodexReasoning -AllowUnknownModel
$CodexModel = [string]$selection.model
$CodexReasoning = [string]$selection.reasoning

# Generate pair id: pair-<yyyymmdd>-<4 hex>
$timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$randHex = -join ((1..4) | ForEach-Object { "{0:x}" -f (Get-Random -Maximum 16) })
$pairId = "pair-$timestamp-$randHex"
if ([string]::IsNullOrWhiteSpace($WorkerName)) { $WorkerName = $pairId }

$root = Join-Path -Path $env:USERPROFILE -ChildPath ".cc-codex-pairs"
$pairDir = Join-Path -Path $root -ChildPath $pairId
New-Item -ItemType Directory -Path $pairDir -Force | Out-Null

# Initialize files
$toCodex = Join-Path $pairDir "to-codex.jsonl"
$toClaude = Join-Path $pairDir "to-claude.jsonl"
$stateFile = Join-Path $pairDir "state.json"
$pairMeta = Join-Path $pairDir "pair.json"
$logFile = Join-Path $pairDir "listener.log"

# Create empty JSONL files
"" | Out-File -FilePath $toCodex -Encoding ascii -NoNewline
"" | Out-File -FilePath $toClaude -Encoding ascii -NoNewline

$state = @{
    last_processed = $null
    codex_session_id = $null
    msg_counter = 0
} | ConvertTo-Json
[System.IO.File]::WriteAllText($stateFile, $state, [System.Text.UTF8Encoding]::new($false))

$meta = @{
    schema_version = 2
    pair_id = $pairId
    worker_name = $WorkerName
    created_at = (Get-Date).ToString("o")
    project_cwd = $ProjectCwd
    task_hint = $Task
    mode = $Mode
    sandbox = $Sandbox
    isolation = $Isolation
    codex_bin = $CodexBin
    requested_model = $requestedCodexModel
    codex_model = $CodexModel
    requested_reasoning = $requestedCodexReasoning
    codex_reasoning = $CodexReasoning
    config_overrides = @($ConfigOverride)
    profile = $Profile
    add_dirs = @($resolvedAddDirs)
    search_enabled = [bool]$Search
    codex_timeout_sec = $CodexTimeoutSec
    window_mode = $WindowMode
    dry_run_listener = [bool]$DryRunListener
} | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($pairMeta, $meta, [System.Text.UTF8Encoding]::new($false))

# Path to listener script (sibling of this script)
$listenerPath = Join-Path $PSScriptRoot "codex-listener.ps1"
if (-not (Test-Path $listenerPath)) {
    Write-Error "codex-listener.ps1 not found at $listenerPath"
    exit 1
}

# Spawn the listener process.
#
# Important: we deliberately use powershell.exe (conhost) instead of wt.exe.
# Windows Terminal does not reliably honor Start-Process -WindowStyle, so the
# listener window steals focus and overlays whatever the user has on screen.
# powershell.exe + conhost honors -WindowStyle Minimized/Hidden cleanly.
$spawned = $false
$spawnDetail = ""

if ($NoSpawn) {
    $spawnDetail = "no-spawn (caller passed -NoSpawn)"
} else {
    # Build the listener PowerShell arg string. Quote paths with spaces.
    # No -ExecutionPolicy Bypass - Claude Code's classifier auto-denies it,
    # and the user's CurrentUser policy (typically RemoteSigned) is sufficient.
    $dryFlag = if ($DryRunListener) { "-DryRun" } else { "" }
    $listenerArgsStr = "-NoExit -File `"$listenerPath`" -PairId $pairId -CodexBin `"$CodexBin`" -CodexModel `"$CodexModel`" -CodexReasoning $CodexReasoning -CodexTimeoutSec $CodexTimeoutSec $dryFlag".Trim()

    $startProcArgs = @{
        FilePath         = "powershell.exe"
        ArgumentList     = $listenerArgsStr
        WorkingDirectory = $ProjectCwd
        WindowStyle      = $WindowMode
        ErrorAction      = "Stop"
    }

    try {
        Start-Process @startProcArgs
        $spawned = $true
        $spawnDetail = "powershell ($WindowMode)"
    } catch {
        $spawnDetail = "powershell-failed: $($_.Exception.Message)"
    }

    # Legacy wt.exe fallback if powershell.exe spawn failed.
    if (-not $spawned) {
        $wt = Get-Command wt -ErrorAction SilentlyContinue
        if ($wt) {
            $wtCmd = "-w new -d `"$ProjectCwd`" --title `"co-review $pairId`" powershell $listenerArgsStr"
            try {
                Start-Process -FilePath "wt.exe" -ArgumentList $wtCmd -WindowStyle $WindowMode -ErrorAction Stop
                $spawned = $true
                $spawnDetail = "$spawnDetail; wt-fallback"
            } catch {
                $spawnDetail = "$spawnDetail; wt-also-failed: $($_.Exception.Message)"
            }
        }
    }
}

# Human-readable summary on stderr-ish (still stdout but before JSON)
Write-Host "[co-review] Created pair: $pairId"
Write-Host "[co-review] Pair dir:     $pairDir"
Write-Host "[co-review] Project cwd:  $ProjectCwd"
Write-Host "[co-review] Codex bin:    $CodexBin"
Write-Host "[co-review] Codex model:  $CodexModel ($CodexReasoning reasoning)"
Write-Host "[co-review] Window:       $spawnDetail"
Write-Host ""

# Final line: machine-readable JSON for the caller
$result = @{
    pair_id = $pairId
    pair_dir = $pairDir
    project_cwd = $ProjectCwd
    window_spawned = $spawned
    spawn_detail = $spawnDetail
    codex_bin = $CodexBin
    codex_model = $CodexModel
    codex_reasoning = $CodexReasoning
    worker_name = $WorkerName
    mode = $Mode
    sandbox = $Sandbox
    isolation = $Isolation
    schema_version = 2
} | ConvertTo-Json -Compress
Write-Output $result
