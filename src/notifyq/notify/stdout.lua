-- Prints the notification instead of showing it. Used by the tests.

local M = {}

function M.send(msg)
  io.write(string.format("NOTIFY\t%s\t%s\t%s\n", msg.title, msg.subtitle or "", msg.icon or ""))
  io.flush()
  return true
end

return M
