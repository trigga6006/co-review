# co-review: send.ps1
# Append a message from Claude into to-codex.jsonl. Prints the new message ID.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PairId,
    [Parameter(Mandatory=$true)][string]$Message,
    [string]$Type = "request",
    [string]$MessageFile = "",
    [string]$Model = "",
    # Optional per-turn overrides. Empty strings mean "use pair default".
    [string]$Reasoning = "",
    [int]$TurnTimeoutSec = 0
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$pairDir = Get-PairDir -PairId $PairId -MustExist

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
