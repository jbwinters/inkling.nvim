-- Kitty Unicode placeholders keep graphics clipped to their Neovim buffer,
-- including when tmux changes panes or Neovim opens another window over it.
-- Protocol: https://sw.kovidgoyal.net/kitty/graphics-protocol/
local M = {}
local uv = vim.uv or vim.loop
local output
local next_id = 0x100000 + (uv.hrtime() % 0xd00000)
local alphabet = require("inkling.view.diacritics")
local placeholder = vim.fn.nr2char(0x10eeee)
local marks = {}
for _, code in ipairs(alphabet) do table.insert(marks, vim.fn.nr2char(code)) end

function M.available(force)
  if #vim.api.nvim_list_uis() == 0 then return false, "Mermaid canvas needs a terminal UI" end
  local program = (vim.env.TERM_PROGRAM or ""):lower()
  local known = program == "kitty" or program == "ghostty"
    or ((program == "" or program == "tmux" or program == "screen")
      and (vim.env.KITTY_WINDOW_ID or vim.env.GHOSTTY_RESOURCES_DIR
      or (vim.env.TERM or ""):find("kitty", 1, true) or (vim.env.TERM or ""):find("ghostty", 1, true)))
  if not force and not known then
    return false, "Direct canvas needs Kitty 0.28+ or Ghostty"
  end
  if not vim.o.termguicolors then return false, "Mermaid canvas needs :set termguicolors" end
  if vim.env.TMUX then
    if (vim.env.TMUX_PANE or "") == "" then return false, "Cannot identify tmux pane (TMUX_PANE is missing)" end
    local result = vim.fn.system({ "tmux", "show-options", "-Apv", "-t", vim.env.TMUX_PANE, "allow-passthrough" })
    if vim.v.shell_error ~= 0 or not vim.trim(result):match("^on") then
      return false, "Mermaid canvas needs tmux allow-passthrough on for this pane"
    end
  end
  return true
end

function M.cell_size()
  if vim.env.TMUX then
    local result = vim.fn.system({ "tmux", "display-message", "-p", "-t", vim.env.TMUX_PANE or "",
      "#{client_cell_width} #{client_cell_height}" })
    local w, h = result:match("(%d+)%s+(%d+)")
    if tonumber(w) and tonumber(w) > 0 and tonumber(h) > 0 then return tonumber(w), tonumber(h) end
  end
  -- TIOCGWINSZ also works outside tmux. Fall back to a standard 1:2 cell ratio.
  local ok, w, h = pcall(function()
    local ffi = require("ffi")
    pcall(ffi.cdef, "int ioctl(int fd, unsigned long request, ...);")
    local size = ffi.new("unsigned short[4]")
    local request = vim.fn.has("macunix") == 1 and 0x40087468 or 0x5413
    if ffi.C.ioctl(1, request, size) == 0 and size[0] > 0 and size[1] > 0 and size[2] > 0 and size[3] > 0 then
      return size[2] / size[1], size[3] / size[0]
    end
  end)
  if ok and w and h then return w, h end
  return 8, 16
end

function M.send(control, data)
  local payload = "\27_G" .. control .. (data and (";" .. data) or "") .. "\27\\"
  if vim.env.TMUX then payload = "\27Ptmux;" .. payload:gsub("\27", "\27\27") .. "\27\\" end
  if vim.api.nvim_ui_send then
    -- Newer Neovim sends graphics through the TUI's own output queue.
    vim.api.nvim_ui_send(payload)
  else
    -- Finish each escape sequence before allowing a redraw. Queued libuv TTY
    -- writes can split a graphics sequence around the separate TUI process's
    -- screen updates, making tmux consume those updates as image data.
    if not output then
      output = io.open("/dev/tty", "wb")
      if not output then
        -- The separate Neovim core may have no controlling terminal. Reopen
        -- stdout's terminal by name to get our own blocking descriptor; do not
        -- share the TUI's nonblocking file flags via dup/new_tty.
        local ffi = require("ffi")
        pcall(ffi.cdef, "char *ttyname(int fd);")
        local name = ffi.C.ttyname(1)
        assert(name ~= nil, "Cannot locate terminal output")
        output = assert(io.open(ffi.string(name), "wb"))
      end
      output:setvbuf("no")
    end
    assert(output:write(payload))
    assert(output:flush())
  end
end

function M.upload(png, id)
  if not id then
    next_id = next_id % 0xffffff + 1
    id = next_id
  end
  local data = vim.base64.encode(png)
  -- Leave room for protocol/tmux headers below the usual 4096-byte TTY buffer.
  for offset = 1, #data, 3072 do
    local chunk = data:sub(offset, offset + 3071)
    local more = offset + #chunk <= #data and 1 or 0
    M.send((offset == 1 and ("a=t,f=100,t=d,q=2,i=" .. id .. ",") or "") .. "m=" .. more, chunk)
  end
  return id
end

-- tmux can erase Kitty's image store on a full redraw. An inactive pane does
-- not receive FocusGained when its window becomes visible, so watch visibility
-- while a canvas is open. Never send images into a hidden/zoomed-away pane.
function M.watch(on_visible, on_hidden)
  if not vim.env.TMUX or not vim.env.TMUX_PANE then return end
  local timer, pending, closed, last = uv.new_timer(), false, false, nil
  timer:start(0, 750, vim.schedule_wrap(function()
    if closed or pending then return end
    pending = true
    vim.system({ "tmux", "display-message", "-p", "-t", vim.env.TMUX_PANE,
      "#{session_attached}:#{window_active}:#{window_zoomed_flag}:#{pane_active}:#{client_pid}:#{client_width}:#{client_height}" },
      { text = true, timeout = 2000 }, vim.schedule_wrap(function(result)
        pending = false
        if closed then return end
        local value = vim.trim(result.stdout or "")
        local attached, active, zoomed, pane = value:match("^(%d+):(%d+):(%d+):(%d+):")
        local visible = result.code == 0 and attached and tonumber(attached) > 0 and active == "1"
          and (zoomed == "0" or pane == "1")
        local signature = visible and value:gsub("^(%d+):1:0:%d+:", "%1:1:0:0:") or "hidden"
        if visible and signature ~= last then on_visible() end
        if not visible and signature ~= last and on_hidden then on_hidden() end
        last = signature
      end))
  end))
  return function() closed = true; timer:stop(); timer:close() end
end

function M.place(id, columns, rows)
  M.send(("a=p,U=1,q=2,C=1,i=%d,p=1,c=%d,r=%d"):format(id, columns, rows))
end

function M.delete(id) if id then M.send("a=d,d=I,q=2,i=" .. id) end end

function M.grid(c)
  local lines = {}
  for row = 0, c.rows - 1 do
    local out = {}
    for col = 0, c.columns - 1 do
      local x, y = col - c.left + c.x, row - c.top + c.y
      if col >= c.left and row >= c.top and x < c.image_columns and y < c.image_rows then
        out[#out + 1] = placeholder .. marks[y + 1] .. marks[x + 1]
      else out[#out + 1] = " " end
    end
    lines[#lines + 1] = table.concat(out)
  end
  return lines
end

return M
