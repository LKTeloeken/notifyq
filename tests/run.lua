-- Dependency-free test runner. Usage: lua tests/run.lua
--
-- The runner re-executes itself with a throw-away NOTIFYQ_HOME and the
-- stdout backend, so tests never touch the real queue or show real
-- notifications.

local function dirname(path)
  return path:match("^(.*)/[^/]*$") or "."
end

local script = arg[0]
if script:sub(1, 1) ~= "/" then
  script = (os.getenv("PWD") or ".") .. "/" .. script
end
local root = dirname(dirname(script))

if not os.getenv("NQ_TEST_CHILD") then
  local p = io.popen("mktemp -d", "r")
  local tmp = p:read("*l")
  p:close()
  local interpreter = arg[-1] or "lua"
  local cmd = string.format(
    "NQ_TEST_CHILD=1 NOTIFYQ_HOME='%s' NOTIFYQ_BACKEND=stdout '%s' '%s'",
    tmp, interpreter, script)
  local a = os.execute(cmd)
  os.execute("rm -rf '" .. tmp .. "'")
  local ok = (a == true) or (a == 0)
  os.exit(ok and 0 or 1)
end

package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path

local util = require("notifyq.util")
local timeparse = require("notifyq.timeparse")
local queue = require("notifyq.queue")

local passed, failed = 0, 0
local current

local function test(name, fn)
  current = name
  util.run("rm -rf " .. util.shquote(util.data_dir()))
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    io.write("FAIL  ", name, "\n      ", tostring(err), "\n")
  end
end

local function eq(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label or "value", tostring(expected), tostring(actual)), 2)
  end
end

-- Runs the real CLI with a pinned clock; returns stdout+stderr and exit ok.
local function cli(args, now, extra_env)
  local env = "NOTIFYQ_NOW=" .. tostring(now) .. " " .. (extra_env or "")
  local ok, out = util.exec(env .. " '" .. root .. "/bin/notifyq' " .. args)
  return out, ok
end

local T0 = os.time({ year = 2026, month = 10, day = 22, hour = 12, min = 0, sec = 0 })

-- timeparse ---------------------------------------------------------------

test("parse_duration accepts simple and compound values", function()
  eq(timeparse.parse_duration("45"), 45)
  eq(timeparse.parse_duration("30s"), 30)
  eq(timeparse.parse_duration("5m"), 300)
  eq(timeparse.parse_duration("2h"), 7200)
  eq(timeparse.parse_duration("1d"), 86400)
  eq(timeparse.parse_duration("1h30m"), 5400)
end)

test("parse_duration rejects garbage", function()
  eq(timeparse.parse_duration("abc"), nil)
  eq(timeparse.parse_duration("5x"), nil)
  eq(timeparse.parse_duration(""), nil)
  eq(timeparse.parse_duration("0m"), nil)
end)

test("parse_at handles full dates", function()
  local t = timeparse.parse_at("2026-10-23 14:30", T0)
  eq(t, os.time({ year = 2026, month = 10, day = 23, hour = 14, min = 30, sec = 0 }))
  local with_seconds = timeparse.parse_at("2026-10-23T14:30:15", T0)
  eq(with_seconds, t + 15)
end)

test("parse_at bare time means today or tomorrow", function()
  eq(timeparse.parse_at("13:00", T0), os.time({ year = 2026, month = 10, day = 22, hour = 13, min = 0, sec = 0 }))
  eq(timeparse.parse_at("11:00", T0), os.time({ year = 2026, month = 10, day = 23, hour = 11, min = 0, sec = 0 }))
end)

test("parse_at rejects impossible dates", function()
  eq(timeparse.parse_at("2026-02-31 10:00", T0), nil)
  eq(timeparse.parse_at("25:00", T0), nil)
  eq(timeparse.parse_at("tomorrow", T0), nil)
end)

test("format_relative", function()
  eq(timeparse.format_relative(T0 + 300, T0), "in 5m")
  eq(timeparse.format_relative(T0 + 5400, T0), "in 1h 30m")
  eq(timeparse.format_relative(T0, T0), "now")
  eq(timeparse.format_relative(T0 - 120, T0), "overdue 2m")
end)

-- queue -------------------------------------------------------------------

test("messages survive a serialize/parse round trip", function()
  local nasty = "it's \"quoted\" \\ back\nsecond line — ação"
  local msg = queue.add({ title = nasty, subtitle = "a=b", created_at = T0, fire_at = T0 + 10 })
  local found = queue.find(msg.id)
  eq(found.title, nasty, "title")
  eq(found.subtitle, "a=b", "subtitle")
  eq(found.fire_at, T0 + 10, "fire_at")
end)

