[CmdletBinding()]
param([string]$Only = "")

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Scripts = Join-Path $RepoRoot "scripts"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT failed: $Message" }
}

function Invoke-ScriptExpectFailure {
    param([string]$ScriptName, [string[]]$ScriptArgs)
    $scriptPath = Join-Path $Scripts $ScriptName
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = powershell -NoProfile -File $scriptPath @ScriptArgs 2>&1
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    $code = $LASTEXITCODE
    [PSCustomObject]@{ ExitCode = $code; Output = ($output | Out-String) }
}

function Test-InvalidPairIdsRejected {
    $badIds = @("..\Documents", "pair-20260516-151017-ae00\..\..", "C:\Temp", "pair-evil")
    foreach ($bad in $badIds) {
        $result = Invoke-ScriptExpectFailure -ScriptName "send.ps1" -ScriptArgs @("-PairId", $bad, "-Message", "x")
        Assert-True ($result.ExitCode -ne 0) "send.ps1 should reject bad PairId '$bad'"
        Assert-True ($result.Output -match "Invalid PairId") "send.ps1 should explain invalid PairId '$bad'"
    }
}

function Test-ArchiveDoesNotEscapePairRoot {
    $result = Invoke-ScriptExpectFailure -ScriptName "end-pair.ps1" -ScriptArgs @("-PairId", "..\Documents", "-Archive")
    Assert-True ($result.ExitCode -ne 0) "end-pair.ps1 should reject traversal PairId"
    Assert-True ($result.Output -match "Invalid PairId") "end-pair.ps1 should explain invalid PairId"
}

function Test-PurgePairDeletesPairDir {
    $json = & (Join-Path $Scripts "new-pair.ps1") -NoSpawn -Task "purge test" | Select-Object -Last 1
    $pair = $json | ConvertFrom-Json
    Assert-True (Test-Path $pair.pair_dir) "test pair dir should exist before purge"

    & (Join-Path $Scripts "purge-pair.ps1") -PairId $pair.pair_id -Force | Out-Null
    Assert-True (-not (Test-Path $pair.pair_dir)) "purge-pair.ps1 should remove pair dir"
}

