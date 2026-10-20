-- nvim --headless -u NONE -i NONE -l tests/view_images.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local kitty = require("inkling.view.kitty")
local adapter = require("inkling.view.image_nvim")
local render = require("inkling.view.render")
local config = require("inkling.config")
local canvas = require("inkling.view.canvas")
local failures = 0
local function check(name, condition)
  print((condition and "ok   " or "FAIL ") .. name)
  if not condition then failures = failures + 1 end
end
local function contains(s, part) return s and s:find(part, 1, true) ~= nil end
-- Isolate terminal detection from whichever terminal runs the tests.
for _, key in ipairs({ "KITTY_WINDOW_ID", "GHOSTTY_RESOURCES_DIR", "TERM_PROGRAM", "TMUX", "TMUX_PANE" }) do vim.env[key] = nil end
vim.env.TERM = "xterm-256color"
vim.o.termguicolors = true
local uis = vim.api.nvim_list_uis
vim.api.nvim_list_uis = function() return { {} } end
check("unknown terminal does not receive Kitty escape sequences", not kitty.available())
vim.env.TERM_PROGRAM = "ghostty"
check("Ghostty uses the direct canvas", kitty.available())
vim.env.TERM_PROGRAM, vim.env.GHOSTTY_RESOURCES_DIR = "tmux", "/test/ghostty"
check("Ghostty remains detectable inside tmux", kitty.available())
vim.env.GHOSTTY_RESOURCES_DIR, vim.env.KITTY_WINDOW_ID = nil, "1"
check("Kitty remains detectable inside tmux", kitty.available())
vim.env.TERM_PROGRAM = "WezTerm"
check("known other terminals do not inherit stale Kitty detection", not kitty.available())
check("explicit Kitty backend allows a compatible unknown terminal", kitty.available(true))
vim.o.termguicolors = false
check("explicit backend still checks truecolor", not kitty.available(true))
vim.o.termguicolors = true
vim.env.TMUX, vim.env.TMUX_PANE = "test", "%70"
local system_fn = vim.fn.system
local passthrough = "off"
vim.fn.system = function() return passthrough end
check("direct canvas requires tmux passthrough", not kitty.available(true))
passthrough = "on"
check("tmux passthrough permits direct rendering", kitty.available(true))
vim.env.TMUX_PANE = nil
check("direct canvas rejects an unidentified tmux pane", not kitty.available(true))
local _, pane_error = adapter.available()
check("optional canvas explains a missing tmux pane ID", contains(pane_error, "TMUX_PANE"))
vim.env.TMUX, vim.env.TMUX_PANE = nil, nil
vim.fn.system = system_fn

