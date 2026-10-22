-- Small helpers shared by every module: shell quoting, paths, file IO.

local M = {}

M.VERSION = "0.1.0"

function M.shquote(s)
  return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
end

-- Runs a command and returns true when it exited with status 0.
-- os.execute returns a number on Lua 5.1 and true/nil on newer versions.
function M.run(cmd)
  local a = os.execute(cmd)
  if type(a) == "number" then
    return a == 0
  end
  return a == true
end

-- Runs a command with stderr merged into stdout.
-- Returns ok, output.
function M.exec(cmd)
  local p = io.popen(cmd .. " 2>&1; echo \"__rc=$?\"", "r")
  if not p then
    return false, "could not run command"
  end
  local out = p:read("*a") or ""
  p:close()
  local rc = out:match("__rc=(%d+)%s*$")
  out = out:gsub("__rc=%d+%s*$", ""):gsub("%s+$", "")
  return rc == "0", out
end

function M.command_exists(name)
  return M.run("command -v " .. M.shquote(name) .. " >/dev/null 2>&1")
end

function M.capture(cmd)
  local p = io.popen(cmd .. " 2>/dev/null", "r")
  if not p then
    return ""
  end
  local out = p:read("*a") or ""
  p:close()
  return (out:gsub("%s+$", ""))
end

-- Current time; NOTIFYQ_NOW lets tests pin the clock.
function M.now()
  return tonumber(os.getenv("NOTIFYQ_NOW") or "") or os.time()
end

function M.home_dir()
  return os.getenv("HOME") or ""
end

-- Directory that holds the single queue shared by every invocation.
function M.data_dir()
  local override = os.getenv("NOTIFYQ_HOME")
  if override and override ~= "" then
    return override
  end
  local xdg = os.getenv("XDG_DATA_HOME")
  if xdg and xdg ~= "" then
    return xdg .. "/notifyq"
  end
  return M.home_dir() .. "/.local/share/notifyq"
end

function M.is_dir(path)
  local f = io.open(path .. "/.", "r")
  if f then
    f:close()
    return true
  end
  return false
end

function M.exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

function M.mkdir_p(path)
  if M.is_dir(path) then
    return true
  end
  return M.run("mkdir -p " .. M.shquote(path))
end

function M.read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

function M.random_hex(n)
  local f = io.open("/dev/urandom", "rb")
  if f then
    local bytes = f:read(n)
    f:close()
    if bytes and #bytes == n then
      return (bytes:gsub(".", function(c)
        return string.format("%02x", c:byte())
      end))
    end
  end
  local out = {}
  for _ = 1, n do
    out[#out + 1] = string.format("%02x", math.random(0, 255))
  end
  return table.concat(out)
end

-- Writes through a temporary file and renames it, so readers never see
-- a half-written file.
function M.write_atomic(path, content)
  local tmp = path .. ".tmp" .. M.random_hex(3)
  local f, err = io.open(tmp, "w")
  if not f then
    return nil, err
  end
  f:write(content)
  f:close()
  local ok, rerr = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return nil, rerr
  end
  return true
end

-- Lists the entry names of a directory (empty when it does not exist).
function M.list_dir(dir)
  local names = {}
  local p = io.popen("ls -1 " .. M.shquote(dir) .. " 2>/dev/null", "r")
  if not p then
    return names
  end
  for line in p:lines() do
    names[#names + 1] = line
  end
  p:close()
  return names
end

-- Turns "~/x" and relative paths into absolute ones. The scheduler runs
-- from another working directory, so stored paths must not be relative.
function M.absolute_path(path)
  if path:sub(1, 2) == "~/" then
    return M.home_dir() .. path:sub(2)
  end
  if path:sub(1, 1) == "/" then
    return path
  end
  local cwd = os.getenv("PWD") or M.capture("pwd")
  return cwd .. "/" .. path
end

function M.uname()
  return M.capture("uname -s")
end

return M
