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

function New-FakeCodex {
    param(
        [Parameter(Mandatory=$true)][string]$Directory,
        [int]$SleepMs = 0
    )

    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $fakeCodex = Join-Path $Directory "codex.exe"
    $typeName = "FakeCodex_" + [System.Guid]::NewGuid().ToString("N")
    $source = @"
using System;
using System.IO;
using System.Text;
using System.Threading;
public static class $typeName {
    public static int Main(string[] args) {
        if (args.Length == 1 && args[0] == "--version") {
            Console.WriteLine("codex-cli 0.999.0-test");
            return 0;
        }

        Thread.Sleep($SleepMs);
        string argsPath = Environment.GetEnvironmentVariable("CO_REVIEW_TEST_ARGS");
        if (!String.IsNullOrWhiteSpace(argsPath)) {
            File.WriteAllLines(argsPath, args, new UTF8Encoding(false));
        }

        string stdin = Console.In.ReadToEnd();
        string stdinPath = Environment.GetEnvironmentVariable("CO_REVIEW_TEST_STDIN");
        if (!String.IsNullOrWhiteSpace(stdinPath)) {
            File.WriteAllText(stdinPath, stdin, new UTF8Encoding(false));
        }

        for (int i = 0; i < args.Length - 1; i++) {
            if (args[i] == "-o") {
                File.WriteAllText(args[i + 1], "fake codex reply", new UTF8Encoding(false));
                break;
            }
        }
        Console.WriteLine("{\"type\":\"thread.started\",\"thread_id\":\"fake-thread\"}");
        return 0;
    }
}
"@
    Add-Type -TypeDefinition $source -OutputAssembly $fakeCodex -OutputType ConsoleApplication
    return $fakeCodex
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
    $fakeCodex = New-FakeCodex -Directory $fakeDir -SleepMs 30000

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

function Invoke-WorkerModeTurn {
    param(
        [Parameter(Mandatory=$true)]$Pair,
        [Parameter(Mandatory=$true)][string]$FakeCodex,
        [Parameter(Mandatory=$true)][string]$CaptureDir,
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$FollowUpMessage = "",
        [string]$Model = "",
        [string]$Reasoning = "",
        [int]$TurnTimeoutSec = 0
    )

    New-Item -ItemType Directory -Path $CaptureDir -Force | Out-Null
    $argsPath = Join-Path $CaptureDir "args.txt"
    $stdinPath = Join-Path $CaptureDir "stdin.txt"
    $oldArgsPath = $env:CO_REVIEW_TEST_ARGS
    $oldStdinPath = $env:CO_REVIEW_TEST_STDIN
    $env:CO_REVIEW_TEST_ARGS = $argsPath
    $env:CO_REVIEW_TEST_STDIN = $stdinPath

    $listener = Start-Process powershell.exe -ArgumentList @(
        "-NoProfile",
        "-File", (Join-Path $Scripts "codex-listener.ps1"),
        "-PairId", $Pair.pair_id,
        "-CodexBin", $FakeCodex,
        "-PollIntervalSec", "1"
    ) -WindowStyle Hidden -PassThru
    try {
        Start-Sleep -Seconds 1
        $askArgs = @{
            PairId = $Pair.pair_id
            Message = $Message
            TimeoutSec = 20
            PollIntervalSec = 1
            RawJson = $true
        }
        if (-not [string]::IsNullOrWhiteSpace($Model)) { $askArgs.Model = $Model }
        if (-not [string]::IsNullOrWhiteSpace($Reasoning)) { $askArgs.Reasoning = $Reasoning }
        if ($TurnTimeoutSec -gt 0) { $askArgs.TurnTimeoutSec = $TurnTimeoutSec }
        $replyJson = & (Join-Path $Scripts "ask.ps1") @askArgs | Select-Object -Last 1
        $reply = $replyJson | ConvertFrom-Json
        Assert-True ($reply.content -eq "fake codex reply") "fake Codex reply should round-trip through the listener"

        if (-not [string]::IsNullOrWhiteSpace($FollowUpMessage)) {
            $askArgs.Message = $FollowUpMessage
            $followUpReplyJson = & (Join-Path $Scripts "ask.ps1") @askArgs | Select-Object -Last 1
            $followUpReply = $followUpReplyJson | ConvertFrom-Json
            Assert-True ($followUpReply.content -eq "fake codex reply") "fake Codex follow-up should resume through the listener"
        }

        $deadline = (Get-Date).AddSeconds(5)
        while ((-not (Test-Path -LiteralPath $argsPath) -or -not (Test-Path -LiteralPath $stdinPath)) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 100
        }
        Assert-True (Test-Path -LiteralPath $argsPath) "fake Codex should capture its argument vector"
        Assert-True (Test-Path -LiteralPath $stdinPath) "fake Codex should capture stdin"

        $queueLine = Get-Content -LiteralPath (Join-Path $Pair.pair_dir "to-codex.jsonl") -Encoding UTF8 |
            Where-Object { $_ -and $_.Trim() -ne "" } | Select-Object -Last 1
        return [PSCustomObject]@{
            Args = @(Get-Content -LiteralPath $argsPath -Encoding UTF8)
            Stdin = [System.IO.File]::ReadAllText($stdinPath)
            Queue = ($queueLine | ConvertFrom-Json)
        }
    } finally {
        & (Join-Path $Scripts "end-pair.ps1") -PairId $Pair.pair_id -Delete | Out-Null
        Start-Sleep -Seconds 2
        if (-not $listener.HasExited) { Stop-Process -Id $listener.Id -Force }
        $env:CO_REVIEW_TEST_ARGS = $oldArgsPath
        $env:CO_REVIEW_TEST_STDIN = $oldStdinPath
    }
}

function Assert-TamperedPairRejected {
    param(
        [Parameter(Mandatory=$true)]$Pair,
        [Parameter(Mandatory=$true)][string]$FakeCodex,
        [Parameter(Mandatory=$true)][string]$CaptureDir
    )

    New-Item -ItemType Directory -Path $CaptureDir -Force | Out-Null
    $argsPath = Join-Path $CaptureDir "args.txt"
    $stdinPath = Join-Path $CaptureDir "stdin.txt"
    $stdoutPath = Join-Path $CaptureDir "listener-stdout.txt"
    $stderrPath = Join-Path $CaptureDir "listener-stderr.txt"
    $oldArgsPath = $env:CO_REVIEW_TEST_ARGS
    $oldStdinPath = $env:CO_REVIEW_TEST_STDIN
    $env:CO_REVIEW_TEST_ARGS = $argsPath
    $env:CO_REVIEW_TEST_STDIN = $stdinPath

    $listener = Start-Process powershell.exe -ArgumentList @(
        "-NoProfile",
        "-NonInteractive",
        "-File", (Join-Path $Scripts "codex-listener.ps1"),
        "-PairId", $Pair.pair_id,
        "-CodexBin", $FakeCodex,
        "-PollIntervalSec", "1"
    ) -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
    try {
        $exited = $listener.WaitForExit(5000)
        Assert-True $exited "listener should reject invalid schema-v2 mode/sandbox metadata"
        $listenerOutput = ((Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue) + (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue))
        Assert-True ($listenerOutput -match "review.*read-only") "listener should explain the fixed review sandbox boundary"
        Assert-True (-not (Test-Path -LiteralPath $argsPath)) "listener should reject tampered metadata before invoking Codex"
    } finally {
        if (-not $listener.HasExited) { Stop-Process -Id $listener.Id -Force }
        $env:CO_REVIEW_TEST_ARGS = $oldArgsPath
        $env:CO_REVIEW_TEST_STDIN = $oldStdinPath
    }
}

function Test-WorkerModes {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("co-review-worker-modes-" + [System.Guid]::NewGuid().ToString("N"))
    $fakeDir = Join-Path $tempRoot "fake"
    $codexHome = Join-Path $tempRoot "codex-home"
    $missingCodexHome = Join-Path $tempRoot "missing-codex-home"
    $extraDir = Join-Path $tempRoot "extra dir"
    New-Item -ItemType Directory -Path $codexHome,$missingCodexHome,$extraDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot "tests\fixtures\models-cache.json") -Destination (Join-Path $codexHome "models_cache.json")
    $fakeCodex = New-FakeCodex -Directory $fakeDir
    $oldCodexHome = $env:CODEX_HOME
    $env:CODEX_HOME = $codexHome
    $review = $null
    $workhorse = $null
    $tampered = $null
    $legacy = $null

    try {
        $env:CODEX_HOME = $missingCodexHome
        try {
            $legacyJson = & (Join-Path $Scripts "new-pair.ps1") -NoSpawn -Task "legacy missing-cache pair" -WorkerName "legacy" -CodexBin $fakeCodex | Select-Object -Last 1
            $legacy = $legacyJson | ConvertFrom-Json
            $missingAuto = Invoke-ScriptExpectFailure -ScriptName "new-pair.ps1" -ScriptArgs @("-NoSpawn", "-Task", "missing auto", "-CodexBin", $fakeCodex, "-CodexModel", "auto", "-CodexReasoning", "auto")
            Assert-True ($missingAuto.ExitCode -ne 0) "auto pair selection should require a discoverable model"
            Assert-True ($missingAuto.Output -match "no visible models were discovered") "missing-cache auto selection should explain the missing discoverable default"
        } finally {
            $env:CODEX_HOME = $codexHome
        }
        $legacyMeta = Get-Content -LiteralPath (Join-Path $legacy.pair_dir "pair.json") -Raw | ConvertFrom-Json
        Assert-True ($legacyMeta.requested_model -eq "gpt-5.5") "missing cache should preserve the pinned legacy model request"
        Assert-True ($legacyMeta.codex_model -eq "gpt-5.5") "missing cache should allow the explicit legacy model"
        Assert-True ($legacyMeta.requested_reasoning -eq "medium") "missing cache should preserve the pinned legacy reasoning request"
        Assert-True ($legacyMeta.codex_reasoning -eq "medium") "missing cache should allow explicit legacy reasoning"
        & (Join-Path $Scripts "purge-pair.ps1") -PairId $legacy.pair_id -Force | Out-Null
        $legacy = $null

        $unsupportedPair = Invoke-ScriptExpectFailure -ScriptName "new-pair.ps1" -ScriptArgs @("-NoSpawn", "-Task", "unsupported reasoning", "-CodexBin", $fakeCodex, "-CodexModel", "gpt-test-fast", "-CodexReasoning", "medium")
        Assert-True ($unsupportedPair.ExitCode -ne 0) "discovered models should reject unsupported pair-level reasoning"
        Assert-True ($unsupportedPair.Output -match "does not support reasoning level 'medium'") "unsupported discovered reasoning should report the model capability mismatch"

        $reviewJson = & (Join-Path $Scripts "new-pair.ps1") -NoSpawn -Task "review task" -WorkerName "reviewer" -Mode review -CodexBin $fakeCodex -CodexModel "gpt-test-frontier" -CodexReasoning medium | Select-Object -Last 1
        $review = $reviewJson | ConvertFrom-Json
        $reviewMeta = Get-Content -LiteralPath (Join-Path $review.pair_dir "pair.json") -Raw | ConvertFrom-Json
        Assert-True ($reviewMeta.schema_version -eq 2) "new pairs should persist schema version 2"
        Assert-True ($reviewMeta.worker_name -eq "reviewer") "new pairs should persist the worker name"
        Assert-True ($reviewMeta.mode -eq "review") "review pairs should persist review mode"
        Assert-True ($reviewMeta.sandbox -eq "read-only") "review pairs should default to read-only"
        Assert-True ($reviewMeta.isolation -eq "shared") "legacy pair creation should default to shared isolation"
        Assert-True ($reviewMeta.requested_model -eq "gpt-test-frontier") "pair metadata should preserve the requested model"
        Assert-True ($reviewMeta.codex_model -eq "gpt-test-frontier") "pair metadata should persist the effective model"
        Assert-True ($reviewMeta.requested_reasoning -eq "medium") "pair metadata should preserve requested reasoning"
        Assert-True ($reviewMeta.codex_reasoning -eq "medium") "pair metadata should persist effective reasoning"

        $reviewTurn = Invoke-WorkerModeTurn -Pair $review -FakeCodex $fakeCodex -CaptureDir (Join-Path $tempRoot "review-capture") -Message "inspect this change" -Model "gpt-test-frontier" -Reasoning "xhigh" -TurnTimeoutSec 17
        $review = $null
        $reviewExec = [Array]::IndexOf($reviewTurn.Args, "exec")
        Assert-True ($reviewTurn.Args[0] -eq "-a" -and $reviewTurn.Args[1] -eq "never") "approval mode should be a top-level option before exec"
        Assert-True ($reviewExec -gt 1) "exec should follow top-level options"
        $reviewSandbox = [Array]::IndexOf($reviewTurn.Args, "--sandbox")
        Assert-True ($reviewSandbox -gt $reviewExec -and $reviewTurn.Args[$reviewSandbox + 1] -eq "read-only") "review turns should use the read-only sandbox"
        Assert-True (($reviewTurn.Args -join "`n") -match "(?m)^features\.multi_agent=false$") "review turns should disable multi-agent"
        Assert-True ($reviewTurn.Stdin -match "MODE: review") "review envelope should identify review mode"
        Assert-True ($reviewTurn.Stdin -match "MUST NOT edit files") "review envelope should prohibit edits"
        Assert-True ($reviewTurn.Stdin -match "TASK FROM CLAUDE:\s*inspect this change") "review envelope should append the original task"
        Assert-True ($reviewTurn.Queue.model -eq "gpt-test-frontier") "queue should persist a per-turn model"
        Assert-True ($reviewTurn.Queue.reasoning -eq "xhigh") "queue should persist dynamic xhigh reasoning"
        Assert-True ($reviewTurn.Queue.turn_timeout_sec -eq 17) "queue should persist the Codex turn timeout separately"

        $workhorseJson = & (Join-Path $Scripts "new-pair.ps1") -NoSpawn -Task "implementation task" -WorkerName "builder" -Mode workhorse -CodexBin $fakeCodex -CodexModel "gpt-test-frontier" -CodexReasoning xhigh -Search -AddDir $extraDir -Profile "test-profile" -ConfigOverride "features.web_search=true" | Select-Object -Last 1
        $workhorse = $workhorseJson | ConvertFrom-Json
        $workhorseMeta = Get-Content -LiteralPath (Join-Path $workhorse.pair_dir "pair.json") -Raw | ConvertFrom-Json
        Assert-True ($workhorseMeta.mode -eq "workhorse") "workhorse pairs should persist workhorse mode"
        Assert-True ($workhorseMeta.sandbox -eq "workspace-write") "workhorse pairs should default to workspace-write"
        Assert-True ($workhorseMeta.requested_reasoning -eq "xhigh") "pair metadata should preserve an advertised explicit xhigh default"
        Assert-True ($workhorseMeta.codex_reasoning -eq "xhigh") "pair metadata should resolve an advertised xhigh default"
        Assert-True ($workhorseMeta.search_enabled -eq $true) "pair metadata should persist search enablement"
        Assert-True (@($workhorseMeta.config_overrides) -contains "features.web_search=true") "pair metadata should persist safe config overrides"

        $workhorseTurn = Invoke-WorkerModeTurn -Pair $workhorse -FakeCodex $fakeCodex -CaptureDir (Join-Path $tempRoot "workhorse-capture") -Message "implement the bounded change" -FollowUpMessage "continue the bounded change"
        $workhorse = $null
        $workhorseExec = [Array]::IndexOf($workhorseTurn.Args, "exec")
        $workhorseSandbox = [Array]::IndexOf($workhorseTurn.Args, "--sandbox")
        Assert-True ($workhorseTurn.Args[0] -eq "-a" -and $workhorseTurn.Args[1] -eq "never") "workhorse approval mode should be top-level before exec"
        $searchIndex = [Array]::IndexOf($workhorseTurn.Args, "--search")
        $addDirIndex = [Array]::IndexOf($workhorseTurn.Args, "--add-dir")
        Assert-True ($searchIndex -ge 0 -and $searchIndex -lt $workhorseExec) "search should be present as a top-level option before exec"
        Assert-True ($addDirIndex -ge 0 -and $addDirIndex -lt $workhorseExec) "add-dir should be present as a top-level option before exec"
        Assert-True ($workhorseSandbox -gt $workhorseExec -and $workhorseTurn.Args[$workhorseSandbox + 1] -eq "workspace-write") "workhorse turns should use workspace-write"
        $resumeIndex = [Array]::IndexOf($workhorseTurn.Args, "resume")
        Assert-True ($resumeIndex -gt [Array]::IndexOf($workhorseTurn.Args, "-o")) "all exec options should remain before the resume subcommand"
        Assert-True ($workhorseTurn.Args[$resumeIndex + 1] -eq "fake-thread") "follow-up turns should resume the saved Codex thread"
        Assert-True (($workhorseTurn.Args -join "`n") -match "(?m)^features\.multi_agent=false$") "workhorse turns should disable multi-agent"
        Assert-True (($workhorseTurn.Args -join "`n") -match "(?m)^features\.web_search=true$") "safe config overrides should be passed as literal argument values"
        Assert-True (($workhorseTurn.Args -join "`n") -match "(?m)^model_reasoning_effort=xhigh$") "advertised xhigh pair defaults should reach listener invocation"
        Assert-True ($workhorseTurn.Stdin -match "MODE: workhorse") "workhorse envelope should identify workhorse mode"
        Assert-True ($workhorseTurn.Stdin -match "implement") "workhorse envelope should require implementation"
        Assert-True ($workhorseTurn.Stdin -match "run verification") "workhorse envelope should require verification"

        $danger = Invoke-ScriptExpectFailure -ScriptName "new-pair.ps1" -ScriptArgs @("-NoSpawn", "-Task", "unsafe", "-Mode", "workhorse", "-Sandbox", "danger-full-access", "-CodexBin", $fakeCodex)
        Assert-True ($danger.ExitCode -ne 0) "danger-full-access should require explicit confirmation"
        Assert-True ($danger.Output -match "ConfirmDangerFullAccess") "danger-full-access failure should name the confirmation switch"

        $writableReview = Invoke-ScriptExpectFailure -ScriptName "new-pair.ps1" -ScriptArgs @("-NoSpawn", "-Task", "unsafe review", "-Mode", "review", "-Sandbox", "workspace-write", "-CodexBin", $fakeCodex)
        Assert-True ($writableReview.ExitCode -ne 0) "review workers should reject writable sandboxes"

        $meshOverride = Invoke-ScriptExpectFailure -ScriptName "new-pair.ps1" -ScriptArgs @("-NoSpawn", "-Task", "mesh", "-Mode", "workhorse", "-ConfigOverride", "features.multi_agent=true", "-CodexBin", $fakeCodex)
        Assert-True ($meshOverride.ExitCode -ne 0) "generic overrides should not bypass the multi-agent guard"

        $tamperedJson = & (Join-Path $Scripts "new-pair.ps1") -NoSpawn -Task "tampered review" -WorkerName "tampered" -Mode review -CodexBin $fakeCodex -CodexModel auto -CodexReasoning auto | Select-Object -Last 1
        $tampered = $tamperedJson | ConvertFrom-Json
        $tamperedMetaPath = Join-Path $tampered.pair_dir "pair.json"
        $tamperedMeta = Get-Content -LiteralPath $tamperedMetaPath -Raw | ConvertFrom-Json
        Assert-True ($tamperedMeta.requested_model -eq "auto") "pair metadata should preserve an automatic model request"
        Assert-True ($tamperedMeta.codex_model -eq "gpt-test-frontier") "pair metadata should persist the resolved automatic model"
        Assert-True ($tamperedMeta.requested_reasoning -eq "auto") "pair metadata should preserve an automatic reasoning request"
        Assert-True ($tamperedMeta.codex_reasoning -eq "medium") "pair metadata should persist the resolved automatic reasoning"
        $tamperedMeta.sandbox = "workspace-write"
        $tamperedMetaJson = $tamperedMeta | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($tamperedMetaPath, $tamperedMetaJson, [System.Text.UTF8Encoding]::new($false))
        Assert-TamperedPairRejected -Pair $tampered -FakeCodex $fakeCodex -CaptureDir (Join-Path $tempRoot "tampered-capture")
        & (Join-Path $Scripts "purge-pair.ps1") -PairId $tampered.pair_id -Force | Out-Null
        $tampered = $null
    } finally {
        if ($null -ne $review -and (Test-Path -LiteralPath $review.pair_dir)) { & (Join-Path $Scripts "purge-pair.ps1") -PairId $review.pair_id -Force | Out-Null }
        if ($null -ne $workhorse -and (Test-Path -LiteralPath $workhorse.pair_dir)) { & (Join-Path $Scripts "purge-pair.ps1") -PairId $workhorse.pair_id -Force | Out-Null }
        if ($null -ne $tampered -and (Test-Path -LiteralPath $tampered.pair_dir)) { & (Join-Path $Scripts "purge-pair.ps1") -PairId $tampered.pair_id -Force | Out-Null }
        if ($null -ne $legacy -and (Test-Path -LiteralPath $legacy.pair_dir)) { & (Join-Path $Scripts "purge-pair.ps1") -PairId $legacy.pair_id -Force | Out-Null }
        $env:CODEX_HOME = $oldCodexHome
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
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

    $malformedOverrideRejected = $false
    try {
        Assert-SafeCodexConfigOverrides -Overrides @("not-an-assignment")
    } catch {
        $malformedOverrideRejected = $true
    }
    Assert-True $malformedOverrideRejected "malformed Codex config overrides should be rejected"

    $multiAgentOverrideRejected = $false
    try {
        Assert-SafeCodexConfigOverrides -Overrides @("features.multi_agent=true")
    } catch {
        $multiAgentOverrideRejected = $true
    }
    Assert-True $multiAgentOverrideRejected "features.multi_agent should be rejected as a generic override"

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

    $inconsistentCapabilities = [PSCustomObject]@{
        models = @([PSCustomObject]@{
            slug = "inconsistent-default"
            priority = 0
            visibility = "list"
            default_reasoning_level = "medium"
            supported_reasoning_levels = @([PSCustomObject]@{ effort = "low" })
        })
    }
    $inconsistentDefaultRejected = $false
    try {
        Resolve-CodexSelection -Capabilities $inconsistentCapabilities -Model "inconsistent-default" -Reasoning "auto" | Out-Null
    } catch {
        $inconsistentDefaultRejected = $true
    }
    Assert-True $inconsistentDefaultRejected "auto reasoning should reject a default not advertised as supported"

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

function Wait-ForListener {
    param([Parameter(Mandatory=$true)][string]$PairDir, [int]$TimeoutSec = 10)
    $pidFile = Join-Path $PairDir "listener.pid"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $pidFile) { return }
        Start-Sleep -Milliseconds 200
    }
    throw "Listener did not start for $PairDir"
}

