# notifyq

A single notification queue for the terminal, written in Lua with no dependencies.

Queue messages from anywhere, optionally with a delay or a date, and get a native
system notification when they are due. Works on macOS and Linux.

## Install

Requires `lua` (5.1 or newer, or LuaJIT).

```bash
./install.sh            # links bin/notifyq into ~/.local/bin
notifyq daemon install  # background job that fires scheduled messages
```

## Usage

```bash
notifyq add "Build finished"                         # fires right away
notifyq add "Standup" -s "Room 3" --in 15m           # after a delay
notifyq add "Deploy" --at 18:30                      # today (or tomorrow if past)
notifyq add "Release" --at "2026-11-01 09:00" -i ~/logo.png

notifyq list            # pending messages
notifyq list --all      # plus fired history
notifyq rm a1b2c3       # remove by id (a unique prefix is enough)
notifyq clear           # remove every pending message
notifyq tick            # fire everything that is due
notifyq daemon status
```

Only the title is required. Durations accept `30s`, `5m`, `2h`, `1d` and
combinations such as `1h30m`.

## How it works

- **One queue.** Every message is a small file in `~/.local/share/notifyq/queue`
  (override with `NOTIFYQ_HOME`), so the queue is the same wherever you run the command.
- **Sync on start.** Most commands first run a `tick`: anything already due fires, so
  messages missed while the machine slept or was off show up as soon as `notifyq` runs.
- **Background job.** `notifyq daemon install` registers a LaunchAgent (macOS) or a
  systemd user timer (Linux) that runs `notifyq tick` every 15 seconds. There is no
  resident process.
- **No double firing.** A message is claimed with an atomic `rename`, so concurrent
  runs never fire the same message twice. Claims left by a crashed run are recovered.
- **Retries.** If the system notifier fails, the message stays queued and is retried,
  and recorded as `failed` after 5 attempts. Fired messages are kept in history for 7 days.

## Backends

| Platform | Tool | Subtitle | Logo |
| --- | --- | --- | --- |
| macOS | `terminal-notifier` if installed, else `osascript` | yes | only with `terminal-notifier` |
| Linux | `notify-send` | shown as the body | yes |

`osascript` cannot show a custom image, so on macOS the logo is ignored until
`terminal-notifier` is installed (`brew install terminal-notifier`); notifyq picks it
up automatically.

## Use it from Claude Code

There are two ways to get notified by Claude Code. Pick one, or combine them.

### Option 1: instructions in `CLAUDE.md` (notify only when it matters)

Tell Claude about the tool and when to use it. It will run `notifyq` on its own,
for example when you ask it to watch a pipeline and tell you when it finishes,
instead of notifying after every reply.

Add this to `~/.claude/CLAUDE.md` (all projects) or to a project's `CLAUDE.md`:

```markdown
## Notifications (notifyq)
- The `notifyq` command shows a system notification:
  `notifyq add "Title" -s "Subtitle" [--in 10m | --at 18:30]`. Only the title is required.
- Use it **only** when I explicitly ask to be notified ("tell me when it finishes",
  "watch the pipeline and notify me") or when I stepped away and you are waiting on
  something long that I asked you to follow. Do not notify at the end of every reply.
- To follow something (pipeline, deploy, build), poll it or use a background monitor and
  run `notifyq add` when the result is known, whether it succeeded or failed. Put the
  result in the title (e.g. "Pipeline failed") and the project or job name in the subtitle.
- If you need a decision from me and I am away, notify me before you wait.
```

Then allow the command so Claude does not ask for approval each time, in
`~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": ["Bash(notifyq add:*)"]
  }
}
```

Claude can only notify while its session is running, and this does not cover tool
permission prompts, because Claude is paused while it waits for your answer. Use
Option 2 for those.

### Option 2: hooks (automatic)

Hooks run `notifyq` without Claude having to decide anything. `Notification` fires
when Claude needs permission or is waiting for you, and `Stop` fires every time
Claude finishes a reply, so it can be noisy. Add them to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [{ "hooks": [{ "type": "command", "command": "notifyq add 'Claude needs you'" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "notifyq add 'Claude finished'" }] }]
  }
}
```

Keep only `Notification` if you want to hear about approvals but not every reply.

## Tests

```bash
lua tests/run.lua
```

The tests use a temporary queue and a fake backend, so they never show notifications.

## License

MIT, see [LICENSE](LICENSE).
