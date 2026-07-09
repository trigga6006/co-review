# Managed Git worktree helpers for isolated Codex workhorses.

function Get-CoReviewWorktreeRoot {
    return (Join-Path $env:USERPROFILE ".cc-codex-worktrees")
}

function Get-CoReviewGitInfo {
    param([Parameter(Mandatory=$true)][string]$Path)
    $repoOutput = @(& git -C $Path rev-parse --show-toplevel 2>$null)
    $repoExit = $LASTEXITCODE
    $repoRoot = if ($repoOutput.Count -gt 0) { [string]$repoOutput[0] } else { "" }
    if ($repoExit -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) { throw "Not a Git repository: $Path" }
    $repoRoot = [System.IO.Path]::GetFullPath([string]$repoRoot)
    $headOutput = @(& git -C $repoRoot rev-parse HEAD 2>$null)
    $head = if ($headOutput.Count -gt 0) { [string]$headOutput[0] } else { "" }
    $branchOutput = @(& git -C $repoRoot branch --show-current 2>$null)
    $branch = if ($branchOutput.Count -gt 0) { [string]$branchOutput[0] } else { "" }
    $dirtyLines = @(& git -C $repoRoot status --porcelain --untracked-files=normal 2>$null)
    return [PSCustomObject]@{
        repo_root = $repoRoot
        head = [string]$head
        branch = [string]$branch
        dirty = ($dirtyLines.Count -gt 0)
    }
}

function New-CoReviewManagedWorktree {
    param(
        [Parameter(Mandatory=$true)][string]$PairId,
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [switch]$AllowDirtyBase
    )
    $info = Get-CoReviewGitInfo -Path $SourcePath
    if ($info.dirty -and -not $AllowDirtyBase) {
        throw "Source repository has uncommitted changes; a new worktree would contain only committed HEAD. Serialize the worker or pass -AllowDirtyBase explicitly."
    }
    $root = Get-CoReviewWorktreeRoot
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
    $worktreePath = [System.IO.Path]::GetFullPath((Join-Path $root $PairId))
    if (-not $worktreePath.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Managed worktree path escapes root" }
    if (Test-Path -LiteralPath $worktreePath) { throw "Managed worktree already exists: $worktreePath" }
    $branch = "codex-worker/$PairId"
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & git -C $info.repo_root worktree add -b $branch $worktreePath HEAD 2>&1 | Out-Null
        $gitExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($gitExit -ne 0) { throw "git worktree add failed for $worktreePath" }
    return [PSCustomObject]@{
        source_repo = $info.repo_root
        worktree_path = $worktreePath
        worktree_branch = $branch
        source_head = $info.head
    }
}

function Remove-CoReviewManagedWorktree {
    param([Parameter(Mandatory=$true)][string]$SourceRepo, [Parameter(Mandatory=$true)][string]$WorktreePath)
    $rootFull = [System.IO.Path]::GetFullPath((Get-CoReviewWorktreeRoot)).TrimEnd('\') + '\'
    $targetFull = [System.IO.Path]::GetFullPath($WorktreePath)
    if (-not $targetFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to remove unmanaged worktree: $targetFull" }
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & git -C $SourceRepo worktree remove --force $targetFull 2>&1 | Out-Null
        $gitExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($gitExit -ne 0 -and (Test-Path -LiteralPath $targetFull)) { throw "git worktree remove failed for $targetFull" }
}

function Test-CoReviewWorktreeHasChanges {
    param([Parameter(Mandatory=$true)][string]$Path)
    return (@(& git -C $Path status --porcelain --untracked-files=normal 2>$null).Count -gt 0)
}
