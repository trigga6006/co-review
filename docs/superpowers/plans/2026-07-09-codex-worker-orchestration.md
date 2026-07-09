# Codex Worker Orchestration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `co-review` into a Claude-controlled Codex worker system with live model discovery, review and workhorse modes, safe multi-worker orchestration, and backward-compatible pair commands.

**Architecture:** Keep the existing file-queue listener and persistent Codex thread, then layer worker metadata and high-level worker commands over it. Claude is the sole orchestrator; scripts enforce fixed worker capability boundaries, disable Codex multi-agent behavior, serialize shared-checkout writers with leases, and isolate parallel writers in Git worktrees.

**Tech Stack:** Windows PowerShell 5.1, Codex CLI 0.144+, JSON/JSONL state files, Git worktrees, the existing script-level PowerShell test harness.

## Global Constraints

- Preserve every pre-existing uncommitted change; several overlap this implementation and must be integrated, not reverted.
- Keep Windows PowerShell 5.1 compatibility; do not use PowerShell 7-only syntax or .NET Core-only APIs.
- Claude is the only orchestrator. Every listener invocation must force `features.multi_agent=false`.
- Review workers are always `read-only`; normal workhorses are `workspace-write`.
- `danger-full-access` requires explicit user direction plus `-ConfirmDangerFullAccess`.
- Background workers default to `Hidden`; `Foreground` is opt-in.
- Concurrent writers never share a checkout. Parallel writers use separate Git worktrees and are never auto-merged.
- Existing pair-oriented scripts and schema-v1 state remain usable as read-only review workers.
- Use test-first development for every behavior change and run the complete regression suite before completion.
- When committing a file that was dirty before this plan, inspect its complete diff and preserve the existing listener-recovery and `xhigh` work.

---

## File Structure

- `scripts/common.ps1`: shared capability, metadata, task-envelope, liveness, and safe-config helpers.
- `scripts/get-capabilities.ps1`: machine- and human-readable live Codex capability discovery.
- `scripts/new-pair.ps1`: backward-compatible low-level worker creation and listener spawn.
- `scripts/new-worker.ps1`: Claude-facing worker creation interface with automatic defaults.
- `scripts/codex-listener.ps1`: fixed-mode leaf-worker execution, task envelopes, and effective per-turn configuration.
- `scripts/send.ps1`, `scripts/ask.ps1`, `scripts/recv.ps1`: existing queue primitives with validated per-turn options.
- `scripts/send-worker.ps1`, `scripts/ask-worker.ps1`, `scripts/recv-worker.ps1`: worker-named compatibility wrappers.
- `scripts/list-pairs.ps1`, `scripts/ensure-pair.ps1`, `scripts/end-pair.ps1`, `scripts/purge-pair.ps1`: existing lifecycle internals extended for worker metadata and leases.
- `scripts/list-workers.ps1`, `scripts/ensure-worker.ps1`, `scripts/end-worker.ps1`, `scripts/purge-worker.ps1`: Claude-facing lifecycle wrappers.
- `scripts/worktrees.ps1`: focused Git repository and managed-worktree helpers.
- `tests/fixtures/models-cache.json`: deterministic visible/hidden model capability fixture.
- `tests/co-review-tests.ps1`: regression, mode, concurrency, isolation, and compatibility tests.
- `SKILL.md`: concise Claude orchestration workflow and command contracts.
- `README.md`: human-facing installation, behavior, and command reference.

---

### Task 1: Live Codex Capability Discovery

**Files:**
- Create: `tests/fixtures/models-cache.json`
- Create: `scripts/get-capabilities.ps1`
- Modify: `scripts/common.ps1`
- Modify: `tests/co-review-tests.ps1`

**Interfaces:**
- Produces: `Get-CodexCapabilities -ModelsCachePath <path> -IncludeHidden <bool>` returning `{ source, cache_path, cli_version, models, modes, sandboxes, isolation, window_modes, defaults }`.
- Produces: `Resolve-CodexSelection -Capabilities <object> -Model <string> -Reasoning <string> -AllowUnknownModel <bool>` returning `{ model, reasoning, model_source, reasoning_source }`.
- Produces: `Assert-SafeCodexConfigOverrides -Overrides <string[]>`.
- Consumed by: Tasks 2, 3, and 6.

