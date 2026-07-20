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
        $repliedTo = @{}
        $toClaude = Join-Path -Path $pairDir -ChildPath "to-claude.jsonl"
        if (Test-Path -LiteralPath $toClaude -PathType Leaf) {
            foreach ($line in @(Get-Content -LiteralPath $toClaude -Encoding UTF8 -ErrorAction SilentlyContinue)) {
                try { $replyObj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                if ([string]$replyObj.type -in @("response", "error") -and -not [string]::IsNullOrWhiteSpace([string]$replyObj.in_reply_to)) { $repliedTo[[string]$replyObj.in_reply_to] = $true }
            }
        }
        $pending = @()
        if (Test-Path -LiteralPath $toCodex -PathType Leaf) {
            foreach ($line in @(Get-Content -LiteralPath $toCodex -Encoding UTF8 -ErrorAction SilentlyContinue)) {
                try { $requestObj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                if (-not $repliedTo.ContainsKey([string]$requestObj.id)) { $pending += [string]$requestObj.id }
            }
        }
        if ($pending.Count -gt 0) {
            throw "Worker $PairId is busy or already queued ($($pending -join ', ')). Wait/cancel it, or pass -Queue to enqueue intentionally."
        }
    }

    # Derive next id from existing line count under lock.
    $cnt = 0
    if (Test-Path $toCodex) {
        $cnt = @(Get-Content $toCodex -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() -ne "" }).Count
    }
    $cnt++
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

    Add-Content -Path $toCodex -Value $msg -Encoding UTF8
} finally {
    if ($locked) { $mutex.ReleaseMutex() | Out-Null }
    $mutex.Dispose()
}

Write-Output $msgId
