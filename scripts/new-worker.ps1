# Claude-facing Codex worker creation.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][ValidateSet("review", "workhorse", "imagegen")][string]$Mode,
    [string]$Task = "",
    [string]$ProjectCwd = "",
    [string]$CodexBin = "",
    [Alias("CodexModel")][string]$Model = "role-default",
    [Alias("CodexReasoning")][string]$Reasoning = "role-default",
    [ValidateSet("auto", "shared", "worktree")][string]$Isolation = "auto",
    [ValidateSet("", "read-only", "workspace-write", "danger-full-access")][string]$Sandbox = "",
    [ValidateSet("Hidden", "Minimized", "Foreground")][string]$WindowMode = "Hidden",
    [ValidateSet("auto", "app-server", "legacy")][string]$Transport = "auto",
    [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$OwnerId = "",
    [int]$TimeoutSec = 300,
    [ValidateRange(0, 1000)][int]$MaxTurns = 2,
    [ValidateRange(0, 86400)][int]$IdleTimeoutSec = 900,
    [ValidateRange(0, 10)][int]$MaxProgressUpdates = 2,
    [ValidateRange(0, 3600)][int]$ProgressMinIntervalSec = 30,
    [ValidateRange(1, 1000)][int]$MaxConcurrentWorkers = 32,
    [switch]$AllowHighFanout,
    [string]$Profile = "",
    [string[]]$AddDir = @(),
    [switch]$Search,
    [string[]]$ConfigOverride = @(),
    [switch]$AllowUnknownModel,
    [switch]$AllowDirtyBase,
    [switch]$ConfirmDangerFullAccess,
    [switch]$NoSpawn,
    [switch]$DryRunListener
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

if ([string]::IsNullOrWhiteSpace($ProjectCwd)) { $ProjectCwd = (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($CodexBin)) {
    $CodexBin = Resolve-CodexBin
}
Assert-ValidCodexBin -CodexBin $CodexBin
$capabilities = Get-CodexCapabilities -CodexBin $CodexBin
$selection = Resolve-CoReviewRoleSelection -Capabilities $capabilities -Mode $Mode -Model $Model -Reasoning $Reasoning -AllowUnknownModel:$AllowUnknownModel

$params = @{
    WorkerName = $Name; Mode = $Mode; Task = $Task; ProjectCwd = $ProjectCwd; CodexBin = $CodexBin
    CodexModel = $selection.model; CodexReasoning = $selection.reasoning; Isolation = $Isolation; Sandbox = $Sandbox
    WindowMode = $WindowMode; CodexTimeoutSec = $TimeoutSec; MaxTurns = $MaxTurns; IdleTimeoutSec = $IdleTimeoutSec; MaxProgressUpdates = $MaxProgressUpdates
    ProgressMinIntervalSec = $ProgressMinIntervalSec; Profile = $Profile; AddDir = $AddDir; Transport = $Transport; OwnerId = $OwnerId
    ConfigOverride = $ConfigOverride; Search = $Search; AllowDirtyBase = $AllowDirtyBase
    ConfirmDangerFullAccess = $ConfirmDangerFullAccess; NoSpawn = $NoSpawn; DryRunListener = $DryRunListener
}
$mutexName = Get-CoReviewMutexName -Scope "fanout" -Key "global"
$reservationPath = $null
Invoke-WithCoReviewMutex -Name $mutexName -ScriptBlock {
    if (-not $NoSpawn -and -not $AllowHighFanout) {
        $activeCount = Get-CoReviewActiveWorkerCount
        $reservedCount = Get-CoReviewPendingWorkerReservationCount
        if (($activeCount + $reservedCount) -ge $MaxConcurrentWorkers) {
            throw "Active co-review worker limit reached ($activeCount active + $reservedCount starting / $MaxConcurrentWorkers). Reuse/stop a worker or pass -AllowHighFanout for explicit fan-out."
        }
        $script:reservationPath = New-CoReviewWorkerReservation
    }
}
try {
    $output = & (Join-Path $PSScriptRoot "new-pair.ps1") @params
    $output | Select-Object -Last 1
} finally {
    if (-not [string]::IsNullOrWhiteSpace([string]$reservationPath)) {
        Remove-Item -LiteralPath $reservationPath -Force -ErrorAction SilentlyContinue
    }
}
