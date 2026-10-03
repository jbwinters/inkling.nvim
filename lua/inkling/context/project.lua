-- Builds the "project context" for a buffer: imported files (upstream), files
-- in the same directory (peers), and usages in files that import it
-- (downstream). Built in the background on BufEnter / save / InsertLeave and
-- cached, so completion requests never wait on it.
local config = require("inkling.config")
local outline = require("inkling.context.outline")
local imports = require("inkling.context.imports")

local M = {}

local uv = vim.uv or vim.loop

local ROOT_MARKERS = {
  ".git", "mix.exs", "package.json", "pyproject.toml", "setup.py", "go.mod", "Cargo.toml", ".luarc.json",
}
local MAX_FILE_BYTES = 300 * 1024
local FAMILY = {
  py = "py", js = "js", jsx = "js", ts = "js", tsx = "js", mjs = "js", cjs = "js", vue = "js", svelte = "js",
  lua = "lua", ex = "ex", exs = "ex", go = "go", rs = "rs", rb = "rb",
  c = "c", h = "c", cc = "c", cpp = "c", hpp = "c",
}
local IGNORE_DIRS = { "node_modules", "_build", "deps", ".git", "dist", "build", "vendor", ".venv", "venv", "target" }

local files = {} -- path -> { key, text, lines, ft, outline }
local state = {} -- bufnr -> { text, version, summary, token }

local function modified_buffers()
  local m = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        m[vim.fs.normalize(name)] = b
      end
    end
  end
  return m
end

local function read(path, open)
  local b = open[path]
  if b then
    local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    return { lines = lines, text = table.concat(lines, "\n"), ft = vim.bo[b].filetype }
  end
  local st = uv.fs_stat(path)
  if not st or st.type ~= "file" or st.size > MAX_FILE_BYTES then
    return nil
  end
  local key = ("%d.%d:%d"):format(st.mtime.sec, st.mtime.nsec, st.size)
  local f = files[path]
  if f and f.key == key then
    return f
  end
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local text = fd:read("*a")
  fd:close()
  if text:sub(1, 4096):find("\0", 1, true) then
    return nil
  end
  text = text:gsub("\r\n", "\n"):gsub("\n$", "")
  f = {
    key = key,
    text = text,
    lines = vim.split(text, "\n", { plain = true }),
    ft = vim.filetype.match({ filename = path }) or "",
  }
  files[path] = f
  return f
end

local function get_outline(f)
  f.outline = f.outline or outline.build(f.lines, f.ft)
  return f.outline
end

