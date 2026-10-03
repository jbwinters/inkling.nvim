-- nvim --headless -u NONE -l tests/live_context.lua [provider]
-- Real request with full project context, using this plugin's own source as the project.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("filetype on")
local gw = require("inkling")
gw.setup({ provider = _G.arg[1] or "openai", debounce_ms = 10 })
-- pin the provider under test (a remembered `:Inkling use` choice would override it)
do
  local cfg = require("inkling.config")
  cfg.options.provider = _G.arg[1] or "openai"
  cfg.options.providers[_G.arg[1] or "openai"].model = require("inkling.config").defaults.providers[_G.arg[1] or "openai"].model
end

local project = require("inkling.context.project")

vim.cmd("edit " .. root .. "/lua/inkling/providers.lua")
vim.o.virtualedit = "onemore"
local n = vim.api.nvim_buf_line_count(0)
-- add a stub before the final `return M`
vim.api.nvim_buf_set_lines(0, n - 1, n - 1, false, { "-- Names of all configured providers, sorted.", "function M.list_providers()", "  " })
vim.api.nvim_win_set_cursor(0, { n + 2, 2 })

project.refresh(0)
vim.wait(5000, function() return select(2, project.get(0)) > 0 end, 20)
local text, _, summary = project.get(0)
print(("project context: %d chars"):format(#text))
print(table.concat(summary, "\n"))

vim.api.nvim_get_mode = function() return { mode = "i" } end
for attempt = 1, 2 do
  local t0 = vim.uv.hrtime()
  gw.dismiss()
  require("inkling")._clear_cache()
  gw.request()
  local ok = vim.wait(30000, function() return gw._current() ~= nil end, 20)
  print(("attempt %d: %s in %.0fms %s"):format(attempt, ok and "suggestion" or "NO suggestion", (vim.uv.hrtime() - t0) / 1e6, gw._last_error() or ""))
  if ok and attempt == 1 then print("----\n" .. gw._current().text .. "\n----") end
end
vim.cmd("bwipeout!")
