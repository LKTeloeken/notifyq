-- Parsing and formatting of durations ("1h30m") and clock times.

local M = {}

local UNIT_SECONDS = { s = 1, m = 60, h = 3600, d = 86400, w = 604800 }

-- "90" (seconds), "30s", "5m", "2h", "1d", "1h30m" -> seconds
function M.parse_duration(text)
  if not text or text == "" then
    return nil, "empty duration"
  end
  local s = text:lower():gsub("%s+", "")
  if s:match("^%d+$") then
    return tonumber(s)
  end
  local total, pos = 0, 1
  while pos <= #s do
    local num, unit, stop = s:match("^(%d+)([smhdw])()", pos)
    if not num then
      return nil, "invalid duration: " .. text
    end
    total = total + tonumber(num) * UNIT_SECONDS[unit]
    pos = stop
  end
  if total <= 0 then
    return nil, "duration must be greater than zero"
  end
  return total
end

local function build_time(y, mo, d, h, mi, sec)
  local t = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = sec })
  if not t then
    return nil
  end
  -- os.time normalizes overflows (Feb 31 -> Mar 3), so check the round trip.
  local back = os.date("*t", t)
  if back.year ~= y or back.month ~= mo or back.day ~= d or back.hour ~= h or back.min ~= mi then
    return nil
  end
  return t
end

-- "YYYY-MM-DD HH:MM[:SS]", "YYYY-MM-DDTHH:MM[:SS]" or "HH:MM[:SS]" -> epoch.
-- A bare time means today, or tomorrow when it has already passed.
function M.parse_at(text, now)
  if not text or text == "" then
    return nil, "empty time"
  end
  local s = text:gsub("^%s+", ""):gsub("%s+$", "")

  local y, mo, d, h, mi, sec = s:match("^(%d%d%d%d)-(%d%d?)-(%d%d?)[ T](%d%d?):(%d%d):?(%d*)$")
  if y then
    local t = build_time(tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(sec) or 0)
    if not t then
      return nil, "invalid date or time: " .. text
    end
    return t
  end

  h, mi, sec = s:match("^(%d%d?):(%d%d):?(%d*)$")
  if h then
    local today = os.date("*t", now)
    local t = build_time(today.year, today.month, today.day, tonumber(h), tonumber(mi), tonumber(sec) or 0)
    if not t then
      return nil, "invalid time: " .. text
    end
    if t <= now then
      local tomorrow = os.date("*t", now + 86400)
      t = build_time(tomorrow.year, tomorrow.month, tomorrow.day, tonumber(h), tonumber(mi), tonumber(sec) or 0)
    end
    return t
  end

  return nil, "invalid time (use YYYY-MM-DD HH:MM or HH:MM): " .. text
end

function M.format_time(epoch)
  return os.date("%Y-%m-%d %H:%M:%S", epoch)
end

-- 5400 -> "1h 30m"; keeps at most the two largest units.
function M.format_duration(secs)
  secs = math.max(0, math.floor(secs))
  if secs < 60 then
    return secs .. "s"
  end
  local parts = {}
  local units = { { "d", 86400 }, { "h", 3600 }, { "m", 60 } }
  for _, u in ipairs(units) do
    local n = math.floor(secs / u[2])
    if n > 0 then
      parts[#parts + 1] = n .. u[1]
      secs = secs - n * u[2]
    end
    if #parts == 2 then
      break
    end
  end
  return table.concat(parts, " ")
end

-- Relative description of a fire time: "in 5m", "now", "overdue 2m".
function M.format_relative(epoch, now)
  local delta = epoch - now
  if delta <= 0 then
    if delta > -5 then
      return "now"
    end
    return "overdue " .. M.format_duration(-delta)
  end
  return "in " .. M.format_duration(delta)
end

return M
