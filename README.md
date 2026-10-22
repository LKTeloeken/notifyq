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

Run it from a hook to be told when Claude needs you, for example in
`~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [{ "hooks": [{ "type": "command", "command": "notifyq add 'Claude needs your approval'" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "notifyq add 'Claude finished the task'" }] }]
  }
}
```

## Tests

```bash
lua tests/run.lua
```

The tests use a temporary queue and a fake backend, so they never show notifications.
