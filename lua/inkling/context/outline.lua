-- Language-aware outlines built from declaration patterns plus indentation.
-- Works without treesitter parsers, which are often not installed.
local M = {}

-- Each rule: pattern (optional capture = declared name), top = only at column 0,
-- private = name is not part of the module's public surface.
local function rules(list)
  local out = {}
  for _, r in ipairs(list) do
    if type(r) == "string" then
      r = { r }
    end
    table.insert(out, r)
  end
  return out
end

local js = rules({
  "^%s*export%s+default%s+async%s+function%*?%s*([%w_$]*)",
  "^%s*export%s+default%s+function%*?%s*([%w_$]*)",
  "^%s*export%s+default%s+class%s*([%w_$]*)",
  "^%s*export%s+default",
  "^%s*export%s+async%s+function%*?%s+([%w_$]+)",
  "^%s*export%s+function%*?%s+([%w_$]+)",
  "^%s*export%s+abstract%s+class%s+([%w_$]+)",
  "^%s*export%s+class%s+([%w_$]+)",
  "^%s*export%s+interface%s+([%w_$]+)",
  "^%s*export%s+type%s+([%w_$]+)",
  "^%s*export%s+const%s+enum%s+([%w_$]+)",
  "^%s*export%s+enum%s+([%w_$]+)",
  "^%s*export%s+const%s+([%w_$]+)",
  "^%s*export%s+let%s+([%w_$]+)",
  "^%s*export%s+var%s+([%w_$]+)",
  "^%s*export%s*{",
  "^%s*export%s+%*",
  "^%s*module%.exports",
  "^%s*exports%.([%w_$]+)",
  { "^async%s+function%*?%s+([%w_$]+)", top = true },
  { "^function%*?%s+([%w_$]+)", top = true },
  { "^abstract%s+class%s+([%w_$]+)", top = true },
  { "^class%s+([%w_$]+)", top = true },
  { "^interface%s+([%w_$]+)", top = true },
  { "^type%s+([%w_$]+)%s*[=<]", top = true },
  { "^enum%s+([%w_$]+)", top = true },
  { "^const%s+([%w_$]+)", top = true },
  { "^let%s+([%w_$]+)", top = true },
  -- class members: `name(args) {` / `async name(args): T {`
  { "^%s+[%w_$%s]-([%w_$#]+)%s*%b()%s*[:{]", method = true },
})

local LANGS = {
  python = rules({
    "^%s*async%s+def%s+([%w_]+)",
    "^%s*def%s+([%w_]+)",
    "^%s*class%s+([%w_]+)",
    { "^([%u_][%u%d_]*)%s*[:=]", top = true },
    { "^%s*@[%w_%.]+", decorator = true },
    -- annotated class fields (dataclasses, pydantic, TypedDict): `    name: str = ""`
    { "^%s+([%a_][%w_]*)%s*:%s*[%w_%.%[%]|,%s\"']+%s*=?[^:]*$", method = true },
  }),
  lua = rules({
    { "^%s*local%s+function%s+([%w_]+)", private = true },
    "^%s*function%s+([%w_.:]+)",
    "^%s*([%w_.:]+)%s*=%s*function",
    { "^([%w_]+%.[%w_]+)%s*=", top = true },
    { "^local%s+([%w_]+)%s*=", top = true, private = true },
    { "^return%s+[%w_]+%s*$", top = true },
  }),
  elixir = rules({
    "^%s*defmodule%s+([%w%.]+)",
    "^%s*defprotocol%s+([%w%.]+)",
    "^%s*defimpl%s+([%w%.]+)",
    "^%s*def%s+([%w_?!]+)",
    "^%s*defmacro%s+([%w_?!]+)",
    "^%s*defdelegate%s+([%w_?!]+)",
    "^%s*defguard%s+([%w_?!]+)",
    { "^%s*defp%s+([%w_?!]+)", private = true },
    { "^%s*defmacrop%s+([%w_?!]+)", private = true },
    "^%s*defstruct",
    "^%s*defexception",
    "^%s*schema%s",
    "^%s*embedded_schema",
    "^%s*field%s",
    "^%s*belongs_to%s",
    "^%s*has_many%s",
    "^%s*has_one%s",
    "^%s*many_to_many%s",
    "^%s*embeds_one%s",
    "^%s*embeds_many%s",
    "^%s*@spec%s",
    "^%s*@callback%s",
    "^%s*@typep?%s",
    "^%s*@opaque%s",
    "^%s*@behaviour%s",
    "^%s*use%s",
  }),
  go = rules({
    "^func%s+%b()%s*([%w_]+)",
    "^func%s+([%w_]+)",
    "^type%s+([%w_]+)",
    "^const%s",
    "^var%s",
  }),
  rust = rules({
    "^%s*pub[^%s]*%s+async%s+fn%s+([%w_]+)",
    "^%s*pub[^%s]*%s+fn%s+([%w_]+)",
    "^%s*pub[^%s]*%s+struct%s+([%w_]+)",
    "^%s*pub[^%s]*%s+enum%s+([%w_]+)",
    "^%s*pub[^%s]*%s+trait%s+([%w_]+)",
    "^%s*pub[^%s]*%s+type%s+([%w_]+)",
    "^%s*pub[^%s]*%s+const%s+([%w_]+)",
    "^%s*pub[^%s]*%s+mod%s+([%w_]+)",
    { "^%s*async%s+fn%s+([%w_]+)", private = true },
    { "^%s*fn%s+([%w_]+)", private = true },
    { "^%s*struct%s+([%w_]+)", private = true },
    { "^%s*enum%s+([%w_]+)", private = true },
    { "^%s*trait%s+([%w_]+)", private = true },
    "^%s*impl[%s<]",
    "^%s*mod%s+([%w_]+)",
  }),
  c = rules({
    { "^#define%s+([%w_]+)", top = true },
    { "^typedef%s", top = true },
    { "^struct%s+([%w_]+)", top = true },
    { "^enum%s+([%w_]+)", top = true },
    { "^class%s+([%w_]+)", top = true },
    { "^[%w_][%w_%s%*&:<>,]*[%s%*&]([%w_:~]+)%s*%(", top = true },
  }),
  default = rules({
    "^%s*def%s+([%w_?!.]+)",
    "^%s*function%s+([%w_.:]+)",
    "^%s*class%s+([%w_:]+)",
    "^%s*module%s+([%w_:]+)",
    "^%s*interface%s+([%w_]+)",
    "^%s*struct%s+([%w_]+)",
    "^%s*fn%s+([%w_]+)",
    "^%s*func%s+([%w_]+)",
  }),
}
LANGS.javascript = js
LANGS.typescript = js
LANGS.javascriptreact = js
LANGS.typescriptreact = js
LANGS.cpp = LANGS.c
LANGS.ruby = LANGS.default

