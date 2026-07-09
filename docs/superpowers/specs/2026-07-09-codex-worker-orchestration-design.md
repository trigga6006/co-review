# Codex Worker Orchestration Design

## Purpose

Expand `co-review` from a single read-only Codex reviewer into a Claude-controlled Codex worker system. Claude must be able to discover the locally available Codex options, start multiple independent workers, choose review or implementation behavior, and vary model and reasoning based on the user's prompt.

Claude is the sole orchestrator. Every Codex process is a leaf worker with a bounded task. The system must prevent worker meshes, conflicting writes, accidental privilege expansion, and silent overwrites.

## Goals

- Give Claude an obvious command surface for discovering capabilities and managing Codex workers.
- Support persistent `review` and `workhorse` workers with independent Codex threads.
- Let Claude select models and supported reasoning levels automatically, while preserving explicit user choices.
- Allow multiple concurrent reviewers and safely isolated workhorses.
- Keep workers hidden by default, with a visible terminal only when requested.
- Preserve the existing queue, listener recovery, logs, and persistent-thread behavior.
- Retain compatibility with the existing `new-pair`, `ask`, `send`, `recv`, `list-pairs`, `ensure-pair`, and `end-pair` commands.
- Teach Claude a natural delegation workflow comparable to its native sub-agent workflow.

## Non-goals

- Codex workers do not spawn or coordinate other workers.
- Workers do not communicate laterally.
- The system does not automatically merge unreviewed parallel work.
- The system does not grant unrestricted host access by default.
- The system does not replace Claude's judgment about decomposition, review, or final verification.

## Topology

```text
User
  -> Claude (sole orchestrator)
       -> Codex reviewer (read-only leaf)
       -> Codex workhorse (single-checkout writer leaf)
       -> Codex workhorse (isolated Git-worktree writer leaf)
```

Claude owns task decomposition, worker selection, prompts, result review, integration, and user communication. Scripts enforce process state and capability boundaries. Prompts define the bounded assignment and completion contract.

## Worker Modes

### Review

- Sandbox: `read-only`.
- Concurrency: any number may inspect the same checkout.
- Expected behavior: inspect code, plans, diffs, tests, or decisions and return evidence-backed findings.
- Completion response: verdict, prioritized findings with file references, uncertainty, and recommended next actions.
- A review worker cannot be promoted to a writer within its existing thread. Claude starts a workhorse instead.

### Workhorse

- Sandbox: `workspace-write` by default.
- Concurrency: one shared-checkout writer lease per canonical working directory.
- Expected behavior: implement the bounded task, run appropriate verification, and report the result.
- Completion response: outcome, changed files, verification run and results, remaining blockers or risks.
- While a shared-checkout workhorse owns the writer lease, Claude must not edit that checkout. Claude may continue read-only inspection or orchestrate workers in other isolated directories.
- Parallel workhorses for the same repository require separate Git worktrees.

### Custom capability boundary

The worker command may expose an explicit sandbox override for advanced use. `danger-full-access` requires both an explicit user instruction and an explicit confirmation switch in the command. It is never selected from inference alone. Mode and sandbox are fixed for a worker's lifetime; start another worker to change the capability boundary.

## Capability Discovery

Add `get-capabilities.ps1`. Its JSON output is the source Claude reads before selecting options. It reports:

- Installed Codex CLI version.
- Visible models from `$CODEX_HOME/models_cache.json` or `~/.codex/models_cache.json`.
- Model slug, display name, description, priority, default reasoning, supported reasoning levels, visibility, and advertised speed tiers.
- Supported worker modes, sandbox choices, isolation choices, and window modes.
- Effective defaults and whether model data came from the live cache or fallback behavior.

Hidden/internal models are excluded unless `-IncludeHidden` is explicitly passed. Model names and reasoning levels are not hardcoded into PowerShell `ValidateSet` declarations. Runtime validation uses the discovered model metadata.

If the cache is missing or stale, the command reports that condition instead of inventing availability. Claude may use the Codex-configured default model or an explicit user-provided model. Unknown model slugs require `-AllowUnknownModel` so typos do not silently start broken workers.

## Primary Command Surface

### `get-capabilities.ps1`

Discover models and supported worker configuration. Supports human-readable output and `-Json`.

### `new-worker.ps1`

Start a named worker and return machine-readable metadata.

Core parameters:

