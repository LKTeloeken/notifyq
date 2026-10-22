-- Installs the background job that runs `notifyq tick` every few seconds:
-- a LaunchAgent on macOS and a systemd user timer on Linux. There is no
-- resident process; each run syncs the queue and exits.

local util = require("notifyq.util")

local M = {}

local INTERVAL = 15
local LABEL = "com.lkteloeken.notifyq"

-- launchd and systemd start jobs with a minimal PATH.
local JOB_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

local function xml_escape(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function plist_path()
  return util.home_dir() .. "/Library/LaunchAgents/" .. LABEL .. ".plist"
end

local function mac_domain()
  return "gui/" .. util.capture("id -u")
end

local function mac_plist(lua_bin, script, log)
  return table.concat({
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    '<plist version="1.0">',
    "<dict>",
    "  <key>Label</key><string>" .. LABEL .. "</string>",
    "  <key>ProgramArguments</key>",
    "  <array>",
    "    <string>" .. xml_escape(lua_bin) .. "</string>",
    "    <string>" .. xml_escape(script) .. "</string>",
    "    <string>tick</string>",
    "  </array>",
    "  <key>StartInterval</key><integer>" .. INTERVAL .. "</integer>",
    "  <key>RunAtLoad</key><true/>",
    "  <key>EnvironmentVariables</key>",
    "  <dict><key>PATH</key><string>" .. xml_escape(JOB_PATH) .. "</string></dict>",
    "  <key>StandardErrorPath</key><string>" .. xml_escape(log) .. "</string>",
    "</dict>",
    "</plist>",
    "",
  }, "\n")
end

local function systemd_dir()
  local base = os.getenv("XDG_CONFIG_HOME")
  if not base or base == "" then
    base = util.home_dir() .. "/.config"
  end
  return base .. "/systemd/user"
end

local function systemd_service(lua_bin, script)
  return table.concat({
    "[Unit]",
    "Description=notifyq: fire due notifications",
    "",
    "[Service]",
    "Type=oneshot",
    "Environment=PATH=" .. JOB_PATH,
    "ExecStart=" .. lua_bin .. " " .. script .. " tick",
    "",
  }, "\n")
end

local function systemd_timer()
  return table.concat({
    "[Unit]",
    "Description=notifyq: run the notification queue",
    "",
    "[Timer]",
    "OnBootSec=" .. INTERVAL .. "s",
    "OnUnitActiveSec=" .. INTERVAL .. "s",
    "",
    "[Install]",
    "WantedBy=timers.target",
    "",
  }, "\n")
end

-- ctx = { script = absolute path of bin/notifyq }
function M.install(ctx)
  local lua_bin = util.capture("command -v lua")
  if lua_bin == "" then
    return nil, "could not find the lua interpreter in PATH"
  end
  local os_name = util.uname()

  if os_name == "Darwin" then
    local log = util.data_dir() .. "/daemon.log"
    util.mkdir_p(util.data_dir())
    util.mkdir_p(util.home_dir() .. "/Library/LaunchAgents")
    local ok, err = util.write_atomic(plist_path(), mac_plist(lua_bin, ctx.script, log))
    if not ok then
      return nil, err
    end
    -- Ignore bootout failures: the job may simply not be loaded yet.
    util.exec("launchctl bootout " .. mac_domain() .. "/" .. LABEL)
    local booted, out = util.exec("launchctl bootstrap " .. mac_domain() .. " " .. util.shquote(plist_path()))
    if not booted then
      return nil, "launchctl bootstrap failed: " .. out
    end
    return "installed LaunchAgent " .. plist_path()
  elseif os_name == "Linux" then
    local dir = systemd_dir()
    util.mkdir_p(dir)
    util.write_atomic(dir .. "/notifyq.service", systemd_service(lua_bin, ctx.script))
    util.write_atomic(dir .. "/notifyq.timer", systemd_timer())
    local ok, out = util.exec("systemctl --user daemon-reload && systemctl --user enable --now notifyq.timer")
    if not ok then
      return nil, "systemctl failed: " .. out
    end
    return "installed systemd user timer in " .. dir
  end
  return nil, "unsupported platform: " .. os_name
end

function M.uninstall()
  local os_name = util.uname()
  if os_name == "Darwin" then
    util.exec("launchctl bootout " .. mac_domain() .. "/" .. LABEL)
    os.remove(plist_path())
    return "removed LaunchAgent"
  elseif os_name == "Linux" then
    util.exec("systemctl --user disable --now notifyq.timer")
    local dir = systemd_dir()
    os.remove(dir .. "/notifyq.timer")
    os.remove(dir .. "/notifyq.service")
    util.exec("systemctl --user daemon-reload")
    return "removed systemd user timer"
  end
  return nil, "unsupported platform: " .. os_name
end

-- Returns a human-readable status line.
function M.status()
  local os_name = util.uname()
  if os_name == "Darwin" then
    if not util.exists(plist_path()) then
      return "not installed (run: notifyq daemon install)"
    end
    local ok = util.exec("launchctl print " .. mac_domain() .. "/" .. LABEL)
    return ok and ("running every " .. INTERVAL .. "s") or "installed but not loaded"
  elseif os_name == "Linux" then
    local ok, out = util.exec("systemctl --user is-active notifyq.timer")
    if ok then
      return "running every " .. INTERVAL .. "s"
    end
    return "not running (" .. out .. ")"
  end
  return "unsupported platform: " .. os_name
end

return M
