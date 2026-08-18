[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PairId,
    [switch]$Archive, [switch]$Delete,
    [switch]$RemoveWorktree, [switch]$ConfirmRemoveWorktree
)
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")
. (Join-Path $PSScriptRoot "worktrees.ps1")
if ($Archive -and $Delete) { throw "Use either -Archive or -Delete, not both" }
if ($RemoveWorktree -and -not $ConfirmRemoveWorktree) { throw "Removing a managed worktree requires -ConfirmRemoveWorktree" }
$pairDir = Get-PairDir -PairId $PairId -MustExist

function Remove-CoReviewPairDirectory {
    param([Parameter(Mandatory=$true)][string]$Path)
    $deadline = (Get-Date).AddSeconds(3)
    do {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        } catch [System.IO.IOException] {
            if ((Get-Date) -ge $deadline) { throw }
            Start-Sleep -Milliseconds 100
        }
    } while ($true)
}

$mutexName = Get-CoReviewMutexName -Scope "lifecycle" -Key $PairId
Invoke-WithCoReviewMutex -Name $mutexName -ScriptBlock {
    $meta = Get-NormalizedPairMetadata -PairDir $pairDir

    [System.IO.File]::WriteAllText((Join-Path $pairDir "shutdown"), "", [System.Text.UTF8Encoding]::new($false))
    Signal-CoReviewChannel -PairId $PairId -Channel "inbox"
    $activePath = Join-Path $pairDir "active-turn.json"
    $cancellationUnconfirmed = $false
    if (Test-Path -LiteralPath $activePath -PathType Leaf) {
        $active = $null
        try {
            $active = Get-Content -LiteralPath $activePath -Raw | ConvertFrom-Json
            $cancelResult = & (Join-Path $PSScriptRoot "cancel-worker.ps1") -WorkerId $PairId -MessageId ([string]$active.message_id) -Json | ConvertFrom-Json
            $cancellationUnconfirmed = ([string]$cancelResult.status -eq "cancellation-unconfirmed")
        } catch {
            if ($null -eq $active -or ([string]$active.backend -eq "app-server" -and [string]$active.connection_mode -eq "shared")) {
                $cancellationUnconfirmed = $true
            }
            Write-Warning "Could not stop active Codex turn cleanly: $($_.Exception.Message)"
        }
    }
    $listenerPid = $null
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline -and (Test-CoReviewListenerAlive -PairDir $pairDir -ListenerPid ([ref]$listenerPid))) { Start-Sleep -Milliseconds 200 }
    $listenerStillAlive = Test-CoReviewListenerAlive -PairDir $pairDir -ListenerPid ([ref]$listenerPid)
    if ($listenerStillAlive -and $cancellationUnconfirmed) {
        throw "The shared Codex turn has not supplied an interruptible turn id yet. Shutdown is queued, and the bounded listener will retire after the turn starts or times out; refusing to orphan it by killing the listener."
    }
    if ($listenerStillAlive -and $null -ne $listenerPid) { Stop-CoReviewProcessTree -ProcessId $listenerPid }
    if ([string]$meta.mode -in @("workhorse", "imagegen")) { Release-WriterLease -PairId $PairId -WorkingDirectory ([string]$meta.project_cwd) }

    if ($RemoveWorktree -and [string]$meta.isolation -eq "worktree" -and -not [string]::IsNullOrWhiteSpace([string]$meta.worktree_path)) {
        if (Test-CoReviewWorktreeHasChanges -Path ([string]$meta.worktree_path)) { throw "Managed worktree has uncommitted changes; refusing removal" }
        Remove-CoReviewManagedWorktree -SourceRepo ([string]$meta.source_repo) -WorktreePath ([string]$meta.worktree_path)
    }

    if ($Delete) { Remove-CoReviewPairDirectory -Path $pairDir; Write-Host "[co-review] Deleted worker $PairId" }
    elseif ($Archive) {
        $archiveRoot = Join-Path (Get-CoReviewRoot) "archive"
        New-Item -ItemType Directory -Path $archiveRoot -Force | Out-Null
        Move-Item -LiteralPath $pairDir -Destination (Join-Path $archiveRoot $PairId) -Force
        Write-Host "[co-review] Archived worker $PairId"
    } else { Write-Host "[co-review] Stopped worker $PairId" }
}
