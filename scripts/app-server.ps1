# co-review: persistent Codex app-server client helpers.
# Dot-source common.ps1 before loading this file.

function Invoke-CoReviewCodexUtility {
    param(
        [Parameter(Mandatory=$true)][string]$CodexBin,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [int]$TimeoutSec = 20
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $CodexBin
    $psi.Arguments = ($Arguments | ForEach-Object { ConvertTo-CoReviewCommandLineArgument -Value $_ }) -join " "
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            try { $process.Kill() } catch {}
            throw "codex $($Arguments -join ' ') timed out after ${TimeoutSec}s"
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        return [PSCustomObject]@{ exit_code=$process.ExitCode; stdout=$stdout; stderr=$stderr }
    } finally { $process.Dispose() }
}

function Test-CoReviewAppServerSupport {
    param([Parameter(Mandatory=$true)][string]$CodexBin)
    try {
        $result = Invoke-CoReviewCodexUtility -CodexBin $CodexBin -Arguments @("app-server", "--help") -TimeoutSec 5
        return ($result.exit_code -eq 0 -and [string]$result.stdout -match 'Run the app server|app-server daemon|Transport endpoint')
    } catch { return $false }
}

function Ensure-CoReviewAppServerDaemon {
    param([Parameter(Mandatory=$true)][string]$CodexBin)
    $mutex = Get-CoReviewMutexName -Scope "app-server" -Key $CodexBin
    Invoke-WithCoReviewMutex -Name $mutex -TimeoutMs 30000 -ScriptBlock {
        $result = Invoke-CoReviewCodexUtility -CodexBin $CodexBin -Arguments @("app-server", "daemon", "start") -TimeoutSec 20
        if ($result.exit_code -ne 0) {
            $detail = ([string]$result.stderr).Trim()
            if ([string]::IsNullOrWhiteSpace($detail)) { $detail = ([string]$result.stdout).Trim() }
            throw "Could not start the shared Codex app-server daemon (exit=$($result.exit_code)): $detail"
        }
    }
}

function Get-CoReviewAppServerBrokerStatePath {
    param([Parameter(Mandatory=$true)][string]$CodexBin)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(([System.IO.Path]::GetFullPath($CodexBin)).ToLowerInvariant())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant().Substring(0, 16) }
    finally { $sha.Dispose() }
    $root = Join-Path (Get-CoReviewRoot) ".app-server"
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return (Join-Path $root "broker-$hash.json")
}

function Get-CoReviewFreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally { $listener.Stop() }
}

function Test-CoReviewBrokerProcess {
    param($State)
    if ($null -eq $State) { return $false }
    [int]$brokerPid = 0
    if (-not [int]::TryParse([string]$State.pid, [ref]$brokerPid) -or $brokerPid -le 0) { return $false }
    $process = Get-Process -Id $brokerPid -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    try {
        $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $brokerPid" -ErrorAction Stop
        return ([string]$cim.CommandLine -match 'app-server' -and [string]$cim.CommandLine -match [regex]::Escape([string]$State.endpoint))
    } catch { return $true }
}

function Connect-CoReviewAppServerWebSocket {
    param([Parameter(Mandatory=$true)][string]$Endpoint, [int]$TimeoutSec = 10)
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
    try {
        [void]$socket.ConnectAsync([Uri]$Endpoint, $cts.Token).GetAwaiter().GetResult()
        return $socket
    } catch {
        $socket.Dispose()
        throw
    } finally { $cts.Dispose() }
}