local NOT_METHODS = {
  ["if"] = true, ["for"] = true, ["while"] = true, ["switch"] = true, ["catch"] = true,
  ["function"] = true, ["return"] = true, ["else"] = true, ["do"] = true, ["try"] = true,
  ["with"] = true, ["await"] = true, ["new"] = true, ["typeof"] = true,
}

local function indent_of(line)
  return #line:match("^%s*")
end

local function paren_balance(s)
  local _, o = s:gsub("[%(%[]", "")
  local _, c = s:gsub("[%)%]]", "")
  return o - c
end

local function match_rule(line, rs)
  local top = indent_of(line) == 0
  for _, r in ipairs(rs) do
    if not r.top or top then
      local s, _, name = line:find(r[1])
      if s then
        if r.method and (not name or NOT_METHODS[name] or line:match("^%s*[%.%}%)]") or line:find("=", 1, true)) then
          -- not a real method declaration; keep looking
        else
          return r, name
        end
      end
    end
  end
end

---@param lines string[]
---@param ft string
---@return { text: string, decls: {name: string|nil, lnum: integer, private: boolean, top: boolean}[], names: string[] }
function M.build(lines, ft, max_lines)
  max_lines = max_lines or 250
  local rs = LANGS[ft] or LANGS.default
  local out, decls, names, seen = {}, {}, {}, {}
  local last_name
  local i = 1
  while i <= #lines and #out < max_lines do
    local line = lines[i]
    local r, name = match_rule(line, rs)
    if r then
      local sig = { line }
      local j = i
      -- join multi-line signatures until parens balance
      while paren_balance(table.concat(sig, " ")) > 0 and j < #lines and j < i + 8 do
        j = j + 1
        table.insert(sig, lines[j])
      end
      if name and name ~= "" then
        name = name:match("([%w_$#?!]+)$") or name -- M.foo / Foo.Bar -> foo / Bar
      end
      local dup = name and name == last_name and not r.decorator
      if not dup then
        vim.list_extend(out, sig)
        if name and name ~= "" then
          table.insert(decls, { name = name, lnum = i, private = r.private or false, top = indent_of(line) == 0 })
          local public = not r.private and not name:match("^_")
          if ft == "go" then
            public = name:match("^%u") ~= nil
          end
          if public and not seen[name] then
            seen[name] = true
            table.insert(names, name)
          end
        end
      end
      if name and not r.decorator then
        last_name = name
      end
      i = j + 1
    else
      i = i + 1
    end
  end
  if #out >= max_lines then
    table.insert(out, "… (outline truncated)")
  end
  return { text = table.concat(out, "\n"), decls = decls, names = names }
end

local CLOSER = { "^%s*[%}%)%]]", "^%s*end%f[%W]", "^%s*end$" }

-- The full text of the declaration starting at `lnum`, found by indentation:
-- the body runs until the next non-blank line at the same or lower indent
-- (which is included if it's a closing brace / `end`).
function M.definition(lines, lnum, max_lines)
  max_lines = max_lines or 80
  local start = lnum
  while start > 1 and (lines[start - 1]:match("^%s*@") or lines[start - 1]:match("^%s*#[^!]") or lines[start - 1]:match("^%s*//") or lines[start - 1]:match("^%s*%-%-")) and lnum - start < 6 do
    start = start - 1
  end
  local base = indent_of(lines[lnum])
  local stop = lnum
  local j = lnum + 1
  -- a multi-line signature belongs to the declaration even if it dedents
  while paren_balance(table.concat(lines, " ", lnum, stop)) > 0 and j <= #lines and j < lnum + 8 do
    stop = j
    j = j + 1
  end
  while j <= #lines do
    local l = lines[j]
    if not l:match("^%s*$") then
      if indent_of(l) <= base then
        for _, p in ipairs(CLOSER) do
          if l:match(p) then
            stop = j
            break
          end
        end
        break
      end
      stop = j
    end
    j = j + 1
  end
  local out = vim.list_slice(lines, start, math.min(stop, start + max_lines - 1))
  if stop > start + max_lines - 1 then
    table.insert(out, "… (definition truncated)")
  end
  return table.concat(out, "\n")
end

return M