test("pending is sorted by fire time", function()
  queue.add({ title = "late", created_at = T0, fire_at = T0 + 100 })
  queue.add({ title = "early", created_at = T0, fire_at = T0 + 5 })
  local list = queue.pending()
  eq(list[1].title, "early")
  eq(list[2].title, "late")
end)

test("a message can only be claimed once", function()
  local msg = queue.add({ title = "x", created_at = T0, fire_at = T0 })
  eq(queue.claim(msg, T0), true, "first claim")
  eq(queue.claim(msg, T0), false, "second claim")
end)

test("stale claims are put back in the queue", function()
  local msg = queue.add({ title = "x", created_at = T0, fire_at = T0 })
  queue.claim(msg, T0)
  eq(#queue.pending(), 0, "claimed message is not pending")
  queue.recover_stale(T0 + 10)
  eq(#queue.pending(), 0, "fresh claim is left alone")
  queue.recover_stale(T0 + 1000)
  eq(#queue.pending(), 1, "stale claim restored")
end)

test("find resolves unique prefixes only", function()
  local a = queue.add({ title = "a", created_at = T0, fire_at = T0 })
  local found = queue.find(a.id:sub(1, 3))
  eq(found.id, a.id)
  eq(queue.find("zzzzzz"), nil)
end)

-- scheduler ---------------------------------------------------------------

test("tick fires only due messages", function()
  queue.add({ title = "due", created_at = T0, fire_at = T0 })
  queue.add({ title = "future", created_at = T0, fire_at = T0 + 3600 })
  -- NOTIFYQ_NOW cannot be set in-process, so go through the CLI.
  local out = cli("tick", T0)
  assert(out:find("NOTIFY\tdue", 1, true), "due message should fire: " .. out)
  assert(not out:find("future", 1, true), "future message must not fire")
  eq(#queue.pending(), 1)
  eq(queue.history()[1].status, "fired")
end)

-- end to end --------------------------------------------------------------

test("cli: add with a delay waits, then fires on a later tick", function()
  local out = cli("add Build --in 10m", T0)
  assert(out:find("in 10m", 1, true), out)
  assert(not out:find("NOTIFY", 1, true), "must not fire early: " .. out)
  out = cli("tick", T0 + 599)
  assert(not out:find("NOTIFY", 1, true), "still too early: " .. out)
  out = cli("tick", T0 + 600)
  assert(out:find("NOTIFY\tBuild", 1, true), "should fire at deadline: " .. out)
  out = cli("tick", T0 + 700)
  assert(not out:find("NOTIFY", 1, true), "must fire only once: " .. out)
end)

test("cli: add without timing fires immediately", function()
  local out = cli("add Now -s Sub", T0)
  assert(out:find("NOTIFY\tNow\tSub", 1, true), out)
end)

test("cli: overdue messages fire on the next start", function()
  cli("add Missed --in 1m", T0)
  local out = cli("list", T0 + 3 * 3600)
  assert(out:find("NOTIFY\tMissed", 1, true), "sync on start should fire it: " .. out)
end)

test("cli: shell metacharacters in the title stay literal", function()
  local title = [[it's "q" $(touch /tmp/nq-pwned) `x` \ back]]
  local out = cli("add " .. util.shquote(title), T0)
  assert(out:find("NOTIFY\t" .. title, 1, true), out)
  eq(util.exists("/tmp/nq-pwned"), false, "command substitution must not run")
end)

test("cli: only the title is required", function()
  local _, ok = cli("add", T0)
  eq(ok, false, "no title")
  local _, ok2 = cli("add Hi --in 1m --at 13:00", T0)
  eq(ok2, false, "--in and --at together")
  local _, ok3 = cli("add Hi --icon /does/not/exist.png", T0)
  eq(ok3, false, "missing icon")
end)

test("cli: rm and clear", function()
  local out = cli("add One --in 5m", T0)
  local id = out:match("^(%x+)")
  cli("add Two --in 5m", T0)
  out = cli("rm " .. id, T0)
  assert(out:find("removed " .. id, 1, true), out)
  eq(#queue.pending(), 1)
  cli("clear", T0)
  eq(#queue.pending(), 0)
end)

test("cli: the queue is shared across working directories", function()
  local _ = cli("add Shared --in 5m", T0)
  local ok, out = util.exec("cd / && NOTIFYQ_NOW=" .. T0 .. " '" .. root .. "/bin/notifyq' list")
  assert(ok and out:find("Shared", 1, true), out)
end)

test("cli: failing backend retries, then gives up", function()
  local env = "NOTIFYQ_BACKEND=missing"
  cli("add Broken", T0, env)
  eq(#queue.pending(), 1, "kept for retry")
  for i = 1, 4 do
    cli("tick", T0 + i, env)
  end
  eq(#queue.pending(), 0, "given up after max attempts")
  eq(queue.history()[1].status, "failed")
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
