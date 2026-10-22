-- Picks the system notification backend and sends a message through it.
--
-- NOTIFYQ_BACKEND forces a backend (macos, linux, stdout); the stdout one
-- exists for tests and debugging.

local util = require("notifyq.util")

local M = {}

local function select_backend()
  local forced = os.getenv("NOTIFYQ_BACKEND")
  if forced and forced ~= "" then
    return forced
  end
  local os_name = util.uname()
  if os_name == "Darwin" then
    return "macos"
  elseif os_name == "Linux" then
    return "linux"
  end
  return nil
end

-- Returns ok, error_message.
function M.send(msg)
  local name = select_backend()
  if not name then
    return false, "unsupported platform: " .. util.uname()
  end
  local ok, backend = pcall(require, "notifyq.notify." .. name)
  if not ok then
    return false, "unknown backend: " .. name
  end
  return backend.send(msg)
end

return M
