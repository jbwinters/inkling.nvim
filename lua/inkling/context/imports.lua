-- Finds the project-local files the current file imports (upstream) and builds
-- ripgrep patterns for finding the files that import it (downstream).
-- Third-party / stdlib imports are ignored: only paths that exist on disk count.
local M = {}

local uv = vim.uv or vim.loop

local function is_file(p)
  local st = p and uv.fs_stat(p)
  return st ~= nil and st.type == "file"
end

local function first_file(cands)
  for _, c in ipairs(cands) do
    if is_file(c) then
      return vim.fs.normalize(c)
    end
  end
end

local function join(...)
  return vim.fs.normalize(table.concat({ ... }, "/"))
end

local function split_names(s)
  local names = {}
  s = s:gsub("[%(%)]", "")
  for part in s:gmatch("[^,]+") do
    local name = vim.trim(part):match("^([%w_$]+)")
    if name and name ~= "type" then
      table.insert(names, name)
    elseif vim.trim(part):match("^type%s+([%w_$]+)") then
      table.insert(names, vim.trim(part):match("^type%s+([%w_$]+)"))
    end
  end
  return names
end

-- result: map path -> set of names used from it (may be empty)
local function add(result, path, names)
  if not path then
    return
  end
  result[path] = result[path] or {}
  for _, n in ipairs(names or {}) do
    result[path][n] = true
  end
end

local resolvers = {}

