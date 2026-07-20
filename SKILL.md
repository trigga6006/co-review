---
name: co-review
description: Use when Claude should get a bounded cross-family review or second opinion from Codex, when the user explicitly asks Codex to implement a task as a workhorse, or when the user requests raster image generation/editing that Codex can perform with its imagegen skill. Supports dedicated review, workhorse, and imagegen modes; live model/reasoning selection; persistent leaf workers; safe writer isolation; cancellation; and parallel workers without making Codex the default critical path.
---

# Co-review: fast cross-family checks for Claude Code

Claude is the sole orchestrator. Codex processes are leaf workers and must not spawn or coordinate other agents.

## Prime directive

Optimize for finishing the user's task, not maximizing Codex involvement.

When the user asks to "use co-review," "ask GPT," or get a cross-family check on an implementation, Claude normally owns the implementation and asks Codex for one bounded review. Do not hand the entire task to a workhorse merely because this skill was invoked.

Use a Codex workhorse only when the user explicitly asks Codex/GPT to implement, delegate, or act as a workhorse. Never turn an ordinary task into a serial plan, implementation, review, fix, and re-review chain.

Image generation is a separate first-class path, not generic workhorse delegation. When the user requests a raster image, select `imagegen` even if they do not mention Codex or use the word "workhorse," unless they explicitly choose another method. Codex can generate images through its installed `$imagegen` skill and image-generation tool. Do not claim otherwise based on stale product knowledge, and do not route an image request through `workhorse` merely because it creates a file.

## Default latency budget

| Class | Typical scope | Reasoning | Codex turn timeout |
|---|---|---|---|
| Fast | focused diff, mechanical check, small second opinion | model default or `low` | 120 seconds |
| Standard | normal implementation review, bounded debugging | `low` or `medium` | 300 seconds |
| Image | raster image generation or editing with `$imagegen` | model default or `low` | 600 seconds |
| Deep | architecture/security investigation with concrete need | `high` | 600 seconds |

Use Fast unless the scope clearly requires Standard. Use Deep only when the user explicitly requests depth or Claude can name a correctness/security question that lower reasoning is unlikely to resolve. Never select `xhigh`, `max`, or `ultra` automatically. "Strongest model" selects model capability; it does not imply high reasoning.

New workers default to a 300-second process timeout, two total turns, and at most two meaningful progress updates per turn. A second turn is reserved for one targeted clarification or one verified blocker. Start a fresh worker only when the responsibility genuinely changes. Do not repeatedly ask Codex to re-review its own work.

## Choose the mode

| User intent | Mode | Sandbox | Default behavior |
|---|---|---|---|
| Review, critique, second opinion, cross-family check | `review` | `read-only` | One bounded turn; Claude continues useful independent work when possible |
| Explicit Codex implementation/delegation | `workhorse` | `workspace-write` | One bounded implementation turn, optional targeted follow-up |
| Generate or edit a raster image | `imagegen` | `workspace-write` | Invoke `$imagegen` and the image-generation tool; return the generated file path |
| Several independent reviews explicitly requested | one reviewer per concern | `read-only` | Dispatch concurrently |
| Several writable workers explicitly requested | one worker per task | `workspace-write` | Managed Git worktrees; never auto-merge |

Explicit user choices for model, reasoning, mode, isolation, search, sandbox, or visibility always win. Never silently widen permissions.

Select `imagegen` for new raster artwork, illustrations, concept images, photo-style assets, and edits to existing images. Keep diagrams, charts, SVGs, and code-rendered graphics in the normal Claude workflow unless the user explicitly wants generative image output. Image generation benefits from tool time, not extreme reasoning; normally use the visible model default with `low` or its advertised default reasoning and a 600-second turn timeout.

## Script root

Use PowerShell and the call operator. Never add `-ExecutionPolicy Bypass`.

```powershell
$coReview = "$env:USERPROFILE\.claude\skills\co-review\scripts"
```

If installed elsewhere, resolve this skill directory and use its `scripts` child.

## Workflow

### 1. Define one bounded question

Send the smallest task that provides independent value. Include exact files/diff/scope and a short output contract. Avoid open-ended prompts such as "be exhaustive," "investigate everything," or "keep working until perfect" unless the user explicitly asks for that depth.

For a normal review, request a verdict and at most three evidence-backed findings. For implementation, request the bounded change, focused verification, changed files, and blockers.

