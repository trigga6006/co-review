# co-review: codex-listener.ps1
# Runs in a dedicated terminal window. Durable JSONL queues are awakened by
# per-pair named events. By default turns use a persistent Codex app-server
# connection, with the one-shot `codex exec` path retained as a fallback.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PairId,
    [string]$CodexBin = "",
    [string]$CodexModel = "",
    [string]$CodexReasoning = "",
    [int]$PollIntervalSec = 2,
    [int]$CodexTimeoutSec = 0,
    [switch]$DryRun  # echo messages without invoking codex
)

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "common.ps1")
. (Join-Path $PSScriptRoot "app-server.ps1")
$pairDir = Get-PairDir -PairId $PairId
if (-not (Test-Path $pairDir)) {
    Write-Host "[co-review] FATAL: pair dir not found: $pairDir" -ForegroundColor Red
    exit 1
}

$toCodex   = Join-Path $pairDir "to-codex.jsonl"
$toClaude  = Join-Path $pairDir "to-claude.jsonl"
$stateFile = Join-Path $pairDir "state.json"
$pairMeta  = Join-Path $pairDir "pair.json"
$logFile   = Join-Path $pairDir "listener.log"
$shutdownFile = Join-Path $pairDir "shutdown"
$pidFile   = Join-Path $pairDir "listener.pid"
$activeTurnFile = Join-Path $pairDir "active-turn.json"
$progressStateFile = Join-Path $pairDir "progress.json"
$cancelDir = Join-Path $pairDir "cancelled"
$inboxSignal = Open-CoReviewSignal -PairId $PairId -Channel "inbox"
$script:appServerClient = $null

# Write our PID so list-pairs can verify the listener is actually alive
[System.IO.File]::WriteAllText($pidFile, $PID, [System.Text.UTF8Encoding]::new($false))
# Ensure we clean up the pid file on exit (graceful or not - the trap covers Ctrl+C too)
$cleanupPidFile = $pidFile
trap {
    try { Stop-CoReviewAppServerClient -Client $script:appServerClient } catch {}
    try { $inboxSignal.Dispose() } catch {}
    Remove-Item -ErrorAction SilentlyContinue $cleanupPidFile
    continue
}

# Load metadata through the shared schema-v1 compatibility boundary.
$meta = Get-NormalizedPairMetadata -PairDir $pairDir
if ([string]::IsNullOrWhiteSpace($CodexBin)) { $CodexBin = $meta.codex_bin }
if ([string]::IsNullOrWhiteSpace($CodexModel)) { $CodexModel = [string]$meta.codex_model }
if ([string]::IsNullOrWhiteSpace($CodexReasoning)) { $CodexReasoning = [string]$meta.codex_reasoning }
if ($CodexTimeoutSec -le 0) {
    $CodexTimeoutSec = if ($meta.codex_timeout_sec -gt 0) { [int]$meta.codex_timeout_sec } else { 1800 }
}
$schemaVersion = [int]$meta.schema_version
$workerMode = [string]$meta.mode
$workerSandbox = [string]$meta.sandbox
$workerIsolation = [string]$meta.isolation

$metadataError = ""
if ($workerMode -notin @("review", "workhorse", "imagegen")) {
    $metadataError = "Invalid worker mode '$workerMode' in schema-v$schemaVersion pair metadata"
} elseif ($workerSandbox -notin @("read-only", "workspace-write", "danger-full-access")) {
    $metadataError = "Invalid worker sandbox '$workerSandbox' in schema-v$schemaVersion pair metadata"
} elseif ($workerMode -eq "review" -and $workerSandbox -ne "read-only") {
    $metadataError = "Review workers must use the read-only sandbox"
} elseif ($workerMode -eq "imagegen" -and $workerSandbox -eq "read-only") {
    $metadataError = "Imagegen workers require a writable sandbox"
}
if ($metadataError) {
    Write-Host "[co-review] FATAL: $metadataError" -ForegroundColor Red
    Remove-Item -ErrorAction SilentlyContinue $pidFile
    exit 1
}