local executable = vim.fn.executable
local has_magick = false
vim.fn.executable = function(name) return (name == "mmdc" or (name == "magick" and has_magick)) and 1 or 0 end
package.preload.image = function() error("not installed") end
config.options.view.image_backend = "auto"
local ok, err = render.image_available()
check("unsupported terminal falls back with actionable reason", not ok and contains(err, "image.nvim"))
local rendered, shallow, cleared, created = 0, 0, 0, {}
local enabled, create_error, render_error, silent = true, nil, nil, false
package.loaded.image = {
  is_enabled = function() return enabled end,
  from_file = function(path, opts)
    if create_error then error(create_error) end
    local image = { path = path, opts = opts, is_rendered = false,
      render = function(self)
        if render_error then error(render_error) end
        if silent then return end
        self.is_rendered = true
        rendered = rendered + 1
      end,
      clear = function(self, keep)
        self.is_rendered = false
        if keep then shallow = shallow + 1 else cleared = cleared + 1 end
      end,
    }
    created[#created + 1] = image
    return image
  end,
}
ok, err = render.image_available()
check("optional adapter requires its viewport processor", not ok and contains(err, "ImageMagick"))
has_magick = true
local backend
ok, err, backend = render.image_available()
check("auto selects configured image.nvim on other terminals", ok and backend == "image.nvim")
enabled = false
check("disabled image.nvim is respected", not render.image_available())
enabled = true
vim.env.TERM_PROGRAM = "ghostty"
ok, err, backend = render.image_available()
check("auto prefers the dependency-free direct backend", ok and backend == "kitty")
config.options.view.image_backend = "image.nvim"
ok, err, backend = render.image_available()
check("explicit image.nvim overrides terminal detection", ok and backend == "image.nvim")
config.options.view.image_backend = "invalid"
ok, err = render.image_available()
check("invalid backend produces a useful fallback reason", not ok and contains(err, "Unknown"))
config.options.view.image_backend = "auto"
vim.api.nvim_list_uis = function() return {} end
check("headless Neovim never emits images", not render.image_available())
vim.api.nvim_list_uis = function() return { {} } end

-- Control asynchronous viewport transforms; no terminal or external program needed.
local system, jobs = vim.system, {}
vim.system = function(argv, opts, cb)
  local job = { argv = argv, callback = cb, opts = opts }
  job.process = { kill = function() job.killed = true end }
  jobs[#jobs + 1] = job
  return job.process
end
local function complete(job, code)
  vim.fn.writefile({ "viewport" }, job.argv[#job.argv])
  job.callback({ code = code or 0, stderr = code and "conversion failed" or "" })
  vim.wait(10)
end
local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
vim.o.lines, vim.o.columns = 50, 100
vim.api.nvim_win_set_height(win, 40)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn["repeat"]({ string.rep(" ", 80) }, 40))
local errors = {}
local function start()
  return adapter.new("/tmp/cached diagram.png", win, buf, 5, function(e) errors[#errors + 1] = e end)
end
local c = canvas.layout(canvas.new(1600, 900, 10, 20), 60, 20)
local h = start()
local grid = h:draw(c)
vim.wait(70)
check("adapter reserves text cells without Unicode placeholders", #grid == 20 and #grid[1] == 60
  and not contains(grid[1], vim.fn.nr2char(0x10eeee)))
check("viewport transforms use argument arrays and a timeout", #jobs == 1 and jobs[1].argv[2] == "/tmp/cached diagram.png"
  and jobs[1].opts.timeout == 10000)
complete(jobs[1])
local first = created[#created]
check("image belongs to the diagram window below its header", first.opts.window == win and first.opts.buffer == buf
  and first.opts.y >= 5 and first.opts.namespace == "inkling" and first.ignore_global_max_size and rendered == 1)
check("source PNG is cropped to fitted cell dimensions", jobs[1].argv[4] == "600x320!"
  and jobs[1].argv[6] == "600x320+0+0")
h:draw(c); h:present(); vim.wait(70)
check("unchanged redraw reuses the viewport", #jobs == 1 and rendered == 2)
canvas.zoom(c, 2); canvas.pan(c, 4, 3)
h:draw(c); h:draw(c); vim.wait(70)
check("zoom and pan transform the cached raster once per burst", #jobs == 2 and jobs[2].argv[2] == jobs[1].argv[2]
  and jobs[2].argv[4] == "1200x640!" and contains(jobs[2].argv[6], "+340+180"))
complete(jobs[2])
check("replaced viewport releases its image and file", cleared == 1 and vim.fn.filereadable(first.path) == 0)
check("camera updates reuse one owned backend ID", first.opts.id == h.image.opts.id and first.path ~= h.file)
-- A picker must cover the image even if image.nvim calls render on its own.
local float_buf = vim.api.nvim_create_buf(false, true)
local count = rendered
local floating = vim.api.nvim_open_win(float_buf, false, { relative = "editor", row = 4, col = 4, width = 20, height = 5 })
vim.wait(20)
check("a nonfocused floating window automatically hides the image", rendered == count and not h.image.is_rendered)
h.image:render()
check("floating pickers hide image.nvim graphics", rendered == count and shallow > 0)
vim.api.nvim_win_close(floating, true); vim.wait(20)
check("closing a picker restores the diagram", rendered > count)
count = rendered
h:restore()
check("manual restore uses the existing viewport", #jobs == 2 and rendered == count + 1)

-- Shrink the image window while its next crop is still pending.
count = rendered
vim.cmd("vsplit")
local split = vim.api.nvim_get_current_win()
vim.wait(20); h:present()
check("resizing cannot paint an old viewport into the neighboring pane", rendered == count and not h.image.is_rendered)
canvas.layout(c, vim.api.nvim_win_get_width(win) - 2, 20)
h:draw(c); vim.wait(70); complete(jobs[#jobs])
check("resized viewport becomes visible when its crop is ready", h.image.is_rendered
  and h.image.opts.width <= vim.api.nvim_win_get_width(win))
vim.api.nvim_win_close(split, true)
canvas.layout(c, 60, 20)
h:draw(c); vim.wait(70); complete(jobs[#jobs])

canvas.pan(c, 1, 1); h:draw(c); vim.wait(70)
local late = jobs[#jobs]
canvas.pan(c, 1, 1); h:draw(c); vim.wait(70)
check("a newer camera position cancels the old transform", late.killed == true)
count = #created
complete(late)
check("late viewport completion cannot replace current pixels", #created == count and vim.fn.filereadable(late.argv[#late.argv]) == 0)
complete(jobs[#jobs])
local current, pending = h.file
canvas.pan(c, 1, 1); h:draw(c); vim.wait(70); pending = jobs[#jobs]
count = #created
h:clear(); h:clear(); complete(pending); h:present()
check("close cancels jobs and removes viewport files", pending.killed and vim.fn.filereadable(current) == 0
  and vim.fn.filereadable(pending.argv[#pending.argv]) == 0 and #created == count)

h = start(); h:draw(c); vim.wait(70); complete(jobs[#jobs], 1)
check("conversion failure reports text fallback once", h.closed and #errors == 1 and contains(errors[1], "conversion failed"))
create_error = "image.nvim is not setup"
h = start(); h:draw(c); vim.wait(70); complete(jobs[#jobs])
check("unconfigured image.nvim reports text fallback", h.closed and #errors == 2 and contains(errors[2], "not setup"))
create_error, render_error = nil, "backend unavailable"
h = start(); h:draw(c); vim.wait(70); complete(jobs[#jobs])
check("backend render failure releases resources and falls back", h.closed and #errors == 3
  and contains(errors[3], "backend unavailable") and vim.fn.filereadable(jobs[#jobs].argv[#jobs[#jobs].argv]) == 0)
render_error = nil
local defer, deadline = vim.defer_fn, nil
vim.defer_fn = function(cb, ms)
  if ms == 10000 then deadline = cb; return {} end
  return defer(cb, ms)
end
silent = true
h = start(); h:draw(c); vim.wait(70); complete(jobs[#jobs])
check("silent backend failures have a bounded wait", deadline and not h.closed)
deadline()
check("a backend that never displays falls back to text", h.closed and #errors == 4
  and contains(errors[4], "did not display"))
silent, vim.defer_fn = false, defer

-- Rendering lifecycle retains the original PNG for camera transforms.
config.options.view.image_backend = "image.nvim"
local graph = { view = "flow", nodes = { { id = "a", label = "A", kind = "step", parent = "", sources = {} } }, edges = {} }
local png = "\137PNG\r\n\26\n" .. string.rep("\0", 8) .. "\0\0\3\32\0\0\1\144"
local ready, failure = false, nil
h = render.image(graph, {}, win, buf, 15, 5, function(e) ready, failure = true, e end)
local mermaid = jobs[#jobs]
local file = assert(io.open(mermaid.argv[5], "wb")); file:write(png); file:close()
mermaid.callback({ code = 0 }); vim.wait(20)
check("image.nvim keeps the original PNG for future pan and zoom", ready and not failure
  and h.external and not h.id and vim.fn.filereadable(mermaid.argv[5]) == 1)
h:draw(60, 15); vim.wait(70); complete(jobs[#jobs])
h:clear()
check("closing the renderer deletes retained original and viewport", vim.fn.filereadable(mermaid.argv[5]) == 0
  and vim.fn.filereadable(jobs[#jobs].argv[#jobs[#jobs].argv]) == 0)

local watch, visible, hidden, unwatched = kitty.watch, nil, nil, false
kitty.watch = function(show, hide)
  visible, hidden = show, hide
  return function() unwatched = true end
end
vim.env.TMUX, vim.env.TMUX_PANE = "test", "%70"
h = start(); count = rendered
h:draw(c); vim.wait(70); complete(jobs[#jobs])
check("tmux adapter waits until its pane is visible", rendered == count)
visible()
check("visible tmux pane presents the cached viewport", rendered == count + 1)
hidden(); h.image:render()
check("hidden tmux pane suppresses plugin-initiated redraws", rendered == count + 1 and not h.image.is_rendered)
h:clear(); visible()
check("closing tmux adapter stops watcher and ignores late callbacks", unwatched and rendered == count + 1)
vim.env.TMUX, vim.env.TMUX_PANE, kitty.watch = nil, nil, watch

vim.system, vim.fn.executable, vim.api.nvim_list_uis = system, executable, uis
os.exit(failures == 0 and 0 or 1)
