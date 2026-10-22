-- Linux backend: notify-send (libnotify). It has no subtitle field, so the
-- subtitle becomes the body text.

local util = require("notifyq.util")

local M = {}

function M.send(msg)
  if not util.command_exists("notify-send") then
    return false, "notify-send not found (install libnotify)"
  end
  local cmd = { "notify-send", "-a", "notifyq" }
  if msg.icon and msg.icon ~= "" then
    cmd[#cmd + 1] = "-i"
    cmd[#cmd + 1] = util.shquote(msg.icon)
  end
  cmd[#cmd + 1] = "--"
  cmd[#cmd + 1] = util.shquote(msg.title)
  if msg.subtitle and msg.subtitle ~= "" then
    cmd[#cmd + 1] = util.shquote(msg.subtitle)
  end
  local ok, out = util.exec(table.concat(cmd, " "))
  if not ok then
    return false, "notify-send failed: " .. out
  end
  return true
end

return M
