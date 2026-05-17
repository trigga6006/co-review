# co-review shared helpers

function Get-CoReviewRoot {
    return (Join-Path -Path $env:USERPROFILE -ChildPath ".cc-codex-pairs")
}

function Assert-ValidPairId {
    param([Parameter(Mandatory=$true)][string]$PairId)
    if ($PairId -notmatch '^pair-\d{8}-\d{6}-[0-9a-f]{4}$') {
        Write-Error "Invalid PairId '$PairId'. Expected format: pair-YYYYMMDD-HHMMSS-xxxx"
        exit 1
    }
}

function Get-PairDir {
    param(
        [Parameter(Mandatory=$true)][string]$PairId,
        [switch]$MustExist
    )
    Assert-ValidPairId -PairId $PairId
    $root = Get-CoReviewRoot
    $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
    $pairDir = Join-Path -Path $root -ChildPath $PairId
    $pairFull = [System.IO.Path]::GetFullPath($pairDir)
    if (-not $pairFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Error "Invalid PairId '$PairId': resolved path escapes pair root"
        exit 1
    }
    if ($MustExist -and -not (Test-Path -LiteralPath $pairFull)) {
        Write-Error "Pair not found: $PairId  (dir: $pairFull)"
        exit 1
    }
    return $pairFull
}

function Assert-ValidCodexBin {
    param([Parameter(Mandatory=$true)][string]$CodexBin)
    if ([string]::IsNullOrWhiteSpace($CodexBin) -or -not (Test-Path -LiteralPath $CodexBin -PathType Leaf)) {
        Write-Error "Could not locate codex executable. Pass -CodexBin <path> or install Codex CLI."
        exit 1
    }
    $leaf = [System.IO.Path]::GetFileName($CodexBin)
    if ($leaf -notin @("codex.exe", "codex")) {
        Write-Error "Invalid CodexBin '$CodexBin'. Expected an executable named codex.exe or codex."
        exit 1
    }
}