function Ensure-CoReviewAppServerBroker {
    param([Parameter(Mandatory=$true)][string]$CodexBin)
    $statePath = Get-CoReviewAppServerBrokerStatePath -CodexBin $CodexBin
    $mutex = Get-CoReviewMutexName -Scope "app-server-broker" -Key $CodexBin
    return Invoke-WithCoReviewMutex -Name $mutex -TimeoutMs 30000 -ScriptBlock {
        $existing = $null
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            try { $existing = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -ErrorAction Stop } catch {}
        }
        if (Test-CoReviewBrokerProcess -State $existing) {
            try {
                $probe = Connect-CoReviewAppServerWebSocket -Endpoint ([string]$existing.endpoint) -TimeoutSec 2
                $probe.Dispose()
                return $existing
            } catch {}
        }

        $port = Get-CoReviewFreeTcpPort
        $endpoint = "ws://127.0.0.1:$port"
        $brokerRoot = Split-Path $statePath -Parent
        $stdoutLog = Join-Path $brokerRoot "broker-$port.stdout.log"
        $stderrLog = Join-Path $brokerRoot "broker-$port.stderr.log"
        $arguments = @("app-server", "--listen", $endpoint)
        $argumentString = ($arguments | ForEach-Object { ConvertTo-CoReviewCommandLineArgument -Value $_ }) -join " "
        $process = Start-Process -FilePath $CodexBin -ArgumentList $argumentString -WindowStyle Hidden -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru -ErrorAction Stop
        $state = [ordered]@{
            pid=$process.Id; endpoint=$endpoint; codex_bin=$CodexBin; started_at=(Get-Date).ToString("o")
            stdout_log=$stdoutLog; stderr_log=$stderrLog
        }
        [System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline) {
            if ($process.HasExited) {
                $process.Dispose()
                throw "Shared Codex app-server broker exited during startup; see $stderrLog"
            }
            try {
                $probe = Connect-CoReviewAppServerWebSocket -Endpoint $endpoint -TimeoutSec 1
                $probe.Dispose()
                $process.Dispose()
                return [PSCustomObject]$state
            } catch { Start-Sleep -Milliseconds 100 }
        }
        try { if (-not $process.HasExited) { $process.Kill() } } catch {}
        $process.Dispose()
        throw "Shared Codex app-server broker did not listen within 20s; see $stderrLog"
    }
}

function Stop-CoReviewAppServerBrokerSafely {
    param([Parameter(Mandatory=$true)][string]$CodexBin)
    $statePath = Get-CoReviewAppServerBrokerStatePath -CodexBin $CodexBin
    $mutex = Get-CoReviewMutexName -Scope "app-server-broker" -Key $CodexBin
    return Invoke-WithCoReviewMutex -Name $mutex -TimeoutMs 30000 -ScriptBlock {
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $false }
        try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -ErrorAction Stop }
        catch { return $false }
        [int]$brokerPid = 0
        if (-not [int]::TryParse([string]$state.pid, [ref]$brokerPid) -or $brokerPid -le 0) { return $false }
        $process = Get-Process -Id $brokerPid -ErrorAction SilentlyContinue
        if ($null -eq $process) {
            Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
            return $true
        }
        try { $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $brokerPid" -ErrorAction Stop }
        catch { return $false }
        $commandLine = [string]$cim.CommandLine
        if ($commandLine -notmatch 'app-server' -or $commandLine -notmatch [regex]::Escape([string]$state.endpoint)) { return $false }
        Stop-CoReviewProcessTree -ProcessId $brokerPid
        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
        return $true
    }
}

function Start-CoReviewAppServerProcess {
    param(
        [Parameter(Mandatory=$true)][string]$CodexBin,
        [Parameter(Mandatory=$true)][string]$WorkingDirectory,
        [ValidateSet("shared", "direct")][string]$ConnectionMode = "shared"
    )
    $args = if ($ConnectionMode -eq "shared") { @("app-server", "proxy") } else { @("app-server", "--stdio") }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $CodexBin
    $psi.Arguments = ($args | ForEach-Object { ConvertTo-CoReviewCommandLineArgument -Value $_ }) -join " "
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    # App-server diagnostics go to the listener's own detached stderr log.
    $psi.RedirectStandardError = $false
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    return [System.Diagnostics.Process]::Start($psi)
}

function Write-CoReviewAppServerMessage {
    param([Parameter(Mandatory=$true)]$Client, [Parameter(Mandatory=$true)]$Message)
    $json = $Message | ConvertTo-Json -Compress -Depth 30
    if ([string]$Client.transport_kind -eq "websocket") {
        if ($null -eq $Client.websocket -or $Client.websocket.State -ne [System.Net.WebSockets.WebSocketState]::Open) { throw "Codex app-server WebSocket is not open" }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $segment = [System.ArraySegment[byte]]::new($bytes)
        [void]$Client.websocket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    } else {
        if ($null -eq $Client.process -or $Client.process.HasExited) { throw "Codex app-server connection is not running" }
        $Client.process.StandardInput.WriteLine($json)
        $Client.process.StandardInput.Flush()
    }
}

