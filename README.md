# co-review

**Pair Claude Code with a sibling OpenAI Codex CLI session. No copy-paste.**

A [Claude Code skill](https://docs.claude.com/en/docs/claude-code/skills) that wires up file-based message passing between your active Claude Code conversation and a dedicated Codex CLI listener running in the background. Type `/co-review` and Claude can `ask` Codex for reviews, second opinions, or adversarial critique - and pipe the responses back into the conversation - without you ever touching the clipboard.

Built for the workflow where you drive on Opus and want Codex as a second pair of eyes on major outputs.

---

## Why

If you already run Opus + Codex as a review duo, you know the pain: copy diff out of Claude Code, switch windows, paste into Codex, wait, copy Codex's review back, switch windows, paste into Claude Code, watch Claude refine, ask Codex again. Ten times per task.

co-review replaces all of that with one command. Claude sends to Codex over a local file queue, Codex's reply gets surfaced in the same Claude conversation, and the Codex thread is preserved across asks so it remembers your prior turns. One Claude session pairs with one Codex sibling for the life of the conversation.

## How it works

```
Claude Code session       ~/.cc-codex-pairs/pair-xxx/      Background powershell window
-----------------         --------------------------       ------------------------------
   /co-review                 to-codex.jsonl  <--------       codex-listener.ps1
   ask.ps1     --------->                                     polls inbox
                            to-claude.jsonl <--------         runs `codex exec resume <id>`
   <----- reply             state.json                        writes reply
                            listener.pid
                            listener.log
```

- One pair = one directory under `~/.cc-codex-pairs/` keyed by a unique `pair_id`.
- Messages flow through two append-only JSONL files (`to-codex` / `to-claude`).
- The listener captures Codex's `thread_id` on the first call and uses `codex exec resume <thread-id>` for every follow-up - so Codex sees the full history without you re-sending context.
- Per Claude Code session: one pair, one Codex thread, full continuity.

## Install

Requires Windows + PowerShell 5.1+ + [Claude Code](https://claude.com/claude-code) + [OpenAI Codex CLI](https://github.com/openai/codex).

Clone the repo directly into your Claude Code skills directory:

```cmd
git clone https://github.com/trigga6006/co-review.git "%USERPROFILE%\.claude\skills\co-review"
```

Then **restart Claude Code** (or open a fresh conversation) so it picks up the new skill. Type `/co` in any conversation and `/co-review` should autocomplete.

### Updating later

```cmd
cd "%USERPROFILE%\.claude\skills\co-review" && git pull
```

### If you downloaded a zip instead of cloning

Windows marks downloaded files as remote, which PowerShell's execution policy may block. Run once after extracting:

```powershell
Get-ChildItem "$env:USERPROFILE\.claude\skills\co-review" -Recurse | Unblock-File
```

### Dev install (optional)

If you want to hack on the skill while keeping the source somewhere else and have edits reflect live, clone wherever you like and junction it in:

```cmd
git clone https://github.com/trigga6006/co-review.git C:\your\dev\path\co-review
mklink /J "%USERPROFILE%\.claude\skills\co-review" "C:\your\dev\path\co-review"
```

No admin needed for the junction.

## Use

In any Claude Code conversation:

> Pair with Codex and have it review the auth middleware refactor I just wrote.

Claude will:
1. Spawn a minimized PowerShell window running the Codex listener.
2. Send your diff + ask through the file queue.
3. Surface Codex's reply inline in the same conversation.
4. Reuse the same Codex thread for every follow-up ask.

Tell Claude things like:
- "Ask Codex if there's a simpler approach."
- "Send the diff to Codex for review."
- "Have Codex challenge that design - try to break it."
- "When you're done with this task, end the pair."

## Architecture (one-screen version)

| File | Purpose |
|---|---|
| `SKILL.md` | The instructions Claude reads when `/co-review` is invoked. |
| `scripts/new-pair.ps1` | Generate pair id, spawn the listener window. |
| `scripts/codex-listener.ps1` | Background loop: poll inbox, run `codex exec`, write reply. |
| `scripts/ask.ps1` | Send a message and block for the matching reply. |
| `scripts/send.ps1` / `recv.ps1` | Async primitives if you want fire-and-forget. |
| `scripts/end-pair.ps1` | Graceful shutdown (with optional `-Archive` / `-Delete`). |
| `scripts/purge-pair.ps1` | Permanent removal with liveness safety check. |
| `scripts/list-pairs.ps1` | Recovery / debugging - shows all pairs with status. |
| `scripts/common.ps1` | Shared validators (path-traversal guard, codex bin guard). |
| `tests/co-review-tests.ps1` | Regression suite. |

## Multiple pairs

Each Claude Code conversation that runs `/co-review` gets **its own** pair_id and Codex sibling. Two parallel Claude conversations = two listeners = two Codex threads, fully isolated. The skill explicitly forbids re-spawning within a single conversation, so you never end up with a swarm.

Run `& "$env:USERPROFILE\.claude\skills\co-review\scripts\list-pairs.ps1"` to see what's running.

## Privacy / data retention

Every prompt and reply is kept on disk in `~/.cc-codex-pairs/<pair-id>/` until you call `end-pair.ps1 -Delete` or `purge-pair.ps1`. Don't send Codex anything you wouldn't want sitting in your home directory.

## Tests

```powershell
& ".\tests\co-review-tests.ps1"
```

Covers path-traversal validation, archive-flag guards, purge behavior, and listener timeout enforcement (including a compiled fake-codex that hangs intentionally).

## License

MIT. See [LICENSE](LICENSE).
