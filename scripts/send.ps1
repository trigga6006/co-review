# co-review: send.ps1
# Append a message from Claude into to-codex.jsonl. Prints the new message ID.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PairId,
    [Parameter(Mandatory=$true)][string]$Message,
    [string]$Type = "request",
    [string]$MessageFile = "",
    # Optional per-ask reasoning override. Empty string means "use pair default".
    [ValidateSet("", "low", "medium", "high")]
    [string]$Reasoning = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$pairDir = Get-PairDir -PairId $PairId -MustExist

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
    if (-not [string]::IsNullOrWhiteSpace($Reasoning)) {
        $msgObj.reasoning = $Reasoning
    }
    $msg = $msgObj | ConvertTo-Json -Compress -Depth 10

    Add-Content -Path $toCodex -Value $msg -Encoding UTF8
} finally {
    if ($locked) { $mutex.ReleaseMutex() | Out-Null }
    $mutex.Dispose()
}

Write-Output $msgId
