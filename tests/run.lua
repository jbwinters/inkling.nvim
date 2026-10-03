-- Headless smoke test: nvim --headless -u NONE -l tests/run.lua [provider]
-- Exercises the full request -> render -> accept path against a real provider.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
-- keep test activity out of the real spend/acceptance log
local test_log = vim.fn.tempname()
require("inkling.usage").path = function() return test_log end
local gw = require("inkling")
gw.setup({ provider = _G.arg[1] or "openai", debounce_ms = 10 })
-- pin the provider under test (a remembered `:Inkling use` choice would override it)
do
  local cfg = require("inkling.config")
  cfg.options.provider = _G.arg[1] or "openai"
  cfg.options.providers[_G.arg[1] or "openai"].model = require("inkling.config").defaults.providers[_G.arg[1] or "openai"].model
end

vim.api.nvim_exec_autocmds("VimEnter", {})

local failures = 0
local function check(name, cond, info)
  print((cond and "ok   " or "FAIL ") .. name .. (info and ("  " .. info) or ""))
  if not cond then failures = failures + 1 end
end

-- clean() heuristics
local c = gw._clean
check("strip fences", c("```python\nfoo()\n```", { before = "", after = "" }) == "foo()")
check("strip echoed tags", c("return x\nend\n\n</reasoning_effort>\n", { before = "", after = "" }) == "return x\nend")
check("keep html closing tag", c("<b>hi</b>\n</div>", { before = "", after = "" }) == "<b>hi</b>\n</div>")
check("strip repeated before", c("x = foo()", { before = "x = ", after = "" }) == "foo()")
check("strip dup indent", c("   return 1", { before = "    ", after = "" }) == "return 1")
check("strip extra closer", c("a, b))", { before = "f(", after = ")" }) == "a, b)")
check("keep balanced closer", c("g(1)", { before = "f(", after = ")" }) == "g(1)")

-- live request
vim.cmd("enew")
vim.o.virtualedit = "onemore" -- let the cursor sit past EOL like in insert mode
vim.bo.filetype = "python"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "def fibonacci(n):", "    " })
vim.api.nvim_win_set_cursor(0, { 2, 4 })
vim.cmd("startinsert")
vim.wait(50)
local orig = vim.api.nvim_get_mode
vim.api.nvim_get_mode = function() return { mode = "i" } end -- headless -l doesn't stay in insert mode
local t0 = vim.uv.hrtime()
gw.request()
local ok = vim.wait(20000, function() return gw._current() ~= nil end, 10)
local first_ms = (vim.uv.hrtime() - t0) / 1e6
check("first text shown", ok, ("%.0fms"):format(first_ms))
-- streaming: wait for the rest
ok = ok and vim.wait(20000, function() return gw._current() and not gw._current().streaming end, 10)
local ms = (vim.uv.hrtime() - t0) / 1e6
check("got suggestion", ok, ("%.0fms (first text at %.0fms)"):format(ms, first_ms))
if ok then
  print("---- suggestion ----\n" .. gw._current().text .. "\n--------------------")
  local marks = vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("inkling"), 0, -1, { details = true })
  check("rendered extmark", #marks == 1)
  gw.accept_word()
  local after_word = vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]
  check("accept word inserts", after_word ~= "    ", vim.inspect(after_word))
  check("rest still shown", gw._current() ~= nil)
  gw.accept()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  check("accept inserts block", #lines > 2, #lines .. " lines")
  check("suggestion cleared", gw._current() == nil)
  print(table.concat(lines, "\n"))
end
vim.api.nvim_get_mode = orig
os.exit(failures == 0 and 0 or 1)