function Test-WorkerLifecycle {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("co-review-lifecycle-" + [System.Guid]::NewGuid().ToString("N"))
    $fakeCodex = New-FakeCodex -Directory (Join-Path $tempRoot "fake")
    $codexHome = Join-Path $tempRoot "codex-home"
    New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot "tests\fixtures\models-cache.json") -Destination (Join-Path $codexHome "models_cache.json")
    $oldCodexHome = $env:CODEX_HOME
    $env:CODEX_HOME = $codexHome
    $workers = @()
    try {
        foreach ($name in @("review-security", "review-performance")) {
            $json = & (Join-Path $Scripts "new-worker.ps1") -Name $name -Mode review -Task "review task" -ProjectCwd $RepoRoot -Model gpt-test-frontier -Reasoning medium -CodexBin $fakeCodex -DryRunListener | Select-Object -Last 1
            $worker = $json | ConvertFrom-Json
            $workers += $worker
            Assert-True ($worker.worker_id -eq $worker.pair_id) "worker output should retain the compatible pair id"
            Wait-ForListener -PairDir $worker.pair_dir
        }
        Assert-True ($workers[0].worker_id -ne $workers[1].worker_id) "workers should have distinct ids"
        $reply = & (Join-Path $Scripts "ask-worker.ps1") -WorkerId $workers[0].worker_id -Message "hello worker" -TimeoutSec 20 -RawJson | Select-Object -Last 1 | ConvertFrom-Json
        Assert-True ($reply.content -match "hello worker") "worker ask should route through the existing queue"
        $listed = @(& (Join-Path $Scripts "list-workers.ps1") -Json | ConvertFrom-Json)
        Assert-True (@($listed | Where-Object { $_.name -eq "review-security" -and $_.mode -eq "review" }).Count -eq 1) "list-workers should expose worker name and mode"
        $ensured = & (Join-Path $Scripts "ensure-worker.ps1") -WorkerId $workers[0].worker_id -Json | Select-Object -Last 1 | ConvertFrom-Json
        Assert-True ($ensured.status -eq "active") "ensure-worker should verify a live worker"
    } finally {
        foreach ($worker in $workers) {
            if (Test-Path -LiteralPath $worker.pair_dir) {
                & (Join-Path $Scripts "end-worker.ps1") -WorkerId $worker.worker_id -Delete | Out-Null
            }
        }
        $env:CODEX_HOME = $oldCodexHome
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-WriterLeases {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("co-review-leases-" + [System.Guid]::NewGuid().ToString("N"))
    $project = Join-Path $tempRoot "project"
    $fakeCodex = New-FakeCodex -Directory (Join-Path $tempRoot "fake")
    $codexHome = Join-Path $tempRoot "codex-home"
    New-Item -ItemType Directory -Path $project,$codexHome -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot "tests\fixtures\models-cache.json") -Destination (Join-Path $codexHome "models_cache.json")
    $oldCodexHome = $env:CODEX_HOME
    $env:CODEX_HOME = $codexHome
    $first = $null
    $second = $null
    try {
        $first = (& (Join-Path $Scripts "new-worker.ps1") -Name writer-one -Mode workhorse -Task "write one" -ProjectCwd $project -Isolation shared -Model gpt-test-frontier -Reasoning medium -CodexBin $fakeCodex -DryRunListener | Select-Object -Last 1) | ConvertFrom-Json
        Wait-ForListener -PairDir $first.pair_dir
        $conflict = Invoke-ScriptExpectFailure -ScriptName "new-worker.ps1" -ScriptArgs @("-Name","writer-two","-Mode","workhorse","-Task","write two","-ProjectCwd",$project,"-Isolation","shared","-Model","gpt-test-frontier","-Reasoning","medium","-CodexBin",$fakeCodex,"-DryRunListener")
        Assert-True ($conflict.ExitCode -ne 0) "a second shared workhorse should be rejected"
        Assert-True ($conflict.Output -match [regex]::Escape($first.worker_id)) "lease conflict should identify the current owner"
        & (Join-Path $Scripts "end-worker.ps1") -WorkerId $first.worker_id -Delete | Out-Null
        $first = $null

        . (Join-Path $Scripts "common.ps1")
        $staleId = "pair-20000101-000000-dead"
        $staleDir = Join-Path (Get-CoReviewRoot) $staleId
        New-Item -ItemType Directory -Path $staleDir -Force | Out-Null
        $staleLeasePath = Get-WriterLeasePath -WorkingDirectory $project
        $staleLease = @{ pair_id=$staleId; pair_dir=$staleDir; working_directory=(Get-CanonicalDirectory $project); created_at="2000-01-01T00:00:00Z" } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($staleLeasePath, $staleLease, [System.Text.UTF8Encoding]::new($false))
        $second = (& (Join-Path $Scripts "new-worker.ps1") -Name writer-two -Mode workhorse -Task "write two" -ProjectCwd $project -Isolation shared -Model gpt-test-frontier -Reasoning medium -CodexBin $fakeCodex -DryRunListener | Select-Object -Last 1) | ConvertFrom-Json
        Wait-ForListener -PairDir $second.pair_dir
        $reclaimedLease = Get-Content -LiteralPath $staleLeasePath -Raw | ConvertFrom-Json
        Assert-True ($reclaimedLease.pair_id -eq $second.worker_id) "a verified stale writer lease should be reclaimed"
        Remove-Item -LiteralPath $staleDir -Recurse -Force -ErrorAction SilentlyContinue
    } finally {
        if ($null -ne $first -and (Test-Path -LiteralPath $first.pair_dir)) { & (Join-Path $Scripts "end-worker.ps1") -WorkerId $first.worker_id -Delete | Out-Null }
        if ($null -ne $second -and (Test-Path -LiteralPath $second.pair_dir)) { & (Join-Path $Scripts "end-worker.ps1") -WorkerId $second.worker_id -Delete | Out-Null }
        $env:CODEX_HOME = $oldCodexHome
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-WorktreeIsolation {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("co-review-worktrees-" + [System.Guid]::NewGuid().ToString("N"))
    $project = Join-Path $tempRoot "repo"
    $fakeCodex = New-FakeCodex -Directory (Join-Path $tempRoot "fake")
    $codexHome = Join-Path $tempRoot "codex-home"
    New-Item -ItemType Directory -Path $project,$codexHome -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot "tests\fixtures\models-cache.json") -Destination (Join-Path $codexHome "models_cache.json")
    & git -C $project init | Out-Null
    & git -C $project config user.email "test@example.com"
    & git -C $project config user.name "Co Review Test"
    Set-Content -LiteralPath (Join-Path $project "tracked.txt") -Value "base" -Encoding ASCII
    & git -C $project add tracked.txt
    & git -C $project commit -m "base" | Out-Null
    $oldCodexHome = $env:CODEX_HOME
    $env:CODEX_HOME = $codexHome
    $first = $null
    $second = $null
    try {
        $first = (& (Join-Path $Scripts "new-worker.ps1") -Name writer-primary -Mode workhorse -Task "primary" -ProjectCwd $project -Isolation auto -Model gpt-test-frontier -Reasoning medium -CodexBin $fakeCodex -DryRunListener | Select-Object -Last 1) | ConvertFrom-Json
        Wait-ForListener -PairDir $first.pair_dir
        $second = (& (Join-Path $Scripts "new-worker.ps1") -Name writer-isolated -Mode workhorse -Task "isolated" -ProjectCwd $project -Isolation auto -Model gpt-test-frontier -Reasoning medium -CodexBin $fakeCodex -DryRunListener | Select-Object -Last 1) | ConvertFrom-Json
        Wait-ForListener -PairDir $second.pair_dir
        Assert-True ($first.project_cwd -eq $project) "first automatic workhorse should use the source checkout"
        Assert-True ($second.project_cwd -ne $project) "second automatic workhorse should use an isolated worktree"
        Assert-True (Test-Path -LiteralPath $second.project_cwd) "managed worktree should exist"
        $secondMeta = Get-Content -LiteralPath (Join-Path $second.pair_dir "pair.json") -Raw | ConvertFrom-Json
        Assert-True ($secondMeta.isolation -eq "worktree") "isolated metadata should record worktree isolation"
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$secondMeta.worktree_branch)) "isolated metadata should record a branch"

        Set-Content -LiteralPath (Join-Path $project "tracked.txt") -Value "dirty" -Encoding ASCII
        $dirty = Invoke-ScriptExpectFailure -ScriptName "new-worker.ps1" -ScriptArgs @("-Name","writer-dirty","-Mode","workhorse","-Task","dirty","-ProjectCwd",$project,"-Isolation","auto","-Model","gpt-test-frontier","-Reasoning","medium","-CodexBin",$fakeCodex,"-DryRunListener")
        Assert-True ($dirty.ExitCode -ne 0) "parallel auto isolation should reject a dirty source"
        Assert-True ($dirty.Output -match "uncommitted|dirty") "dirty-source rejection should be actionable"
        Assert-True ((Get-Content -LiteralPath (Join-Path $project "tracked.txt") -Raw).Trim() -eq "dirty") "failed isolation must preserve source changes"
    } finally {
        if ($null -ne $first -and (Test-Path -LiteralPath $first.pair_dir)) { & (Join-Path $Scripts "end-worker.ps1") -WorkerId $first.worker_id -Delete | Out-Null }
        if ($null -ne $second -and (Test-Path -LiteralPath $second.pair_dir)) { & (Join-Path $Scripts "end-worker.ps1") -WorkerId $second.worker_id -Delete | Out-Null }
        if ($null -ne $second -and (Test-Path -LiteralPath $second.project_cwd)) { & git -C $project worktree remove --force $second.project_cwd 2>$null | Out-Null }
        $env:CODEX_HOME = $oldCodexHome
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$TestGroups = [ordered]@{
    PathSafety = {
        Test-InvalidPairIdsRejected
        Test-ArchiveDoesNotEscapePairRoot
    }
    Purge = { Test-PurgePairDeletesPairDir }
    Timeout = { Test-ListenerReturnsTimeoutError }
    CapabilityDiscovery = { Test-CapabilityDiscovery }
    WorkerModes = { Test-WorkerModes }
    WorkerLifecycle = { Test-WorkerLifecycle }
    WriterLeases = { Test-WriterLeases }
    WorktreeIsolation = { Test-WorktreeIsolation }
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