function Read-CoReviewAppServerMessage {
    param([Parameter(Mandatory=$true)]$Client, [int]$TimeoutMilliseconds = 30000)
    if ([string]$Client.transport_kind -eq "websocket") {
        if ($null -eq $Client.websocket -or $Client.websocket.State -ne [System.Net.WebSockets.WebSocketState]::Open) { throw "Codex app-server WebSocket closed" }
        $buffer = New-Object byte[] 65536
        $stream = New-Object System.IO.MemoryStream
        $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromMilliseconds([Math]::Max(1, $TimeoutMilliseconds)))
        try {
            do {
                $segment = [System.ArraySegment[byte]]::new($buffer)
                try { $received = $Client.websocket.ReceiveAsync($segment, $cts.Token).GetAwaiter().GetResult() }
                catch [System.OperationCanceledException] {
                    Stop-CoReviewAppServerClient -Client $Client
                    throw "Codex app-server response timed out"
                }
                if ($received.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { throw "Codex app-server WebSocket closed" }
                $stream.Write($buffer, 0, $received.Count)
            } while (-not $received.EndOfMessage)
            $line = [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
        } finally { $cts.Dispose(); $stream.Dispose() }
    } else {
        if ($null -eq $Client.process -or $Client.process.HasExited) { throw "Codex app-server connection exited" }
        $read = $Client.process.StandardOutput.ReadLineAsync()
        if (-not $read.Wait([Math]::Max(1, $TimeoutMilliseconds))) {
            # ReadLineAsync cannot be cancelled on the supported runtimes. Retaining this
            # client would leave an outstanding reader that can steal the next response.
            Stop-CoReviewAppServerClient -Client $Client
            throw "Codex app-server response timed out"
        }
        $line = $read.Result
        if ($null -eq $line) { throw "Codex app-server connection closed" }
    }
    try { return ($line | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw "Codex app-server emitted invalid JSON: $line" }
}

function Send-CoReviewUnsupportedServerRequest {
    param([Parameter(Mandatory=$true)]$Client, [Parameter(Mandatory=$true)]$Request)
    if ($null -eq $Request.id) { return }
    Write-CoReviewAppServerMessage -Client $Client -Message ([ordered]@{
        id = $Request.id
        error = [ordered]@{ code=-32601; message="co-review workers run non-interactively; server request '$([string]$Request.method)' is unavailable" }
    })
}

function Invoke-CoReviewAppServerRequest {
    param(
        [Parameter(Mandatory=$true)]$Client,
        [Parameter(Mandatory=$true)][string]$Method,
        $Params = $null,
        [int]$TimeoutSec = 30
    )
    $Client.next_request_id = [long]$Client.next_request_id + 1
    $requestId = [long]$Client.next_request_id
    $request = [ordered]@{ id=$requestId; method=$Method }
    if ($null -ne $Params) { $request.params = $Params }
    Write-CoReviewAppServerMessage -Client $Client -Message $request
    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSec)
    while ([DateTimeOffset]::Now -lt $deadline) {
        $remaining = [int][Math]::Max(1, ($deadline - [DateTimeOffset]::Now).TotalMilliseconds)
        $message = Read-CoReviewAppServerMessage -Client $Client -TimeoutMilliseconds $remaining
        if ($null -ne $message.id -and [string]$message.id -eq [string]$requestId -and $null -eq $message.method) {
            if ($null -ne $message.error) { throw "Codex app-server $Method failed: $([string]$message.error.message)" }
            return $message.result
        }
        if ($null -ne $message.id -and -not [string]::IsNullOrWhiteSpace([string]$message.method)) {
            Send-CoReviewUnsupportedServerRequest -Client $Client -Request $message
        }
    }
    throw "Codex app-server $Method timed out after ${TimeoutSec}s"
}

function Initialize-CoReviewAppServerClient {
    param([Parameter(Mandatory=$true)]$Client)
    $params = [ordered]@{
        clientInfo = [ordered]@{ name="co-review"; title="Claude/Codex co-review"; version="2" }
        capabilities = [ordered]@{ experimentalApi=$true }
    }
    [void](Invoke-CoReviewAppServerRequest -Client $Client -Method "initialize" -Params $params -TimeoutSec 20)
    Write-CoReviewAppServerMessage -Client $Client -Message ([ordered]@{ method="initialized" })
}

function Start-CoReviewAppServerClient {
    param(
        [Parameter(Mandatory=$true)][string]$CodexBin,
        [Parameter(Mandatory=$true)][string]$WorkingDirectory,
        [ValidateSet("auto", "shared", "direct")][string]$ConnectionMode = "auto"
    )
    $modes = if ($ConnectionMode -eq "auto") { @("shared", "direct") } else { @($ConnectionMode) }
    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($mode in $modes) {
        $process = $null
        $socket = $null
        try {
            if ($mode -eq "shared") {
                $broker = Ensure-CoReviewAppServerBroker -CodexBin $CodexBin
                $socket = Connect-CoReviewAppServerWebSocket -Endpoint ([string]$broker.endpoint) -TimeoutSec 10
                $client = [PSCustomObject]@{ process=$null; websocket=$socket; transport_kind="websocket"; endpoint=[string]$broker.endpoint; next_request_id=0L; connection_mode=$mode; codex_bin=$CodexBin }
            } else {
                $process = Start-CoReviewAppServerProcess -CodexBin $CodexBin -WorkingDirectory $WorkingDirectory -ConnectionMode "direct"
                $client = [PSCustomObject]@{ process=$process; websocket=$null; transport_kind="stdio"; endpoint=""; next_request_id=0L; connection_mode=$mode; codex_bin=$CodexBin }
            }
            Initialize-CoReviewAppServerClient -Client $client
            return $client
        } catch {
            $failures.Add("$mode`: $($_.Exception.Message)") | Out-Null
            if ($null -ne $process) {
                try { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() } } catch {}
                $process.Dispose()
            }
            if ($null -ne $socket) { $socket.Dispose() }
        }
    }
    throw "Could not connect to Codex app-server. $($failures -join '; ')"
}