- [ ] **Step 1: Add capability fixtures and failing tests**

Create `tests/fixtures/models-cache.json` with one visible frontier model, one visible fast model, and one hidden model:

```json
{
  "client_version": "0.144.0",
  "fetched_at": "2026-07-09T00:00:00Z",
  "models": [
    {
      "slug": "gpt-test-frontier",
      "display_name": "GPT Test Frontier",
      "description": "Fixture frontier model",
      "priority": 0,
      "visibility": "list",
      "default_reasoning_level": "medium",
      "supported_reasoning_levels": [
        {"effort": "low", "description": "Low"},
        {"effort": "medium", "description": "Medium"},
        {"effort": "high", "description": "High"},
        {"effort": "xhigh", "description": "Extra high"}
      ],
      "additional_speed_tiers": ["fast"]
    },
    {
      "slug": "gpt-test-fast",
      "display_name": "GPT Test Fast",
      "description": "Fixture fast model",
      "priority": 10,
      "visibility": "list",
      "default_reasoning_level": "high",
      "supported_reasoning_levels": [
        {"effort": "low", "description": "Low"},
        {"effort": "high", "description": "High"}
      ]
    },
    {
      "slug": "gpt-test-hidden",
      "display_name": "GPT Test Hidden",
      "description": "Fixture hidden model",
      "priority": 99,
      "visibility": "hide",
      "default_reasoning_level": "medium",
      "supported_reasoning_levels": [{"effort": "medium", "description": "Medium"}]
    }
  ]
}
```

Add `Test-CapabilityDiscovery` to `tests/co-review-tests.ps1`. It must assert that normal output contains the first two models, excludes the hidden model, resolves `auto/auto` to `gpt-test-frontier/medium`, accepts `xhigh` for the frontier fixture, rejects unsupported `medium` for `gpt-test-fast`, and exposes `review`, `workhorse`, `read-only`, `workspace-write`, and `danger-full-access`.

Extend the test harness parameter block to `param([string]$Only = "")` and register tests in an ordered map so `-Only <name>` runs one named group while an empty value runs every group. Unknown names must throw with the available group names.

- [ ] **Step 2: Run the capability test and verify RED**

Run:

```powershell
& ".\tests\co-review-tests.ps1" -Only CapabilityDiscovery
```

Expected: FAIL because `get-capabilities.ps1` and `Get-CodexCapabilities` do not exist.

- [ ] **Step 3: Implement dynamic capability helpers and command**

Add PowerShell 5.1-compatible helpers to `common.ps1` with these exact signatures:

```powershell
function Get-CodexCapabilities {
    param([string]$ModelsCachePath = "", [switch]$IncludeHidden, [string]$CodexBin = "")
    # Resolve CODEX_HOME, then ~/.codex. Parse models defensively, sort by priority,
    # and return a PSCustomObject with an always-present models array.
}

function Resolve-CodexSelection {
    param(
        [Parameter(Mandatory=$true)]$Capabilities,
        [string]$Model = "auto",
        [string]$Reasoning = "auto",
        [switch]$AllowUnknownModel
    )
    # auto model = first visible model by priority; auto reasoning = selected
    # model's advertised default. Throw on unsupported combinations.
}

function Assert-SafeCodexConfigOverrides {
    param([string[]]$Overrides = @())
    $reserved = @('model','model_reasoning_effort','sandbox_mode','approval_policy','cwd','output_last_message','features.multi_agent')
    foreach ($override in $Overrides) {
        if ($override -notmatch '^[A-Za-z0-9_.-]+=.+$') { throw "Invalid Codex config override: $override" }
        $key = ($override -split '=', 2)[0]
        if ($reserved -contains $key) { throw "Codex config '$key' has a dedicated guarded option" }
    }
}
```

Implement `get-capabilities.ps1` with `-ModelsCachePath`, `-CodexBin`, `-IncludeHidden`, and `-Json`. Human output is a model table plus mode defaults; JSON output serializes the complete object at depth 10.

- [ ] **Step 4: Run focused and full tests and verify GREEN**

