-- nvim --headless -u NONE -l tests/view_canvas.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local canvas = require("inkling.view.canvas")
local kitty = require("inkling.view.kitty")
local graphs = require("inkling.view.graph")
local failures = 0
local function check(name, condition)
  print((condition and "ok   " or "FAIL ") .. name)
  if not condition then failures = failures + 1 end
end
local c = canvas.layout(canvas.new(1600, 900, 9, 18), 80, 30)
check("fit preserves aspect ratio in terminal cells", c.image_columns == 80 and c.image_rows == 22 and c.top == 4)
local before = (c.x + 40 - c.left) / c.image_columns
canvas.zoom(c, 2, 40, 15)
check("zoom preserves the point under the pointer", math.abs((c.x + 40 - c.left) / c.image_columns - before) < 0.02)
canvas.pan(c, 12, 5)
check("pan moves the viewport", c.x > 40 and c.y > 7)
canvas.pan(c, 10000, 10000)
check("pan clamps to the image boundary", c.x == c.image_columns - c.columns and c.y == c.image_rows - c.rows)
local grid = kitty.grid(c)
check("viewport clips to window dimensions", #grid == 30 and vim.fn.strdisplaywidth(grid[1]) == 80)
canvas.zoom(c, 1000)
check("zoom cannot exceed terminal coordinate limits", c.image_columns <= 297 and c.image_rows <= 297)
canvas.layout(c, 120, 40)
check("resize keeps the viewport in bounds", c.x >= 0 and c.x <= math.max(0, c.image_columns - 120))
canvas.fit(c)
check("fit resets zoom and pan", c.zoom == 1 and c.x == 0 and c.y == 0)
canvas.zoom(c, 0.01)
check("zoom out remains visible and centered", c.zoom == 0.25 and c.left > 0 and c.top > 0)
local a = graphs.schema_for("components").properties.nodes.items.properties.kind.enum
local b = graphs.schema_for("flow").properties.nodes.items.properties.kind.enum
check("components and flow use distinct generation schemas", vim.deep_equal(a, { "group", "component" })
  and vim.deep_equal(b, { "step", "decision" }))
local sent = {}
local raw_send = kitty.send
local ui_send, open = vim.api.nvim_ui_send, io.open
local output, flushed
vim.api.nvim_ui_send = function(payload) output = payload end
raw_send("a=p,i=42")
check("graphics use the TUI output queue when available", output and output:find("a=p,i=42", 1, true) ~= nil)
vim.api.nvim_ui_send = nil
io.open = function() return { write = function(_, payload) output = payload; return true end,
  setvbuf = function() end, flush = function() flushed = true; return true end } end
raw_send("a=p,i=43")
io.open, vim.api.nvim_ui_send = open, ui_send
check("older Neovim finishes graphics output before returning to redraw", flushed
  and output:find("a=p,i=43", 1, true) ~= nil)
kitty.send = function(control, data) table.insert(sent, { control, data }) end
local id = kitty.upload(string.rep("x", 10000))
check("PNG upload leaves room for TTY headers and a final chunk", #sent > 1 and #sent[1][2] <= 3072
  and sent[#sent][1] == "m=0" and sent[1][1]:find("i=" .. id, 1, true) ~= nil)
kitty.place(id, 80, 30)
check("virtual placement stays anchored in buffer text", sent[#sent][1]:find("U=1", 1, true) ~= nil)
kitty.delete(id)
check("cleanup targets only the owned image", sent[#sent][1] == "a=d,d=I,q=2,i=" .. id)
sent = {}
check("restoring pixels retains the placeholder image ID", kitty.upload("pixels", id) == id
  and sent[1][1]:find("i=" .. id, 1, true) ~= nil)

-- Poll tmux without requiring a real server; verify visibility transitions,
-- including an inactive pane that cannot receive a Neovim FocusGained event.
local uv = vim.uv or vim.loop
local new_timer, system = uv.new_timer, vim.system
local tmux, pane = vim.env.TMUX, vim.env.TMUX_PANE
vim.env.TMUX, vim.env.TMUX_PANE = "test", "%70"
local tick, stopped, resumed = nil, false, 0
uv.new_timer = function() return {
  start = function(_, _, _, cb) tick = cb end,
  stop = function() stopped = true end, close = function() end,
} end
local status = "1:1:0:0:123:284:77"
vim.system = function(_, _, cb) cb({ code = 0, stdout = status }); return {} end
local unwatch = kitty.watch(function() resumed = resumed + 1 end)
local function poll(value) status = value; tick(); vim.wait(10) end
poll(status)
poll("1:1:0:1:123:284:77")
check("tmux pane focus changes do not repeatedly upload images", resumed == 1)
poll("1:0:0:0:123:284:77")
poll("1:1:0:0:123:284:77")
check("returning to a tmux window restores even its inactive canvas pane", resumed == 2)
poll("1:1:1:0:123:284:77")
check("zoomed-away panes stay hidden", resumed == 2)
poll("1:1:0:0:123:284:77")
poll("1:1:0:0:123:280:77")
check("unzooming and client resizing restore image data", resumed == 4)
unwatch(); poll("1:1:0:0:124:280:77")
check("closing the canvas stops its tmux watcher", stopped and resumed == 4)
uv.new_timer, vim.system = new_timer, system
vim.env.TMUX, vim.env.TMUX_PANE = tmux, pane
os.exit(failures == 0 and 0 or 1)
