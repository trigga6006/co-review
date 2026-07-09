# co-review: codex-listener.ps1
# Runs in a dedicated terminal window. Polls to-codex.jsonl for new messages
# from Claude, runs `codex exec` (or `codex exec resume <id>` for follow-ups),
# and appends responses to to-claude.jsonl.
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
$pairDir = Get-PairDir -PairId $PairId
if (-not (Test-Path $pairDir)) {
    Write-Host "[co-review] FATAL: pair dir not found: $pairDir" -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

$toCodex   = Join-Path $pairDir "to-codex.jsonl"
$toClaude  = Join-Path $pairDir "to-claude.jsonl"
$stateFile = Join-Path $pairDir "state.json"
$pairMeta  = Join-Path $pairDir "pair.json"
$logFile   = Join-Path $pairDir "listener.log"
$shutdownFile = Join-Path $pairDir "shutdown"
$pidFile   = Join-Path $pairDir "listener.pid"

# Write our PID so list-pairs can verify the listener is actually alive
[System.IO.File]::WriteAllText($pidFile, $PID, [System.Text.UTF8Encoding]::new($false))
# Ensure we clean up the pid file on exit (graceful or not - the trap covers Ctrl+C too)
$cleanupPidFile = $pidFile
trap {
    Remove-Item -ErrorAction SilentlyContinue $cleanupPidFile
    continue
}

# Load metadata
$meta = Get-Content $pairMeta -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($CodexBin)) { $CodexBin = $meta.codex_bin }
if ([string]::IsNullOrWhiteSpace($CodexModel)) { $CodexModel = [string]$meta.codex_model }
if ([string]::IsNullOrWhiteSpace($CodexReasoning)) { $CodexReasoning = [string]$meta.codex_reasoning }
if ($CodexTimeoutSec -le 0) {
    $CodexTimeoutSec = if ($meta.codex_timeout_sec -gt 0) { [int]$meta.codex_timeout_sec } else { 1800 }
}
$schemaVersion = if ($meta.schema_version -ge 2) { [int]$meta.schema_version } else { 1 }
if ($schemaVersion -eq 1) {
    $workerMode = "review"
    $workerSandbox = "read-only"
    $workerIsolation = "shared"
} else {
    $workerMode = [string]$meta.mode
    $workerSandbox = [string]$meta.sandbox
    $workerIsolation = [string]$meta.isolation
}

$metadataError = ""
if ($workerMode -notin @("review", "workhorse")) {
    $metadataError = "Invalid worker mode '$workerMode' in schema-v$schemaVersion pair metadata"
} elseif ($workerSandbox -notin @("read-only", "workspace-write", "danger-full-access")) {
    $metadataError = "Invalid worker sandbox '$workerSandbox' in schema-v$schemaVersion pair metadata"
} elseif ($workerMode -eq "review" -and $workerSandbox -ne "read-only") {
    $metadataError = "Review workers must use the read-only sandbox"
}
if ($metadataError) {
    Write-Host "[co-review] FATAL: $metadataError" -ForegroundColor Red
    Remove-Item -ErrorAction SilentlyContinue $pidFile
    exit 1
}

$meta | Add-Member -NotePropertyName mode -NotePropertyValue $workerMode -Force
$meta | Add-Member -NotePropertyName sandbox -NotePropertyValue $workerSandbox -Force
$meta | Add-Member -NotePropertyName isolation -NotePropertyValue $workerIsolation -Force
$workerProfile = [string]$meta.profile
$workerAddDirs = @($meta.add_dirs | ForEach-Object { [string]$_ })
$workerSearch = ($meta.search_enabled -eq $true)
$workerConfigOverrides = @($meta.config_overrides | ForEach-Object { [string]$_ })
try {
    Assert-ValidCodexBin -CodexBin $CodexBin
    Assert-SafeCodexConfigOverrides -Overrides $workerConfigOverrides
} catch {
    Write-Host "[co-review] FATAL: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
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
        return Get-Content $stateFile -Raw | ConvertFrom-Json
    }
    return [PSCustomObject]@{ last_processed = $null; codex_session_id = $null; msg_counter = 0 }
}

function Save-State {
    param($state)
    $json = $state | ConvertTo-Json
    [System.IO.File]::WriteAllText($stateFile, $json, [System.Text.UTF8Encoding]::new($false))
}

function Append-Reply {
    param([string]$InReplyTo, [string]$Content, [string]$ErrMsg = "")
    # Derive next id from line count in to-claude.jsonl (avoids state.json races)
    $cnt = 0
    if (Test-Path $toClaude) {
        $cnt = @(Get-Content $toClaude -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() -ne "" }).Count
    }
    $cnt++
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
    Add-Content -Path $toClaude -Value $line -Encoding UTF8
    return $replyId
}

