[CmdletBinding()]
param(
    [string]$Repo = "",
    [int]$PrNumber = 0,
    [ValidateRange(30, 7200)][int]$TimeoutSec = 900,
    [ValidateRange(5, 300)][int]$PollIntervalSec = 20,
    [ValidateRange(0, 1800)][int]$CodexGraceSec = 300,
    [bool]$TriggerCodex = $true,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

function Invoke-GhJson {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)
    $raw = & gh @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "gh $($Arguments -join ' ') failed: $($raw | Out-String)" }
    $text = ($raw | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI (gh) is required" }
if ([string]::IsNullOrWhiteSpace($Repo)) {
    $repoInfo = Invoke-GhJson -Arguments @("repo", "view", "--json", "nameWithOwner")
    $Repo = [string]$repoInfo.nameWithOwner
}
if ($Repo -notmatch '^([^/]+)/([^/]+)$') { throw "Repo must be owner/name" }
$owner = $Matches[1]
$name = $Matches[2]
if ($PrNumber -le 0) {
    $prInfo = Invoke-GhJson -Arguments @("pr", "view", "--repo", $Repo, "--json", "number")
    $PrNumber = [int]$prInfo.number
}

$threadQuery = @'
query($owner:String!, $name:String!, $number:Int!) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      reviewThreads(first:100) {
        nodes { isResolved comments(first:1) { nodes { url path author { login } } } }
      }
    }
  }
}
'@

$deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSec)
$headSha = ""
$headSeenAt = [DateTimeOffset]::Now
$lastStatus = $null

while ([DateTimeOffset]::Now -lt $deadline) {
    $pr = Invoke-GhJson -Arguments @("pr", "view", [string]$PrNumber, "--repo", $Repo, "--json", "headRefOid,url,state")
    if ([string]$pr.state -ne "OPEN") { throw "PR #$PrNumber is $($pr.state), not open" }
    if ($headSha -ne [string]$pr.headRefOid) {
        $headSha = [string]$pr.headRefOid
        $headSeenAt = [DateTimeOffset]::Now
    }

    $reviews = @(Invoke-GhJson -Arguments @("api", "-X", "GET", "repos/$Repo/pulls/$PrNumber/reviews?per_page=100"))
    $codexReviews = @($reviews | Where-Object {
        [string]$_.user.login -match '^(chatgpt-codex-connector|codex)(\[bot\])?$' -and
        [string]$_.commit_id -eq $headSha -and [string]$_.state -ne "DISMISSED"
    })

    $comments = @(Invoke-GhJson -Arguments @("api", "-X", "GET", "repos/$Repo/issues/$PrNumber/comments?per_page=100"))
    $marker = "<!-- co-review-codex:$headSha -->"
    $alreadyTriggered = @($comments | Where-Object { [string]$_.body -match [regex]::Escape($marker) }).Count -gt 0
    $elapsedForHead = ([DateTimeOffset]::Now - $headSeenAt).TotalSeconds
    if ($TriggerCodex -and $codexReviews.Count -eq 0 -and -not $alreadyTriggered -and $elapsedForHead -ge $CodexGraceSec) {
        $commentBody = "@codex review`n`n$marker"
        $commentOutput = & gh pr comment $PrNumber --repo $Repo --body $commentBody 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not request Codex review: $($commentOutput | Out-String)" }
        $alreadyTriggered = $true
    }

    $checksRaw = & gh pr checks $PrNumber --repo $Repo --json name,bucket,state,link 2>&1
    $checksExit = $LASTEXITCODE
    $checks = @()
    if (-not [string]::IsNullOrWhiteSpace(($checksRaw | Out-String))) {
        try { $checks = @(($checksRaw | Out-String) | ConvertFrom-Json) } catch {
            if ($checksExit -ne 0) { throw "Could not inspect PR checks: $($checksRaw | Out-String)" }
        }
    }
    $failedChecks = @($checks | Where-Object { [string]$_.bucket -in @("fail", "cancel") })
    $pendingChecks = @($checks | Where-Object { [string]$_.bucket -eq "pending" })

    $threads = Invoke-GhJson -Arguments @("api", "graphql", "-f", "query=$threadQuery", "-F", "owner=$owner", "-F", "name=$name", "-F", "number=$PrNumber")
    $unresolved = @($threads.data.repository.pullRequest.reviewThreads.nodes | Where-Object { -not $_.isResolved })

    $lastStatus = [PSCustomObject]@{
        repo = $Repo
        pr_number = $PrNumber
        url = [string]$pr.url
        head_sha = $headSha
        codex_reviewed_current_head = ($codexReviews.Count -gt 0)
        codex_triggered_current_head = $alreadyTriggered
        checks_total = $checks.Count
        checks_pending = $pendingChecks.Count
        checks_failed = $failedChecks.Count
        unresolved_threads = $unresolved.Count
        ready = ($codexReviews.Count -gt 0 -and $pendingChecks.Count -eq 0 -and $failedChecks.Count -eq 0 -and $unresolved.Count -eq 0)
    }

    if ($failedChecks.Count -gt 0) {
        if ($Json) { $lastStatus | ConvertTo-Json -Depth 6 } else { $lastStatus | Format-List }
        Write-Error "PR #$PrNumber has failing checks"
        exit 1
    }
    if ($lastStatus.ready) {
        if ($Json) { $lastStatus | ConvertTo-Json -Depth 6 } else { Write-Host "[co-review] PR #$PrNumber is review-ready at $headSha" -ForegroundColor Green }
        exit 0
    }

    if (-not $Json) {
        Write-Host "[co-review] Waiting: codex=$($lastStatus.codex_reviewed_current_head) pending=$($lastStatus.checks_pending) unresolved=$($lastStatus.unresolved_threads) head=$headSha"
    }
    $remainingMs = [Math]::Max(1, ($deadline - [DateTimeOffset]::Now).TotalMilliseconds)
    Start-Sleep -Milliseconds ([Math]::Min($PollIntervalSec * 1000, $remainingMs))
}

if ($Json -and $null -ne $lastStatus) { $lastStatus | ConvertTo-Json -Depth 6 }
Write-Error "Timed out after ${TimeoutSec}s waiting for current-head Codex review, successful checks, and resolved review threads on PR #$PrNumber"
exit 2
