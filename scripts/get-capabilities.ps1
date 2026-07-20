[CmdletBinding()]
param(
    [string]$ModelsCachePath = "",
    [string]$CodexBin = "",
    [switch]$IncludeHidden,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$capabilities = Get-CodexCapabilities -ModelsCachePath $ModelsCachePath -CodexBin $CodexBin -IncludeHidden:$IncludeHidden

if ($Json) {
    $capabilities | ConvertTo-Json -Depth 10
    return
}

Write-Output "Codex capabilities"
Write-Output "Source: $($capabilities.source)"
Write-Output "Cache: $($capabilities.cache_path)"
Write-Output "CLI version: $($capabilities.cli_version)"
Write-Output ""
Write-Output "Models:"
if (@($capabilities.models).Count -eq 0) {
    Write-Output "  (no visible models discovered)"
} else {
    $modelTable = $capabilities.models |
        Select-Object slug, display_name, priority, default_reasoning_level,
            @{Name="reasoning_levels"; Expression={ (@($_.supported_reasoning_levels | ForEach-Object { $_.effort }) -join ",") }},
            @{Name="speed_tiers"; Expression={ (@($_.additional_speed_tiers) -join ",") }} |
        Format-Table -AutoSize |
        Out-String
    Write-Output $modelTable.TrimEnd()
}

Write-Output ""
Write-Output "Mode defaults:"
$modeTable = @(
    [PSCustomObject]@{ mode = "review"; sandbox = "read-only" },
    [PSCustomObject]@{ mode = "workhorse"; sandbox = "workspace-write" },
    [PSCustomObject]@{ mode = "imagegen"; sandbox = "workspace-write" }
) | Format-Table -AutoSize | Out-String
Write-Output $modeTable.TrimEnd()
Write-Output "Default selection: model=$($capabilities.defaults.model), reasoning=$($capabilities.defaults.reasoning), isolation=$($capabilities.defaults.isolation), window=$($capabilities.defaults.window_mode)"
