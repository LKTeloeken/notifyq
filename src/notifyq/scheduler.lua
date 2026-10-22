-- Fires every message whose time has come. This is the "sync" step: it
-- runs at the start of most commands and periodically from the daemon.

local queue = require("notifyq.queue")
local notify = require("notifyq.notify")
local util = require("notifyq.util")

local M = {}

local MAX_ATTEMPTS = 5
local HISTORY_MAX_AGE = 7 * 86400

-- Returns the list of messages that fired and the list that failed.
function M.tick()
  local now = util.now()
  queue.init()
  queue.recover_stale(now)

  local fired, failed = {}, {}
  for _, msg in ipairs(queue.pending()) do
    if msg.fire_at > now then
      break -- pending() is sorted, nothing later is due either
    end
    if queue.claim(msg, now) then
      local ok, err = notify.send(msg)
      if ok then
        queue.finish(msg, "fired", nil, now)
        fired[#fired + 1] = msg
      else
        msg.attempts = (msg.attempts or 0) + 1
        msg.error = err
        if msg.attempts >= MAX_ATTEMPTS then
          queue.finish(msg, "failed", err, now)
        else
          queue.release(msg)
        end
        failed[#failed + 1] = msg
      end
    end
  end

  queue.prune(now, HISTORY_MAX_AGE)
  return fired, failed
end

return M