For `imagegen`, include the desired subject, composition, style, aspect ratio or dimensions when known, exact output directory/name, and every source-image path needed for an edit. Tell Codex to use `$imagegen`; never ask it only to draft a prompt. If a required source image is unavailable, obtain a usable local path before dispatching rather than falling back to a workhorse.

### 2. Discover live capabilities

Run only when capabilities are not fresh in the conversation:

```powershell
$caps = & "$coReview\get-capabilities.ps1" -Json | ConvertFrom-Json
$caps.models | Select-Object slug, display_name, default_reasoning_level, supported_reasoning_levels
```

Do not use a frozen model list. If `cache_stale` is true, use `configured-default` with `auto` reasoning or honor an explicit user selection. Otherwise choose the highest-priority visible model with its advertised default reasoning. Prefer a smaller visible model only for clearly mechanical work.

### 3. Inspect status before reuse

```powershell
$workers = & "$coReview\list-workers.ps1" -Json | ConvertFrom-Json
```

Reuse only an `idle` worker whose project, mode, sandbox, and narrow responsibility match. Never send to a `busy` worker. `queue_depth`, `active_message_id`, and `active_elapsed_sec` show hidden work. Sending refuses an occupied worker unless `-Queue` is explicitly supplied; intentional queueing should be rare.

### 4. Dispatch without creating dead time

Prefer asynchronous dispatch when Claude has independent inspection, implementation, tests, or documentation work:

```powershell
$messageId = & "$coReview\send-worker.ps1" -WorkerId $worker.worker_id `
  -Message "Review only the current diff. Return a verdict and at most 3 correctness findings with file references." `
  -TurnTimeoutSec 120

# Claude does useful independent work, then checks for progress without waiting:
$updates = & "$coReview\recv-worker.ps1" -WorkerId $worker.worker_id `
  -InReplyTo $messageId -IncludeProgress

# Wait for the final response only when it gates completion:
& "$coReview\recv-worker.ps1" -WorkerId $worker.worker_id `
  -InReplyTo $messageId -Wait -UntilFinal -TimeoutSec 150
```

Use the synchronous path only when the reply genuinely gates the next action. Keep the wait timeout slightly longer than the Codex turn timeout:

```powershell
& "$coReview\ask-worker.ps1" -WorkerId $worker.worker_id `
  -Message "Answer the single bounded question..." `
  -TurnTimeoutSec 300 -TimeoutSec 330
```

By default, a synchronous wait timeout cancels the Codex turn so it cannot keep consuming time invisibly. Use `-LeaveRunning` only when the user wants background continuation.

Progress messages contain only explicitly marked, high-confidence findings; they do not make a worker idle or complete a turn. Poll them at natural checkpoints rather than continuously. Use the last returned message `id` with `-Since` to avoid rereading updates.

### 5. Decide once, then stop

Claude evaluates the result, integrates useful findings, and finishes. One targeted follow-up is allowed only for an unresolved blocker or ambiguous correctness/security evidence. Do not ask broad follow-ups, request ceremonial re-reviews, or wait for Codex after Claude already has enough evidence to proceed.

Stop workers when the task finishes or pivots:

```powershell
& "$coReview\end-worker.ps1" -WorkerId $worker.worker_id
```

## Complete examples

### Normal cross-family implementation review

Claude implements and runs focused tests first, then creates one reviewer:

```powershell
$caps = & "$coReview\get-capabilities.ps1" -Json | ConvertFrom-Json
$model = $caps.models[0].slug
$reasoning = $caps.models[0].default_reasoning_level

$reviewer = & "$coReview\new-worker.ps1" `
  -Name "focused-review" -Mode review `
  -Task "Independent correctness review of the current bounded change" `
  -ProjectCwd (Get-Location).Path -Model $model -Reasoning $reasoning `
  -TimeoutSec 120 -MaxTurns 1 | Select-Object -Last 1 | ConvertFrom-Json

& "$coReview\ask-worker.ps1" -WorkerId $reviewer.worker_id `
  -Message "Inspect only the current diff. Return a verdict and at most 3 actionable correctness findings with file references. Do not summarize unchanged code." `
  -TurnTimeoutSec 120 -TimeoutSec 150
```

### Explicit workhorse delegation

```powershell
$worker = & "$coReview\new-worker.ps1" `
  -Name "parser-change" -Mode workhorse `
  -Task "Implement only the parser change and run focused tests" `
  -ProjectCwd (Get-Location).Path -Model $model -Reasoning low `
  -Isolation auto -TimeoutSec 300 -MaxTurns 2 | Select-Object -Last 1 | ConvertFrom-Json

& "$coReview\ask-worker.ps1" -WorkerId $worker.worker_id `
  -Message "Implement the bounded parser change. Run focused tests. Report outcome, changed files, test results, and blockers; do not broaden scope." `
  -TurnTimeoutSec 300 -TimeoutSec 330
```

