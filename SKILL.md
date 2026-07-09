---
name: co-review
description: Use when Claude should ask Codex for a review or second opinion, delegate implementation to Codex as a workhorse or sub-agent, run multiple Codex workers, or honor a requested Codex model, reasoning level, sandbox, or execution mode.
---

# Codex workers for Claude Code

Claude is the sole orchestrator. Codex processes are leaf workers: Claude chooses their assignments and configuration, reviews their results, and communicates with the user. A Codex worker must not spawn, delegate to, or coordinate other agents.

Workers run through a hidden PowerShell listener that maintains a persistent Codex thread and file queue. The listener is a background process host, not the interactive Codex TUI.

## Decision table

| User intent | Mode | Sandbox | Isolation |
|---|---|---|---|
| Review, critique, challenge, second opinion | `review` | `read-only` | `shared` |
| Implement, fix, test, workhorse, sub-agent | `workhorse` | `workspace-write` | `auto` |
| Several reviews in parallel | one `review` worker per concern | `read-only` | `shared` |
| Several writers in parallel | one `workhorse` per task | `workspace-write` | managed Git worktrees |

Explicit user choices for mode, model, reasoning, isolation, search, or visibility take precedence. Never silently widen permissions.

## Non-negotiable guardrails

- Keep Claude as the sole orchestrator; each Codex process is a leaf worker.
- Review workers are always read-only.
- A shared-checkout workhorse holds a writer lease. Claude must not edit that checkout until the worker finishes.
- Parallel workhorses use separate Git worktrees. The system never auto-merges their work.
- Automatic parallel isolation refuses a dirty source repository because uncommitted changes are absent from a new worktree. Serialize instead, or use `-AllowDirtyBase` only when the user accepts committed-HEAD-only context.
- Use `danger-full-access` only when the user explicitly requests it, and pass `-ConfirmDangerFullAccess`.
- Do not ask workers to spawn agents. The listener also forces Codex `features.multi_agent=false`.
- Claude reviews worker changes and verification evidence before claiming completion.

## Script root

Use PowerShell and the call operator. Never add `-ExecutionPolicy Bypass`.

```powershell
$coReview = "$env:USERPROFILE\.claude\skills\co-review\scripts"
```

If the skill is installed elsewhere, resolve the current skill directory and use its `scripts` child.

## Orchestration workflow

### 1. Honor the user's configuration

Extract any explicit request for:

- mode: review or workhorse
- model slug
- reasoning level
- parallel or serial execution
- search, profile, additional writable directories, or advanced config
- hidden, minimized, or foreground listener

An explicit choice wins over heuristics.

### 2. Discover live options

Run this when capabilities are not already fresh in the current conversation:

```powershell
$caps = & "$coReview\get-capabilities.ps1" -Json | ConvertFrom-Json
$caps.models | Select-Object slug, display_name, default_reasoning_level, supported_reasoning_levels, additional_speed_tiers
```

Do not rely on a frozen model list. Choose only combinations advertised by the installed Codex cache. Hidden/internal models appear only with `-IncludeHidden`.

Selection guidance when the user did not choose:

- Hard architecture, security, correctness, debugging, or ambiguous review: highest-capability visible model and higher reasoning.
- Ordinary implementation/review: highest-priority visible model and its advertised default reasoning.
- Small, mechanical, low-risk task: a visible smaller/faster model.
- If live models are unavailable, use `configured-default` or an explicit known model. Unknown slugs require `-AllowUnknownModel` on `new-worker.ps1`.

### 3. Reuse or create a matching worker

List current workers:

```powershell
$workers = @(& "$coReview\list-workers.ps1" -Json | ConvertFrom-Json)
```

Reuse an idle worker only when its project, mode, sandbox, and responsibility match. A persistent worker retains its Codex thread. Start a new named worker when the role or capability boundary differs.

### 4. Dispatch and wait or continue in parallel

Use `ask-worker.ps1` for the common synchronous path. Use `send-worker.ps1` plus `recv-worker.ps1` when Claude has useful independent work or several workers are running.

### 5. Review and integrate

For workhorses, inspect the diff and reported test evidence. For managed worktrees, review the dedicated branch/commit and deliberately cherry-pick or merge it. Never auto-integrate.

### 6. Stop workers

Stop workers when the task finishes or the conversation pivots. Preserve isolated worktrees unless their changes are safely integrated or the user confirms removal.

## Complete examples

### Review with the strongest available model

```powershell
$caps = & "$coReview\get-capabilities.ps1" -Json | ConvertFrom-Json
$model = $caps.models[0].slug
$reasoning = if (@($caps.models[0].supported_reasoning_levels.effort) -contains "high") { "high" } else { $caps.models[0].default_reasoning_level }

$reviewer = & "$coReview\new-worker.ps1" `
  -Name "auth-review" `
  -Mode review `
  -Task "Review the current authentication changes for correctness and security" `
  -ProjectCwd (Get-Location).Path `
  -Model $model `
  -Reasoning $reasoning | Select-Object -Last 1 | ConvertFrom-Json

& "$coReview\ask-worker.ps1" `
  -WorkerId $reviewer.worker_id `
  -Message "Inspect the current diff. Return a verdict and prioritized evidence-backed findings with file references." `
  -TimeoutSec 900
