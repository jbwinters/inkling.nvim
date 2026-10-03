-- Completion-quality benchmark over real code.
--
--   INKLING_EVAL_DIR=/path/to/code nvim --headless -u NONE -l tests/eval.lua <provider> [n] [seed] [hint]
--
-- Samples lines from source files under INKLING_EVAL_DIR, cuts each one either
-- mid-line or at its indentation, removes the rest of that line, asks the
-- provider for a completion (with the full project context) and compares the
-- first suggested line with what was really there.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("filetype on")
vim.o.swapfile = false
vim.o.virtualedit = "onemore"

local provider = _G.arg[1] or "openai"
local n = tonumber(_G.arg[2] or "20")
local seed = tonumber(_G.arg[3] or "1")
local output = _G.arg[4] -- "json" / "tags" / nil = provider default
local dir = assert(os.getenv("INKLING_EVAL_DIR"), "set INKLING_EVAL_DIR")

local inkling = require("inkling")
local override = {}
if os.getenv("INKLING_EVAL_MODEL") then
  override.model = os.getenv("INKLING_EVAL_MODEL")
end
if os.getenv("INKLING_EVAL_EXTRA") then
  -- JSON merged into the provider's request body, e.g. '{"thinking":{"type":"between_tools"}}'
  override.extra_body = vim.json.decode(os.getenv("INKLING_EVAL_EXTRA"))
end
override.output = output
inkling.setup({ provider = provider, providers = { [provider] = override } })
output = require("inkling.config").provider().output
print("model: " .. require("inkling.config").provider().model .. " extra: " .. (os.getenv("INKLING_EVAL_EXTRA") or "-"))
local providers = require("inkling.providers")
local project = require("inkling.context.project")
vim.api.nvim_get_mode = function()
  return { mode = "i", blocking = false }
end

local exts = { py = true, go = true, ts = true, tsx = true, js = true, lua = true, sh = true, ex = true, rb = true, rs = true }
local files = {}
for name, type in vim.fs.dir(dir, { depth = 8 }) do
  local ext = name:match("%.(%w+)$")
  if type == "file" and exts[ext] and not name:match("node_modules") and not name:match("_test%.go$") then
    table.insert(files, dir .. "/" .. name)
  end
end
table.sort(files)
-- spread samples evenly across languages
local by_ext = {}
for _, f in ipairs(files) do
  local e = f:match("%.(%w+)$")
  by_ext[e] = by_ext[e] or {}
  table.insert(by_ext[e], f)
end
local langs = vim.tbl_keys(by_ext)
table.sort(langs)

math.randomseed(seed)
local samples = {}
local tries = 0
while #samples < n and tries < n * 50 do
  tries = tries + 1
  local list = by_ext[langs[(#samples % #langs) + 1]]
  local path = list[math.random(#list)]
  local lines = vim.fn.readfile(path)
  if #lines > 5 then
    local lnum = math.random(#lines)
    local line = lines[lnum]
    local code = vim.trim(line)
    -- skip blank, comment-only, trivially short and very long lines
    if #code >= 12 and #code <= 140 and not code:match("^[#/%-%*]") and not code:match("^[%]%)}]") then
      local indent = #line:match("^%s*")
      local r = math.random()
      local col, stop
      if r < 0.4 then
        col, stop = indent, #line -- start of line
      elseif r < 0.75 then
        col, stop = math.random(indent + 3, #line - 3), #line -- mid-line
      else
        -- infill: a span in the middle is missing and text follows the cursor
        col = math.random(indent + 3, #line - 8)
        stop = math.random(col + 3, #line - 2)
      end
      table.insert(samples, {
        path = path, lines = lines, lnum = lnum, col = col,
        truth = line:sub(col + 1, stop), after = line:sub(stop + 1),
      })
    end
  end
end

local function common_prefix(a, b)
  local i = 0
  while i < #a and i < #b and a:sub(i + 1, i + 1) == b:sub(i + 1, i + 1) do
    i = i + 1
  end
  return i
end

local results = { exact = 0, good = 0, empty = 0, bad_start = 0, total_ms = 0, n = 0 }
for i, s in ipairs(samples) do
  local lines = vim.deepcopy(s.lines)
  lines[s.lnum] = lines[s.lnum]:sub(1, s.col) .. s.after
  local buf = vim.fn.bufadd(s.path)
  vim.fn.bufload(buf)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { s.lnum, s.col })
  project.forget(buf)
  project.refresh(buf)
  vim.wait(5000, function()
    return select(2, project.get(buf)) > 0
  end, 20)
  local ctx = inkling._build_context()
  local done, out, err
  local t0 = vim.uv.hrtime()
  providers.complete(ctx, function(e, text)
    err, out, done = e, text, true
  end)
  vim.wait(30000, function()
    return done
  end, 10)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  local got = err and "" or inkling._clean(out or "", ctx)
  local first = (got:match("^[^\n]*") or "")
  local truth = s.truth
  if s.after == "" then
    first, truth = first:gsub("%s+$", ""), truth:gsub("%s+$", "")
  end
  local lcp = common_prefix(first, truth)
  local exact = first == truth
  -- "good": the suggestion's first line is right for at least 2/3 of the real line (or all of the suggestion is)
  local good = exact or (lcp >= math.ceil(#truth * 2 / 3)) or (#first > 0 and lcp == #first and #first >= 4)
  local bad_start = #truth > 0 and #first > 0 and lcp == 0
  results.n = results.n + 1
  results.total_ms = results.total_ms + ms
  results.exact = results.exact + (exact and 1 or 0)
  results.good = results.good + (good and 1 or 0)
  results.empty = results.empty + (first == "" and 1 or 0)
  results.bad_start = results.bad_start + (bad_start and 1 or 0)
  local tag = exact and "EXACT" or good and "good " or bad_start and "BAD  " or "miss "
  print(("%2d %s %5dms %s:%d  [%s|%s]"):format(i, tag, ms, vim.fn.fnamemodify(s.path, ":t"), s.lnum,
    s.lines[s.lnum]:sub(1, s.col):gsub("^%s+", ""), (err and ("ERR " .. err) or first) .. (s.after ~= "" and ("|" .. s.after) or "")))
  if not exact then
    print(("                truth: %s"):format(truth))
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end
print(("\n%s%s: %d samples  exact %d  good %d  bad-start %d  empty %d  avg %.0fms"):format(
  provider .. " " .. require("inkling.config").provider().model, " [" .. output .. "]", results.n, results.exact, results.good, results.bad_start, results.empty,
  results.total_ms / math.max(1, results.n)))
