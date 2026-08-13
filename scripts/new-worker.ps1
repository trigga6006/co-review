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
    [int]$TimeoutSec = 300,
    [ValidateRange(0, 1000)][int]$MaxTurns = 2,
    [ValidateRange(0, 10)][int]$MaxProgressUpdates = 2,
    [ValidateRange(0, 3600)][int]$ProgressMinIntervalSec = 30,
    [ValidateRange(1, 1000)][int]$MaxConcurrentWorkers = 4,
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
    WindowMode = $WindowMode; CodexTimeoutSec = $TimeoutSec; MaxTurns = $MaxTurns; MaxProgressUpdates = $MaxProgressUpdates
    ProgressMinIntervalSec = $ProgressMinIntervalSec; Profile = $Profile; AddDir = $AddDir
    ConfigOverride = $ConfigOverride; Search = $Search; AllowDirtyBase = $AllowDirtyBase
    ConfirmDangerFullAccess = $ConfirmDangerFullAccess; NoSpawn = $NoSpawn; DryRunListener = $DryRunListener
}
$mutexName = Get-CoReviewMutexName -Scope "fanout" -Key "global"
$output = Invoke-WithCoReviewMutex -Name $mutexName -ScriptBlock {
    if (-not $NoSpawn -and -not $AllowHighFanout) {
        $activeCount = Get-CoReviewActiveWorkerCount
        if ($activeCount -ge $MaxConcurrentWorkers) {
            throw "Active co-review worker limit reached ($activeCount/$MaxConcurrentWorkers). Reuse/stop a worker or pass -AllowHighFanout for explicit fan-out."
        }
    }
    & (Join-Path $PSScriptRoot "new-pair.ps1") @params
}
$output | Select-Object -Last 1