```

### Workhorse sub-agent

```powershell
$worker = & "$coReview\new-worker.ps1" `
  -Name "parser-implementation" `
  -Mode workhorse `
  -Task "Implement the parser change and run its focused tests" `
  -ProjectCwd (Get-Location).Path `
  -Model $model `
  -Reasoning medium `
  -Isolation auto | Select-Object -Last 1 | ConvertFrom-Json

& "$coReview\ask-worker.ps1" `
  -WorkerId $worker.worker_id `
  -Message "Implement the bounded parser task from the repository context. Run appropriate tests and report outcome, changed files, commands/results, and remaining risks." `
  -TimeoutSec 1800
```

While this shared workhorse owns the checkout, Claude pauses its own edits. After the reply, Claude inspects and verifies the changes.

### Parallel workhorses

Start the first worker normally. Additional `-Isolation auto` workhorses for the same clean Git repository receive separate managed worktrees:

```powershell
$api = & "$coReview\new-worker.ps1" -Name "api-task" -Mode workhorse -Task "Implement API task" -ProjectCwd $repo -Model $model -Reasoning medium -Isolation auto | Select-Object -Last 1 | ConvertFrom-Json
$ui  = & "$coReview\new-worker.ps1" -Name "ui-task"  -Mode workhorse -Task "Implement UI task"  -ProjectCwd $repo -Model $model -Reasoning medium -Isolation auto | Select-Object -Last 1 | ConvertFrom-Json

& "$coReview\send-worker.ps1" -WorkerId $api.worker_id -Message "Implement and verify only the API task."
& "$coReview\send-worker.ps1" -WorkerId $ui.worker_id  -Message "Implement and verify only the UI task."

& "$coReview\recv-worker.ps1" -WorkerId $api.worker_id -Wait -TimeoutSec 1800
& "$coReview\recv-worker.ps1" -WorkerId $ui.worker_id  -Wait -TimeoutSec 1800
```

Each isolated workhorse commits to its dedicated branch. Claude reviews and integrates each branch separately.

## Configuration options

`new-worker.ps1` supports:

- `-Name`, `-Task`, `-Mode`, `-ProjectCwd`
- `-Model`, `-Reasoning`, `-AllowUnknownModel`
- `-Isolation auto|shared|worktree`, `-AllowDirtyBase`
- `-Sandbox`, `-ConfirmDangerFullAccess`
- `-WindowMode Hidden|Minimized|Foreground` (default `Hidden`)
- `-TimeoutSec`
- `-Profile`
- `-AddDir <path[]>`
- `-Search`
- `-ConfigOverride <key=value[]>`

Generic config overrides cannot replace guarded model, reasoning, sandbox, approval, working-directory, output, thread, or multi-agent settings.

Per-turn `ask-worker.ps1` and `send-worker.ps1` may override `-Model`, `-Reasoning`, and `-TurnTimeoutSec`. They cannot change mode or sandbox.

## Command reference

| Command | Purpose |
|---|---|
| `get-capabilities.ps1` | Show installed models, reasoning levels, and supported worker options |
| `new-worker.ps1` | Start a named review/workhorse worker |
| `ask-worker.ps1` | Send one task and wait for its correlated reply |
| `send-worker.ps1` | Queue a task without blocking |
| `recv-worker.ps1` | Poll or wait for replies |
| `list-workers.ps1` | Show names, modes, models, directories, threads, leases, and status |
| `ensure-worker.ps1` | Verify/restart a remembered listener without losing its queue/thread |
| `end-worker.ps1` | Stop and optionally archive/delete a worker |
| `purge-worker.ps1` | Permanently delete stopped worker logs/state |

The old pair-oriented commands remain compatibility aliases for existing users. Legacy pairs are interpreted as shared, read-only review workers.

## Recovery

Remember each `worker_id`. If a session resumes after sleep/reboot:

```powershell
& "$coReview\ensure-worker.ps1" -WorkerId $workerId -Json
```

`ask-worker.ps1` and `send-worker.ps1` also ensure the listener before queueing. Restart preserves message history and the Codex thread ID in `state.json`.

## Result handling and disagreement

Claude evaluates every reply rather than blindly relaying it.

- Correctness/security disagreement between Claude and Codex: show both verdicts to the user, labeled `Claude:` and `Codex:`, with a short weighting note. The user resolves it.
- Stylistic/taste disagreement: keep it out of the main thread; optionally append one summary line to the worker's `disagreements.log`.
- Workhorse result: verify changed files and tests before claiming success.

Cross-family disagreement is useful signal. Do not silently erase behavioral or security divergence.

## Windows and privacy notes

- Requires Windows PowerShell 5.1+ and the Codex CLI.
- Background is `Hidden` by default. `Minimized` or `Foreground` shows the listener log console; it is still not the interactive Codex TUI.
- Prompts and replies persist under `~/.cc-codex-pairs/<pair-id>/` until archived or deleted.
- Managed worktrees live under `~/.cc-codex-worktrees/` and are retained by default.
- Do not send secrets unless the user accepts local persistence and Codex processing.
- If downloaded scripts are blocked, run `Get-ChildItem "$env:USERPROFILE\.claude\skills\co-review" -Recurse | Unblock-File` once.
