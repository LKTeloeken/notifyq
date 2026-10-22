-- macOS backend.
--
-- terminal-notifier is used when it is installed because it can show a
-- custom image. Otherwise we fall back to osascript, which always works
-- but cannot show a logo (the icon is always Script Editor's).

local util = require("notifyq.util")

local M = {}

local function has_text(s)
  return s ~= nil and s ~= ""
end

local function send_terminal_notifier(msg)
  local cmd = {
    "terminal-notifier",
    "-title", util.shquote(msg.title),
    -- terminal-notifier insists on a message; a space keeps the body empty.
    "-message", util.shquote(" "),
    "-group", util.shquote("notifyq-" .. msg.id),
  }
  if has_text(msg.subtitle) then
    cmd[#cmd + 1] = "-subtitle"
    cmd[#cmd + 1] = util.shquote(msg.subtitle)
  end
  if has_text(msg.icon) then
    cmd[#cmd + 1] = "-contentImage"
    cmd[#cmd + 1] = util.shquote(msg.icon)
  end
  local ok, out = util.exec(table.concat(cmd, " "))
  if not ok then
    return false, "terminal-notifier failed: " .. out
  end
  return true
end

-- The text is passed as argv instead of being spliced into the script, so
-- quotes and backslashes in titles cannot break out of the AppleScript.
local APPLESCRIPT = {
  "on run argv",
  "set theTitle to item 1 of argv",
  "set theSubtitle to item 2 of argv",
  "if theSubtitle is \"\" then",
  "display notification \" \" with title theTitle",
  "else",
  "display notification \" \" with title theTitle subtitle theSubtitle",
  "end if",
  "end run",
}

local function send_osascript(msg)
  local cmd = { "osascript" }
  for _, line in ipairs(APPLESCRIPT) do
    cmd[#cmd + 1] = "-e"
    cmd[#cmd + 1] = util.shquote(line)
  end
  cmd[#cmd + 1] = util.shquote(msg.title)
  cmd[#cmd + 1] = util.shquote(msg.subtitle or "")
  local ok, out = util.exec(table.concat(cmd, " "))
  if not ok then
    return false, "osascript failed: " .. out
  end
  return true
end

function M.send(msg)
  if util.command_exists("terminal-notifier") then
    return send_terminal_notifier(msg)
  end
  return send_osascript(msg)
end

return M
