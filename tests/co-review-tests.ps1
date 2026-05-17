[CmdletBinding()]
param()

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

Test-InvalidPairIdsRejected
Test-ArchiveDoesNotEscapePairRoot
Test-PurgePairDeletesPairDir
Test-ListenerReturnsTimeoutError

# All asserts passed if we got here. Clear any non-zero $LASTEXITCODE that leaked
# from Invoke-ScriptExpectFailure (where we INTENTIONALLY ran scripts that exit non-zero).
Write-Output "All co-review tests passed"
$global:LASTEXITCODE = 0
exit 0