- `-Name <label>`: short Claude-chosen role name.
- `-Task <hint>`: initial bounded responsibility.
- `-Mode review|workhorse`.
- `-ProjectCwd <path>`.
- `-Model <slug|auto|configured-default>`.
- `-Reasoning <level|auto>`.
- `-Isolation auto|shared|worktree`.
- `-WindowMode Hidden|Minimized|Foreground`; default `Hidden`.
- `-TimeoutSec <seconds>`.
- Optional advanced Codex profile, additional writable directory, search, and validated config overrides.

Claude performs task-aware routing after reading live capabilities. The script-level `auto` fallback is deliberately mechanical: choose the highest-priority visible model and that model's advertised default reasoning. Explicit user selections always win. The final resolved configuration is saved and returned to Claude.

Advanced overrides are passed as argument-array values, never evaluated as shell text. Dedicated capability fields cannot be overridden through the generic channel: model, reasoning, sandbox, working directory, output capture, thread/session selection, and `features.multi_agent` must use their guarded paths. This preserves broad Codex configurability without bypassing worker boundaries.

### `ask-worker.ps1`

Send one task and wait for its matching reply. Accepts inline text or a message file. It may override model, reasoning, and timeout for that turn after validating them against capabilities. It cannot widen sandbox permissions or change mode.

### `send-worker.ps1` and `recv-worker.ps1`

Provide asynchronous dispatch and polling for natural parallel orchestration. Replies remain correlated by message ID.

### `list-workers.ps1`

Report worker ID, name, mode, model, reasoning, status, working directory, isolation, writer-lease state, process ID, Codex thread ID, and last activity. Supports `-Json`.

### `ensure-worker.ps1`

Verify or restart a remembered background listener from saved metadata without discarding its queue or Codex thread.

### `end-worker.ps1`

Stop a worker, release its lease, and optionally archive/delete logs. An isolated worktree with unintegrated changes is retained unless the caller explicitly confirms cleanup.

### Compatibility wrappers

Existing pair-oriented scripts continue to work. They map legacy pairs to `review` workers and preserve existing pair IDs and state. The skill documentation presents worker commands first and labels pair commands as compatibility aliases.

## State Model

Continue using the existing local pair-state root to avoid breaking active installations. Extend each `pair.json` with a schema version and worker metadata:

- Worker ID and display name.
- Mode, sandbox, isolation, and window mode.
- Requested and resolved model/reasoning.
- Project root and actual worker working directory.
- Git worktree/branch metadata when isolated.
- Timeout and safe advanced overrides.
- Creation time, task hint, and Codex binary.

Legacy metadata without these fields is interpreted as schema version 1, `review`, `read-only`, and `shared`.

Queue messages may include per-turn model, reasoning, timeout, and structured task metadata. The listener validates every override before invoking Codex and records the effective configuration in the reply/log.

## Task Envelope

Every Codex turn receives a generated role envelope plus Claude's task:

- Worker identity and fixed mode.
- Leaf-agent rule: do not spawn, delegate to, or coordinate other agents.
- Exact working directory and allowed scope.
- Review or workhorse completion contract.
- Instruction to report blockers rather than broaden permissions or task scope.
- User/Claude task content.

The launch command also forces Codex's `multi_agent` feature off. The prompt is explanatory; the CLI configuration is the primary mesh guardrail.

Prompts should reference repository files rather than embedding large content when the worker can read those files. This conserves Claude context while letting Codex inspect the source directly.

## Model and Reasoning Selection

Claude reads `get-capabilities.ps1 -Json` when capabilities are not already fresh in the current conversation.

Default routing guidance:

- Respect any model, reasoning, speed, or mode named by the user.
- Prefer the highest-capability visible model for hard reviews, architecture, security, debugging, and ambiguous tasks.
- Prefer a smaller or faster visible model for bounded mechanical work when quality risk is low.
- Use the model's advertised default reasoning for ordinary tasks.
- Increase reasoning for difficult correctness/security work; reduce it for cheap checks.
- Never choose an unsupported model/reasoning combination.

The routing table is guidance rather than a frozen model list. Live capability metadata keeps the skill useful as models change.

## Concurrency and Isolation

### Shared checkout

A workhorse must atomically acquire a writer lease keyed by the canonical working directory. If another live worker owns the lease, startup fails with the current owner's metadata and suggests serial execution or worktree isolation. Stale leases may be reclaimed only after verifying that the recorded listener is dead.

### Git worktree

`-Isolation worktree` creates a dedicated branch and worktree under a managed local worktree root. Each worker receives its own directory and writer lease. The source repository must be a Git repository. If the source has uncommitted changes, automatic parallel isolation refuses by default because a new worktree would not contain those changes; Claude may serialize the work or explicitly acknowledge a clean-HEAD-only worktree.