local function rel(root, p)
  if p:sub(1, #root + 1) == root .. "/" then
    return p:sub(#root + 2)
  end
  return vim.fn.fnamemodify(p, ":~")
end

local function fence(ft, body)
  return ("```%s\n%s\n```"):format(ft or "", body)
end

-- Every section builder returns { full = string, short = string|nil, label = string }.

-- An outline, or for files with no recognisable declarations (YAML, SQL,
-- config), the first lines of the file.
local function skeleton(f)
  local o = get_outline(f)
  if o.text ~= "" then
    return "Outline:\n" .. fence(f.ft, o.text), "outline"
  end
  local head = table.concat(f.lines, "\n", 1, math.min(#f.lines, 40))
  return "Beginning of file:\n" .. fence(f.ft, head), "start"
end

local function upstream_section(root, path, f, names, opts)
  local header = ("### %s (imported by the current file)"):format(rel(root, path))
  if #f.text <= opts.small_file_chars then
    return { label = rel(root, path) .. " [upstream, whole]", full = header .. "\n" .. fence(f.ft, f.text) }
  end
  local o = get_outline(f)
  local defs, seen = {}, {}
  for _, d in ipairs(o.decls) do
    if names[d.name] and not seen[d.lnum] then
      seen[d.lnum] = true
      table.insert(defs, outline.definition(f.lines, d.lnum))
    end
  end
  local short = header .. "\n" .. skeleton(f)
  if #defs == 0 then
    return { label = rel(root, path) .. " [upstream, outline]", full = short }
  end
  return {
    label = rel(root, path) .. (" [upstream, outline + %d definitions]"):format(#defs),
    full = short .. "\nDefinitions used by the current file:\n" .. fence(f.ft, table.concat(defs, "\n\n")),
    short = short,
  }
end

local function peer_section(root, path, f, opts)
  local header = ("### %s (same directory)"):format(rel(root, path))
  if #f.text <= opts.small_file_chars then
    return { label = rel(root, path) .. " [peer, whole]", full = header .. "\n" .. fence(f.ft, f.text), whole = true }
  end
  local body, kind = skeleton(f)
  return { label = rel(root, path) .. " [peer, " .. kind .. "]", full = header .. "\n" .. body }
end

-- Snippets from a file that imports the current one: its import lines plus
-- the places it uses the current file's public names.
local function downstream_section(root, path, f, import_lnums, names)
  local hits = {}
  for _, l in ipairs(import_lnums) do
    hits[l] = true
  end
  for i, line in ipairs(f.lines) do
    if not hits[i] then
      for _, n in ipairs(names) do
        if line:find("%f[%w_]" .. vim.pesc(n) .. "%f[^%w_?!]") then
          hits[i] = true
          break
        end
      end
    end
  end
  local lnums = vim.tbl_keys(hits)
  table.sort(lnums)
  local windows = {}
  for _, l in ipairs(lnums) do
    local s, e = math.max(1, l - 2), math.min(#f.lines, l + 2)
    local last = windows[#windows]
    if last and s <= last[2] + 1 then
      last[2] = e
    elseif #windows < 5 then
      table.insert(windows, { s, e })
    end
  end
  if #windows == 0 then
    return nil
  end
  local chunks, total = {}, 0
  for _, w in ipairs(windows) do
    local e = math.min(w[2], w[1] + 40 - total - 1)
    if e < w[1] then
      break
    end
    table.insert(chunks, ("lines %d-%d:\n"):format(w[1], e) .. table.concat(f.lines, "\n", w[1], e))
    total = total + (e - w[1] + 1)
  end
  return {
    label = rel(root, path) .. " [downstream, usages]",
    full = ("### %s (imports the current file; usages)\n%s"):format(
      rel(root, path),
      fence(f.ft, table.concat(chunks, "\n...\n"))
    ),
  }
end

local function is_test(p)
  local name = vim.fs.basename(p)
  return name:match("_test%.") or name:match("^test_") or name:match("%.test%.") or name:match("%.spec%.")
    or name:match("_spec%.") or name:match("Test%.") ~= nil
end

local function name_tokens(p)
  local stem = vim.fn.fnamemodify(p, ":t:r"):gsub("(%l)(%u)", "%1_%2"):lower()
  local set = {}
  for t in stem:gmatch("[%l%d]+") do
    if #t > 1 then
      set[t] = true
    end
  end
  return set
end

-- Same-directory files, most relevant first: files declaring names this file
-- uses, similar names (half_normal.py next to normal.py), files this one
-- mentions, and recently edited files.
local function list_peers(path, dir, exclude, max, text, open)
  local ext = vim.fn.fnamemodify(path, ":e")
  if ext == "" then
    return {}
  end
  -- known language families group related extensions; anything else matches its own extension
  local fam = FAMILY[ext] or ext
  local mine = name_tokens(path)
  local now = os.time()
  local words = {}
  for w in text:gmatch("[%a_][%w_]*") do
    words[w] = true
  end
  -- cheap score first (names, recency, tests); only the best candidates get read
  local scored = {}
  for name, type in vim.fs.dir(dir) do
    local e = name:match("%.([%w]+)$") or ""
    if type == "file" and (FAMILY[e] or e) == fam then
      local p = vim.fs.normalize(dir .. "/" .. name)
      if p ~= path and not exclude[p] then
        local score = 0
        for t in pairs(name_tokens(p)) do
          if mine[t] then
            score = score + 3
          end
        end
        local stem = vim.fn.fnamemodify(name, ":r")
        if #stem > 2 and words[stem] then
          score = score + 2
        end
        -- other files' tests are rarely useful context for non-test code
        if is_test(p) and not is_test(path) then
          score = score - 3
        end
        local st = uv.fs_stat(p)
        if st and now - st.mtime.sec < 2 * 86400 then
          score = score + 1
        end
        table.insert(scored, { p = p, score = score })
      end
    end
  end
  table.sort(scored, function(a, b)
    return a.score > b.score or (a.score == b.score and a.p < b.p)
  end)
  scored = vim.list_slice(scored, 1, 150)
  -- then: does this file use names the peer declares?
  for _, c in ipairs(scored) do
    local f = read(c.p, open)
    if f then
      local uses = 0
      for _, d in ipairs(get_outline(f).decls) do
        if d.top and words[d.name] and #d.name > 2 then
          uses = uses + 1
        end
      end
      c.score = c.score + 2 * math.min(uses, 4)
    end
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.p < b.p
  end)
  return vim.tbl_map(function(x)
    return x.p
  end, vim.list_slice(scored, 1, max))
end

local function closeness(a, b)
  local n = 0
  for i = 1, math.min(#a, #b) do
    if a:sub(i, i) ~= b:sub(i, i) then
      break
    end
    n = i
  end
  return n
end

local function find_downstream(path, text, ft, root, cb)
  local pattern, globs = imports.downstream_query(path, text, ft, root)
  if not pattern or vim.fn.executable("rg") == 0 then
    return cb({})
  end
  local args = { "rg", "-n", "--no-heading", "--with-filename", "--no-messages", "--max-count", "5", "--max-filesize", "300K" }
  for _, d in ipairs(IGNORE_DIRS) do
    vim.list_extend(args, { "-g", "!" .. d })
  end
  for _, g in ipairs(globs) do
    vim.list_extend(args, { "-g", g })
  end
  vim.list_extend(args, { "-e", pattern, "--", root })
  vim.system(args, { text = true, timeout = 5000 }, function(res)
    local by_file = {}
    for line in (res.stdout or ""):gmatch("[^\n]+") do
      local p, l = line:match("^(.-):(%d+):")
      if p then
        p = vim.fs.normalize(p)
        if p ~= path then
          by_file[p] = by_file[p] or {}
          table.insert(by_file[p], tonumber(l))
        end
      end
    end
    cb(by_file)
  end)
end

-- The nearest enclosing directory with any project marker (a nested package
-- inside a monorepo is its own project).
local function project_root(path)
  local root
  for dir in vim.fs.parents(path) do
    for _, m in ipairs(ROOT_MARKERS) do
      if uv.fs_stat(dir .. "/" .. m) then
        root = dir
        break
      end
    end
    if root then
      break
    end
  end
  -- Neovim-plugin layout without a marker: the directory containing lua/
  local plugin = path:match("^(.*)/lua/")
  if plugin and (not root or #plugin > #root) then
    root = plugin
  end
  local home = vim.fs.normalize(vim.env.HOME or "")
  if not root or root == home or root == "/" then
    root = vim.fs.dirname(path)
  end
  return vim.fs.normalize(root)
end

M.root = project_root

---@param bufnr integer
---@param cb fun(text: string, summary: string[])
function M.build(bufnr, cb)
  local opts = config.context_opts().project
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not opts.enabled or name == "" then
    return cb("", {})
  end
  local path = vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
  local root = project_root(path)
  local dir = vim.fs.dirname(path)
  local ft = vim.bo[bufnr].filetype
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")
  local open = modified_buffers()

  local upstream, peers = {}, {}
  local used = { [path] = true }
  if opts.upstream then
    local deps = imports.upstream(path, text, ft, root)
    local paths = vim.tbl_keys(deps)
    table.sort(paths)
    for _, p in ipairs(vim.list_slice(paths, 1, opts.max_upstream)) do
      local f = read(p, open)
      if f then
        used[p] = true
        table.insert(upstream, upstream_section(root, p, f, deps[p], opts))
      end
    end
  end
  if opts.peers then
    for _, p in ipairs(list_peers(path, dir, used, opts.max_peers, text, open)) do
      local f = read(p, open)
      local s = f and peer_section(root, p, f, opts)
      if s then
        table.insert(peers, s)
        -- a whole peer file already shows its usages; outline-only peers can still add downstream snippets
        if s.whole then
          used[p] = true
        end
      end
    end
  end

  local function finish(downstream)
    local budget = opts.max_chars
    local parts, summary, total = {}, {}, 0
    for _, group in ipairs({ upstream, peers, downstream }) do
      for _, s in ipairs(group) do
        local chosen, label = s.full, s.label
        if total + #chosen > budget and s.short then
          chosen, label = s.short, s.label:gsub("%[upstream.*%]", "[upstream, outline]")
        end
        if total + #chosen <= budget then
          table.insert(parts, chosen)
          table.insert(summary, ("%6d chars  %s"):format(#chosen, label))
          total = total + #chosen
        else
          table.insert(summary, ("%6s        %s (skipped: over budget)"):format("-", s.label))
        end
      end
    end
    cb(table.concat(parts, "\n\n"), summary)
  end

  if not opts.downstream then
    return finish({})
  end
  local current_names = outline.build(lines, ft).names
  current_names = vim.tbl_filter(function(n)
    return #n > 2
  end, vim.list_slice(current_names, 1, 60))
  find_downstream(path, text, ft, root, vim.schedule_wrap(function(by_file)
    local paths = vim.tbl_keys(by_file)
    table.sort(paths, function(a, b)
      local ca, cb_ = closeness(a, path), closeness(b, path)
      if ca ~= cb_ then
        return ca > cb_
      end
      return a < b
    end)
    local downstream = {}
    for _, p in ipairs(paths) do
      if #downstream >= opts.max_downstream then
        break
      end
      local f = not used[p] and read(p, modified_buffers())
      local s = f and downstream_section(root, p, f, by_file[p], current_names)
      if s then
        table.insert(downstream, s)
      end
    end
    finish(downstream)
  end))
end

-- Rebuild a buffer's project context in the background.
function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local st = state[bufnr] or { text = "", version = 0, token = 0, summary = {} }
  state[bufnr] = st
  st.token = st.token + 1
  local token = st.token
  local ok, err = pcall(M.build, bufnr, function(text, summary)
    if token ~= st.token then
      return
    end
    if text ~= st.text then
      st.text = text
      st.version = st.version + 1
    end
    st.summary = summary
  end)
  if not ok then
    st.summary = { "error building context: " .. tostring(err) }
  end
end

---@return string text, integer version, string[] summary
function M.get(bufnr)
  local st = state[bufnr]
  if not st then
    return "", 0, {}
  end
  return st.text, st.version, st.summary
end

function M.forget(bufnr)
  state[bufnr] = nil
end

return M
