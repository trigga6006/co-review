# co-review

**Let Claude Code orchestrate OpenAI Codex as reviewers, workhorse sub-agents, and image-generation specialists.**

`co-review` gives Claude a latency-bounded local worker manager around the Codex CLI. A bare co-review request for coding now uses a dedicated pair: GPT-5.6-Luna at high reasoning implements and verifies the change, then GPT-5.6-Sol at high reasoning reviews the stable result. Review-only, workhorse-only, and image requests remain explicit paths; image requests invoke Codex's installed `$imagegen` skill.

Claude remains the sole orchestrator. Codex workers are leaf agents and cannot create an uncontrolled agent mesh.

## Modes

| Mode | Codex permissions | Best for |
|---|---|---|
| `review` | `read-only` | Reviews, critique, second opinions, architecture and security challenges |
| `workhorse` | `workspace-write` | Bounded implementation, fixes, refactors, tests, and delegated coding |
| `imagegen` | `workspace-write` | Raster image generation and editing through Codex's `$imagegen` skill and image-generation tool |

Several reviewers may inspect one checkout concurrently. Only one writable worker (`workhorse` or `imagegen`) may use a shared checkout. Additional parallel writers receive separate managed Git worktrees when the source repository is clean.

## How it works

```text
User
  └─ Claude Code (sole orchestrator)
       ├─ Codex reviewer ─── read-only, shared checkout
       ├─ Codex workhorse ── writer lease, shared checkout
       └─ Codex workhorse ── isolated Git worktree
```

Each worker has a directory under `~/.cc-codex-pairs/` containing a JSONL inbox/outbox, metadata, logs, and its persisted Codex thread ID. A hidden PowerShell listener watches the queue and invokes `codex exec`/`codex exec resume` with the worker's fixed permissions.

The PowerShell process is a background worker host, not the interactive Codex TUI. Hidden listeners detach stdout/stderr into per-worker log files so the launch does not appear as a failed Claude tool use. Use `-WindowMode Minimized` or `Foreground` when you want to see its log console.

## Install

