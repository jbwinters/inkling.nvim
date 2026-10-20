-- A small editable split keeps a question beside its diagram and conversation.
local M = {}

function M.open(opts)
  local previous = vim.api.nvim_get_current_win()
  vim.cmd("belowright 4new")
  local input = { win = vim.api.nvim_get_current_win(), buf = vim.api.nvim_get_current_buf() }
  vim.bo[input.buf].buftype = "nofile"
  vim.bo[input.buf].bufhidden = "wipe"
  vim.bo[input.buf].swapfile = false
  vim.bo[input.buf].filetype = "inkling-input"
  vim.api.nvim_buf_set_name(input.buf, "inkling://draft/" .. input.buf)
  vim.wo[input.win].number = false
  vim.wo[input.win].relativenumber = false
  vim.wo[input.win].signcolumn = "no"
  vim.wo[input.win].wrap = true
  vim.wo[input.win].linebreak = true
  vim.wo[input.win].winfixheight = true
  vim.wo[input.win].winbar = " " .. opts.title:gsub("%%", "%%%%")
  vim.wo[input.win].statusline = " Ctrl-S send · Enter newline · Esc normal · q cancel"
  vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, vim.split(opts.default or "", "\n", { plain = true }))
  local closed = false
  local function text()
    return vim.api.nvim_buf_is_valid(input.buf) and table.concat(vim.api.nvim_buf_get_lines(input.buf, 0, -1, false), "\n") or ""
  end
  function input.close(send)
    if closed then return end
    local answer = text()
    if send and vim.trim(answer) == "" then return end
    closed = true
    local focused = vim.api.nvim_get_current_win() == input.win
    if focused then vim.cmd("stopinsert") end
    if opts.save then opts.save(send and "" or answer) end
    if vim.api.nvim_win_is_valid(input.win) then vim.api.nvim_win_close(input.win, true) end
    if focused and vim.api.nvim_win_is_valid(previous) then vim.api.nvim_set_current_win(previous) end
    if send then opts.submit(answer) end
  end
  vim.keymap.set({ "i", "n" }, "<C-s>", function() input.close(true) end, { buffer = input.buf, desc = "inkling: send" })
  vim.keymap.set("n", "q", function() input.close(false) end, { buffer = input.buf, desc = "inkling: keep draft and close" })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = input.buf, once = true, callback = function()
    if not closed and opts.save then opts.save(text()) end
    closed = true
  end })
  vim.api.nvim_win_set_cursor(input.win, { vim.api.nvim_buf_line_count(input.buf), 0 })
  vim.cmd("startinsert!")
  return input
end

return M
