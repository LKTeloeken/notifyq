-- On-disk queue. Each message is one small key=value file:
--
--   queue/<id>.msg      waiting to fire
--   queue/<id>.firing   claimed by a running process
--   history/<id>.msg    already fired (or given up on)
--
-- Claiming a message is a single rename(2), so two processes can never
-- fire the same message and no global lock is needed.

local util = require("notifyq.util")

local M = {}

local STALE_CLAIM_SECONDS = 60
local NUMERIC = { created_at = true, fire_at = true, fired_at = true, claimed_at = true, attempts = true }

local function dirs()
  local root = util.data_dir()
  return { root = root, queue = root .. "/queue", history = root .. "/history" }
end

function M.paths()
  return dirs()
end

function M.init()
  local d = dirs()
  util.mkdir_p(d.queue)
  util.mkdir_p(d.history)
  return d
end

local function escape(v)
  return (tostring(v):gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\r", ""))
end

local function unescape(v)
  return (v:gsub("\\(.)", function(c)
    if c == "n" then
      return "\n"
    end
    return c
  end))
end

local KEY_ORDER = {
  "id", "title", "subtitle", "icon", "created_at", "fire_at",
  "claimed_at", "fired_at", "status", "attempts", "error",
}

function M.serialize(msg)
  local lines = {}
  for _, key in ipairs(KEY_ORDER) do
    local v = msg[key]
    if v ~= nil and v ~= "" then
      lines[#lines + 1] = key .. "=" .. escape(v)
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

function M.parse(text)
  local msg = {}
  for line in text:gmatch("[^\n]+") do
    local key, value = line:match("^([%w_]+)=(.*)$")
    if key then
      value = unescape(value)
      msg[key] = NUMERIC[key] and tonumber(value) or value
    end
  end
  if not msg.id or not msg.title then
    return nil
  end
  return msg
end

local function load(path)
  local text = util.read_file(path)
  return text and M.parse(text) or nil
end

local function sorted_by(list, cmp)
  table.sort(list, cmp)
  return list
end

local function load_dir(dir, suffix)
  local out = {}
  for _, name in ipairs(util.list_dir(dir)) do
    if name:sub(-#suffix) == suffix then
      local msg = load(dir .. "/" .. name)
      if msg then
        out[#out + 1] = msg
      end
    end
  end
  return out
end

function M.new_id()
  local d = dirs()
  for _ = 1, 20 do
    local id = util.random_hex(3)
    if not util.exists(d.queue .. "/" .. id .. ".msg")
      and not util.exists(d.queue .. "/" .. id .. ".firing")
      and not util.exists(d.history .. "/" .. id .. ".msg") then
      return id
    end
  end
  return util.random_hex(6)
end

function M.add(fields)
  local d = M.init()
  local msg = {
    id = M.new_id(),
    title = fields.title,
    subtitle = fields.subtitle,
    icon = fields.icon,
    created_at = fields.created_at,
    fire_at = fields.fire_at,
  }
  local ok, err = util.write_atomic(d.queue .. "/" .. msg.id .. ".msg", M.serialize(msg))
  if not ok then
    return nil, "could not write queue file: " .. tostring(err)
  end
  return msg
end

-- Waiting messages, earliest first.
function M.pending()
  local d = dirs()
  return sorted_by(load_dir(d.queue, ".msg"), function(a, b)
    if a.fire_at ~= b.fire_at then
      return a.fire_at < b.fire_at
    end
    if a.created_at ~= b.created_at then
      return (a.created_at or 0) < (b.created_at or 0)
    end
    return a.id < b.id
  end)
end

-- Fired messages, most recent first.
function M.history()
  local d = dirs()
  return sorted_by(load_dir(d.history, ".msg"), function(a, b)
    return (a.fired_at or 0) > (b.fired_at or 0)
  end)
end

-- Finds a pending message by id or unique id prefix.
function M.find(prefix)
  local matches = {}
  for _, msg in ipairs(M.pending()) do
    if msg.id == prefix then
      return msg
    end
    if msg.id:sub(1, #prefix) == prefix then
      matches[#matches + 1] = msg
    end
  end
  if #matches == 1 then
    return matches[1]
  end
  if #matches > 1 then
    return nil, "id prefix is ambiguous: " .. prefix
  end
  return nil, "no pending message with id: " .. prefix
end

function M.remove(msg)
  local d = dirs()
  local ok = os.remove(d.queue .. "/" .. msg.id .. ".msg")
  return ok ~= nil
end

-- Atomically takes ownership of a message. Returns false when another
-- process got there first.
function M.claim(msg, now)
  local d = dirs()
  local from = d.queue .. "/" .. msg.id .. ".msg"
  local to = d.queue .. "/" .. msg.id .. ".firing"
  if not os.rename(from, to) then
    return false
  end
  msg.claimed_at = now
  util.write_atomic(to, M.serialize(msg))
  return true
end

-- Moves a claimed message into history.
function M.finish(msg, status, err, now)
  local d = dirs()
  msg.status = status
  msg.error = err
  msg.fired_at = now
  msg.claimed_at = nil
  util.write_atomic(d.history .. "/" .. msg.id .. ".msg", M.serialize(msg))
  os.remove(d.queue .. "/" .. msg.id .. ".firing")
end

-- Puts a claimed message back so a later tick retries it.
function M.release(msg)
  local d = dirs()
  msg.claimed_at = nil
  util.write_atomic(d.queue .. "/" .. msg.id .. ".msg", M.serialize(msg))
  os.remove(d.queue .. "/" .. msg.id .. ".firing")
end

-- Restores claims left behind by a process that died mid-fire.
function M.recover_stale(now)
  local d = dirs()
  for _, name in ipairs(util.list_dir(d.queue)) do
    if name:sub(-7) == ".firing" then
      local path = d.queue .. "/" .. name
      local msg = load(path)
      if not msg then
        os.remove(path)
      elseif not msg.claimed_at then
        -- Claimed but not stamped yet: give it a grace period.
        msg.claimed_at = now
        util.write_atomic(path, M.serialize(msg))
      elseif now - msg.claimed_at > STALE_CLAIM_SECONDS then
        M.release(msg)
      end
    end
  end
end

-- Deletes history older than max_age seconds.
function M.prune(now, max_age)
  local d = dirs()
  for _, msg in ipairs(M.history()) do
    if msg.fired_at and now - msg.fired_at > max_age then
      os.remove(d.history .. "/" .. msg.id .. ".msg")
    end
  end
end

-- Removes every pending message. Returns how many were removed.
function M.clear_pending()
  local count = 0
  for _, msg in ipairs(M.pending()) do
    if M.remove(msg) then
      count = count + 1
    end
  end
  return count
end

function M.clear_history()
  local d = dirs()
  local count = 0
  for _, msg in ipairs(M.history()) do
    if os.remove(d.history .. "/" .. msg.id .. ".msg") then
      count = count + 1
    end
  end
  return count
end

return M
