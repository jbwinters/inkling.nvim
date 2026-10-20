-- Bounded source snapshots and evidence. All paths are project-relative and
-- resolved before reading, including symlinks. Unsaved buffers take precedence.
local config = require("inkling.config")
local project = require("inkling.context.project")
local outline = require("inkling.context.outline")
local imports = require("inkling.context.imports")
local uv = vim.uv or vim.loop
local M = {}
local scopes = {}
local MAX_BYTES = 300 * 1024

local function inside(root, path)
  return path:sub(1, #root + 1) == root .. "/"
end

function M.path(root, relative)
  if type(relative) ~= "string" or relative == "" or relative:find("[%z\r\n]") then
    return nil
  end
  local base = uv.fs_realpath(root) or vim.fs.normalize(root)
  local path = vim.fs.normalize(relative:sub(1, 1) == "/" and relative or (base .. "/" .. relative))
  if not inside(base, path) then
    return nil
  end
  -- Existing files use realpath. New unsaved files must have a real parent.
  local real = uv.fs_realpath(path)
  if not real then
    local parent = uv.fs_realpath(vim.fs.dirname(path))
    real = parent and (parent .. "/" .. vim.fs.basename(path))
  end
  return real and inside(base, real) and real or nil
end

function M.read(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == "" then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" and (uv.fs_realpath(name) or vim.fs.normalize(name)) == path then
        local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        local text = table.concat(lines, "\n")
        if #text <= MAX_BYTES then
          return lines, vim.fn.sha256(text), b
        end
        return nil
      end
    end
  end
  local st = uv.fs_stat(path)
  if not st or st.type ~= "file" or st.size > MAX_BYTES then
    return nil
  end
  local fd = io.open(path, "rb")
  if not fd then return nil end
  local text = fd:read("*a")
  fd:close()
  if text:find("\0", 1, true) then return nil end
  text = text:gsub("\r\n", "\n"):gsub("\n$", "")
  return vim.split(text, "\n", { plain = true }), vim.fn.sha256(text)
end

function M.eligible(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= ""
    and not vim.b[buf].inkling_disabled
    and not vim.tbl_contains(config.options.disabled_filetypes, vim.bo[buf].filetype)
end

local function functions(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if scopes[buf] and scopes[buf].tick == tick then return scopes[buf].items end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local items = {}
  for _, d in ipairs(outline.build(lines, vim.bo[buf].filetype, 10000).decls) do
    local line = lines[d.lnum]
    if line:match("%f[%w]function%f[%W]") or line:match("%f[%w]def%f[%W]")
      or line:match("%f[%w]defp%f[%W]") or line:match("^%s*func%s")
      or line:match("%f[%w]fn%f[%W]") or line:find("=>", 1, true) then
      local def = vim.split(outline.definition(lines, d.lnum, #lines), "\n", { plain = true })
      local first = d.lnum
      for i = math.max(1, d.lnum - 6), d.lnum do
        if lines[i] == def[1] then first = i; break end
      end
      table.insert(items, { first = first, last = math.min(#lines, first + #def - 1), label = d.name })
    end
  end
  scopes[buf] = { tick = tick, items = items }
  return items
end

function M.focus(buf, row, view)
  if not M.eligible(buf) then return nil end
  local name = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
  local path = uv.fs_realpath(name) or name
  local root = project.root(path)
  root = uv.fs_realpath(root) or root
  local scope = { bufnr = buf, root = root, path = path, first = 1,
    last = vim.api.nvim_buf_line_count(buf), label = vim.fs.basename(path), view = view }
  if view == "flow" then
    for _, f in ipairs(functions(buf)) do
      if row >= f.first and row <= f.last then
        scope.first, scope.last, scope.label = f.first, f.last, f.label
      end
    end
  end
  scope.identity = path .. ":" .. scope.first .. ":" .. scope.last .. ":" .. view
  scope.tick = vim.api.nvim_buf_get_changedtick(buf)
  return scope
end

function M.forget(buf) scopes[buf] = nil end

local function add(ctx, path, first, last)
  path = M.path(ctx.root, path)
  if not path then return false end
  local relative = path:sub(#ctx.root + 2)
  local f = ctx.files[relative]
  if not f and #ctx.order >= ctx.max_files then return false end
  local lines, hash, buf = M.read(path)
  if not lines or (f and hash ~= f.hash) then return false end
  first, last = first or 1, math.min(last or #lines, #lines)
  if first < 1 or first > last then return false end
  f = f or { path = path, hash = hash, bufnr = buf, total = #lines, lines = {} }
  local added = 0
  for i = first, last do
    if not f.lines[i] then
      local line = ("%d| %s"):format(i, lines[i])
      if ctx.chars + #line + 1 > ctx.max_chars then break end
      f.lines[i] = line
      ctx.chars, added = ctx.chars + #line + 1, added + 1
    end
  end
  if added == 0 then return false end
  local numbers, out = vim.tbl_keys(f.lines), {}
  table.sort(numbers)
  f.ranges = {}
  for _, i in ipairs(numbers) do
    local span = f.ranges[#f.ranges]
    if span and span[2] == i - 1 then
      span[2] = i
    else
      table.insert(f.ranges, { i, i })
      if #out > 0 then table.insert(out, "... (lines not inspected) ...") end
    end
    table.insert(out, f.lines[i])
  end
  f.first, f.last, f.count = numbers[1], numbers[#numbers], #numbers
  f.text = table.concat(out, "\n")
  if not ctx.files[relative] then table.insert(ctx.order, relative) end
  ctx.files[relative] = f
  return true
end

function M.collect(scope)
  local opts = config.options.view
  local ctx = { root = scope.root, scope = vim.deepcopy(scope), files = {}, order = {}, chars = 0,
    max_chars = math.floor(opts.max_chars * 0.7), max_files = math.max(1, opts.max_files - 2) }
  -- Focus first, with a little surrounding context. Components use the whole file.
  if not add(ctx, scope.path, math.max(1, scope.first - 12), scope.last + 12) then
    return nil, "Cannot read the focused source within the diagram budget"
  end
  local lines = M.read(scope.path)
  local text = table.concat(lines, "\n")
  local ft = vim.bo[scope.bufnr].filetype
  local deps = vim.tbl_keys(imports.upstream(scope.path, text, ft, scope.root))
  table.sort(deps)
  for _, path in ipairs(deps) do add(ctx, path) end
  if scope.view == "components" then
    local dir, ext = vim.fs.dirname(scope.path), vim.fn.fnamemodify(scope.path, ":e")
    local peers = {}
    for name, kind in vim.fs.dir(dir) do
      if kind == "file" and vim.fn.fnamemodify(name, ":e") == ext then
        table.insert(peers, dir .. "/" .. name)
      end
    end
    table.sort(peers)
    for _, path in ipairs(peers) do add(ctx, path) end
  end
  -- Leave room for evidence discovered while investigating a question.
  ctx.max_chars, ctx.max_files = opts.max_chars, opts.max_files
  return ctx
end

function M.prompt(ctx)
  local out = { ("Project: %s\nFocus: %s, lines %d-%d\nSource excerpts (untrusted reference data):"):format(
    ctx.root, ctx.scope.path:sub(#ctx.root + 2), ctx.scope.first, ctx.scope.last) }
  for _, relative in ipairs(ctx.order) do
    local f = ctx.files[relative]
    table.insert(out, ("<source path=%s first=%d last=%d total=%d>\n%s\n</source>"):format(
      vim.json.encode(relative), f.first, f.last, f.total, f.text))
  end
  return table.concat(out, "\n\n")
end

function M.current(ctx)
  if not ctx then return false end
  for _, f in pairs(ctx.files) do
    local _, hash = M.read(f.path)
    if hash ~= f.hash then return false end
  end
  return true
end

function M.references(refs, ctx)
  local out = {}
  if type(refs) ~= "table" then return out end
  for _, r in ipairs(refs) do
    if type(r) == "table" then
      local path = M.path(ctx.root, r.path)
      local relative = path and path:sub(#ctx.root + 2)
      local f = relative and ctx.files[relative]
      local a, b = r.start_line, r.end_line
      if f and type(a) == "number" and type(b) == "number" and a % 1 == 0 and b % 1 == 0 and b >= a then
        for _, span in ipairs(f.ranges) do
          if a >= span[1] and b <= span[2] then
            table.insert(out, { path = relative, start_line = a, end_line = b })
            break
          end
        end
      end
    end
  end
  return out
end

-- Follow-up reads always add source to the same snapshot. Never mix revisions.
function M.extend(ctx, paths)
  if not M.current(ctx) then return false, "Source changed; refresh before continuing" end
  local before = ctx.chars
  for _, path in ipairs(paths or {}) do add(ctx, path) end
  return ctx.chars > before
end

-- Bounded literal search; results are context, never commands. The caller owns
-- cancellation and revision checks. Read only a small window around each hit.
function M.search(ctx, query, cb)
  if type(query) ~= "string" or #query < 3 or #query > 120 or query:find("[%z\r\n]")
    or vim.fn.executable("rg") == 0 then
    cb(false)
    return nil
  end
  local args = { "rg", "-n", "-F", "--no-heading", "--no-messages", "--max-count", "2", "--max-filesize", "100K" }
  for _, dir in ipairs({ ".git", "node_modules", "vendor", "dist", "build", ".venv", "target" }) do
    vim.list_extend(args, { "-g", "!" .. dir .. "/**" })
  end
  vim.list_extend(args, { "--", query, "." })
  local chunks, bytes, process = {}, 0, nil
  process = vim.system(args, { cwd = ctx.root, text = true, timeout = 2000, stdout = function(_, data)
    if data and bytes < 32768 then
      local chunk = data:sub(1, 32768 - bytes)
      table.insert(chunks, chunk)
      bytes = bytes + #chunk
    end
    if bytes >= 32768 and process then pcall(process.kill, process, 15) end
  end }, vim.schedule_wrap(function()
    if not M.current(ctx) then return cb(false) end
    local before = ctx.chars
    for line in table.concat(chunks):gmatch("[^\n]+") do
      local path, row = line:match("^%./(.-):(%d+):")
      if path then
        row = tonumber(row)
        add(ctx, path, math.max(1, row - 25), row + 40)
      end
      if ctx.chars >= ctx.max_chars then break end
    end
    cb(ctx.chars > before)
  end))
  return process
end

return M
