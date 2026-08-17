# co-review: send.ps1
# Append a message from Claude into to-codex.jsonl. Prints the new message ID.
[CmdletBinding(DefaultParameterSetName="Inline")]
param(
    [Parameter(Mandatory=$true)][string]$PairId,
    [Parameter(Mandatory=$true, ParameterSetName="Inline")][string]$Message,
    [string]$Type = "request",
    [Parameter(Mandatory=$true, ParameterSetName="File")][string]$MessageFile,
    [string]$Model = "",
    # Optional per-turn overrides. Empty strings mean "use pair default".
    [string]$Reasoning = "",
    [int]$TurnTimeoutSec = 0,
    [switch]$Queue,
    [switch]$NoEnsure
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$pairDir = Get-PairDir -PairId $PairId -MustExist

$meta = Get-NormalizedPairMetadata -PairDir $pairDir
$statePath = Join-Path $pairDir "state.json"
if ([int]$meta.max_turns -gt 0 -and (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    try {
        $turnState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -ErrorAction Stop
        $completedTurns = if ($null -ne $turnState.PSObject.Properties["completed_turns"]) { [int]$turnState.completed_turns } else { 0 }
        if ($completedTurns -ge [int]$meta.max_turns) {
            throw "Worker $PairId reached its turn limit ($($meta.max_turns)) and has retired. Start a fresh worker for a new responsibility."
        }
    } catch {
        if ($_.Exception.Message -match "reached its turn limit") { throw }
    }
}

if (-not $NoEnsure) {
    & (Join-Path $PSScriptRoot "ensure-pair.ps1") -PairId $PairId -Json | Out-Null
}

if ($TurnTimeoutSec -lt 0) {
    throw "TurnTimeoutSec must be greater than zero when specified"
}

$resolvedModel = $Model
$resolvedReasoning = $Reasoning
if (-not [string]::IsNullOrWhiteSpace($Model) -or -not [string]::IsNullOrWhiteSpace($Reasoning)) {
    $meta = Get-Content -LiteralPath (Join-Path $pairDir "pair.json") -Raw | ConvertFrom-Json
    $modelToValidate = if ([string]::IsNullOrWhiteSpace($Model)) { [string]$meta.codex_model } else { $Model }
    $reasoningToValidate = if ([string]::IsNullOrWhiteSpace($Reasoning)) { [string]$meta.codex_reasoning } else { $Reasoning }
    $capabilities = Get-CodexCapabilities -CodexBin ([string]$meta.codex_bin)
    $selection = Resolve-CodexSelection -Capabilities $capabilities -Model $modelToValidate -Reasoning $reasoningToValidate
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $resolvedModel = [string]$selection.model }
    if (-not [string]::IsNullOrWhiteSpace($Reasoning)) { $resolvedReasoning = [string]$selection.reasoning }
}

$toCodex = Join-Path -Path $pairDir -ChildPath "to-codex.jsonl"

# Support -MessageFile for large payloads (avoid quoting hell)
if (-not [string]::IsNullOrWhiteSpace($MessageFile)) {
    if (-not (Test-Path $MessageFile)) {
        Write-Error "MessageFile not found: $MessageFile"
        exit 1
    }
    $Message = [System.IO.File]::ReadAllText($MessageFile)
}

$mutexName = "Global\co-review-$PairId-send"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
$locked = $false
try {
    $locked = $mutex.WaitOne(30000)
    if (-not $locked) {
        Write-Error "Timed out waiting for send lock for $PairId"
        exit 2
    }

    if (-not $Queue) {
        $sequencePath = Get-CoReviewSequencePath -PairDir $pairDir -Channel "inbox"
        $queueState = $null
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            try { $queueState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -ErrorAction Stop } catch {}
        }
        $hasSynchronizedCounters = [int]$meta.schema_version -ge 2 -and
            (Test-Path -LiteralPath $sequencePath -PathType Leaf) -and
            $null -ne $queueState -and $null -ne $queueState.PSObject.Properties["completed_turns"]
        if ($hasSynchronizedCounters) {
            $sentCount = Get-CoReviewSequence -PairDir $pairDir -Channel "inbox" -FallbackQueuePath $toCodex
            $pendingCount = [Math]::Max(0, $sentCount - [long]$queueState.completed_turns)
            $pendingIds = @()
        } else {
            # Schema-v1 workers predate the sequence/completed-turn counters.
            # Reconcile their durable journals instead of treating all history
            # as permanently pending.
            $pendingIds = @(Get-CoReviewPendingRequestIds -RequestPath $toCodex -ReplyPath (Join-Path $pairDir "to-claude.jsonl"))
            $pendingCount = $pendingIds.Count
        }
        if ($pendingCount -gt 0) {
            throw "Worker $PairId is busy or already queued ($pendingCount pending). Wait/cancel it, or pass -Queue to enqueue intentionally."
        }
    }

    $cnt = Get-NextCoReviewSequence -PairId $PairId -PairDir $pairDir -Channel "inbox" -FallbackQueuePath $toCodex
    $msgId = "msg-{0:D4}" -f $cnt

    $msgObj = @{
        id = $msgId
        ts = (Get-Date).ToString("o")
        from = "claude"
        type = $Type
        content = $Message
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedModel)) { $msgObj.model = $resolvedModel }
    if (-not [string]::IsNullOrWhiteSpace($resolvedReasoning)) { $msgObj.reasoning = $resolvedReasoning }
    if ($TurnTimeoutSec -gt 0) { $msgObj.turn_timeout_sec = $TurnTimeoutSec }
    $msg = $msgObj | ConvertTo-Json -Compress -Depth 10

    [System.IO.File]::AppendAllText($toCodex, ($msg + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    Signal-CoReviewChannel -PairId $PairId -Channel "inbox"
} finally {
    if ($locked) { $mutex.ReleaseMutex() | Out-Null }
    $mutex.Dispose()
}

Write-Output $msgId