Requires Windows, PowerShell 5.1+, [Claude Code](https://docs.anthropic.com/en/docs/claude-code), Git, and the [OpenAI Codex CLI](https://github.com/openai/codex).

```cmd
git clone https://github.com/trigga6006/co-review.git "%USERPROFILE%\.claude\skills\co-review"
```

Restart Claude Code so the skill is discovered.

For a development junction:

```cmd
mklink /J "%USERPROFILE%\.claude\skills\co-review" "C:\path\to\co-review"
```

If downloaded scripts are blocked by Windows:

```powershell
Get-ChildItem "$env:USERPROFILE\.claude\skills\co-review" -Recurse | Unblock-File
```

## Natural-language use

Tell Claude what role Codex should play:

- “Use co-review on this parser change.” (one Luna workhorse, then one Sol reviewer)
- “Use Codex to review this auth refactor.” (review-only)
- “Use Codex as a workhorse sub-agent to implement this parser and run its tests.”
- “Use Codex image generation to create a cinematic hero image and save it under assets.”
- “Have two Codex workers handle the API and UI tasks in parallel.”
- “Use Codex-Spark at xhigh reasoning for this focused change.”
- “Ask Codex for a security review, but keep it read-only.”

Claude reads `SKILL.md`, discovers live capabilities, chooses or honors your requested configuration, dispatches workers, and reviews their results. The default count is exactly one workhorse and one reviewer; explicit counts override it. New workers default to five-minute turns, two total turns, up to two meaningful progress updates, and a four-worker global concurrency cap. Luna may move to xhigh for genuinely complex implementation work; max and ultra are never selected automatically.

## Commands

Set a convenience variable:

```powershell
$coReview = "$env:USERPROFILE\.claude\skills\co-review\scripts"
```

### Discover models and reasoning

```powershell
& "$coReview\get-capabilities.ps1"
& "$coReview\get-capabilities.ps1" -Json
```

The command reads the installed Codex model cache instead of hardcoding model names. It reports visible models, default/supported reasoning, speed tiers, modes, sandboxes, isolation choices, and window modes.

### Start a reviewer

```powershell
$reviewer = & "$coReview\new-worker.ps1" `
  -Name "auth-review" `
  -Mode review `
  -Task "Review the auth refactor" `
  -ProjectCwd (Get-Location).Path | Select-Object -Last 1 | ConvertFrom-Json
```

### Start a workhorse

```powershell
$worker = & "$coReview\new-worker.ps1" `
  -Name "parser-worker" `
  -Mode workhorse `
  -Task "Implement and test the parser" `
  -ProjectCwd (Get-Location).Path `
  -Isolation auto | Select-Object -Last 1 | ConvertFrom-Json
```

Reviewers use `read-only`. Workhorses and image generators use `workspace-write`. A shared writable worker obtains an atomic writer lease. If another writer already owns that checkout, `auto` uses a managed worktree for a clean Git repository or fails safely for a dirty source.

### Start an image generator

```powershell
$imageWorker = & "$coReview\new-worker.ps1" `
  -Name "hero-art" `
  -Mode imagegen `
  -Task 'Generate the requested hero image with the $imagegen skill' `
  -ProjectCwd (Get-Location).Path `
  -TimeoutSec 600 | Select-Object -Last 1 | ConvertFrom-Json

& "$coReview\ask-worker.ps1" `
  -WorkerId $imageWorker.worker_id `
  -Message 'Use $imagegen and the image-generation tool now. Save the raster result under assets/hero.png and return its absolute path.' `
  -TurnTimeoutSec 600 `
  -TimeoutSec 630
```

The mode's initialization envelope tells Codex that image generation is available and requires an actual `$imagegen` tool workflow instead of a text-only prompt, SVG, or generic coding substitute.

### Dispatch synchronously

```powershell
& "$coReview\ask-worker.ps1" `
  -WorkerId $worker.worker_id `
  -Message "Implement the bounded task, verify it, and report changed files and test results." `
  -TurnTimeoutSec 300 `
  -TimeoutSec 330
```

Use `-MessageFile <path>` for long prompts. `-Model`, `-Reasoning`, and `-TurnTimeoutSec` may override a single turn without changing the worker's permission boundary.

### Dispatch asynchronously

```powershell
$messageId = & "$coReview\send-worker.ps1" -WorkerId $worker.worker_id -Message "Implement and test the bounded task." -TurnTimeoutSec 300
& "$coReview\recv-worker.ps1" -WorkerId $worker.worker_id -InReplyTo $messageId -IncludeProgress
& "$coReview\recv-worker.ps1" -WorkerId $worker.worker_id -InReplyTo $messageId -Wait -UntilFinal -TimeoutSec 330
```

### List, recover, and stop

```powershell
& "$coReview\list-workers.ps1"
& "$coReview\list-workers.ps1" -Json
& "$coReview\ensure-worker.ps1" -WorkerId $worker.worker_id -Json
& "$coReview\cancel-worker.ps1" -WorkerId $worker.worker_id
& "$coReview\end-worker.ps1" -WorkerId $worker.worker_id
& "$coReview\end-worker.ps1" -WorkerId $worker.worker_id -Delete
```

`list-workers.ps1` reports `idle` or `busy`, active elapsed time, and queue depth. Sending refuses a busy worker unless `-Queue` is intentional. `ask-worker.ps1` cancels a turn when its wait expires unless `-LeaveRunning` is explicit. `ensure-worker.ps1` restarts a dead listener without replaying an interrupted turn.

## Configuration

`new-worker.ps1` supports:

- `-Model <slug|role-default|auto|configured-default>` and `-Reasoning <level|role-default|auto>`; `role-default` is Luna/high for workhorse and Sol/high for review
- `-AllowUnknownModel` for an explicit undiscovered slug
- `-Isolation auto|shared|worktree`
- `-AllowDirtyBase` when a committed-HEAD-only isolated worker is intentional
- `-Sandbox read-only|workspace-write|danger-full-access`
- `-ConfirmDangerFullAccess` (required for unrestricted execution)
- `-WindowMode Hidden|Minimized|Foreground`
- `-TimeoutSec` (300 seconds by default) and `-MaxTurns` (2 by default; 0 is unlimited)
- `-MaxProgressUpdates` (2 by default), `-ProgressMinIntervalSec`, `-MaxConcurrentWorkers` (4 by default), and `-AllowHighFanout`
- `-Profile`, `-AddDir`, `-Search`, and safe `-ConfigOverride key=value`

Workers always run Codex with non-interactive approval policy `never` and `features.multi_agent=false`. Generic overrides cannot replace guarded model, reasoning, sandbox, approval, working-directory, output, session, or multi-agent values.

## Safe parallel work

- Review workers: concurrent and read-only.
- First automatic writable worker (`workhorse` or `imagegen`): shared checkout plus writer lease.
- Additional automatic writable worker: separate branch/worktree under `~/.cc-codex-worktrees/`.
- Dirty source: automatic parallel writer fails rather than silently missing uncommitted context.
- Integration: Claude reviews each worker branch/commit and deliberately cherry-picks or merges. Nothing auto-merges.

Managed worktrees are retained by default. Explicit removal requires `-RemoveWorktree -ConfirmRemoveWorktree`, and dirty worktrees are refused.

## Compatibility

Existing scripts such as `new-pair.ps1`, `ask.ps1`, `send.ps1`, `recv.ps1`, `list-pairs.ps1`, and `end-pair.ps1` remain available. Schema-v1 pairs are interpreted as shared read-only reviewers.

## Privacy

Prompts, replies, state, and logs persist under `~/.cc-codex-pairs/<pair-id>/` until archived or deleted. Do not send secrets unless you accept local persistence and Codex processing.

```powershell
& "$coReview\purge-worker.ps1" -WorkerId $worker.worker_id -Force
```

## Tests

```powershell
& ".\tests\co-review-tests.ps1"
```

The suite covers path safety, capability discovery, mode/sandbox enforcement, leaf-agent CLI flags, lifecycle recovery, writer leases, stale-lease recovery, worktree isolation, dirty-source protection, timeout handling, and legacy compatibility.

## License

MIT. See [LICENSE](LICENSE).
