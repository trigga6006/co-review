---
name: co-review
description: Use when the user asks Claude to use co-review/Codex/GPT as a coding copilot, workhorse, reviewer, second opinion, or raster image generator/editor. Defaults coding tasks to a coordinated Luna workhorse plus Sol reviewer, while preserving dedicated workhorse, review-only, and imagegen paths; live capability checks; persistent leaf workers; safe writer isolation; cancellation; and explicit worker counts.
---

# Co-review: fast cross-family checks for Claude Code

Claude is the sole orchestrator. Codex processes are leaf workers and must not spawn or coordinate other agents.

## Prime directive

Optimize for finishing the user's task. Keep Claude as the sole orchestrator and keep every Codex process a dedicated leaf worker.

When the user says only "use co-review," "use Codex," or similar for a coding task, run the default copilot pair:

1. One `workhorse` using `gpt-5.6-luna` at `high` reasoning implements and verifies the bounded change.
2. One separate `review` worker using `gpt-5.6-sol` at `high` reasoning reviews the resulting diff and test evidence.

Do not merge both responsibilities into one Codex session. Start the reviewer only when there is a stable artifact to inspect. It may review an independent plan or risk question concurrently, but final-diff review follows the workhorse so it never judges a half-written checkout. Claude evaluates the review, applies clear fixes itself or gives Luna one targeted follow-up, and stops.

Use `xhigh` for Luna only when the implementation is genuinely complex: cross-cutting architecture, difficult multi-file debugging, a high-risk migration, or an explicit user request. Otherwise use `high`. Keep Sol at `high`; do not automatically raise review or image generation to `xhigh`.

Explicit user requests for review-only, workhorse-only, imagegen, model, reasoning, worker counts, isolation, or permissions override these defaults.

Image generation is a separate first-class path, not generic workhorse delegation. When the user requests a raster image, select `imagegen` even if they do not mention Codex or use the word "workhorse," unless they explicitly choose another method. Codex can generate images through its installed `$imagegen` skill and image-generation tool. Do not claim otherwise based on stale product knowledge, and do not route an image request through `workhorse` merely because it creates a file.

## Default latency budget

| Class | Typical scope | Reasoning | Codex turn timeout |
|---|---|---|---|
| Fast | focused mechanical check | role default, optionally lower when explicitly requested | 120 seconds |
| Standard | Luna implementation or Sol review | `high` | 300 seconds |
| Image | raster image generation or editing with `$imagegen` | model default or `low` | 600 seconds |
| Deep work | complex Luna implementation | `xhigh` | 600 seconds |

Use Standard for the default pair. Use Deep work only under the Luna criteria above. Never select `max` or `ultra` automatically. "Strongest model" selects model capability; it does not by itself imply extreme reasoning.

New workers default to a 300-second process timeout, two total turns, and at most two meaningful progress updates per turn. A second turn is reserved for one targeted clarification or one verified blocker. Start a fresh worker only when the responsibility genuinely changes. Do not repeatedly ask Codex to re-review its own work.

## Choose the mode

| User intent | Mode | Sandbox | Default behavior |
|---|---|---|---|
| Bare co-review/Codex request for a coding change | `workhorse` then `review` | write then read-only | Default pair: Luna/high implements; Sol/high reviews the stable result |
| Review-only, critique, second opinion | `review` | `read-only` | One Sol/high reviewer |
| Workhorse-only implementation/delegation | `workhorse` | `workspace-write` | One Luna/high worker; use xhigh only for complex work |
| Generate or edit a raster image | `imagegen` | `workspace-write` | Invoke `$imagegen` and the image-generation tool; return the generated file path |
| Several independent reviews explicitly requested | one reviewer per concern | `read-only` | Dispatch concurrently |
| Several writable workers explicitly requested | one worker per task | `workspace-write` | Managed Git worktrees; never auto-merge |

Explicit user choices for model, reasoning, mode, isolation, search, sandbox, or visibility always win. Never silently widen permissions.

### Worker counts

Default to exactly one workhorse and one reviewer. Treat requests such as "two workhorses" or "three reviewers" as exact counts while leaving the unspecified role at one. Use multiple workhorses only for independent writable scopes and isolate them with managed worktrees; never have two writers edit the same checkout. Give multiple reviewers distinct concerns rather than duplicate prompts. Do not infer extra workers merely because a task is large. The normal global cap remains four live workers; exceeding it requires an explicit user request.