function Read-NewIncoming {
    param([string]$LastId)
    if (-not (Test-Path $toCodex)) { return @() }
    $lines = Get-Content $toCodex -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() -ne "" }
    $msgs = @()
    foreach ($line in $lines) {
        try { $msgs += ($line | ConvertFrom-Json) } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($LastId)) { return $msgs }
    $afterIdx = -1
    for ($i = 0; $i -lt $msgs.Count; $i++) {
        if ($msgs[$i].id -eq $LastId) { $afterIdx = $i; break }
    }
    if ($afterIdx -lt 0) { return $msgs }
    if ($afterIdx -ge ($msgs.Count - 1)) { return @() }
    return $msgs[($afterIdx + 1)..($msgs.Count - 1)]
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
        [string[]]$ConfigOverrides = @()
    )

    $lastMsgFile = New-TemporaryFile

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
        # `-m` pins the model so behavior is consistent across machines regardless
        # of each user's ~/.codex/config.toml. `-c model_reasoning_effort=...`
        # overrides reasoning depth the same way.
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
        $codexArgs += @(
            "-m", $Model,
            "-c", "model_reasoning_effort=$Reasoning",
            "-c", "features.multi_agent=false"
        )
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

        # Drain stdout/stderr concurrently. This avoids pipe-buffer deadlocks and
        # lets us enforce a timeout even if Codex hangs mid-turn.
        $stdoutRunspace = [runspacefactory]::CreateRunspace()
        $stdoutRunspace.Open()
        $stdoutPs = [powershell]::Create()
        $stdoutPs.Runspace = $stdoutRunspace
        [void]$stdoutPs.AddScript({
            param($p)
            $p.StandardOutput.ReadToEnd()
        }).AddArgument($proc)
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
            $proc.WaitForExit()
        }

        # Collect stdout/stderr from the background runspaces.
        $stdoutText = ""
        try {
            $stdoutResult = $stdoutPs.EndInvoke($stdoutHandle)
            if ($stdoutResult) {
                $stdoutText = if ($stdoutResult -is [string]) { $stdoutResult } else { [string]$stdoutResult }
            }
        } catch {
            $stdoutText = ""
        } finally {
            $stdoutPs.Dispose()
            $stdoutRunspace.Close()
            $stdoutRunspace.Dispose()
        }

        $stdoutLines = New-Object System.Collections.Generic.List[string]
        foreach ($line in ($stdoutText -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $stdoutLines.Add($line) | Out-Null
                Write-Host "    $line" -ForegroundColor DarkGray
            }
        }

        $stderr = ""
        try {
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
        Remove-Item -ErrorAction SilentlyContinue $lastMsgFile.FullName
    }
}

# Main loop
Write-Log "Listener started for $PairId"

while ($true) {
    if (Test-Path $shutdownFile) {
        Write-Host ""
        Write-Host "[co-review] Shutdown signal received. Exiting." -ForegroundColor Yellow
        Write-Log "Shutdown signal received."
        Remove-Item $shutdownFile -ErrorAction SilentlyContinue
        break
    }

    $state = Get-State
    $newMsgs = @(Read-NewIncoming -LastId $state.last_processed)

    foreach ($msg in $newMsgs) {
        Write-Host ""
        Write-Host ">>> Incoming from Claude: $($msg.id) ($($msg.ts))" -ForegroundColor Green
        $preview = if ($msg.content.Length -gt 200) { $msg.content.Substring(0, 200) + "... [" + ($msg.content.Length - 200) + " more chars]" } else { $msg.content }
        Write-Host $preview
        Write-Host ""
        Write-Log "Processing $($msg.id) (type=$($msg.type), $($msg.content.Length) chars)"

        $capturedSid = $null
        if ($DryRun) {
            $reply = "[DRY RUN] Echo of your message:`n`n$($msg.content)"
            $rid = Append-Reply -InReplyTo $msg.id -Content $reply
            Write-Host "<<< Replied (dry run) as $rid" -ForegroundColor Magenta
        } else {
            try {
                $sid = $state.codex_session_id
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
                $result = Invoke-Codex -Prompt $envelope -SessionId $sid -Cwd $workDir -Model $effectiveModel -Reasoning $effectiveReasoning -Sandbox $workerSandbox -TimeoutSec $effectiveTimeout -Profile $workerProfile -AddDir $workerAddDirs -Search $workerSearch -ConfigOverrides $workerConfigOverrides

                if ($result.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($result.Reply)) {
                    $errText = "codex exec exit=$($result.ExitCode). stderr:`n$($result.Stderr)"
                    Write-Host "    ERROR: $errText" -ForegroundColor Red
                    Write-Log "ERROR on $($msg.id): $errText"
                    $rid = Append-Reply -InReplyTo $msg.id -Content "" -ErrMsg $errText
                } else {
                    if ($result.SessionId -and -not $state.codex_session_id) {
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

        # One state save per message - load fresh, apply both updates, save once.
        # (Append-Reply doesn't touch state.json, so the only writer here is this block.)
        $state = Get-State
        $state.last_processed = $msg.id
        if ($capturedSid) {
            $state | Add-Member -NotePropertyName codex_session_id -NotePropertyValue $capturedSid -Force
        }
        Save-State $state
    }

    Start-Sleep -Seconds $PollIntervalSec
}

Remove-Item -ErrorAction SilentlyContinue $pidFile

Write-Host ""
Write-Host "[co-review] Listener exited. Window will stay open - close it manually." -ForegroundColor DarkGray