While a shared workhorse holds the writer lease, Claude must not edit that checkout. Claude inspects the diff and test evidence after the reply. The same no-concurrent-edit rule applies to a shared `imagegen` worker.

### Codex image generation

Use a dedicated image worker even though it writes an output file:

```powershell
$imageWorker = & "$coReview\new-worker.ps1" `
  -Name "hero-art" -Mode imagegen `
  -Task 'Generate the requested hero image with the $imagegen skill' `
  -ProjectCwd (Get-Location).Path -Model $model -Reasoning low `
  -Isolation auto -TimeoutSec 600 -MaxTurns 2 | Select-Object -Last 1 | ConvertFrom-Json

& "$coReview\ask-worker.ps1" -WorkerId $imageWorker.worker_id `
  -Message 'Use $imagegen and the image-generation tool now. Create the requested raster image, save it under assets/hero.png, and report the absolute output path. Do not return only a prompt or substitute SVG/HTML.' `
  -TurnTimeoutSec 600 -TimeoutSec 630
```

The `imagegen` initialization envelope independently tells Codex that image generation is available, requires the installed `$imagegen` skill, and requires an actual image-generation tool call. For edits, provide an accessible source-image path; Codex must inspect it first. Claude verifies that every reported output file exists before finishing.

## Control and recovery

```powershell
& "$coReview\list-workers.ps1" -Json
& "$coReview\cancel-worker.ps1" -WorkerId $worker.worker_id
& "$coReview\ensure-worker.ps1" -WorkerId $worker.worker_id -Json
& "$coReview\end-worker.ps1" -WorkerId $worker.worker_id
```

`cancel-worker.ps1` stops the active Codex process without killing the listener; pass `-MessageId` to cancel a queued turn. `ensure-worker.ps1` restarts a dead listener while preserving the thread and queue. An interrupted active turn is returned as an error and is never replayed automatically, which prevents duplicate writes.

## Guardrails

- Review workers are always read-only.
- Shared-checkout `workhorse` and `imagegen` workers hold a writer lease; Claude pauses its edits until release.
- Parallel writers use separate managed Git worktrees and never auto-merge.
- Automatic worktree isolation refuses a dirty source repository unless the user accepts `-AllowDirtyBase` committed-HEAD-only context.
- Use `danger-full-access` only when explicitly requested and pass `-ConfirmDangerFullAccess`.
- Do not ask workers to spawn agents. The listener forces `features.multi_agent=false`.
- New workers allow two turns by default. Use `-MaxTurns 0` only when the user explicitly wants an open-ended persistent worker.
- Allow at most four live workers by default. Beyond four, require an explicit user request and pass `-AllowHighFanout`. Each `new-worker.ps1` call creates one leaf Codex process; never enable nested Codex agents.
- Keep progress at the default two meaningful updates per turn. Set `-MaxProgressUpdates 0` to disable it.
- `-Queue` and `-LeaveRunning` are explicit escape hatches, not normal workflow.

## Command reference

| Command | Purpose |
|---|---|
| `get-capabilities.ps1` | Discover installed models and reasoning levels |
| `new-worker.ps1` | Start a bounded review/workhorse worker |
| `ask-worker.ps1` | Send one task and wait; cancel on wait timeout by default |
| `send-worker.ps1` | Queue one task without blocking; refuses busy workers |
| `recv-worker.ps1` | Poll progress or wait for the correlated final reply |
| `list-workers.ps1` | Show `idle`/`busy`, elapsed time, queue, thread, and lease state |
| `cancel-worker.ps1` | Cancel an active or queued turn |
| `ensure-worker.ps1` | Verify/restart a listener without replaying interrupted work |
| `end-worker.ps1` | Stop and optionally archive/delete a worker |
| `purge-worker.ps1` | Permanently delete stopped worker state |

Legacy pair-oriented commands remain compatibility aliases.

## Disagreement

Claude must evaluate rather than blindly relay a reply. For correctness/security disagreement, show the two verdicts briefly and let the user decide. Ignore purely stylistic disagreement unless requested. Cross-family divergence is useful signal, but it is not a reason to start an unbounded debate between models.

Prompts, replies, state, and logs persist under `~/.cc-codex-pairs/`. Managed worktrees live under `~/.cc-codex-worktrees/` and are retained by default.
