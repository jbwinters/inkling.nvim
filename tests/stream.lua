-- nvim --headless -u NONE -l tests/stream.lua
-- Streaming display with a fake provider: text arrives in pieces while the
-- user types over it and accepts parts of it.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local providers = require("inkling.providers")
local feed_partial, feed_done
providers.run = function(_, on_partial, on_done)
  feed_partial, feed_done = on_partial, on_done
  return { kill = function() end }
end
local gw = require("inkling")
gw.setup({ debounce_ms = 10, context = { project = { enabled = false } } })
vim.api.nvim_get_mode = function() return { mode = "i", blocking = false } end

local failures = 0
local function check(name, cond, info)
  print((cond and "ok   " or "FAIL ") .. name .. (info and ("  " .. info) or ""))
  if not cond then failures = failures + 1 end
end
local function settle() vim.wait(30) end
local function text() return gw._current() and gw._current().text end
local function line() return vim.api.nvim_get_current_line() end
local function type_text(s)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  vim.api.nvim_buf_set_text(0, row - 1, col, row - 1, col, { s })
  vim.api.nvim_win_set_cursor(0, { row, col + #s })
  vim.api.nvim_exec_autocmds("TextChangedI", {})
  settle()
end

vim.o.virtualedit = "onemore"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x = " })
vim.api.nvim_win_set_cursor(0, { 1, 4 })
gw.request()
feed_partial("compu"); settle()
check("partial shown", text() == "compu", vim.inspect(text()))
check("marked streaming", gw._current().streaming == true)
type_text("co")
check("typing over a streaming suggestion keeps it", text() == "mpu", vim.inspect(text()))
feed_partial("compute(a, b"); settle()
check("more text arrives after typing", text() == "mpute(a, b", vim.inspect(text()))
gw.accept_word()
check("accept word mid-stream", line() == "x = compute", line())
check("rest still streaming", text() == "(a, b", vim.inspect(text()))
feed_done(nil, "compute(a, b) + 1"); settle()
check("final text", text() == "(a, b) + 1", vim.inspect(text()))
check("no longer streaming", gw._current().streaming == false)
gw.accept()
check("accept rest", line() == "x = compute(a, b) + 1", line())
check("suggestion gone", gw._current() == nil)

-- divergent typing drops the suggestion
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "y = " })
vim.api.nvim_win_set_cursor(0, { 1, 4 })
gw.request()
feed_partial("hello"); settle()
type_text("w")
check("non-matching typing clears it", gw._current() == nil)

-- prose without tags never shows (partial nil) and an empty final shows nothing
gw.request()
feed_done(nil, ""); settle()
check("empty final shows nothing", gw._current() == nil)

-- partial JSON decoding
local pj = providers.partial_json_field
check("partial json: open string", pj('{"text": "ab\\ncd', "text") == "ab\ncd")
check("partial json: half escape dropped", pj('{"text": "ab\\', "text") == "ab")
check("partial json: unicode", pj('{"text": "\\u00e9t\\u00e9"}', "text") == "été")
check("partial json: closed", pj('{"text": "done", "x": 1}', "text") == "done")
check("partial json: not yet", pj('{"te', "text") == nil)

os.exit(failures == 0 and 0 or 1)