Select `imagegen` for new raster artwork, illustrations, concept images, photo-style assets, and edits to existing images. Keep diagrams, charts, SVGs, and code-rendered graphics in the normal Claude workflow unless the user explicitly wants generative image output. Image generation benefits from tool time, not extreme reasoning; normally use the visible model default with `low` or its advertised default reasoning and a 600-second turn timeout.

## Script root

Use PowerShell and the call operator. Never add `-ExecutionPolicy Bypass`.

```powershell
$coReview = "$env:USERPROFILE\.claude\skills\co-review\scripts"
```

If installed elsewhere, resolve this skill directory and use its `scripts` child.

Hidden listeners redirect their process stdout and stderr to `listener.stdout.log` and `listener.stderr.log` inside the worker directory. This prevents a successful background listener from retaining Claude Code's foreground tool handles and appearing as a tool error. Inspect those files only when listener startup or recovery actually fails.

## Workflow

### 1. Define one bounded question

Send the smallest task that provides independent value. Include exact files/diff/scope and a short output contract. Avoid open-ended prompts such as "be exhaustive," "investigate everything," or "keep working until perfect" unless the user explicitly asks for that depth.

For a normal review, request a verdict and at most three evidence-backed findings. For implementation, request the bounded change, focused verification, changed files, and blockers. In the default pair, include Luna's changed files, diff or worktree, and test evidence in Sol's review request.

For `imagegen`, include the desired subject, composition, style, aspect ratio or dimensions when known, exact output directory/name, and every source-image path needed for an edit. Tell Codex to use `$imagegen`; never ask it only to draft a prompt. If a required source image is unavailable, obtain a usable local path before dispatching rather than falling back to a workhorse.

### 2. Discover live capabilities

Run only when capabilities are not fresh in the conversation:

```powershell
$caps = & "$coReview\get-capabilities.ps1" -Json | ConvertFrom-Json
$caps.models | Select-Object slug, display_name, default_reasoning_level, supported_reasoning_levels
```

`new-worker.ps1` applies role defaults automatically: Luna/high for `workhorse` and Sol/high for `review`. It first verifies those slugs against the live cache. If a role model is unavailable, it falls back to the highest-priority visible model; if `cache_stale` is true, it uses `configured-default` with `auto` reasoning. Honor any explicit user selection. Use `-Reasoning xhigh` for Luna only under the Deep work rule.

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

### Default Luna + Sol copilot pair

Omitting `-Model` and `-Reasoning` deliberately selects the role defaults. Create a dedicated reviewer against Luna's actual checkout, but do not send the final review until Luna finishes:

```powershell
$luna = & "$coReview\new-worker.ps1" `
  -Name "parser-change" -Mode workhorse `
  -Task "Implement only the parser change and run focused tests" `
  -ProjectCwd (Get-Location).Path `
  -Isolation auto -TimeoutSec 300 -MaxTurns 2 | Select-Object -Last 1 | ConvertFrom-Json

$sol = & "$coReview\new-worker.ps1" `
  -Name "parser-review" -Mode review `
  -Task "Review Luna's completed parser change" `
  -ProjectCwd $luna.project_cwd `
  -TimeoutSec 300 -MaxTurns 1 | Select-Object -Last 1 | ConvertFrom-Json

$lunaResult = & "$coReview\ask-worker.ps1" -WorkerId $luna.worker_id `
  -Message "Implement the bounded parser change. Run focused tests. Report outcome, changed files, test results, and blockers; do not broaden scope." `
  -TurnTimeoutSec 300 -TimeoutSec 330

$solResult = & "$coReview\ask-worker.ps1" -WorkerId $sol.worker_id `
  -Message "Review only Luna's now-stable diff and reported test evidence. Return a verdict and at most 3 actionable correctness findings with file references." `
  -TurnTimeoutSec 300 -TimeoutSec 330
```

While a shared workhorse holds the writer lease, Claude must not edit that checkout. Claude inspects the diff and test evidence after the reply. The same no-concurrent-edit rule applies to a shared `imagegen` worker.

For review-only or workhorse-only requests, create just the requested dedicated worker with the same role defaults.

### Codex image generation

Use a dedicated image worker even though it writes an output file:

```powershell
$imageWorker = & "$coReview\new-worker.ps1" `
  -Name "hero-art" -Mode imagegen `
  -Task 'Generate the requested hero image with the $imagegen skill' `
  -ProjectCwd (Get-Location).Path `
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
