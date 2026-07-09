[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PairId,
    [switch]$Archive, [switch]$Delete,
    [switch]$RemoveWorktree, [switch]$ConfirmRemoveWorktree
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")
. (Join-Path $PSScriptRoot "worktrees.ps1")
$pairDir = Get-PairDir -PairId $PairId -MustExist
$meta = Get-NormalizedPairMetadata -PairDir $pairDir
if ($Archive -and $Delete) { throw "Use either -Archive or -Delete, not both" }
if ($RemoveWorktree -and -not $ConfirmRemoveWorktree) { throw "Removing a managed worktree requires -ConfirmRemoveWorktree" }

[System.IO.File]::WriteAllText((Join-Path $pairDir "shutdown"), "", [System.Text.UTF8Encoding]::new($false))
$listenerPid = $null
$deadline = (Get-Date).AddSeconds(5)
while ((Get-Date) -lt $deadline -and (Test-CoReviewListenerAlive -PairDir $pairDir -ListenerPid ([ref]$listenerPid))) { Start-Sleep -Milliseconds 200 }
if ([string]$meta.mode -eq "workhorse") { Release-WriterLease -PairId $PairId -WorkingDirectory ([string]$meta.project_cwd) }

if ($RemoveWorktree -and [string]$meta.isolation -eq "worktree" -and -not [string]::IsNullOrWhiteSpace([string]$meta.worktree_path)) {
    if (Test-CoReviewWorktreeHasChanges -Path ([string]$meta.worktree_path)) { throw "Managed worktree has uncommitted changes; refusing removal" }
    Remove-CoReviewManagedWorktree -SourceRepo ([string]$meta.source_repo) -WorktreePath ([string]$meta.worktree_path)
}

if ($Delete) { Remove-Item -LiteralPath $pairDir -Recurse -Force; Write-Host "[co-review] Deleted worker $PairId" }
elseif ($Archive) {
    $archiveRoot = Join-Path (Get-CoReviewRoot) "archive"
    New-Item -ItemType Directory -Path $archiveRoot -Force | Out-Null
    Move-Item -LiteralPath $pairDir -Destination (Join-Path $archiveRoot $PairId) -Force
    Write-Host "[co-review] Archived worker $PairId"
} else { Write-Host "[co-review] Stopped worker $PairId" }