An isolated workhorse commits its completed bounded change to its dedicated branch after verification. Claude reviews the commit and chooses whether to cherry-pick or merge it. No automatic integration occurs.

### Automatic isolation

- Review -> shared checkout.
- First workhorse for a checkout -> shared checkout with exclusive lease.
- Additional parallel workhorse for the same clean Git repository -> isolated worktree.
- Additional parallel workhorse when the source is dirty -> fail safely with an actionable serialization/worktree message.

## Listener Invocation

Keep the current PowerShell listener architecture. The window is only a process host and log surface, not the interactive Codex TUI.

For every `codex exec` call, the listener supplies:

- Effective model and reasoning.
- Fixed worker sandbox.
- Worker working directory.
- Non-interactive output and persisted Codex thread behavior.
- `features.multi_agent=false`.
- Mode-appropriate task envelope.
- Any explicitly validated optional configuration.

Background workers use a hidden window by default. `Minimized` provides a visible taskbar process. `Foreground` is available only when the user asks to watch or debug the listener. A foreground listener remains a log console; launching a separate interactive Codex TUI is an advanced/manual action and is not required for worker operation.

## Failure Handling

- Invalid model/reasoning/configuration fails before queueing work.
- Listener death triggers the existing self-healing restart path.
- Lease conflicts return the owning worker and safe alternatives.
- Worktree creation failure rolls back only resources created by that attempt.
- Codex timeout or nonzero exit produces a correlated error reply with sanitized stderr and preserves the worker for retry.
- A worker cannot silently fall back from workhorse to review or from isolated to shared.
- Cleanup never deletes a dirty or unintegrated worktree without explicit confirmation.
- Pair logs retain prompts, replies, resolved options, and lifecycle events until archived or deleted.

## Skill Documentation

Rewrite `SKILL.md` around Claude's orchestration decisions rather than the transport internals:

1. Trigger conditions covering Codex review, consultation, implementation delegation, workhorse/sub-agent requests, parallel Codex work, and explicit model/reasoning requests.
2. Quick start: discover capabilities, choose mode, start worker, dispatch, inspect, stop.
3. Mode-selection table.
4. Model/reasoning selection rules with explicit-user-choice precedence.
5. Safe concurrency and worktree rules.
6. Synchronous and asynchronous examples.
7. Result handling and disagreement protocol.
8. Recovery, logs, privacy, and cleanup.
9. Compatibility notes for old pair commands.

Update the repository README for human installation and command reference. Do not duplicate detailed transport internals in both files; `SKILL.md` remains optimized for Claude and README for the user.

## Testing Strategy

Extend the existing PowerShell regression suite using fake Codex executables and temporary repositories.

Required tests:

- Capability discovery from a model-cache fixture, including hidden models and dynamic reasoning levels.
- Missing/invalid cache behavior and unknown-model confirmation.
- Review mode invokes read-only sandbox and disables multi-agent.
- Workhorse mode invokes workspace-write and disables multi-agent.
- `danger-full-access` is rejected without explicit confirmation.
- Per-turn model/reasoning validation and override propagation.
- Multiple reviewers may share a checkout.
- A second shared workhorse is rejected without corrupting the first lease.
- Stale writer lease recovery verifies process ownership.
- Parallel workhorse worktrees use separate directories/branches.
- Dirty-source automatic isolation fails without losing user changes.
- Legacy pair metadata loads as a review worker.
- Dead-listener recovery preserves worker configuration and thread state.
- Message-file dispatch, timeout handling, and correlated replies continue working.
- Cleanup retains unintegrated isolated work.

Forward-test the finished skill with realistic Claude prompts for review-only, single-workhorse, mixed review/workhorse, explicit-model, and parallel-workhorse scenarios. Verify that Claude chooses commands correctly and does not create a worker mesh.

## Acceptance Criteria

- Claude can inspect currently available models/reasoning levels through one documented command.
- "Use Codex to review" naturally creates or reuses a read-only reviewer.
- "Use Codex as a workhorse/sub-agent" naturally creates a workspace-writing leaf worker.
- Explicit user configuration is preserved; otherwise Claude selects sensible live options.
- Claude can manage multiple named Codex workers and distinguish their replies.
- Concurrent writers cannot modify the same checkout.
- Parallel work is isolated and never auto-merged.
- Codex multi-agent spawning is disabled for workers.
- Workers recover after sleep/reboot without losing their Codex thread.
- Legacy pair commands and existing state remain usable.
- Automated regression tests and realistic skill forward-tests pass.