Run:

```powershell
& ".\tests\co-review-tests.ps1" -Only CapabilityDiscovery
& ".\tests\co-review-tests.ps1"
```

Expected: capability assertions pass; existing path, purge, timeout, and restart tests remain green.

- [ ] **Step 5: Commit capability discovery**

```powershell
git add scripts/common.ps1 scripts/get-capabilities.ps1 tests/fixtures/models-cache.json tests/co-review-tests.ps1
git commit -m "Add live Codex capability discovery"
```

---

### Task 2: Fixed Worker Modes and Leaf-Agent Execution

**Files:**
- Modify: `scripts/new-pair.ps1`
- Modify: `scripts/codex-listener.ps1`
- Modify: `scripts/send.ps1`
- Modify: `scripts/ask.ps1`
- Modify: `scripts/common.ps1`
- Modify: `tests/co-review-tests.ps1`

**Interfaces:**
- Consumes: `Get-CodexCapabilities`, `Resolve-CodexSelection`, and `Assert-SafeCodexConfigOverrides` from Task 1.
- Produces: schema-v2 `pair.json` fields `worker_name`, `mode`, `sandbox`, `isolation`, `requested_model`, `codex_model`, `requested_reasoning`, `codex_reasoning`, `config_overrides`, `search_enabled`, and `schema_version`.
- Produces: `New-CodexTaskEnvelope -Meta <object> -Task <string>`.
- Produces: queue fields `model`, `reasoning`, and `turn_timeout_sec`.

- [ ] **Step 1: Add failing mode and invocation tests**

Enhance `New-FakeCodex` so the fake executable writes its argument vector and stdin to paths supplied by `CO_REVIEW_TEST_ARGS` and `CO_REVIEW_TEST_STDIN`. Add focused tests that create one review pair and one workhorse pair, dispatch a turn, and assert:

```text
review:    --sandbox read-only
workhorse: --sandbox workspace-write
both:      -c features.multi_agent=false
both:      -a never before the exec subcommand
review envelope: MODE: review and MUST NOT edit files
workhorse envelope: MODE: workhorse and implement/run verification
```

Also assert `danger-full-access` creation fails without `-ConfirmDangerFullAccess`.

- [ ] **Step 2: Run the mode tests and verify RED**

Run:

```powershell
& ".\tests\co-review-tests.ps1" -Only WorkerModes
```

Expected: FAIL because pairs do not persist a mode and the listener hardcodes `read-only`.

- [ ] **Step 3: Implement schema-v2 mode enforcement and task envelopes**

Extend `new-pair.ps1` with guarded parameters while keeping legacy defaults (`review`, `shared`, `Minimized`, current pinned model/reasoning):

```powershell
[ValidateSet("review", "workhorse")][string]$Mode = "review",
[string]$WorkerName = "",
[ValidateSet("auto", "shared", "worktree")][string]$Isolation = "shared",
[ValidateSet("", "read-only", "workspace-write", "danger-full-access")][string]$Sandbox = "",
[switch]$ConfirmDangerFullAccess,
[string[]]$ConfigOverride = @(),
[string]$Profile = "",
[string[]]$AddDir = @(),
[switch]$Search
```

Resolve the default sandbox from mode, reject a review worker with a writable sandbox, and require the confirmation switch for `danger-full-access`. Preserve the currently added timeout, window-mode, and dry-run recovery metadata.

Add `New-CodexTaskEnvelope` to `common.ps1`. The envelope must identify the worker, state the fixed mode, prohibit spawning/delegating/coordinating other agents, state the working directory, define the mode-specific completion contract, and append the original task under `TASK FROM CLAUDE:`.

Change `Invoke-Codex` to accept `Model`, `Reasoning`, `Sandbox`, `TimeoutSec`, `Profile`, `AddDir`, `Search`, and `ConfigOverrides`. Build top-level arguments first (`-a never`, optional `--search`, and one `--add-dir` per validated directory), then `exec`, then `--sandbox $Sandbox`, optional `-p $Profile`, `-m $Model`, `-c model_reasoning_effort=$Reasoning`, and `-c features.multi_agent=false`. Append validated generic `-c` values without evaluating them as shell text. Preserve all `exec` options before `resume`.