$workerProfile = [string]$meta.profile
$workerAddDirs = @($meta.add_dirs | ForEach-Object { [string]$_ })
$workerSearch = ($meta.search_enabled -eq $true)
$workerConfigOverrides = @($meta.config_overrides | ForEach-Object { [string]$_ })
$requestedTransport = [string]$meta.transport
if ($requestedTransport -notin @("auto", "app-server", "legacy")) { $requestedTransport = "auto" }
$activeTransport = if ($requestedTransport -eq "legacy") { "legacy" } else { "app-server" }
if ($activeTransport -eq "app-server" -and (-not [string]::IsNullOrWhiteSpace($workerProfile) -or $workerSearch -or $workerConfigOverrides.Count -gt 0)) {
    if ($requestedTransport -eq "app-server") {
        $metadataError = "The app-server transport does not yet support Profile, Search, or ConfigOverride worker options; use transport=legacy"
    } else {
        $activeTransport = "legacy"
    }
}
if ($metadataError) {
    Write-Host "[co-review] FATAL: $metadataError" -ForegroundColor Red
    Remove-Item -ErrorAction SilentlyContinue $pidFile
    exit 1
}
try {
    Assert-ValidCodexBin -CodexBin $CodexBin
    Assert-SafeCodexConfigOverrides -Overrides $workerConfigOverrides
} catch {
    Write-Host "[co-review] FATAL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
if ($activeTransport -eq "app-server" -and -not (Test-CoReviewAppServerSupport -CodexBin $CodexBin)) {
    if ($requestedTransport -eq "app-server") {
        Write-Host "[co-review] FATAL: Codex CLI does not expose app-server support" -ForegroundColor Red
        Remove-Item -ErrorAction SilentlyContinue $pidFile
        exit 1
    }
    $activeTransport = "legacy"
}

# Header
$ESC = [char]27
Write-Host ""
Write-Host "===================================================================" -ForegroundColor Cyan
Write-Host "  CO-REVIEW :: Codex sibling session" -ForegroundColor Cyan
Write-Host "===================================================================" -ForegroundColor Cyan
Write-Host "  Pair ID:     $PairId"
Write-Host "  Pair dir:    $pairDir"
Write-Host "  Project cwd: $($meta.project_cwd)"
Write-Host "  Task:        $($meta.task_hint)"
Write-Host "  Worker mode: $workerMode ($workerSandbox)"
Write-Host "  Codex bin:   $CodexBin"
Write-Host "  Codex model: $CodexModel ($CodexReasoning reasoning)"
Write-Host "  Transport:   $activeTransport (requested: $requestedTransport)"
Write-Host "  Created:     $($meta.created_at)"
if ($DryRun) { Write-Host "  Mode:        DRY RUN (echo only, no codex calls)" -ForegroundColor Yellow }
Write-Host ""
Write-Host "  Waiting for messages from Claude Code..." -ForegroundColor Yellow
Write-Host "  To stop: close this window OR drop a file named 'shutdown' in pair dir." -ForegroundColor DarkGray
Write-Host ""

# Working dir for codex calls - the project, not the pair dir
$workDir = $meta.project_cwd
if ([string]::IsNullOrWhiteSpace($workDir) -or -not (Test-Path $workDir)) {
    $workDir = (Get-Location).Path
}

function Write-Log {
    param([string]$Line)
    $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $logFile -Value "[$stamp] $Line" -Encoding UTF8
}

function Get-State {
    if (Test-Path $stateFile) {
        $loaded = Get-Content $stateFile -Raw | ConvertFrom-Json
        if ($null -eq $loaded.PSObject.Properties['completed_turns']) { $loaded | Add-Member completed_turns 0 -Force }
        if ($null -eq $loaded.PSObject.Properties['inbox_offset']) { $loaded | Add-Member inbox_offset 0 -Force }
        if ($null -eq $loaded.PSObject.Properties['codex_thread_id']) { $loaded | Add-Member codex_thread_id $null -Force }
        return $loaded
    }
    return [PSCustomObject]@{ last_processed = $null; codex_session_id = $null; codex_thread_id = $null; inbox_offset = 0; msg_counter = 0; completed_turns = 0 }
}

function Save-State {
    param($state)
    $json = $state | ConvertTo-Json
    [System.IO.File]::WriteAllText($stateFile, $json, [System.Text.UTF8Encoding]::new($false))
}

function Append-Reply {
    param([string]$InReplyTo, [string]$Content, [string]$ErrMsg = "")
    $cnt = Get-NextCoReviewSequence -PairId $PairId -PairDir $pairDir -Channel "outbox" -FallbackQueuePath $toClaude
    $replyId = "cdx-{0:D4}" -f $cnt
    $obj = @{
        id = $replyId
        ts = (Get-Date).ToString("o")
        from = "codex"
        in_reply_to = $InReplyTo
        type = if ($ErrMsg) { "error" } else { "response" }
        content = $Content
    }
    if ($ErrMsg) { $obj.error = $ErrMsg }
    $line = $obj | ConvertTo-Json -Compress -Depth 10
    [System.IO.File]::AppendAllText($toClaude, ($line + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    Signal-CoReviewChannel -PairId $PairId -Channel "outbox"
    return $replyId
}

function Read-NewIncoming {
    param([string]$LastId, [long]$Offset = 0)
    $tail = Read-CoReviewJsonlTail -Path $toCodex -Offset $Offset
    $records = @($tail.records | Where-Object { $null -ne $_.value })
    if ($Offset -eq 0 -and -not [string]::IsNullOrWhiteSpace($LastId)) {
        $afterIdx = -1
        for ($i = 0; $i -lt $records.Count; $i++) { if ([string]$records[$i].value.id -eq $LastId) { $afterIdx = $i; break } }
        if ($afterIdx -ge 0) { $records = if ($afterIdx -lt ($records.Count - 1)) { @($records[($afterIdx + 1)..($records.Count - 1)]) } else { @() } }
    }
    foreach ($record in $records) {
        $record.value | Add-Member -NotePropertyName _queue_end_offset -NotePropertyValue ([long]$record.end_offset) -Force
    }
    return $records | ForEach-Object { $_.value }
}

function Format-CmdArg {
    # Windows command-line quoting per CommandLineToArgvW rules. Used because
    # PS5.1 / .NET Framework lacks ProcessStartInfo.ArgumentList (added in .NET Core 2.1).
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    # Escape: any backslashes immediately before a quote must be doubled,
    # then the quote itself must be escaped with a backslash.
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    for ($i = 0; $i -lt $Value.Length; $i++) {
        $backslashes = 0
        while ($i -lt $Value.Length -and $Value[$i] -eq '\') { $backslashes++; $i++ }
        if ($i -eq $Value.Length) {
            # trailing backslashes - double them so they don't escape the closing quote
            [void]$sb.Append('\' * ($backslashes * 2))
            break
        } elseif ($Value[$i] -eq '"') {
            [void]$sb.Append('\' * ($backslashes * 2 + 1))
            [void]$sb.Append('"')
        } else {
            [void]$sb.Append('\' * $backslashes)
            [void]$sb.Append($Value[$i])
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-Codex {
    param(
        [string]$Prompt,
        [string]$SessionId,
        [string]$Cwd,
        [string]$Model,
        [string]$Sandbox,
        [int]$TimeoutSec,
        [string]$Reasoning,
        [string]$Profile,
        [string[]]$AddDir = @(),
        [bool]$Search = $false,
        [string[]]$ConfigOverrides = @(),
        [string]$MessageId,
        [string]$ActiveTurnFile,
        [string]$ProgressStateFile,
        [int]$MaxProgressUpdates = 0,
        [int]$ProgressMinIntervalSec = 30
    )

    $lastMsgFile = New-TemporaryFile
    $stdoutEventFile = New-TemporaryFile

    try {
        Assert-SafeCodexConfigOverrides -Overrides $ConfigOverrides
        $validatedAddDirs = @()
        foreach ($dir in $AddDir) {
            if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) {
                throw "AddDir does not exist or is not a directory: $dir"
            }
            $validatedAddDirs += (Resolve-Path -LiteralPath $dir).Path
        }

        # All global `exec` options must come BEFORE the `resume` subcommand;
        # clap rejects `--sandbox` etc. after the subcommand name.
        # Explicit selections pin model/reasoning. Sentinel values omit those
        # flags so Codex can honor the user's own ~/.codex/config.toml defaults.
        $codexArgs = @("-a", "never")
        if ($Search) { $codexArgs += "--search" }
        foreach ($dir in $validatedAddDirs) { $codexArgs += @("--add-dir", $dir) }
        $codexArgs += @(
            "exec",
            "--json",
            "--skip-git-repo-check",
            "--sandbox", $Sandbox
        )
        if (-not [string]::IsNullOrWhiteSpace($Profile)) { $codexArgs += @("-p", $Profile) }
        if (-not [string]::IsNullOrWhiteSpace($Model) -and $Model -notin @("auto", "configured-default")) {
            $codexArgs += @("-m", $Model)
        }
        if (-not [string]::IsNullOrWhiteSpace($Reasoning) -and $Reasoning -ne "auto") {
            $codexArgs += @("-c", "model_reasoning_effort=$Reasoning")
        }
        $codexArgs += @("-c", "features.multi_agent=false")
        foreach ($override in $ConfigOverrides) { $codexArgs += @("-c", $override) }
        $codexArgs += @(
            "-C", $Cwd,
            "-o", $lastMsgFile.FullName
        )
        if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
            $codexArgs += @("resume", $SessionId)
        }
        $codexArgs += "-"  # prompt-from-stdin marker (valid for both `exec` and `exec resume`)

        $argString = ($codexArgs | ForEach-Object { Format-CmdArg $_ }) -join " "
        Write-Host "  -> codex $argString" -ForegroundColor DarkGray

        $procInfo = New-Object System.Diagnostics.ProcessStartInfo
        $procInfo.FileName = $CodexBin
        $procInfo.Arguments = $argString
        $procInfo.WorkingDirectory = $Cwd
        $procInfo.RedirectStandardInput = $true
        $procInfo.RedirectStandardOutput = $true
        $procInfo.RedirectStandardError = $true
        $procInfo.UseShellExecute = $false
        $procInfo.CreateNoWindow = $false

        $proc = [System.Diagnostics.Process]::Start($procInfo)

        if (-not [string]::IsNullOrWhiteSpace($ProgressStateFile)) {
            Remove-Item -LiteralPath $ProgressStateFile -Force -ErrorAction SilentlyContinue
        }

        if (-not [string]::IsNullOrWhiteSpace($ActiveTurnFile)) {
            $active = [ordered]@{
                message_id = $MessageId
                listener_pid = $PID
                process_pid = $proc.Id
                started_at = (Get-Date).ToString("o")
                timeout_sec = $TimeoutSec
            } | ConvertTo-Json
            [System.IO.File]::WriteAllText($ActiveTurnFile, $active, [System.Text.UTF8Encoding]::new($false))
        }

        # Drain JSONL stdout line-by-line so explicitly marked agent updates can
        # reach Claude before the turn finishes. Keep all raw events for final
        # session-id/reply processing.
        $stdoutRunspace = [runspacefactory]::CreateRunspace()
        $stdoutRunspace.Open()
        $stdoutPs = [powershell]::Create()
        $stdoutPs.Runspace = $stdoutRunspace
        [void]$stdoutPs.AddScript({
            param($p, $eventPath, $outboxPath, $progressPath, $messageId, $maxUpdates, $minIntervalSec, $outboxSignalName)
            $utf8 = [System.Text.UTF8Encoding]::new($false)
            $count = 0
            $lastProgress = [DateTimeOffset]::MinValue
            while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
                [System.IO.File]::AppendAllText($eventPath, $line + [Environment]::NewLine, $utf8)
                if ($maxUpdates -le 0 -or $count -ge $maxUpdates) { continue }
                try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                $text = ""
                if ($event.type -eq "item.completed" -and $event.item.type -eq "agent_message") { $text = [string]$event.item.text }
                elseif ($event.type -eq "agent_message" -and $event.message) { $text = [string]$event.message }
                $trimmed = $text.TrimStart()
                $prefix = "CO_REVIEW_PROGRESS:"
                if (-not $trimmed.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                $now = [DateTimeOffset]::Now
                if ($count -gt 0 -and ($now - $lastProgress).TotalSeconds -lt $minIntervalSec) { continue }
                $content = $trimmed.Substring($prefix.Length).Trim()
                if ([string]::IsNullOrWhiteSpace($content)) { continue }
                $count++
                $progress = [ordered]@{
                    id = "prg-$messageId-{0:D2}" -f $count
                    ts = $now.ToString("o")
                    from = "codex"
                    in_reply_to = $messageId
                    type = "progress"
                    content = $content
                }
                [System.IO.File]::AppendAllText($outboxPath, (($progress | ConvertTo-Json -Compress -Depth 10) + [Environment]::NewLine), $utf8)
                try {
                    $created = $false
                    $outboxSignal = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::AutoReset, $outboxSignalName, [ref]$created)
                    try { [void]$outboxSignal.Set() } finally { $outboxSignal.Dispose() }
                } catch {}
                $progressState = [ordered]@{ message_id=$messageId; count=$count; last_progress_at=$progress.ts; last_progress=$content }
                [System.IO.File]::WriteAllText($progressPath, ($progressState | ConvertTo-Json -Depth 5), $utf8)
                $lastProgress = $now
            }
        }).AddArgument($proc).AddArgument($stdoutEventFile.FullName).AddArgument($toClaude).AddArgument($ProgressStateFile).AddArgument($MessageId).AddArgument($MaxProgressUpdates).AddArgument($ProgressMinIntervalSec).AddArgument((Get-CoReviewSignalName -PairId $PairId -Channel "outbox"))
        $stdoutHandle = $stdoutPs.BeginInvoke()

        $stderrRunspace = [runspacefactory]::CreateRunspace()
        $stderrRunspace.Open()
        $stderrPs = [powershell]::Create()
        $stderrPs.Runspace = $stderrRunspace
        [void]$stderrPs.AddScript({
            param($p)
            $p.StandardError.ReadToEnd()
        }).AddArgument($proc)
        $stderrHandle = $stderrPs.BeginInvoke()

        # Write prompt as raw UTF-8 bytes through the base stream
        # (StandardInputEncoding on ProcessStartInfo is .NET Core only).
        $promptBytes = [System.Text.Encoding]::UTF8.GetBytes($Prompt)
        $proc.StandardInput.BaseStream.Write($promptBytes, 0, $promptBytes.Length)
        $proc.StandardInput.BaseStream.Flush()
        $proc.StandardInput.Close()

        $exited = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $exited) {
            Write-Log "codex exec timed out after ${TimeoutSec}s; killing pid=$($proc.Id)"
            try {
                & taskkill.exe /PID $proc.Id /T /F | Out-Null
            } catch {
                try { $proc.Kill() } catch {}
            }
            [void]$proc.WaitForExit(10000)
        }

        # Collect stdout/stderr from the background runspaces.
        try {
            if (-not $stdoutHandle.IsCompleted) { $stdoutPs.Stop() }
            [void]$stdoutPs.EndInvoke($stdoutHandle)
        } catch {
        } finally {
            $stdoutPs.Dispose()
            $stdoutRunspace.Close()
            $stdoutRunspace.Dispose()
        }

        $stdoutLines = New-Object System.Collections.Generic.List[string]
        foreach ($line in @(Get-Content -LiteralPath $stdoutEventFile.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $stdoutLines.Add($line) | Out-Null
                Write-Host "    $line" -ForegroundColor DarkGray
            }
        }

        $stderr = ""
        try {
            if (-not $stderrHandle.IsCompleted) { $stderrPs.Stop() }
            $stderrResult = $stderrPs.EndInvoke($stderrHandle)
            if ($stderrResult) {
                $stderr = if ($stderrResult -is [string]) { $stderrResult } else { [string]$stderrResult }
            }
        } catch {
            $stderr = "[co-review: stderr drain error: $($_.Exception.Message)]"
        } finally {
            $stderrPs.Dispose()
            $stderrRunspace.Close()
            $stderrRunspace.Dispose()
        }

        # Extract session id (Codex emits `thread.started` with `thread_id`)
        $extractedSid = $null
        foreach ($l in $stdoutLines) {
            try { $obj = $l | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($obj.type -eq "thread.started" -and $obj.thread_id) { $extractedSid = $obj.thread_id; break }
            # Fallbacks for other potential event shapes
            if ($obj.type -eq "session_configured" -and $obj.session_id) { $extractedSid = $obj.session_id; break }
            if ($obj.thread_id) { $extractedSid = $obj.thread_id; break }
            if ($obj.session_id) { $extractedSid = $obj.session_id; break }
        }

        # Read last message file (cleanest source of Codex's reply text)
        $reply = ""
        if (Test-Path $lastMsgFile) {
            $reply = [System.IO.File]::ReadAllText($lastMsgFile.FullName)
        }

        # Fallback: if -o didn't produce content, try to extract from JSONL events
        if ([string]::IsNullOrWhiteSpace($reply)) {
            $assembled = New-Object System.Text.StringBuilder
            foreach ($l in $stdoutLines) {
                try { $obj = $l | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                # Look for assistant text deltas / messages
                if ($obj.type -eq "agent_message" -and $obj.msg.message) { [void]$assembled.AppendLine($obj.msg.message) }
                elseif ($obj.type -eq "agent_message" -and $obj.message) { [void]$assembled.AppendLine($obj.message) }
                elseif ($obj.delta -and $obj.delta.content) { [void]$assembled.Append($obj.delta.content) }
            }
            $reply = $assembled.ToString()
        }

        $exitCode = if ($exited) { $proc.ExitCode } else { 124 }
        $timeoutMsg = if ($exited) { "" } else { "codex exec timed out after ${TimeoutSec}s" }

        return [PSCustomObject]@{
            ExitCode    = $exitCode
            Reply       = $reply.Trim()
            Stderr      = if ($timeoutMsg) { "$timeoutMsg`n$stderr" } else { $stderr }
            SessionId   = $extractedSid
            StdoutLines = $stdoutLines
        }
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($ActiveTurnFile)) {
            Remove-Item -LiteralPath $ActiveTurnFile -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -ErrorAction SilentlyContinue $lastMsgFile.FullName
        Remove-Item -ErrorAction SilentlyContinue $stdoutEventFile.FullName
    }
}

# Main loop
Write-Log "Listener started for $PairId"

# A hard-killed listener used to leave the current request unacknowledged. On
# restart that caused a mutating writable-worker turn to run a second time. Convert a
# stale active-turn marker into a correlated interruption error instead.
if (Test-Path -LiteralPath $activeTurnFile -PathType Leaf) {
    try {
        $interrupted = Get-Content -LiteralPath $activeTurnFile -Raw | ConvertFrom-Json
        $interruptedId = [string]$interrupted.message_id
        if ($interruptedId -match '^msg-\d+$') {
            $alreadyReplied = $false
            if (Test-Path -LiteralPath $toClaude) {
                foreach ($line in @(Get-Content -LiteralPath $toClaude -Encoding UTF8 -ErrorAction SilentlyContinue)) {
                    try { $replyObj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                    if ([string]$replyObj.in_reply_to -eq $interruptedId -and [string]$replyObj.type -in @("response", "error")) { $alreadyReplied = $true; break }
                }
            }
            if (-not $alreadyReplied) {
                [void](Append-Reply -InReplyTo $interruptedId -Content "" -ErrMsg "Codex turn was interrupted when the listener stopped; it was not replayed automatically.")
                $recoveryState = Get-State
                $recoveryState.last_processed = $interruptedId
                $completed = if ($null -ne $recoveryState.PSObject.Properties['completed_turns']) { [int]$recoveryState.completed_turns } else { 0 }
                $recoveryState | Add-Member -NotePropertyName completed_turns -NotePropertyValue ($completed + 1) -Force
                Save-State $recoveryState
                Write-Log "Recovered interrupted $interruptedId without replaying it"
            }
        }
    } catch {
        Write-Log "Could not recover stale active turn: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $activeTurnFile -Force -ErrorAction SilentlyContinue
    }
}

while ($true) {
    if (Test-Path $shutdownFile) {
        Write-Host ""
        Write-Host "[co-review] Shutdown signal received. Exiting." -ForegroundColor Yellow
        Write-Log "Shutdown signal received."
        Remove-Item $shutdownFile -ErrorAction SilentlyContinue
        break
    }

    $state = Get-State
    $newMsgs = @(Read-NewIncoming -LastId $state.last_processed -Offset ([long]$state.inbox_offset))

    foreach ($msg in $newMsgs) {
        Write-Host ""
        Write-Host ">>> Incoming from Claude: $($msg.id) ($($msg.ts))" -ForegroundColor Green
        $preview = if ($msg.content.Length -gt 200) { $msg.content.Substring(0, 200) + "... [" + ($msg.content.Length - 200) + " more chars]" } else { $msg.content }
        Write-Host $preview
        Write-Host ""
        Write-Log "Processing $($msg.id) (type=$($msg.type), $($msg.content.Length) chars)"

        $capturedSid = $null
        $capturedThreadId = $null
        $cancelMarker = Join-Path $cancelDir ([string]$msg.id + ".cancel")
        $completedTurns = if ($null -ne $state.PSObject.Properties['completed_turns']) { [int]$state.completed_turns } else { 0 }
        $maxTurns = [int]$meta.max_turns
        if (Test-Path -LiteralPath $cancelMarker -PathType Leaf) {
            $rid = Append-Reply -InReplyTo $msg.id -Content "" -ErrMsg "Codex turn was cancelled before execution."
            Remove-Item -LiteralPath $cancelMarker -Force -ErrorAction SilentlyContinue
            Write-Log "Cancelled queued $($msg.id) before execution"
        } elseif ($maxTurns -gt 0 -and $completedTurns -ge $maxTurns) {
            $rid = Append-Reply -InReplyTo $msg.id -Content "" -ErrMsg "Worker turn limit reached ($maxTurns). Start a fresh worker or explicitly create one with a larger -MaxTurns value."
            Write-Log "Rejected $($msg.id): max_turns=$maxTurns"
        } elseif ($DryRun) {
            $reply = "[DRY RUN] Echo of your message:`n`n$($msg.content)"
            $rid = Append-Reply -InReplyTo $msg.id -Content $reply
            Write-Host "<<< Replied (dry run) as $rid" -ForegroundColor Magenta
        } else {
            try {
                $effectiveModel = if ($msg.model) { [string]$msg.model } else { $CodexModel }
                $effectiveReasoning = if ($msg.reasoning) { $msg.reasoning } else { $CodexReasoning }
                $effectiveTimeout = if ($msg.turn_timeout_sec -gt 0) { [int]$msg.turn_timeout_sec } else { $CodexTimeoutSec }
                if ($msg.model -or $msg.reasoning) {
                    $capabilities = Get-CodexCapabilities -CodexBin $CodexBin
                    $selection = Resolve-CodexSelection -Capabilities $capabilities -Model $effectiveModel -Reasoning $effectiveReasoning
                    $effectiveModel = [string]$selection.model
                    $effectiveReasoning = [string]$selection.reasoning
                }
                if ($effectiveReasoning -ne $CodexReasoning) {
                    Write-Host "    [co-review] Reasoning override for $($msg.id): $effectiveReasoning (pair default: $CodexReasoning)" -ForegroundColor DarkCyan
                    Write-Log "Reasoning override on $($msg.id): $effectiveReasoning"
                }
                $envelope = New-CodexTaskEnvelope -Meta $meta -Task ([string]$msg.content)
                if ($activeTransport -eq "app-server") {
                    if (-not (Test-CoReviewAppServerClientAlive -Client $script:appServerClient)) {
                        try {
                            $script:appServerClient = Start-CoReviewAppServerClient -CodexBin $CodexBin -WorkingDirectory $workDir -ConnectionMode "auto"
                            Write-Log "Connected to Codex app-server ($($script:appServerClient.connection_mode))"
                        } catch {
                            if ($requestedTransport -eq "auto") {
                                Write-Log "App-server unavailable; falling back to legacy transport: $($_.Exception.Message)"
                                $activeTransport = "legacy"
                            } else { throw }
                        }
                    }
                }
                if ($activeTransport -eq "app-server") {
                    $threadId = [string]$state.codex_thread_id
                    if ([string]::IsNullOrWhiteSpace($threadId)) {
                        $threadId = Open-CoReviewAppServerThread -Client $script:appServerClient -WorkingDirectory $workDir -Sandbox $workerSandbox -Model $effectiveModel -WorkspaceRoots (@($workDir) + @($workerAddDirs))
                        $capturedThreadId = $threadId
                        Write-Host "    [co-review] Captured app-server thread id: $threadId" -ForegroundColor DarkCyan
                        Write-Log "Captured app-server thread_id=$threadId"
                    }
                    $result = Invoke-CoReviewAppServerTurn -Client $script:appServerClient -PairId $PairId -ThreadId $threadId -Prompt $envelope -MessageId ([string]$msg.id) -WorkingDirectory $workDir -OutboxPath $toClaude -ActiveTurnFile $activeTurnFile -Model $effectiveModel -Reasoning $effectiveReasoning -TimeoutSec $effectiveTimeout -MaxProgressUpdates ([int]$meta.max_progress_updates) -ProgressMinIntervalSec ([int]$meta.progress_min_interval_sec)
                } else {
                    $sid = $state.codex_session_id
                    $result = Invoke-Codex -Prompt $envelope -SessionId $sid -Cwd $workDir -Model $effectiveModel -Reasoning $effectiveReasoning -Sandbox $workerSandbox -TimeoutSec $effectiveTimeout -Profile $workerProfile -AddDir $workerAddDirs -Search $workerSearch -ConfigOverrides $workerConfigOverrides -MessageId ([string]$msg.id) -ActiveTurnFile $activeTurnFile -ProgressStateFile $progressStateFile -MaxProgressUpdates ([int]$meta.max_progress_updates) -ProgressMinIntervalSec ([int]$meta.progress_min_interval_sec)
                }

                if ($result.ExitCode -ne 0) {
                    $stderrText = [string]$result.Stderr
                    if ($stderrText.Length -gt 8000) { $stderrText = $stderrText.Substring(0, 8000) + "`n[stderr truncated]" }
                    $partialReply = [string]$result.Reply
                    if ($partialReply.Length -gt 4000) { $partialReply = $partialReply.Substring(0, 4000) + "`n[partial output truncated]" }
                    $errText = "Codex turn exit=$($result.ExitCode). stderr:`n$stderrText"
                    if (-not [string]::IsNullOrWhiteSpace($partialReply)) { $errText += "`npartial output:`n$partialReply" }
                    Write-Host "    ERROR: $errText" -ForegroundColor Red
                    Write-Log "ERROR on $($msg.id): $errText"
                    $rid = Append-Reply -InReplyTo $msg.id -Content "" -ErrMsg $errText
                } else {
                    if ($activeTransport -eq "legacy" -and $result.SessionId -and -not $state.codex_session_id) {
                        $capturedSid = $result.SessionId
                        Write-Host "    [co-review] Captured codex session id: $capturedSid" -ForegroundColor DarkCyan
                        Write-Log "Captured session_id=$capturedSid"
                    }
                    $rid = Append-Reply -InReplyTo $msg.id -Content $result.Reply
                    Write-Host "<<< Replied as $rid ($($result.Reply.Length) chars)" -ForegroundColor Magenta
                    Write-Log "Replied $rid for $($msg.id)"
                }
            } catch {
                $errText = $_.Exception.Message
                Write-Host "    EXCEPTION: $errText" -ForegroundColor Red
                Write-Log "EXCEPTION on $($msg.id): $errText"
                $rid = Append-Reply -InReplyTo $msg.id -Content "" -ErrMsg $errText
            }
        }

        Remove-Item -LiteralPath $activeTurnFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $cancelMarker -Force -ErrorAction SilentlyContinue

        # One state save per message - load fresh, apply both updates, save once.
        # (Append-Reply doesn't touch state.json, so the only writer here is this block.)
        $state = Get-State
        $state.last_processed = $msg.id
        $state | Add-Member -NotePropertyName inbox_offset -NotePropertyValue ([long]$msg._queue_end_offset) -Force
        $completed = if ($null -ne $state.PSObject.Properties['completed_turns']) { [int]$state.completed_turns } else { 0 }
        $state | Add-Member -NotePropertyName completed_turns -NotePropertyValue ($completed + 1) -Force
        if ($capturedSid) {
            $state | Add-Member -NotePropertyName codex_session_id -NotePropertyValue $capturedSid -Force
        }
        if ($capturedThreadId) {
            $state | Add-Member -NotePropertyName codex_thread_id -NotePropertyValue $capturedThreadId -Force
        }
        Save-State $state
    }

    if ($newMsgs.Count -eq 0) {
        [void](Wait-CoReviewChannel -Signal $inboxSignal -TimeoutMilliseconds ([Math]::Max(50, $PollIntervalSec * 1000)))
    }
}

Stop-CoReviewAppServerClient -Client $script:appServerClient
$inboxSignal.Dispose()
Remove-Item -ErrorAction SilentlyContinue $pidFile

Write-Host ""
Write-Host "[co-review] Listener exited. Window will stay open - close it manually." -ForegroundColor DarkGray
