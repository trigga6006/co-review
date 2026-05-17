---
name: co-review
description: Pair the current Claude Code session with a sibling OpenAI Codex CLI session so the two agents can ping-pong without copy-paste. Spawns a background PowerShell window (minimized) running a Codex listener, wires up file-based message passing under ~/.cc-codex-pairs/<pair-id>/, and gives Claude send/recv/ask primitives. Each Claude session that runs the skill creates its OWN sibling - multiple pairs run side-by-side. Use this skill whenever the user invokes "/co-review", says "pair with codex" or "spawn a codex sibling", OR is in a multi-turn task where they would benefit from sustained back-and-forth with Codex as reviewer - even if they don't explicitly name the skill. Specific triggers: a non-trivial refactor or implementation that wants a second opinion before shipping, debating two design approaches, working through a hard bug where outside perspective helps, or any situation where the user mentions wanting Codex to review or critique their work.
---

# co-review - Claude Code <-> Codex pair workflow

You are now in a paired-session workflow. The user wants this Claude Code session to have a dedicated OpenAI Codex CLI sibling running in a separate terminal window. The two of you exchange messages via a file-based message queue.

## When to use

**Explicit triggers** (always invoke):
- User types `/co-review` or says "pair with codex", "spawn a codex sibling", "have codex review this"
- User asks to "ask codex" mid-task and the conversation looks like it will involve more than one exchange

**Implicit triggers** (invoke proactively, even without exact phrasing):
- User finishes a non-trivial implementation, refactor, or bug fix and you sense they want a second opinion before shipping
- User is debating between two approaches and wants outside judgment
- User keeps copy-pasting between Claude Code and Codex manually — that is exactly the pain this skill removes
- User is working through a hard problem over many turns and would benefit from a sustained reviewer rather than restarting context with Codex each time

When in doubt, ask: "Want me to spin up a Codex sibling so we can ping-pong on this?" Better to offer than to silently leave them copy-pasting.

**When NOT to use:**
- Single one-shot Codex review (use the existing `codex` skill - `/codex review`, `/codex challenge`, `/codex consult` - it is faster for that)
- The user wants Claude alone, not a paired review workflow
- Simple lookups or questions that don't need a second agent

`co-review` is specifically for sustained ping-pong over many turns. The setup cost (spawning a listener window) only pays off if the user will ask Codex more than once.

## Architecture (read this once, then act)

