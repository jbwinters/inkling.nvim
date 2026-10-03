-- Minimal async HTTP POST over curl. Headers and body go through stdin / a
-- temp file so that API keys never show up in the process list.
local M = {}

local function quote(s)
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function curl_config(url, headers, body, timeout, stream)
  local tmp = vim.fn.tempname()
  vim.fn.writefile({ vim.json.encode(body) }, tmp, "b")
  local cfg = {
    "url = " .. quote(url),
    "request = POST",
    "silent",
    "show-error",
    "max-time = " .. tostring(timeout),
    'header = "Content-Type: application/json"',
    "data-binary = " .. quote("@" .. tmp),
  }
  if stream then
    table.insert(cfg, "no-buffer")
  end
  for k, v in pairs(headers) do
    table.insert(cfg, "header = " .. quote(k .. ": " .. v))
  end
  return table.concat(cfg, "\n") .. "\n", tmp
end

-- An error body (non-streamed JSON) -> message, or nil.
local function error_message(raw)
  local ok, decoded = pcall(vim.json.decode, raw or "")
  if ok and type(decoded) == "table" and decoded.error then
    local e = decoded.error
    return type(e) == "table" and (e.message or vim.inspect(e)) or tostring(e)
  end
end

---@param cb fun(err: string|nil, resp: table|nil)
---@return vim.SystemObj
function M.post_json(url, headers, body, timeout, cb)
  local stdin, tmp = curl_config(url, headers, body, timeout, false)
  return vim.system({ "curl", "--config", "-" }, { stdin = stdin, text = true }, function(res)
    os.remove(tmp)
    if res.signal ~= 0 then
      return cb("cancelled")
    end
    if res.code ~= 0 then
      return cb(("curl exit %d: %s"):format(res.code, vim.trim(res.stderr or "")))
    end
    local ok, decoded = pcall(vim.json.decode, res.stdout)
    if not ok or type(decoded) ~= "table" then
      return cb("invalid JSON response: " .. (res.stdout or ""):sub(1, 200))
    end
    local msg = error_message(res.stdout)
    if msg then
      return cb(msg)
    end
    cb(nil, decoded)
  end)
end

-- Streamed POST: `on_line` gets each complete line of the response as it
-- arrives (SSE `data: ...` lines or NDJSON), `on_done(err)` at the end.
-- Callbacks run in a fast (libuv) context: no Neovim API calls in them.
---@return vim.SystemObj
function M.post_stream(url, headers, body, timeout, on_line, on_done)
  local stdin, tmp = curl_config(url, headers, body, timeout, true)
  local pending, raw = "", {}
  local function feed(data)
    if #raw < 50 then
      table.insert(raw, data)
    end
    pending = pending .. data
    while true do
      local nl = pending:find("\n", 1, true)
      if not nl then
        break
      end
      local line = pending:sub(1, nl - 1):gsub("\r$", "")
      pending = pending:sub(nl + 1)
      if line ~= "" then
        on_line(line)
      end
    end
  end
  return vim.system({ "curl", "--config", "-" }, {
    stdin = stdin,
    text = true,
    stdout = function(_, data)
      if data then
        feed(data)
      end
    end,
  }, function(res)
    os.remove(tmp)
    if pending ~= "" then
      on_line(pending)
      pending = ""
    end
    if res.signal ~= 0 then
      return on_done("cancelled")
    end
    if res.code ~= 0 then
      return on_done(("curl exit %d: %s"):format(res.code, vim.trim(res.stderr or "")))
    end
    on_done(error_message(table.concat(raw)))
  end)
end

return M
