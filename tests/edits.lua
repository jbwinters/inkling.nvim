-- nvim --headless -u NONE -l tests/edits.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local edits = require("inkling.context.edits")

local failures = 0
local function check(name, cond, info)
  print((cond and "ok   " or "FAIL ") .. name .. (info and ("  " .. info) or ""))
  if not cond then failures = failures + 1 end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local function open(name, lines)
  vim.fn.writefile(lines, tmp .. "/" .. name)
  vim.cmd("edit " .. tmp .. "/" .. name)
  local b = vim.api.nvim_get_current_buf()
  edits.track(b)
  return b
end

local a = open("models.py", { "class User:", "    def __init__(self, name):", "        self.name = name", "" })
check("no edits yet", edits.render(tmp, 4000) == "")
vim.api.nvim_buf_set_lines(a, 1, 3, false, { "    def __init__(self, name, email):", "        self.name = name", "        self.email = email" })
local range = edits.checkpoint(a)
check("checkpoint returns changed range", range and range[1] == 2 and range[2] == 4, vim.inspect(range))
local text, v1 = edits.render(tmp, 4000)
check("diff shows new param", text:find("+    def __init__(self, name, email):", 1, true) ~= nil)
check("diff shows old line", text:find("-    def __init__(self, name):", 1, true) ~= nil)
check("path relative to root", text:find("--- models.py", 1, true) ~= nil)
check("unchanged checkpoint is a no-op", edits.checkpoint(a) == nil and select(2, edits.render(tmp, 4000)) == v1)

local b = open("views.py", { "def show(u):", "    return u.name", "" })
vim.api.nvim_buf_set_lines(b, 1, 2, false, { "    return f'{u.name} <{u.email}>'" })
edits.checkpoint(b)
text = edits.render(tmp, 4000)
local pm, pv = text:find("models.py", 1, true), text:find("views.py", 1, true)
check("both files, newest last", pm and pv and pm < pv)
-- a second edit to models.py consolidates against the same base
vim.cmd("buffer " .. a)
vim.api.nvim_buf_set_lines(a, 0, 1, false, { "class Account:" })
edits.checkpoint(a)
text = edits.render(tmp, 4000)
check("consolidated diff keeps earlier change", text:find("+        self.email = email", 1, true) ~= nil and text:find("+class Account:", 1, true) ~= nil)
check("models.py now newest", text:find("models.py", 1, true) > text:find("views.py", 1, true))
check("budget respected", #edits.render(tmp, 150) <= 150)

vim.fn.delete(tmp, "rf")
os.exit(failures == 0 and 0 or 1)
