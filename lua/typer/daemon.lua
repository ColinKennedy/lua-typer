--- Daemon mode (spec §10.3), modelled on `dmypy`.
---
--- NOT the default: a bare `typer` invocation never starts one and must behave
--- identically with no daemon present.
---
--- Transport is TCP on the loopback interface with a port file, rather than the
--- Unix domain socket the spec sketched: luasocket's `socket.unix` is a
--- build-time option that many distro packages omit, while TCP is present in
--- every build and works on Windows too. The port file is written with the
--- session's own key so a stray process cannot be mistaken for ours.
---
--- Invalidation: the daemon keeps *parsed models* across checks and rebuilds
--- the type index from them each time. Re-indexing is far cheaper than
--- re-parsing, and rebuilding wholesale means a renamed or deleted `---@class`
--- can never linger in the registry -- which a reverse type->referrer map would
--- have to get exactly right to avoid.
---@class typer.daemon
local M = {}

local compat = require("typer.compat")
local fs = require("typer.fs")
local json = require("typer.json")
local check = require("typer.check")
local config_mod = require("typer.config")
local vimgrep = require("typer.report.vimgrep")
local json_report = require("typer.report.json")

local IDLE_TIMEOUT = 30 * 60

---@param config typer.Config
---@return string
local function port_file(config)
  return compat.join(config.root or ".", ".typer_cache", "daemon.port")
end

---@param config typer.Config
---@return integer|nil port
---@return string|nil token
local function read_port(config)
  local contents = compat.read_file(port_file(config))
  if not contents then return nil, nil end
  local port, token = contents:match("^(%d+)%s+(%S+)")
  return tonumber(port), token
end

--- Wire framing: a payload followed by a blank line.
---
--- The payload is pretty-printed JSON and therefore multi-line, so neither side
--- may `receive("*l")` once and call it a message -- but pretty-printed JSON
--- never contains an *empty* line, which makes one a safe terminator.
---@param socket_handle table
---@return string|nil
local function receive_message(socket_handle)
  ---@type string[]
  local pieces = {}
  while true do
    local line = socket_handle:receive("*l")
    if not line then
      return #pieces > 0 and table.concat(pieces, "\n") or nil
    end
    if line == "" then break end
    pieces[#pieces + 1] = line
  end
  return table.concat(pieces, "\n")
end

---@param socket_handle table
---@param payload table
local function send_message(socket_handle, payload)
  socket_handle:send(json.encode(payload) .. "\n\n")
end

--- Serves requests until idle timeout.
---@param args table
---@return integer
local function serve(args)
  local ok, socket = pcall(require, "socket")
  if not ok then
    io.stderr:write("typer: daemon mode needs luasocket\n")
    return 2
  end

  local cwd = fs.cwd()
  local config = config_mod.load(args.config, cwd)

  local server = assert(socket.bind("127.0.0.1", 0))
  local _, port = server:getsockname()

  local token = tostring(port) .. "-" .. tostring(os.time())
  fs.mkdir_p(compat.dirname(port_file(config)))
  compat.write_file(port_file(config), ("%s %s\n"):format(port, token))

  io.write(("typer daemon listening on 127.0.0.1:%s\n"):format(port))
  io.flush()

  ---@type table<string, table>
  local model_cache = {}
  server:settimeout(IDLE_TIMEOUT)

  while true do
    local client = server:accept()
    if not client then break end -- idle timeout

    client:settimeout(30)
    local request = receive_message(client)

    if request then
      local decoded = json.decode(request) or {}

      if decoded.command == "stop" then
        send_message(client, { ok = true, stopped = true })
        client:close()
        break
      elseif decoded.command == "status" then
        local count = 0
        for _ in pairs(model_cache) do count = count + 1 end
        send_message(client, { ok = true, port = port, cached_files = count })
      else
        local run_config = config_mod.load(decoded.config or args.config, cwd)
        for code, level in pairs(decoded.severity or {}) do
          run_config.severity[code] = level
        end

        local ok_run, diagnostics, summary = pcall(check.run, decoded.paths or {}, {
          config = run_config,
          model_cache = model_cache,
          use_cache = false,
          no_suppress = decoded.no_suppress,
        })

        if ok_run then
          send_message(client, { ok = true, diagnostics = diagnostics, summary = summary })
        else
          send_message(client, { ok = false, error = tostring(diagnostics) })
        end
      end
    end

    client:close()
    server:settimeout(IDLE_TIMEOUT)
  end

  os.remove(port_file(config))
  return 0
end

--- Sends one request to a running daemon.
---@param config typer.Config
---@param payload table
---@return table|nil
---@return string|nil
local function request(config, payload)
  local ok, socket = pcall(require, "socket")
  if not ok then return nil, "luasocket not available" end

  local port, token = read_port(config)
  if not port then return nil, "no daemon running" end

  local client, err = socket.connect("127.0.0.1", port)
  if not client then return nil, "cannot reach daemon: " .. tostring(err) end

  client:settimeout(60)
  payload.token = token
  send_message(client, payload)

  local body = receive_message(client)
  client:close()
  if not body then return nil, "no response from daemon" end

  local decoded = json.decode(body)
  if not decoded then return nil, "malformed daemon response" end
  return decoded, nil
end

---@param args table
---@return integer
function M.main(args)
  local cwd = fs.cwd()
  local config = config_mod.load(args.config, cwd)
  local command = args.daemon

  if command == "start" then
    return serve(args)

  elseif command == "stop" then
    local response, err = request(config, { command = "stop" })
    if not response then
      io.stderr:write("typer: " .. tostring(err) .. "\n")
      return 2
    end
    io.write("typer daemon stopped\n")
    return 0

  elseif command == "status" then
    local response, err = request(config, { command = "status" })
    if not response then
      io.write("typer daemon: not running (" .. tostring(err) .. ")\n")
      return 1
    end
    io.write(("typer daemon: running, %d files cached\n")
      :format(response.cached_files or 0))
    return 0

  elseif command == "check" then
    local response, err = request(config, {
      command = "check",
      paths = args.paths,
      config = args.config,
      severity = args.severity,
      no_suppress = args.no_suppress,
    })
    if not response then
      io.stderr:write("typer: " .. tostring(err) .. "\n")
      return 2
    end
    if not response.ok then
      io.stderr:write("typer: " .. tostring(response.error) .. "\n")
      return 2
    end

    local reporter = args.json and json_report or vimgrep
    io.write(reporter.render(response.diagnostics or {}, response.summary or {}))
    return #(response.diagnostics or {}) > 0 and 1 or 0
  end

  io.stderr:write("typer: unknown daemon command '" .. tostring(command) .. "'\n")
  return 2
end

return M