Extend `send.ps1` and `ask.ps1` with free-form `-Model`, dynamic `-Reasoning`, and `-TurnTimeoutSec`. Validate them before enqueueing. Keep the existing wait timeout separate as `-TimeoutSec`.

- [ ] **Step 4: Run focused and full tests and verify GREEN**

```powershell
& ".\tests\co-review-tests.ps1" -Only WorkerModes
& ".\tests\co-review-tests.ps1"
```

Expected: both mode command lines and envelopes match; legacy tests pass; `xhigh` works end to end when the model advertises it.

- [ ] **Step 5: Commit mode enforcement**

```powershell
git add scripts/new-pair.ps1 scripts/codex-listener.ps1 scripts/send.ps1 scripts/ask.ps1 scripts/common.ps1 tests/co-review-tests.ps1
git commit -m "Add review and workhorse worker modes"
```

---

### Task 3: Claude-Facing Worker Lifecycle and Multiple Named Workers

**Files:**
- Create: `scripts/new-worker.ps1`
- Create: `scripts/send-worker.ps1`
- Create: `scripts/ask-worker.ps1`
- Create: `scripts/recv-worker.ps1`
- Create: `scripts/list-workers.ps1`
- Create: `scripts/ensure-worker.ps1`
- Create: `scripts/end-worker.ps1`
- Create: `scripts/purge-worker.ps1`
- Modify: `scripts/list-pairs.ps1`
- Modify: `scripts/ensure-pair.ps1`
- Modify: `tests/co-review-tests.ps1`

**Interfaces:**
- Consumes: schema-v2 creation and per-turn options from Tasks 1-2.
- Produces: worker commands accepting `-WorkerId` and returning `worker_id`, `name`, `mode`, `status`, `working_directory`, effective model/reasoning, listener PID, and thread ID.

- [ ] **Step 1: Add failing lifecycle tests**

Add `Test-WorkerLifecycle` that starts two dry-run review workers with names `review-security` and `review-performance`, asserts distinct IDs and independent replies, lists both by name/mode, restarts one with `ensure-worker.ps1`, ends both, and confirms the pair-oriented list still sees the same state.

- [ ] **Step 2: Run the lifecycle test and verify RED**

```powershell
& ".\tests\co-review-tests.ps1" -Only WorkerLifecycle
```

Expected: FAIL because worker-named commands do not exist.

- [ ] **Step 3: Implement worker wrappers and enriched listing**

`new-worker.ps1` must default to `-Model auto`, `-Reasoning auto`, `-Isolation auto`, and `-WindowMode Hidden`, resolve capabilities, then call `new-pair.ps1` with explicit resolved values. It exposes `-Profile`, `-AddDir`, `-Search`, `-ConfigOverride`, `-AllowUnknownModel`, `-AllowDirtyBase`, `-ConfirmDangerFullAccess`, and the existing dry-run/testing switches. Its last output line is JSON containing both `worker_id` and `pair_id` for compatibility.

Each queue/lifecycle wrapper uses `[Alias('PairId')] [string]$WorkerId`, invokes the corresponding pair script in-process, and preserves exit codes and the last JSON/result line. Do not duplicate queue logic.

Extend `list-pairs.ps1` to read schema-v2 fields plus `state.json.codex_session_id`. Add `-Json`. `list-workers.ps1` calls it and presents worker terminology without changing stored IDs.

- [ ] **Step 4: Run focused and full tests and verify GREEN**

```powershell
& ".\tests\co-review-tests.ps1" -Only WorkerLifecycle
& ".\tests\co-review-tests.ps1"
```

Expected: two workers remain isolated, lifecycle commands agree on status, and old pair commands still work.

- [ ] **Step 5: Commit the worker command surface**

```powershell
git add scripts/new-worker.ps1 scripts/send-worker.ps1 scripts/ask-worker.ps1 scripts/recv-worker.ps1 scripts/list-workers.ps1 scripts/ensure-worker.ps1 scripts/end-worker.ps1 scripts/purge-worker.ps1 scripts/list-pairs.ps1 scripts/ensure-pair.ps1 tests/co-review-tests.ps1
git commit -m "Add Claude-facing Codex worker commands"
```

