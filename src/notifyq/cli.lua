-- Command line interface: argument parsing and the user-facing commands.

local util = require("notifyq.util")
local timeparse = require("notifyq.timeparse")
local queue = require("notifyq.queue")
local scheduler = require("notifyq.scheduler")
local daemon = require("notifyq.daemon")

local M = {}

local USAGE = [[
notifyq - a single notification queue for your terminal

Usage:
  notifyq add <title> [options]     queue a notification (fires now by default)
  notifyq list [--all]              show pending messages (--all adds history)
  notifyq rm <id>                   remove a pending message
  notifyq clear [--all]             remove all pending messages (--all: history too)
  notifyq tick                      fire everything that is due
  notifyq daemon install|uninstall|status
  notifyq help | version

Options for add:
  -s, --subtitle <text>   second line of the notification
  -i, --icon <path>       logo image (shown where the system supports it)
      --in <duration>     fire after a delay: 30s, 5m, 2h, 1d, 1h30m
      --at <time>         fire at "YYYY-MM-DD HH:MM" or "HH:MM"

Environment:
  NOTIFYQ_HOME            queue directory (default ~/.local/share/notifyq)
]]

local OPTIONS = {
  s = { name = "subtitle", value = true },
  subtitle = { name = "subtitle", value = true },
  i = { name = "icon", value = true },
  icon = { name = "icon", value = true },
  ["in"] = { name = "in", value = true },
  at = { name = "at", value = true },
  all = { name = "all", value = false },
  v = { name = "verbose", value = false },
  verbose = { name = "verbose", value = false },
}