- **Pair dir**: `~/.cc-codex-pairs/<pair-id>/` (Windows: `C:\Users\<user>\.cc-codex-pairs\<pair-id>\`)
  - `to-codex.jsonl` - messages Claude sends (one JSON per line)
  - `to-claude.jsonl` - messages Codex sends back
  - `state.json` - `{ "last_processed": "<msg-id>", "codex_session_id": "<thread-id-or-null>" }`
  - `pair.json` - `{ "pair_id", "created_at", "project_cwd", "task_hint" }`
  - `listener.pid` - PID of the spawned listener (written at startup, removed on exit)
  - `listener.log` - human-readable listener activity
  - JSONL message files retain full prompts and replies until archived or deleted
  - `shutdown` - touch file; listener exits cleanly when it sees this
- **Codex window**: a new PowerShell console window (spawned minimized by default) running `codex-listener.ps1`. It polls `to-codex.jsonl`, runs `codex exec` (or `codex exec resume <thread-id>` for follow-ups), and appends responses to `to-claude.jsonl`. The window's cwd is the *project* cwd (so Codex picks up the project's `AGENTS.md`), not the pair dir.
- **Pair ID** is the only thing you must remember inside this conversation. Pass it to every script call. Lose it and you can't reach the sibling (recover via `list-pairs.ps1`).

## Primitives - invoke via the PowerShell tool using the call operator

Use the PowerShell tool (not Bash) and call scripts with the `&` operator. **Never pass `-ExecutionPolicy Bypass`** - Claude Code's permission classifier auto-denies it. The user's CurrentUser policy (typically RemoteSigned) is sufficient for local skill scripts.

All script paths are under `~/.claude/skills/co-review/scripts/` (or the equivalent junction target).

### 1. Create a pair (start the sibling)

```powershell
& "$env:USERPROFILE\.claude\skills\co-review\scripts\new-pair.ps1" -Task "Review my refactor of the auth middleware"
```

Output (last line is JSON):

```
{"pair_id":"pair-20260516-153012-a3f1","pair_dir":"...","window_spawned":true}
```

A new PowerShell window spawns **minimized** by default - visible in the taskbar but never stealing focus or overlaying the user's other windows. Tell the user the pair ID so they can spot the right taskbar icon if they want to peek.

Optional flags:
- `-WindowMode Hidden` - listener has no visible window at all (activity still visible via `~/.cc-codex-pairs/<pair-id>/listener.log` and `list-pairs.ps1`).
- `-WindowMode Foreground` - old behavior, opens the window in the foreground. Avoid unless the user explicitly asks.
- `-CodexTimeoutSec 1800` - max seconds to let one Codex turn run before the listener kills it and returns an error.

Capture `pair_id` from the JSON line - you will need it for every other call.

### 2. Send a message and wait for the reply (most common)

```powershell
& "$env:USERPROFILE\.claude\skills\co-review\scripts\ask.ps1" -PairId "pair-20260516-153012-a3f1" -Message "Here is my diff. Review for correctness and edge cases:`n`n<diff>" -TimeoutSec 600
```

Blocks until Codex replies (or timeout). Default timeout 600s. Matching is done by `in_reply_to == msgId`, so it is race-free.

For long prompts (large diffs), use `-MessageFile <path>` instead of `-Message` to avoid command-line length limits.

### 3. Send without blocking

```powershell
& "$env:USERPROFILE\.claude\skills\co-review\scripts\send.ps1" -PairId "pair-20260516-153012-a3f1" -Message "<text>"
```

Returns the new message ID.

### 4. Poll / wait for new replies

```powershell
& "$env:USERPROFILE\.claude\skills\co-review\scripts\recv.ps1" -PairId "pair-20260516-153012-a3f1" -Since "cdx-0003" -Wait -TimeoutSec 300
```

`-Since` is the last reply ID you have already seen (omit on first call to get all). `-Wait` polls until something new arrives.

### 5. End the pair (close the Codex window cleanly)

```powershell
& "$env:USERPROFILE\.claude\skills\co-review\scripts\end-pair.ps1" -PairId "pair-20260516-153012-a3f1"
```

Use `-Archive` to move the retained pair logs under `~/.cc-codex-pairs/archive/`. Use `-Delete` to remove the retained prompts/replies after shutdown.

### 6. List active pairs (recovery)

```powershell
& "$env:USERPROFILE\.claude\skills\co-review\scripts\list-pairs.ps1"
```

Status is determined by `listener.pid` liveness, not just the shutdown file.

### 7. Purge retained logs

```powershell
& "$env:USERPROFILE\.claude\skills\co-review\scripts\purge-pair.ps1" -PairId "pair-20260516-153012-a3f1" -Force
```

Deletes a stopped pair directory permanently. This removes `to-codex.jsonl`, `to-claude.jsonl`, `state.json`, and logs.

## Operating instructions for you (Claude)

1. **Spawn at most one pair per Claude conversation.** Before calling `new-pair.ps1`, check:
   - Do you already have a `pair_id` tracked from earlier in this conversation? If yes, reuse it. Do NOT spawn another.
   - If you are unsure (e.g. long conversation, you can't find the pair_id in context), run `list-pairs.ps1` first. If there is an `active` pair whose `project_cwd` matches the user's current working directory and whose `task_hint` matches what you are doing, reuse that `pair_id` instead of spawning a new one.
   - Only call `new-pair.ps1` if no existing pair fits, or the user explicitly asks for a fresh sibling.

2. **When you do spawn**: call `new-pair.ps1` with a short `-Task` describing what you are working on. Parse the JSON output for `pair_id`. Tell the user: "Spawned Codex sibling <pair-id>." Then continue the user's task.

3. **Reuse the pair_id for every ask.** The Codex listener captures Codex's `thread_id` on its first run and uses `codex exec resume <thread-id>` for every subsequent message, so Codex sees the full conversation history on its side automatically. You do NOT need to re-spawn or re-create the pair to get continuity. If you want to verify continuity is working, look at `state.json` `codex_session_id` after the first ask - it should be populated with a thread id. If it stays null, fall back to including prior context inline in your messages.

4. **When to call Codex**:
   - After a non-trivial implementation, ask for review
   - When you are unsure between two approaches, ask for opinion
   - Before claiming a task done, ask Codex to spot what you missed
   - The user may also explicitly say "ask codex"

5. **Surfacing Codex's response to the user**: relay it, but be selective. If Codex's critique is wrong or out of scope, push back briefly and tell the user what you disagree with and why - do not blindly apply everything Codex says. Codex is a peer reviewer, not an authority.

6. **End the pair when**: user says they are done, the task is shipped, or the conversation pivots to something unrelated. Call `end-pair.ps1` to close the terminal cleanly.

## Caveats / known limitations

- The listener requires Windows PowerShell 5.1+ on Windows (no .NET Core dependencies).
- If installing from a downloaded zip or browser download, Windows may mark scripts as remote. If local execution policy blocks them, run: `Get-ChildItem "$env:USERPROFILE\.claude\skills\co-review" -Recurse | Unblock-File`
- Pair logs are local but persistent. Do not send secrets to Codex unless you are comfortable with them being stored in `~/.cc-codex-pairs/<pair-id>/` until archived or deleted.
- No real-time interrupts. If you send a message while Codex is mid-response, it will be processed after the current one finishes.
- The Codex window is a real terminal - the user can also type into it manually if they want to talk to Codex directly. Treat that as normal; the listener still processes your messages.
- One pair per Claude session. If the user explicitly wants two pairs in one Claude session, you can call `new-pair.ps1` twice and track two pair IDs - but that is unusual.
- Codex runs with `--sandbox read-only` by default, so it cannot edit files. If the user wants Codex to apply suggestions directly, they will need to relax the sandbox via `codex exec --sandbox workspace-write` - but that is currently hardcoded in the listener.
- `-CodexBin` is intended only for advanced local debugging and must point to an executable named `codex.exe` or `codex`.