---

### Task 4: Atomic Shared-Checkout Writer Leases

**Files:**
- Modify: `scripts/common.ps1`
- Modify: `scripts/new-pair.ps1`
- Modify: `scripts/ensure-pair.ps1`
- Modify: `scripts/end-pair.ps1`
- Modify: `scripts/purge-pair.ps1`
- Modify: `scripts/list-pairs.ps1`
- Modify: `tests/co-review-tests.ps1`

**Interfaces:**
- Produces: `Get-WriterLeasePath -WorkingDirectory <path>`.
- Produces: `Acquire-WriterLease -PairId <id> -PairDir <path> -WorkingDirectory <path>`.
- Produces: `Release-WriterLease -PairId <id> -WorkingDirectory <path>`.
- Consumed by: workhorse creation, recovery, listing, shutdown, and Task 5 auto-isolation.

- [ ] **Step 1: Add failing writer-lease tests**

Add tests that run two dry-run reviewers in one directory successfully, start one dry-run shared workhorse, reject a second shared workhorse with an error naming the owner, stop the first worker, and then successfully start the second. Add a stale-lease fixture whose owner pair has no live listener and assert it is reclaimed.

- [ ] **Step 2: Run the lease tests and verify RED**

```powershell
& ".\tests\co-review-tests.ps1" -Only WriterLeases
```

Expected: FAIL because multiple workhorses currently have no mutual exclusion.

- [ ] **Step 3: Implement atomic lease acquisition, validation, and release**

Store leases under `~/.cc-codex-pairs/.leases/<sha256-of-canonical-path>.json`. Use `[System.IO.File]::Open(..., CreateNew, Write, None)` so acquisition is atomic. The JSON must contain pair ID, pair directory, canonical working directory, creation time, and listener PID when known.

On conflict, load the owner and call `Test-CoReviewListenerAlive`. Reclaim only if the owner is verified dead, using a remove-then-atomic-retry loop. Release only when the stored owner matches the caller. A shared workhorse acquires before listener spawn; failed spawn releases it. `ensure-pair.ps1` reasserts ownership before restarting. Shutdown and purge release ownership safely.

Expose `writer_lease` and `lease_owner` from list commands.

- [ ] **Step 4: Run focused and full tests and verify GREEN**

```powershell
& ".\tests\co-review-tests.ps1" -Only WriterLeases
& ".\tests\co-review-tests.ps1"
```

Expected: reviewers coexist; only one shared writer is active; stale ownership is reclaimed without deleting live ownership.

- [ ] **Step 5: Commit writer leases**

```powershell
git add scripts/common.ps1 scripts/new-pair.ps1 scripts/ensure-pair.ps1 scripts/end-pair.ps1 scripts/purge-pair.ps1 scripts/list-pairs.ps1 tests/co-review-tests.ps1
git commit -m "Prevent conflicting Codex workhorse writes"
```

---

### Task 5: Automatic Git-Worktree Isolation for Parallel Workhorses

**Files:**
- Create: `scripts/worktrees.ps1`
- Modify: `scripts/new-pair.ps1`
- Modify: `scripts/end-pair.ps1`
- Modify: `scripts/list-pairs.ps1`
- Modify: `scripts/common.ps1`
- Modify: `tests/co-review-tests.ps1`

**Interfaces:**
- Produces: `Get-CoReviewGitInfo -Path <path>` returning repo root, HEAD, branch, and dirty state.
- Produces: `New-CoReviewManagedWorktree -PairId <id> -SourcePath <path> -AllowDirtyBase <bool>` returning worktree path and branch.
- Produces: `Test-CoReviewWorktreeHasChanges -Path <path>`.
- Consumes: writer leases from Task 4.

- [ ] **Step 1: Add failing temporary-repository isolation tests**

Create a temporary Git repository in the test, configure local test identity, commit one file, and start two `-Isolation auto` workhorses. Assert the first uses the source checkout and the second uses a distinct managed worktree/branch. Modify the source without committing and assert a further automatic parallel worker fails with a message explaining that uncommitted changes are not present in new worktrees. Verify source files remain unchanged.

