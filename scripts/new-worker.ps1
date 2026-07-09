# Claude-facing Codex worker creation.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][ValidateSet("review", "workhorse")][string]$Mode,
    [string]$Task = "",
    [string]$ProjectCwd = "",
    [string]$CodexBin = "",
    [Alias("CodexModel")][string]$Model = "auto",
    [Alias("CodexReasoning")][string]$Reasoning = "auto",
    [ValidateSet("auto", "shared", "worktree")][string]$Isolation = "auto",
    [ValidateSet("", "read-only", "workspace-write", "danger-full-access")][string]$Sandbox = "",
    [ValidateSet("Hidden", "Minimized", "Foreground")][string]$WindowMode = "Hidden",
    [int]$TimeoutSec = 1800,
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
    $candidate = "$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe"
    if (Test-Path -LiteralPath $candidate) { $CodexBin = $candidate }
    else {
        $command = Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) { $CodexBin = $command.Source }
    }
}
Assert-ValidCodexBin -CodexBin $CodexBin
$capabilities = Get-CodexCapabilities -CodexBin $CodexBin
$selection = Resolve-CodexSelection -Capabilities $capabilities -Model $Model -Reasoning $Reasoning -AllowUnknownModel:$AllowUnknownModel

$params = @{
    WorkerName = $Name; Mode = $Mode; Task = $Task; ProjectCwd = $ProjectCwd; CodexBin = $CodexBin
    CodexModel = $Model; CodexReasoning = $Reasoning; Isolation = $Isolation; Sandbox = $Sandbox
    WindowMode = $WindowMode; CodexTimeoutSec = $TimeoutSec; Profile = $Profile; AddDir = $AddDir
    ConfigOverride = $ConfigOverride; Search = $Search; AllowDirtyBase = $AllowDirtyBase
    ConfirmDangerFullAccess = $ConfirmDangerFullAccess; NoSpawn = $NoSpawn; DryRunListener = $DryRunListener
}
$output = & (Join-Path $PSScriptRoot "new-pair.ps1") @params
$output | Select-Object -Last 1
