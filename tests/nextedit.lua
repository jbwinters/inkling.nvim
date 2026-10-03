-- nvim --headless -u NONE -l tests/nextedit.lua
-- Next-edit prediction with a fake provider.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
-- keep test activity out of the real spend/acceptance log
local test_log = vim.fn.tempname()
require("inkling.usage").path = function() return test_log end
local providers = require("inkling.providers")
local reply
providers.run = function(_, _, on_done)
  vim.defer_fn(function() on_done(nil, reply) end, 10)
  return { kill = function() end }
end
local nextedit = require("inkling.nextedit")
local edits = require("inkling.context.edits")
require("inkling").setup({ context = { project = { enabled = false } } })

local failures = 0
local function check(name, cond, info)
  print((cond and "ok   " or "FAIL ") .. name .. (info and ("  " .. info) or ""))
  if not cond then failures = failures + 1 end
end

local tmp = vim.fn.tempname() .. ".py"
vim.fn.writefile({ "def f(eps):", "    a = eps", "    return eps * 2" }, tmp)
vim.cmd("edit " .. tmp)
local buf = vim.api.nvim_get_current_buf()
edits.track(buf)
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "def f(noise):" })
edits.checkpoint(buf)
-- a pre-existing buffer-local <Tab> mapping must survive
vim.keymap.set("n", "<Tab>", ":echo 'mine'<CR>", { buffer = buf })

local function ask(r)
  reply = r
  nextedit.request(buf)
  vim.wait(200, function() return nextedit.current() ~= nil end, 10)
  return nextedit.current()
end

check("no edit -> nothing", ask({ has_edit = false, start_line = 0, end_line = 0, replacement = "", reason = "" }) == nil)
check("out of range rejected", ask({ has_edit = true, start_line = 2, end_line = 9, replacement = "x", reason = "" }) == nil)
check("no-op rejected", ask({ has_edit = true, start_line = 2, end_line = 2, replacement = "    a = eps", reason = "" }) == nil)
local c = ask({ has_edit = true, start_line = 2, end_line = 3, replacement = "2|     a = noise\n3|     return noise * 2", reason = "rename" })
check("prediction shown", c ~= nil)
check("echoed line numbers stripped", c and c.lines[1] == "    a = noise", c and vim.inspect(c.lines))
check("tab mapped while showing", (vim.fn.maparg("<Tab>", "n", false, true).desc or ""):match("inkling") ~= nil)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
nextedit._on_tab()
check("first tab jumps", vim.api.nvim_win_get_cursor(0)[1] == 2)
nextedit._on_tab()
check("second tab applies", table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "|") == "def f(noise):|    a = noise|    return noise * 2")
check("cleared after apply", nextedit.current() == nil)
check("own buffer mapping restored", vim.fn.maparg("<Tab>", "n") == ":echo 'mine'<CR>", vim.fn.maparg("<Tab>", "n"))
vim.cmd("normal! u")
check("one undo reverts the applied edit", vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "    a = eps")

vim.fn.delete(tmp)
os.exit(failures == 0 and 0 or 1)