-- Splits argv into positional arguments and a table of options.
local function parse_args(argv)
  local positional, opts = {}, {}
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--" then
      for j = i + 1, #argv do
        positional[#positional + 1] = argv[j]
      end
      break
    end
    local key, inline = a:match("^%-%-([%w%-]+)=(.*)$")
    if not key then
      key = a:match("^%-%-([%w%-]+)$") or a:match("^%-([%w])$")
    end
    if key then
      local spec = OPTIONS[key]
      if not spec then
        return nil, "unknown option: " .. a
      end
      if spec.value then
        local v = inline
        if v == nil then
          i = i + 1
          v = argv[i]
        end
        if v == nil then
          return nil, "option needs a value: " .. a
        end
        opts[spec.name] = v
      else
        opts[spec.name] = true
      end
    else
      positional[#positional + 1] = a
    end
    i = i + 1
  end
  return positional, opts
end

local function say(...)
  io.stdout:write(string.format(...), "\n")
end

local function warn(...)
  io.stderr:write("notifyq: ", string.format(...), "\n")
end

local function report_tick(fired, failed, verbose)
  for _, msg in ipairs(failed) do
    warn("could not notify %q: %s", msg.title, tostring(msg.error))
  end
  if verbose then
    say("fired %d message(s)", #fired)
  end
end

local function sync(verbose)
  local fired, failed = scheduler.tick()
  report_tick(fired, failed, verbose)
end

local function cmd_add(argv)
  local pos, opts = parse_args(argv)
  if not pos then
    return nil, opts
  end
  if #pos == 0 then
    return nil, "a title is required: notifyq add <title>"
  end
  if #pos > 1 then
    return nil, "too many arguments (quote the title if it has spaces)"
  end
  if opts["in"] and opts.at then
    return nil, "use either --in or --at, not both"
  end

  local now = util.now()
  local fire_at = now
  if opts["in"] then
    local secs, err = timeparse.parse_duration(opts["in"])
    if not secs then
      return nil, err
    end
    fire_at = now + secs
  elseif opts.at then
    local t, err = timeparse.parse_at(opts.at, now)
    if not t then
      return nil, err
    end
    fire_at = t
  end

  local icon
  if opts.icon then
    icon = util.absolute_path(opts.icon)
    if not util.exists(icon) then
      return nil, "icon file not found: " .. icon
    end
  end

  local msg, err = queue.add({
    title = pos[1],
    subtitle = opts.subtitle,
    icon = icon,
    created_at = now,
    fire_at = fire_at,
  })
  if not msg then
    return nil, err
  end

  if fire_at <= now then
    say("%s  firing now", msg.id)
  else
    say("%s  %s (%s)", msg.id, timeparse.format_time(fire_at), timeparse.format_relative(fire_at, now))
  end
  sync(false)
  return true
end

local function truncate(s, n)
  if #s <= n then
    return s
  end
  -- Back up to a character boundary so UTF-8 sequences are not cut in half.
  local cut = n - 1
  while cut > 0 do
    local b = s:byte(cut + 1)
    if b < 0x80 or b >= 0xC0 then
      break
    end
    cut = cut - 1
  end
  return s:sub(1, cut) .. "…"
end

local function describe(msg)
  local text = msg.title:gsub("\n", " ")
  if msg.subtitle then
    text = text .. " — " .. msg.subtitle:gsub("\n", " ")
  end
  return truncate(text, 70)
end

local function cmd_list(argv)
  local pos, opts = parse_args(argv)
  if not pos then
    return nil, opts
  end
  sync(false)
  local now = util.now()
  local pending = queue.pending()

  if #pending == 0 then
    say("no pending messages")
  else
    say("%-7s %-19s %-14s %s", "ID", "WHEN", "IN", "MESSAGE")
    for _, msg in ipairs(pending) do
      say("%-7s %-19s %-14s %s", msg.id, timeparse.format_time(msg.fire_at),
        timeparse.format_relative(msg.fire_at, now), describe(msg))
    end
  end

  if opts.all then
    local history = queue.history()
    say("")
    if #history == 0 then
      say("history is empty")
    else
      say("%-7s %-19s %-8s %s", "ID", "FIRED", "STATUS", "MESSAGE")
      for _, msg in ipairs(history) do
        say("%-7s %-19s %-8s %s", msg.id, timeparse.format_time(msg.fired_at or msg.fire_at),
          msg.status or "?", describe(msg))
      end
    end
  end
  return true
end

local function cmd_rm(argv)
  local pos, err = parse_args(argv)
  if not pos then
    return nil, err
  end
  if #pos == 0 then
    return nil, "an id is required: notifyq rm <id>"
  end
  for _, prefix in ipairs(pos) do
    local msg, ferr = queue.find(prefix)
    if not msg then
      return nil, ferr
    end
    queue.remove(msg)
    say("removed %s  %s", msg.id, describe(msg))
  end
  return true
end

local function cmd_clear(argv)
  local pos, opts = parse_args(argv)
  if not pos then
    return nil, opts
  end
  local removed = queue.clear_pending()
  say("removed %d pending message(s)", removed)
  if opts.all then
    say("removed %d history entr(ies)", queue.clear_history())
  end
  return true
end

local function cmd_tick(argv)
  local pos, opts = parse_args(argv)
  if not pos then
    return nil, opts
  end
  sync(opts.verbose)
  return true
end

local function cmd_daemon(argv, ctx)
  local action = argv[1]
  if action == "install" then
    local msg, err = daemon.install(ctx)
    if not msg then
      return nil, err
    end
    say("%s", msg)
  elseif action == "uninstall" then
    local msg, err = daemon.uninstall()
    if not msg then
      return nil, err
    end
    say("%s", msg)
  elseif action == "status" then
    say("%s", daemon.status())
  else
    return nil, "usage: notifyq daemon install|uninstall|status"
  end
  return true
end

local COMMANDS = {
  add = cmd_add,
  list = cmd_list,
  ls = cmd_list,
  rm = cmd_rm,
  remove = cmd_rm,
  clear = cmd_clear,
  tick = cmd_tick,
  daemon = cmd_daemon,
}

-- ctx = { script = absolute path to bin/notifyq }. Returns a process exit code.
function M.main(argv, ctx)
  local command = argv[1]
  if command == nil or command == "help" or command == "-h" or command == "--help" then
    io.stdout:write(USAGE)
    return command == nil and 1 or 0
  end
  if command == "version" or command == "--version" then
    say("notifyq %s", util.VERSION)
    return 0
  end

  local handler = COMMANDS[command]
  if not handler then
    warn("unknown command: %s (try: notifyq help)", command)
    return 1
  end

  local rest = {}
  for i = 2, #argv do
    rest[#rest + 1] = argv[i]
  end
  local ok, err = handler(rest, ctx)
  if not ok then
    warn("%s", err)
    return 1
  end
  return 0
end

return M