- [ ] **Step 2: Run the isolation tests and verify RED**

```powershell
& ".\tests\co-review-tests.ps1" -Only WorktreeIsolation
```

Expected: FAIL because `auto` does not create isolated worktrees.

- [ ] **Step 3: Implement managed worktree helpers and auto routing**

`worktrees.ps1` must use native `git -C <repo>` commands, validate every resolved path under `~/.cc-codex-worktrees`, and create branch `codex-worker/<pair-id>` at current HEAD with:

```powershell
& git -C $repoRoot worktree add -b $branch $worktreePath HEAD
```

For `new-pair.ps1 -Mode workhorse -Isolation auto`, attempt the source checkout lease first. On a live conflict, require a clean Git source, create the isolated worktree, acquire its distinct lease, save `source_repo`, `worktree_path`, and `worktree_branch`, and spawn the listener there. Explicit `shared` never falls back. Explicit `worktree` always isolates and requires clean HEAD unless `-AllowDirtyBase` confirms that only committed state is expected.

The isolated workhorse envelope requires verification and a commit on its dedicated branch. `end-pair.ps1` keeps managed worktrees by default; `-RemoveWorktree -ConfirmRemoveWorktree` may remove only after reporting dirty/unintegrated state. Never auto-merge or auto-cherry-pick.

- [ ] **Step 4: Run focused and full tests and verify GREEN**

```powershell
& ".\tests\co-review-tests.ps1" -Only WorktreeIsolation
& ".\tests\co-review-tests.ps1"
```

Expected: clean repositories isolate parallel writers; dirty repositories fail safely; normal shared work remains unchanged.

- [ ] **Step 5: Commit worktree isolation**

```powershell
git add scripts/worktrees.ps1 scripts/new-pair.ps1 scripts/end-pair.ps1 scripts/list-pairs.ps1 scripts/common.ps1 tests/co-review-tests.ps1
git commit -m "Isolate parallel Codex workhorses in worktrees"
```

---

### Task 6: Rewrite the Skill for Natural Claude Orchestration

**Files:**
- Modify: `SKILL.md`
- Modify: `README.md`
- Modify: `tests/co-review-tests.ps1`

**Interfaces:**
- Consumes: every public worker command and safety rule from Tasks 1-5.
- Produces: a discoverable skill whose examples use only implemented parameters and commands.

- [ ] **Step 1: Run baseline skill scenarios without the revised instructions**

Use fresh-context forward tests with the current `SKILL.md` for these prompts and record the emitted command choices:

```text
Use Codex to review my current auth changes with the strongest available model.
Use Codex as a workhorse sub-agent to implement the parser and run its tests.
Have two Codex workers implement independent clean-repo tasks in parallel.
Use Codex-Spark at xhigh reasoning for a quick focused change.
```

Expected RED: the current skill creates at most one review-only pair, does not discover models, and cannot safely orchestrate parallel writers.

- [ ] **Step 2: Add static command-contract tests and verify RED**

Add `Test-SkillCommandContracts` asserting `SKILL.md` references every primary worker command, both modes, live capability discovery, explicit-user-choice precedence, writer leases, worktree isolation, hidden default windows, leaf-agent rules, and `danger-full-access` confirmation. It must also assert the old “spawn at most one pair” and review-only limitations are absent.

Run:

```powershell
& ".\tests\co-review-tests.ps1" -Only SkillCommandContracts
```

Expected: FAIL against the current skill.

- [ ] **Step 3: Rewrite `SKILL.md` and update the human README**

Use frontmatter with only `name` and a third-person `description` beginning with `Use when...`. The description must trigger on Codex review, consultation, workhorse/sub-agent delegation, implementation, parallel Codex work, and model/reasoning selection without summarizing the workflow.

The body must present this exact decision order:

```text
1. Read explicit user mode/model/reasoning/isolation choices.
2. Run get-capabilities.ps1 -Json when live options are not fresh.
3. Choose review or workhorse.
4. Reuse a matching idle worker or start a named worker.
5. Dispatch synchronously or asynchronously.
6. Review/integrate the result; Claude remains accountable.
7. End workers and preserve unintegrated worktrees.
```