function Stop-CoReviewAppServerClient {
    param($Client)
    if ($null -eq $Client) { return }
    if ([string]$Client.transport_kind -eq "websocket") {
        try { $Client.websocket.Dispose() } catch {}
        $Client.websocket = $null
        return
    }
    if ($null -eq $Client.process) { return }
    try { $Client.process.StandardInput.Close() } catch {}
    try {
        if (-not $Client.process.WaitForExit(2000)) { $Client.process.Kill(); $Client.process.WaitForExit() }
    } catch {}
    $Client.process.Dispose()
    $Client.process = $null
}

function Test-CoReviewAppServerClientAlive {
    param($Client)
    if ($null -eq $Client) { return $false }
    if ([string]$Client.transport_kind -eq "websocket") { return ($null -ne $Client.websocket -and $Client.websocket.State -eq [System.Net.WebSockets.WebSocketState]::Open) }
    try { return ($null -ne $Client.process -and -not $Client.process.HasExited) }
    catch { return $false }
}

function Open-CoReviewAppServerThread {
    param(
        [Parameter(Mandatory=$true)]$Client,
        [string]$ExistingThreadId = "",
        [Parameter(Mandatory=$true)][string]$WorkingDirectory,
        [Parameter(Mandatory=$true)][string]$Sandbox,
        [string]$Model = "",
        [string[]]$WorkspaceRoots = @()
    )
    $params = [ordered]@{
        cwd=$WorkingDirectory
        approvalPolicy="never"
        sandbox=$Sandbox
        developerInstructions="You are a dedicated leaf worker controlled by Claude. Never spawn, delegate to, or coordinate other agents. Do not broaden the task or permissions."
        multiAgentMode="explicitRequestOnly"
    }
    if (-not [string]::IsNullOrWhiteSpace($Model) -and $Model -notin @("auto", "configured-default")) { $params.model = $Model }
    $roots = @($WorkspaceRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($roots.Count -gt 0) { $params.runtimeWorkspaceRoots = $roots }
    if ([string]::IsNullOrWhiteSpace($ExistingThreadId)) {
        $params.ephemeral = $false
        $result = Invoke-CoReviewAppServerRequest -Client $Client -Method "thread/start" -Params $params -TimeoutSec 60
    } else {
        $params.threadId = $ExistingThreadId
        $result = Invoke-CoReviewAppServerRequest -Client $Client -Method "thread/resume" -Params $params -TimeoutSec 60
    }
    $threadId = [string]$result.thread.id
    if ([string]::IsNullOrWhiteSpace($threadId)) { throw "Codex app-server did not return a thread id" }
    return $threadId
}

function Publish-CoReviewAppServerProgress {
    param(
        [Parameter(Mandatory=$true)][string]$PairId,
        [Parameter(Mandatory=$true)][string]$OutboxPath,
        [Parameter(Mandatory=$true)][string]$MessageId,
        [Parameter(Mandatory=$true)][string]$Content,
        [int]$Index
    )
    $progress = [ordered]@{
        id = "prg-$MessageId-{0:D2}" -f $Index
        ts = (Get-Date).ToString("o")
        from = "codex"
        in_reply_to = $MessageId
        type = "progress"
        content = $Content
    }
    [System.IO.File]::AppendAllText($OutboxPath, (($progress | ConvertTo-Json -Compress -Depth 10) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    Signal-CoReviewChannel -PairId $PairId -Channel "outbox"
}

function Invoke-CoReviewAppServerTurn {
    param(
        [Parameter(Mandatory=$true)]$Client,
        [Parameter(Mandatory=$true)][string]$PairId,
        [Parameter(Mandatory=$true)][string]$ThreadId,
        [Parameter(Mandatory=$true)][string]$Prompt,
        [Parameter(Mandatory=$true)][string]$MessageId,
        [Parameter(Mandatory=$true)][string]$WorkingDirectory,
        [Parameter(Mandatory=$true)][string]$OutboxPath,
        [Parameter(Mandatory=$true)][string]$ActiveTurnFile,
        [string]$Model = "",
        [string]$Reasoning = "",
        [int]$TimeoutSec = 1800,
        [int]$MaxProgressUpdates = 0,
        [int]$ProgressMinIntervalSec = 30
    )
    $params = [ordered]@{
        threadId = $ThreadId
        input = @([ordered]@{ type="text"; text=$Prompt })
        cwd = $WorkingDirectory
        approvalPolicy = "never"
        clientUserMessageId = "$PairId-$MessageId"
    }
    if (-not [string]::IsNullOrWhiteSpace($Model) -and $Model -notin @("auto", "configured-default")) { $params.model = $Model }
    if (-not [string]::IsNullOrWhiteSpace($Reasoning) -and $Reasoning -ne "auto") { $params.effort = $Reasoning }

    $Client.next_request_id = [long]$Client.next_request_id + 1
    $requestId = [long]$Client.next_request_id
    $connectionPid = if ($null -ne $Client.process) { $Client.process.Id } else { 0 }
    $active = [ordered]@{
        message_id=$MessageId; listener_pid=$PID; process_pid=$connectionPid
        backend="app-server"; connection_mode=$Client.connection_mode
        thread_id=$ThreadId; turn_id=""; phase="starting"; codex_bin=$Client.codex_bin
        started_at=(Get-Date).ToString("o"); timeout_sec=$TimeoutSec
    }
    # Establish the no-replay marker before turn/start can begin executing.
    [System.IO.File]::WriteAllText($ActiveTurnFile, ($active | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    Write-CoReviewAppServerMessage -Client $Client -Message ([ordered]@{ id=$requestId; method="turn/start"; params=$params })

    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSec)
    $turnId = ""
    $lastAgentMessage = ""
    $deltaByItem = @{}
    $progressCount = 0
    $lastProgress = [DateTimeOffset]::MinValue
    while ([DateTimeOffset]::Now -lt $deadline) {
        $remaining = [int][Math]::Max(1, ($deadline - [DateTimeOffset]::Now).TotalMilliseconds)
        try { $message = Read-CoReviewAppServerMessage -Client $Client -TimeoutMilliseconds $remaining }
        catch {
            if ($_.Exception.Message -match 'timed out') {
                if ([string]$Client.connection_mode -eq "shared" -and [string]::IsNullOrWhiteSpace($turnId)) {
                    $active.phase = "stopping-shared-broker"
                    [System.IO.File]::WriteAllText($ActiveTurnFile, ($active | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
                    Stop-CoReviewAppServerClient -Client $Client
                    $brokerStopped = $false
                    try { $brokerStopped = Stop-CoReviewAppServerBrokerSafely -CodexBin ([string]$Client.codex_bin) } catch {}
                    if (-not $brokerStopped) {
                        $active.phase = "cancellation-unconfirmed"
                        [System.IO.File]::WriteAllText($ActiveTurnFile, ($active | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
                        throw "UNCONFIRMED_SHARED_TURN: timed out before Codex returned a turn id, and the dedicated shared broker could not be safely terminated"
                    }
                    $active.phase = "shared-broker-stopped"
                    [System.IO.File]::WriteAllText($ActiveTurnFile, ($active | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
                } elseif (-not [string]::IsNullOrWhiteSpace($turnId) -and (Test-CoReviewAppServerClientAlive -Client $Client)) {
                    $Client.next_request_id = [long]$Client.next_request_id + 1
                    Write-CoReviewAppServerMessage -Client $Client -Message ([ordered]@{ id=[long]$Client.next_request_id; method="turn/interrupt"; params=[ordered]@{threadId=$ThreadId;turnId=$turnId} })
                }
                throw "Codex app-server turn timed out after ${TimeoutSec}s"
            }
            throw
        }

        if ($null -ne $message.id -and [string]$message.id -eq [string]$requestId -and $null -eq $message.method) {
            if ($null -ne $message.error) { throw "Codex app-server turn/start failed: $([string]$message.error.message)" }
            $turnId = [string]$message.result.turn.id
            if ([string]::IsNullOrWhiteSpace($turnId)) { throw "Codex app-server did not return a turn id" }
            $active.turn_id = $turnId
            $active.phase = "running"
            [System.IO.File]::WriteAllText($ActiveTurnFile, ($active | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
            continue
        }
        if ($null -ne $message.id -and -not [string]::IsNullOrWhiteSpace([string]$message.method)) {
            Send-CoReviewUnsupportedServerRequest -Client $Client -Request $message
            continue
        }
        $method = [string]$message.method
        if ($method -eq "item/agentMessage/delta" -and [string]$message.params.threadId -eq $ThreadId -and ([string]::IsNullOrWhiteSpace($turnId) -or [string]$message.params.turnId -eq $turnId)) {
            $itemId = [string]$message.params.itemId
            if (-not $deltaByItem.ContainsKey($itemId)) { $deltaByItem[$itemId] = New-Object System.Text.StringBuilder }
            [void]$deltaByItem[$itemId].Append([string]$message.params.delta)
        } elseif ($method -eq "item/completed" -and [string]$message.params.threadId -eq $ThreadId -and [string]$message.params.turnId -eq $turnId) {
            $item = $message.params.item
            if ([string]$item.type -eq "agentMessage") {
                $text = [string]$item.text
                if ([string]::IsNullOrWhiteSpace($text) -and $deltaByItem.ContainsKey([string]$item.id)) { $text = $deltaByItem[[string]$item.id].ToString() }
                $trimmed = $text.TrimStart()
                $prefix = "CO_REVIEW_PROGRESS:"
                if ($trimmed.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $now = [DateTimeOffset]::Now
                    if ($MaxProgressUpdates -gt 0 -and $progressCount -lt $MaxProgressUpdates -and ($progressCount -eq 0 -or ($now - $lastProgress).TotalSeconds -ge $ProgressMinIntervalSec)) {
                        $content = $trimmed.Substring($prefix.Length).Trim()
                        if (-not [string]::IsNullOrWhiteSpace($content)) {
                            $progressCount++
                            Publish-CoReviewAppServerProgress -PairId $PairId -OutboxPath $OutboxPath -MessageId $MessageId -Content $content -Index $progressCount
                            $lastProgress = $now
                        }
                    }
                } elseif (-not [string]::IsNullOrWhiteSpace($text)) { $lastAgentMessage = $text }
            }
        } elseif ($method -eq "turn/completed" -and [string]$message.params.threadId -eq $ThreadId -and [string]$message.params.turn.id -eq $turnId) {
            $status = [string]$message.params.turn.status
            if ($status -ne "completed") {
                $detail = [string]$message.params.turn.error.message
                if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "turn status: $status" }
                throw "Codex app-server turn failed: $detail"
            }
            if ([string]::IsNullOrWhiteSpace($lastAgentMessage)) {
                foreach ($item in @($message.params.turn.items)) {
                    if ([string]$item.type -eq "agentMessage" -and -not [string]::IsNullOrWhiteSpace([string]$item.text)) { $lastAgentMessage = [string]$item.text }
                }
            }
            return [PSCustomObject]@{ Reply=$lastAgentMessage; ThreadId=$ThreadId; TurnId=$turnId; ExitCode=0; Stderr="" }
        } elseif ($method -eq "error") {
            $detail = [string]$message.params.message
            if (-not [string]::IsNullOrWhiteSpace($detail)) { throw "Codex app-server error: $detail" }
        }
    }
    throw "Codex app-server turn timed out after ${TimeoutSec}s"
}

function Interrupt-CoReviewAppServerTurn {
    param(
        [Parameter(Mandatory=$true)][string]$CodexBin,
        [Parameter(Mandatory=$true)][string]$WorkingDirectory,
        [Parameter(Mandatory=$true)][string]$ThreadId,
        [Parameter(Mandatory=$true)][string]$TurnId
    )
    $client = Start-CoReviewAppServerClient -CodexBin $CodexBin -WorkingDirectory $WorkingDirectory -ConnectionMode "shared"
    try {
        [void](Invoke-CoReviewAppServerRequest -Client $client -Method "turn/interrupt" -Params ([ordered]@{threadId=$ThreadId;turnId=$TurnId}) -TimeoutSec 20)
    } finally { Stop-CoReviewAppServerClient -Client $client }
}
