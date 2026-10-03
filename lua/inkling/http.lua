-- Minimal async JSON POST over curl. Headers and body go through stdin so that
-- API keys never show up in the process list.
local M = {}

local function quote(s)
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

---@param url string
---@param headers table<string,string>
---@param body table
---@param timeout number seconds
---@param cb fun(err: string|nil, resp: table|nil)
---@return vim.SystemObj
function M.post_json(url, headers, body, timeout, cb)
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
  for k, v in pairs(headers) do
    table.insert(cfg, "header = " .. quote(k .. ": " .. v))
  end

  return vim.system({ "curl", "--config", "-" }, { stdin = table.concat(cfg, "\n") .. "\n", text = true }, function(res)
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
    if decoded.error then
      local e = decoded.error
      return cb(type(e) == "table" and (e.message or vim.inspect(e)) or tostring(e))
    end
    cb(nil, decoded)
  end)
end

return M