function Test-ListenerReturnsTimeoutError {
    $fakeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("co-review-fake-codex-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $fakeDir -Force | Out-Null
    $fakeCodex = Join-Path $fakeDir "codex.exe"
    $source = @"
using System;
using System.Threading;
public static class Program {
    public static int Main(string[] args) {
        Thread.Sleep(30000);
        return 0;
    }
}
"@
    Add-Type -TypeDefinition $source -OutputAssembly $fakeCodex -OutputType ConsoleApplication

    $json = & (Join-Path $Scripts "new-pair.ps1") -NoSpawn -Task "timeout test" -CodexBin $fakeCodex | Select-Object -Last 1
    $pair = $json | ConvertFrom-Json
    $listener = Start-Process powershell.exe -ArgumentList @(
        "-NoProfile",
        "-File", (Join-Path $Scripts "codex-listener.ps1"),
        "-PairId", $pair.pair_id,
        "-CodexBin", $fakeCodex,
        "-CodexTimeoutSec", "1",
        "-PollIntervalSec", "1"
    ) -WindowStyle Hidden -PassThru
    try {
        Start-Sleep -Seconds 1
        $replyJson = & (Join-Path $Scripts "ask.ps1") -PairId $pair.pair_id -Message "timeout please" -TimeoutSec 20 -RawJson | Select-Object -Last 1
        $reply = $replyJson | ConvertFrom-Json
        Assert-True ($reply.type -eq "error") "timeout should produce an error reply"
        Assert-True ($reply.error -match "timed out") "timeout error should mention timed out"
    } finally {
        & (Join-Path $Scripts "end-pair.ps1") -PairId $pair.pair_id -Delete | Out-Null
        Start-Sleep -Seconds 2
        if (-not $listener.HasExited) { Stop-Process -Id $listener.Id -Force }
        Remove-Item -LiteralPath $fakeDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-CapabilityDiscovery {
    $fixture = Join-Path $RepoRoot "tests\fixtures\models-cache.json"
    . (Join-Path $Scripts "common.ps1")

    Assert-SafeCodexConfigOverrides -Overrides @("features.web_search=true", "network_access=false")
    $reservedOverrideRejected = $false
    try {
        Assert-SafeCodexConfigOverrides -Overrides @("model=gpt-test-frontier")
    } catch {
        $reservedOverrideRejected = $true
    }
    Assert-True $reservedOverrideRejected "dedicated Codex options should be rejected as generic overrides"

    $humanOutput = & (Join-Path $Scripts "get-capabilities.ps1") -ModelsCachePath $fixture | Out-String
    Assert-True ($humanOutput -match "gpt-test-frontier") "human output should include the frontier model"
    Assert-True ($humanOutput -match "gpt-test-fast") "human output should include the fast model"
    Assert-True ($humanOutput -notmatch "gpt-test-hidden") "human output should exclude hidden models"

    $capabilities = Get-CodexCapabilities -ModelsCachePath $fixture
    $modelSlugs = @($capabilities.models | ForEach-Object { $_.slug })
    Assert-True ($modelSlugs -contains "gpt-test-frontier") "capabilities should include the frontier model"
    Assert-True ($modelSlugs -contains "gpt-test-fast") "capabilities should include the fast model"
    Assert-True ($modelSlugs -notcontains "gpt-test-hidden") "capabilities should exclude hidden models"
    $hiddenCapabilities = Get-CodexCapabilities -ModelsCachePath $fixture -IncludeHidden
    Assert-True (@($hiddenCapabilities.models | ForEach-Object { $_.slug }) -contains "gpt-test-hidden") "IncludeHidden should expose hidden models"

    $hiddenFirstCachePath = Join-Path ([System.IO.Path]::GetTempPath()) ("co-review-models-" + [System.Guid]::NewGuid().ToString("N") + ".json")
    try {
        $hiddenFirstCache = Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json
        $hiddenFirstCache.models[2].priority = -1
        $hiddenFirstCache | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $hiddenFirstCachePath -Encoding UTF8
        $hiddenFirstDefaults = Get-CodexCapabilities -ModelsCachePath $hiddenFirstCachePath -IncludeHidden -CodexBin "missing-codex.exe"
        Assert-True ($hiddenFirstDefaults.defaults.model -eq "gpt-test-frontier") "defaults should never advertise a hidden model"
    } finally {
        Remove-Item -LiteralPath $hiddenFirstCachePath -Force -ErrorAction SilentlyContinue
    }

    $jsonCapabilities = & (Join-Path $Scripts "get-capabilities.ps1") -ModelsCachePath $fixture -Json | ConvertFrom-Json
    Assert-True (@($jsonCapabilities.models).Count -eq 2) "JSON output should contain the complete visible model list"

    $automatic = Resolve-CodexSelection -Capabilities $capabilities -Model "auto" -Reasoning "auto"
    Assert-True ($automatic.model -eq "gpt-test-frontier") "auto model should select the highest-priority visible model"
    Assert-True ($automatic.reasoning -eq "medium") "auto reasoning should use the selected model default"

    $hiddenFirstCapabilities = [PSCustomObject]@{
        models = @(
            [PSCustomObject]@{
                slug = "hidden-first"
                priority = -1
                visibility = "hide"
                default_reasoning_level = "medium"
                supported_reasoning_levels = @([PSCustomObject]@{ effort = "medium" })
            },
            $capabilities.models[0]
        )
    }
    $visibleAutomatic = Resolve-CodexSelection -Capabilities $hiddenFirstCapabilities -Model "auto" -Reasoning "auto"
    Assert-True ($visibleAutomatic.model -eq "gpt-test-frontier") "auto model should never select a hidden model"

    $xhigh = Resolve-CodexSelection -Capabilities $capabilities -Model "gpt-test-frontier" -Reasoning "xhigh"
    Assert-True ($xhigh.reasoning -eq "xhigh") "frontier model should accept advertised xhigh reasoning"

    $unsupportedRejected = $false
    try {
        Resolve-CodexSelection -Capabilities $capabilities -Model "gpt-test-fast" -Reasoning "medium" | Out-Null
    } catch {
        $unsupportedRejected = $true
    }
    Assert-True $unsupportedRejected "fast model should reject unsupported medium reasoning"

    Assert-True ($capabilities.modes -contains "review") "capabilities should expose review mode"
    Assert-True ($capabilities.modes -contains "workhorse") "capabilities should expose workhorse mode"
    Assert-True ($capabilities.sandboxes -contains "read-only") "capabilities should expose read-only sandbox"
    Assert-True ($capabilities.sandboxes -contains "workspace-write") "capabilities should expose workspace-write sandbox"
    Assert-True ($capabilities.sandboxes -contains "danger-full-access") "capabilities should expose danger-full-access sandbox"
}

$TestGroups = [ordered]@{
    PathSafety = {
        Test-InvalidPairIdsRejected
        Test-ArchiveDoesNotEscapePairRoot
    }
    Purge = { Test-PurgePairDeletesPairDir }
    Timeout = { Test-ListenerReturnsTimeoutError }
    CapabilityDiscovery = { Test-CapabilityDiscovery }
}

if ($Only) {
    if (-not $TestGroups.Contains($Only)) {
        throw "Unknown test group '$Only'. Available groups: $($TestGroups.Keys -join ', ')"
    }
    & $TestGroups[$Only]
} else {
    foreach ($group in $TestGroups.GetEnumerator()) {
        & $group.Value
    }
}

# All asserts passed if we got here. Clear any non-zero $LASTEXITCODE that leaked
# from Invoke-ScriptExpectFailure (where we INTENTIONALLY ran scripts that exit non-zero).
Write-Output "All co-review tests passed"
$global:LASTEXITCODE = 0
exit 0
