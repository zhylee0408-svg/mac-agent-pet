# Discipline Companion

Discipline is a local macOS floating companion for Codex task status. It does not modify the ChatGPT/Codex application.

## State source

The primary bridge connects read-only to Codex Desktop's local IPC router. Session
files supply candidate task IDs; the bridge then uses Desktop's owner-discovery and
thread-follower protocol to subscribe to the client that actually owns each live
task. Its snapshots and patches carry `threadRuntimeStatus`, so
`waitingOnApproval` and `waitingOnUserInput` switch to Needs input without relying
on rollout-log heuristics. The menu-bar menu includes a `Bridge:` diagnostic line
showing follower discovery and the number of active and waiting tasks.

The bridge also watches `~/.codex/sessions/**/*.jsonl` for the brief Ready and
Blocked transitions, and as a fallback when Codex Desktop IPC is unavailable. It
does not display, copy, or log conversation text.

- `task_started` → Running
- approval or user-input request → Needs input
- `task_complete` → Ready for seven seconds, then Idle
- aborted, failed, or stream-error event → Blocked briefly

## Build

```bash
./build.sh
./build/Discipline.app/Contents/MacOS/Discipline --self-test
open ./build/Discipline.app
```

The menu-bar icon provides live status, Show/Hide, temporary state previews, and Quit.

## Local installation

The installed app is intentionally kept outside `/Applications`, so it does not
appear in Launchpad:

```text
~/Library/Application Support/Discipline/Discipline.app
```

The `discipline` launcher is installed in `/opt/homebrew/bin`, which is already
on the user's shell `PATH`. Running this starts the hidden app without blocking
the terminal:

```bash
discipline
```

Discipline is also registered under **System Settings → General → Login Items →
Open at Login**. The previous `/Applications` copy was moved to the Trash as a
recoverable backup during migration.

After rebuilding, update the hidden installation with:

```bash
./Scripts/update-hidden.sh
```
