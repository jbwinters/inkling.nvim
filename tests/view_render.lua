-- nvim --headless -u NONE -l tests/view_render.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local render = require("inkling.view.render")
local kitty = require("inkling.view.kitty")
local camera = require("inkling.view.canvas")
local failures = 0
local function check(name, condition)
  print((condition and "ok   " or "FAIL ") .. name)
  if not condition then failures = failures + 1 end
end
local executable = vim.fn.executable
vim.fn.executable = function() return 0 end
check("missing Mermaid CLI explained", not render.image_available())
vim.fn.executable = function() return 1 end
kitty.available = function() return true end
kitty.cell_size = function() return 9, 18 end
local transmitted, placements, deleted, unwatched = 0, 0, 0, 0
local restored_id, resume
kitty.upload = function(_, id) transmitted = transmitted + 1; restored_id = id; return id or 42 end
kitty.place = function() placements = placements + 1 end
kitty.delete = function() deleted = deleted + 1 end
kitty.watch = function(cb) resume = cb; return function() unwatched = unwatched + 1 end end
local callback, args, killed
local system = vim.system
vim.system = function(argv, _, cb)
  args, callback = argv, cb
  return { kill = function() killed = true end }
end
local graph = { view = "flow", nodes = { { id = "a", label = "A", kind = "step", parent = "", sources = {} } }, edges = {} }
local done, err
local function start()
  return render.image(graph, {}, vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf(), 15, 6,
    function(e) done, err = true, e end)
end
local h = start()
check("Mermaid invoked with argv and temporary source", args[1] == "mmdc" and vim.fn.filereadable(args[3]) == 1)
check("CLI flags support Mermaid 11 and 12", vim.tbl_contains(args, "-s") and not vim.tbl_contains(args, "-w"))
check("diagrams render at higher resolution by default", args[#args] == "4")
-- Minimal PNG header suffices: decoding belongs to the terminal, dimensions to us.
local png = "\137PNG\r\n\26\n" .. string.rep("\0", 8) .. "\0\0\3\32\0\0\1\144"
local file = assert(io.open(args[5], "wb")); file:write(png); file:close()
callback({ code = 0 }); vim.wait(20)
check("rendered image uploaded with actual PNG dimensions", done and not err and h.id == 42
  and h.camera.width == 800 and h.camera.height == 400 and transmitted == 1)
h:draw(60, 15)
check("layout creates the virtual image placement", placements == 1)
h:present()
vim.wait(120)
check("presentation restores placement after the UI paints", placements == 2)
local initial = placements
camera.zoom(h.camera, 2)
h:draw(60, 15)
h:present()
vim.wait(120)
camera.pan(h.camera, 4, 2)
local grid = h:draw(60, 15)
h:present()
check("pan and zoom reuse the uploaded image", transmitted == 1 and placements == initial + 2 and #grid == 15)
local previous_camera = vim.deepcopy(h.camera)
resume()
vim.wait(120)
check("returning to tmux restores cached pixels and placement", transmitted == 2 and restored_id == 42
  and placements == initial + 4 and vim.deep_equal(h.camera, previous_camera))
camera.zoom(h.camera, 0.5)
h:draw(60, 15)
h:present()
local before_close = placements
h:clear()
h:present()
vim.wait(120)
check("queued presentation cannot paint a closed canvas", placements == before_close)
check("image cleanup deletes only owned image and temporary files", deleted == 1
  and placements == before_close and unwatched == 1 and h.png == nil
  and vim.fn.filereadable(args[3]) == 0 and vim.fn.filereadable(args[5]) == 0)
resume()
check("late visibility callbacks cannot restore a closed canvas", transmitted == 2)
done = false
h = start(); h:clear(); callback({ code = 0 }); vim.wait(20)
check("cancelled image cannot render late", killed and not done and transmitted == 2)
h = start(); callback({ code = 1, stderr = "invalid diagram" }); vim.wait(20)
check("renderer errors returned for native fallback", err:find("invalid diagram", 1, true) ~= nil)
h:clear()
h = start(); file = assert(io.open(args[5], "wb")); file:write("invalid PNG"); file:close()
callback({ code = 0 }); vim.wait(20)
check("invalid raster does not reach terminal", err:find("Invalid", 1, true) ~= nil and transmitted == 2)
h:clear()
vim.system, vim.fn.executable = system, executable
os.exit(failures == 0 and 0 or 1)
