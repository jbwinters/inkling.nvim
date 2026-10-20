-- Bounded, ignore-aware file discovery for folder and project perspectives.
local M = {}
local extensions = {}
for ext in ("lua py pyi js jsx ts tsx mjs cjs vue svelte go rs rb ex exs c h cc cpp hpp java kt kts cs swift php scala sh sql proto graphql gql yaml yml toml json md rst"):gmatch("%S+") do
  extensions[ext] = true
end
local ignored = { ".git", "node_modules", "vendor", "dist", "build", ".venv", "venv", "target", "_build", "deps" }
local entrypoints = { init = true, __init__ = true, index = true, main = true, app = true, server = true }
local function priority(path)
  local name = vim.fs.basename(path):lower()
  if entrypoints[name:match("^([^.]+)")] then return 0 end
  if name:match("^readme") or name == "package.json" or name == "pyproject.toml" or name == "cargo.toml" or name == "go.mod" then return 1 end
  return 2
end

local function spread(paths)
  local buckets = {}
  for _, path in ipairs(paths) do
    local area, tail = path:match("^([^/]+)/(.+)$")
    area = area or "."
    buckets[area] = buckets[area] or {}
    table.insert(buckets[area], tail or path)
  end
  local areas = vim.tbl_keys(buckets)
  table.sort(areas)
  for _, area in ipairs(areas) do
    if area == "." then
      table.sort(buckets[area], function(a, b)
        if priority(a) ~= priority(b) then return priority(a) < priority(b) end
        return a < b
      end)
    else buckets[area] = spread(buckets[area]) end
  end
  local ordered, index, remaining = {}, 1, true
  while remaining do
    remaining = false
    for _, area in ipairs(areas) do
      local path = buckets[area][index]
      if path then
        table.insert(ordered, (area == "." and "" or area .. "/") .. path)
        remaining = true
      end
    end
    index = index + 1
  end
  return ordered
end

function M.files(scope)
  if vim.fn.executable("rg") == 0 then return nil, "Folder and project views need ripgrep (rg)" end
  local stat = (vim.uv or vim.loop).fs_stat(scope.directory)
  if not stat or stat.type ~= "directory" then return nil, "The containing folder is no longer available" end
  local args = { "rg", "--files", "--null", "--no-messages" }
  for _, dir in ipairs(ignored) do vim.list_extend(args, { "-g", "!**/" .. dir .. "/**" }) end
  vim.list_extend(args, { "-g", "!*-lock.json", "-g", "!*.min.js", "-g", "!*.lock", "--", "." })
  local chunks, bytes, capped, process = {}, 0, false, nil
  process = vim.system(args, { cwd = scope.directory, timeout = 1000, stdout = function(_, data)
    if not data then return end
    if bytes < 262144 then
      local chunk = data:sub(1, 262144 - bytes)
      chunks[#chunks + 1], bytes = chunk, bytes + #chunk
    end
    if bytes >= 262144 then
      capped = true
      if process then pcall(process.kill, process, 15) end
    end
  end })
  local result = process:wait()
  if result.code == 2 and not capped then return nil, "Cannot enumerate this folder's source files" end
  capped = capped or result.code ~= 0 and result.code ~= 1
  local paths = {}
  for relative in table.concat(chunks):gmatch("([^%z]+)%z") do
    relative = relative:gsub("^%./", "")
    local ext = relative:match("%.([^./]+)$")
    local name = vim.fs.basename(relative)
    if extensions[ext] or name == "Makefile" or name == "Dockerfile" then
      if #paths >= 4096 then capped = true; break end
      table.insert(paths, relative)
    end
  end
  table.sort(paths)
  -- Round-robin areas at each level, preferring entry points within each area.
  local ordered = vim.tbl_map(function(path) return scope.directory .. "/" .. path end, spread(paths))
  return { paths = ordered, capped = capped, hash = vim.fn.sha256(vim.json.encode(paths)) }
end

return M