Include one complete review example, one complete workhorse example, and one parallel-worktree example. Keep transport internals concise. Preserve the correctness/security disagreement protocol and local-log privacy warning. Document pair scripts only as compatibility aliases.

Update README installation and command tables to match actual script names and defaults. Explain that the hidden PowerShell process is a background listener rather than the interactive Codex TUI.

- [ ] **Step 4: Run static tests and forward-test the revised skill**

```powershell
& ".\tests\co-review-tests.ps1" -Only SkillCommandContracts
& ".\tests\co-review-tests.ps1"
```

Then repeat the four fresh-context forward tests with the revised skill. Expected GREEN: Claude discovers live options, uses read-only for review, workspace-write for a workhorse, separate worktrees for parallel writers, preserves explicit model/reasoning, and never asks Codex workers to spawn agents.

- [ ] **Step 5: Commit skill and README documentation**

```powershell
git add SKILL.md README.md tests/co-review-tests.ps1
git commit -m "Teach Claude to orchestrate Codex workers"
```

---

### Task 7: Backward Compatibility, Regression Hardening, and Final Verification

**Files:**
- Modify: `tests/co-review-tests.ps1`
- Modify: any implementation file only when a failing regression proves it necessary.

**Interfaces:**
- Verifies: all public worker and legacy pair contracts from Tasks 1-6.

- [ ] **Step 1: Add schema-v1 and recovery regression tests**

Create a legacy `pair.json` fixture without worker fields and assert list/ensure/ask interpret it as `review`, `read-only`, and `shared`. Verify dead-listener recovery preserves schema-v2 mode, sandbox, model, reasoning, timeout, window mode, isolation, dry-run state, queue, and Codex thread ID. Verify isolated-worktree cleanup refuses unconfirmed removal.

- [ ] **Step 2: Run new regression tests and verify RED where gaps remain**

```powershell
& ".\tests\co-review-tests.ps1" -Only BackwardCompatibility
```

Expected: any missing schema/recovery field fails with an explicit assertion; do not weaken the test to match implementation.

- [ ] **Step 3: Make only the minimal compatibility fixes**

Centralize schema defaults in one helper:

```powershell
function Get-NormalizedPairMetadata {
    param([Parameter(Mandatory=$true)][string]$PairDir)
    # Return schema-v1 defaults as review/read-only/shared and preserve all
    # schema-v2 fields without mutating pair.json during a read.
}
```

Use that helper from listener startup, ensure, list, end, and purge so legacy interpretation cannot drift.

- [ ] **Step 4: Run syntax, regression, and repository checks**

```powershell
$scripts = Get-ChildItem .\scripts -Filter *.ps1
foreach ($script in $scripts) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { throw "$($script.Name): $($errors | Out-String)" }
}
& ".\tests\co-review-tests.ps1"
git diff --check
git status --short
python "C:\Users\fowle\.codex\skills\.system\skill-creator\scripts\quick_validate.py" .
```

Expected: zero parser errors, `All co-review tests passed`, no whitespace errors, skill validation success, and only intentional changes.

- [ ] **Step 5: Run live smoke checks without editing a project**

```powershell
& ".\scripts\get-capabilities.ps1" -Json | ConvertFrom-Json | Out-Null
$review = (& ".\scripts\new-worker.ps1" -Name "smoke-review" -Mode review -Task "Echo smoke" -DryRunListener | Select-Object -Last 1) | ConvertFrom-Json
& ".\scripts\ask-worker.ps1" -WorkerId $review.worker_id -Message "smoke" -TimeoutSec 20 | Out-Null
& ".\scripts\end-worker.ps1" -WorkerId $review.worker_id -Delete | Out-Null
```

Expected: capability JSON parses, the hidden dry-run worker replies, and shutdown deletes only its pair directory.

- [ ] **Step 6: Commit final regression hardening**

```powershell
git add scripts tests SKILL.md README.md
git commit -m "Harden Codex worker compatibility and recovery"
```

- [ ] **Step 7: Request final code review**

Use `superpowers:requesting-code-review` against the complete implementation diff. Address only validated issues, rerun Step 4, and report the exact verification output and any preserved pre-existing changes.