function resolvers.python(text, dir, root)
  local result = {}
  local function resolve(mod)
    local dots = mod:match("^(%.*)")
    local rel = mod:sub(#dots + 1):gsub("%.", "/")
    local bases
    if #dots > 0 then
      local base = dir
      for _ = 2, #dots do
        base = vim.fs.dirname(base)
      end
      bases = { base }
    else
      -- absolute import: try every directory from here up to the root, like sys.path would
      bases = {}
      local d = dir
      while d and #d >= #root do
        table.insert(bases, d)
        table.insert(bases, join(d, "src"))
        if d == root then
          break
        end
        d = vim.fs.dirname(d)
      end
    end
    for _, b in ipairs(bases) do
      local p = rel == "" and first_file({ join(b, "__init__.py") })
        or first_file({ join(b, rel .. ".py"), join(b, rel, "__init__.py") })
      if p then
        return p, b
      end
    end
  end
  for mod, rest in text:gmatch("\n%s*from%s+([%w_%.]+)%s+import%s+(%b())") do
    local p, base = resolve(mod)
    add(result, p, split_names(rest))
    -- `from . import submodule`
    for _, n in ipairs(split_names(rest)) do
      if base then
        add(result, first_file({ join(base, (mod:gsub("^%.+", ""):gsub("%.", "/")), n .. ".py") }), {})
      end
    end
  end
  for mod, rest in text:gmatch("\n%s*from%s+([%w_%.]+)%s+import%s+([^\n%(]+)") do
    local p, base = resolve(mod)
    add(result, p, split_names(rest))
    for _, n in ipairs(split_names(rest)) do
      if base then
        add(result, first_file({ join(base, (mod:gsub("^%.+", ""):gsub("%.", "/")), n .. ".py") }), {})
      end
    end
  end
  for mods in text:gmatch("\n%s*import%s+([%w_%., ]+)") do
    for mod in mods:gmatch("([%w_%.]+)") do
      if mod ~= "as" then
        add(result, (resolve(mod)), {})
      end
    end
  end
  return result
end

local JS_EXTS = { ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".d.ts", ".vue", ".svelte" }

function resolvers.javascript(text, dir, root)
  local result = {}
  local function resolve(spec)
    local base
    if spec:match("^%.") then
      base = join(dir, spec)
    elseif spec:match("^[@~]/") then
      base = join(root, "src", spec:sub(3))
    else
      return nil
    end
    local cands = { base }
    local stem = base:gsub("%.[cm]?jsx?$", "")
    for _, ext in ipairs(JS_EXTS) do
      table.insert(cands, stem .. ext)
    end
    for _, ext in ipairs(JS_EXTS) do
      table.insert(cands, join(base, "index" .. ext))
    end
    return first_file(cands)
  end
  for what, spec in text:gmatch("import%s+([^;'\"]-)%s+from%s+['\"]([^'\"]+)['\"]") do
    local names = {}
    local braces = what:match("{(.-)}")
    if braces then
      names = split_names((braces:gsub("[%w_$]+%s+as%s+", "")))
    end
    local default = what:match("^%s*type%s+([%w_$]+)") or what:match("^%s*([%w_$]+)")
    if default and default ~= "type" then
      table.insert(names, "default")
    end
    add(result, resolve(spec), names)
  end
  for _, pat in ipairs({
    "export%s+[^;'\"]-%s+from%s+['\"]([^'\"]+)['\"]",
    "require%s*%(%s*['\"]([^'\"]+)['\"]",
    "import%s*%(%s*['\"]([^'\"]+)['\"]",
    "\n%s*import%s+['\"]([^'\"]+)['\"]",
  }) do
    for spec in text:gmatch(pat) do
      add(result, resolve(spec), {})
    end
  end
  return result
end

function resolvers.lua(text, dir, root)
  local result = {}
  local bases = {}
  -- the nearest enclosing `lua/` directory (plugin layout), then common roots
  local lua_dir = dir:match("^(.*/lua)/") or dir:match("^(.*/lua)$")
  if lua_dir then
    table.insert(bases, lua_dir)
  end
  vim.list_extend(bases, { join(root, "lua"), root, join(root, "src"), dir })
  for mod in text:gmatch("require%s*%(?%s*['\"]([%w_%.%-/]+)['\"]") do
    local rel = mod:gsub("%.", "/")
    for _, b in ipairs(bases) do
      local p = first_file({ join(b, rel .. ".lua"), join(b, rel, "init.lua") })
      if p then
        add(result, p, {})
        break
      end
    end
  end
  return result
end

local function underscore(s)
  s = s:gsub("(%u+)(%u%l)", "%1_%2"):gsub("([%l%d])(%u)", "%1_%2")
  return s:lower()
end

function M.elixir_module_path(mod)
  local parts = {}
  for seg in mod:gmatch("[^%.]+") do
    table.insert(parts, underscore(seg))
  end
  return table.concat(parts, "/")
end

function resolvers.elixir(text, _, root)
  local result = {}
  local self_mod = text:match("defmodule%s+([%w%.]+)")
  local aliases = {} -- short name -> full module
  local modules = {} -- full module -> names
  local function note(full)
    modules[full] = modules[full] or {}
    local short = full:match("([%w]+)$")
    aliases[short] = aliases[short] or full
  end
  for base, list in text:gmatch("alias%s+([%u][%w%.]*)%.(%b{})") do
    for short in list:gmatch("[%u][%w%.]*") do
      note(base .. "." .. short)
    end
  end
  for full, as in text:gmatch("alias%s+([%u][%w%.]*[%w]),%s*as:%s*([%u][%w]*)") do
    modules[full] = modules[full] or {}
    aliases[as] = full
  end
  for _, kw in ipairs({ "alias", "import", "use", "require" }) do
    for full in text:gmatch(kw .. "%s+([%u][%w%.]*[%w])") do
      note(full)
    end
  end
  for mod, fun in text:gmatch("([%u][%w%.]*)%.([%l_][%w_]*[?!]?)") do
    local first = mod:match("^([%w]+)")
    local full = aliases[first] and (aliases[first] .. mod:sub(#first + 1)) or mod
    modules[full] = modules[full] or {}
    table.insert(modules[full], fun)
  end
  local bases = { join(root, "lib"), join(root, "test/support") }
  for _, app in ipairs(vim.fn.glob(join(root, "apps/*/lib"), false, true)) do
    table.insert(bases, app)
  end
  for full, names in pairs(modules) do
    if full ~= self_mod then
      local rel = M.elixir_module_path(full)
      for _, b in ipairs(bases) do
        local p = first_file({ join(b, rel .. ".ex"), join(b, rel .. ".exs") })
        if p then
          add(result, p, names)
          break
        end
      end
    end
  end
  return result
end

function resolvers.go(text, _, root)
  local result = {}
  local gomod = root and io.open(join(root, "go.mod"))
  if not gomod then
    return result
  end
  local module = gomod:read("*a"):match("module%s+(%S+)")
  gomod:close()
  if not module then
    return result
  end
  local specs = {} -- { alias, path }
  for block in text:gmatch("import%s*(%b())") do
    for line in block:gmatch("[^\n]+") do
      local alias, s = line:match('^%s*([%w_%.]*)%s*"([^"]+)"')
      if s then
        table.insert(specs, { alias, s })
      end
    end
  end
  for alias, s in text:gmatch('\nimport%s+([%w_%.]*)%s*"([^"]+)"') do
    table.insert(specs, { alias, s })
  end
  for _, spec in ipairs(specs) do
    local alias, s = spec[1], spec[2]
    if s:sub(1, #module) == module then
      local d = join(root, s:sub(#module + 2))
      local pkg = alias ~= "" and alias or s:match("([^/]+)$")
      -- names this file uses from the package: `sessions.SessionState`
      local used = {}
      for n in text:gmatch("%f[%w_]" .. vim.pesc(pkg) .. "%.([%u][%w_]*)") do
        used[n] = true
      end
      -- a Go import is a whole directory: keep the files that declare those names
      local files = {}
      for name, type in vim.fs.dir(d) do
        if type == "file" and name:match("%.go$") and not name:match("_test%.go$") then
          table.insert(files, name)
        end
      end
      table.sort(files)
      local matched = false
      for _, name in ipairs(files) do
        local fd = io.open(join(d, name))
        local src = fd and ("\n" .. fd:read("*a")) or ""
        if fd then
          fd:close()
        end
        local declared = {}
        for n in pairs(used) do
          local p = vim.pesc(n) .. "%f[^%w_]"
          if src:find("\nfunc%s+" .. p) or src:find("\ntype%s+" .. p) or src:find("\nvar%s+" .. p)
            or src:find("\nconst%s+" .. p) or src:find("\n%s+" .. p .. "%s*=") or src:find("\n%s+" .. p .. "%s+[%w%*%[]") then
            table.insert(declared, n)
          end
        end
        if #declared > 0 then
          matched = true
          add(result, join(d, name), declared)
        end
      end
      if not matched and files[1] then
        add(result, join(d, files[1]), {})
      end
    end
  end
  return result
end

function resolvers.rust(text, dir, root)
  local result = {}
  for name in text:gmatch("mod%s+([%w_]+)%s*;") do
    add(result, first_file({ join(dir, name .. ".rs"), join(dir, name, "mod.rs") }), {})
  end
  for kind, path in text:gmatch("use%s+(%w+)::([%w_:]+)") do
    local base = (kind == "crate" and join(root, "src")) or (kind == "super" and vim.fs.dirname(dir)) or (kind == "self" and dir)
    if base then
      local segs = vim.split(path, "::", { plain = true })
      for n = #segs, 1, -1 do
        local rel = table.concat(segs, "/", 1, n)
        local p = first_file({ join(base, rel .. ".rs"), join(base, rel, "mod.rs") })
        if p then
          add(result, p, { segs[#segs] })
          break
        end
      end
    end
  end
  return result
end

function resolvers.c(text, dir, root)
  local result = {}
  for inc in text:gmatch('#include%s+"([^"]+)"') do
    add(result, first_file({ join(dir, inc), join(root, "include", inc), join(root, inc) }), {})
  end
  return result
end

resolvers.typescript = resolvers.javascript
resolvers.javascriptreact = resolvers.javascript
resolvers.typescriptreact = resolvers.javascript
resolvers.cpp = resolvers.c

---@return table<string, table<string, boolean>> path -> set of imported names
function M.upstream(path, text, ft, root)
  local r = resolvers[ft]
  if not r then
    return {}
  end
  local ok, result = pcall(r, "\n" .. text, vim.fs.dirname(path), root)
  if not ok then
    return {}
  end
  result[vim.fs.normalize(path)] = nil
  return result
end

local function rx_escape(s)
  return (s:gsub("[%.%+%*%?%^%$%(%)%[%]{}|\\]", "\\%0"))
end

local GLOBS = {
  python = { "*.py" },
  javascript = { "*.{js,jsx,ts,tsx,mjs,cjs,vue,svelte}" },
  lua = { "*.lua" },
  elixir = { "*.{ex,exs,heex}" },
  go = { "*.go" },
  rust = { "*.rs" },
  c = { "*.{c,h,cc,cpp,hpp}" },
}
GLOBS.typescript, GLOBS.javascriptreact, GLOBS.typescriptreact = GLOBS.javascript, GLOBS.javascript, GLOBS.javascript
GLOBS.cpp = GLOBS.c

-- A ripgrep regex matching lines that import `path`, plus globs to search.
---@return string|nil pattern, string[] globs
function M.downstream_query(path, text, ft, root)
  local stem = vim.fn.fnamemodify(path, ":t:r")
  if stem == "index" or stem == "init" or stem == "__init__" or stem == "mod" then
    stem = vim.fs.basename(vim.fs.dirname(path))
  end
  local s = rx_escape(stem)
  local globs = GLOBS[ft] or { "*." .. vim.fn.fnamemodify(path, ":e") }
  if ft == "python" then
    return ([=[(from|import)\s+[\w.]*\b%s\b]=]):format(s), globs
  elseif GLOBS[ft] == GLOBS.javascript then
    return ([=[(from|require\(|import\()\s*['"][^'"]*\b%s(\.\w+)?['"]]=]):format(s), globs
  elseif ft == "lua" then
    return ([=[require\s*\(?\s*['"][\w./-]*\b%s['"]]=]):format(s), globs
  elseif ft == "elixir" then
    local mod = text:match("defmodule%s+([%w%.]+)")
    return mod and ("\\b" .. rx_escape(mod) .. "\\b") or nil, globs
  elseif ft == "go" then
    local gomod = io.open(join(root, "go.mod"))
    if not gomod then
      return nil, globs
    end
    local module = gomod:read("*a"):match("module%s+(%S+)")
    gomod:close()
    local rel = vim.fs.dirname(path):sub(#root + 2)
    return module and ('"' .. rx_escape(module .. "/" .. rel) .. '"') or nil, globs
  elseif ft == "rust" then
    return ([=[\b%s::|mod\s+%s\s*;]=]):format(s, s), globs
  elseif ft == "c" or ft == "cpp" then
    return ([=[#include\s+"[^"]*\b%s\.h"]=]):format(s), globs
  end
  return "\\b" .. s .. "\\b", globs
end

return M
