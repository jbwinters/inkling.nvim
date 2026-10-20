-- nvim --headless -u NONE -l tests/view.lua
-- Diagram workspace, real buffers/windows and deterministic provider responses.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("filetype on")
vim.o.columns, vim.o.lines = 140, 55
require("inkling.usage").path = function() return vim.fn.tempname() end
local requests = {}
local providers = require("inkling.providers")
providers.run = function(job, _, cb)
  local r = { job = job, cb = cb, killed = false }
  table.insert(requests, r)
  return { kill = function() r.killed = true end }
end
require("inkling").setup({ enabled = false, view = { debounce_ms = 10 } })
local view = require("inkling.view")
local source = require("inkling.view.source")
local graphs = require("inkling.view.graph")
local render = require("inkling.view.render")
local config = require("inkling.config")
local failures = 0
local function check(name, condition)
  print((condition and "ok   " or "FAIL ") .. name)
  if not condition then failures = failures + 1 end
end
local function settle() vim.wait(40) end
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/.git", "p")
vim.fn.mkdir(tmp .. "/helpers", "p")
local path = tmp .. "/app.py"
vim.fn.writefile({ "def run(user):", "    if user is None:", "        return None", "    return user.name", "",
  "def other():", "    return 2" }, path)
vim.fn.writefile({ "def allowed(user):", "    return user.admin" }, tmp .. "/helpers/check.py")
vim.cmd("edit " .. vim.fn.fnameescape(path))
local buf = vim.api.nvim_get_current_buf()
local original_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(0, { 2, 0 })
local scope = source.focus(buf, 2, "flow")
check("flow scope is enclosing function", scope.first == 1 and scope.last == 4)
check("other function has distinct scope", source.focus(buf, 7, "flow").first == 6)
check("component scope is entire file", source.focus(buf, 2, "components").last == 7)
local ctx = assert(source.collect(scope))
check("snapshot includes numbered source", source.prompt(ctx):find("2|     if user is None:", 1, true) ~= nil)
check("snapshot reserves investigation capacity", ctx.max_files > #ctx.order and ctx.max_chars > ctx.chars)
check("path traversal rejected", source.path(tmp, "../outside.py") == nil)
local outside = vim.fn.tempname()
vim.fn.writefile({ "private" }, outside)
vim.uv.fs_symlink(outside, tmp .. "/escape.py")
check("symlink escape rejected", source.path(tmp, "escape.py") == nil)
check("out-of-excerpt evidence rejected", #source.references({ { path = "app.py", start_line = 1, end_line = 1000 } }, ctx) == 0)

local function refs(a, b) return { { path = "app.py", start_line = a, end_line = b or a } } end
local graph = { title = "User lookup", summary = "Checks a user before reading a name.", omissions = {},
  nodes = {
    { id = "lookup", label = "Lookup", detail = "", kind = "group", parent = "", sources = refs(1, 4) },
    { id = "guard", label = 'User "present"?', detail = "Handles missing users", kind = "decision", parent = "lookup", sources = refs(2, 3) },
    { id = "name", label = "Return name", detail = "", kind = "step", parent = "lookup", sources = refs(4) },
  }, edges = { { id = "success", from = "guard", to = "name", label = "yes", inferred = false, sources = refs(2, 4) } } }
local validated = assert(graphs.validate(graph, ctx, config.options.view))
local mermaid = graphs.mermaid(validated)
check("nested Mermaid groups", mermaid:find('subgraph n_lookup["Lookup"]', 1, true) ~= nil)
check("Mermaid labels escaped", mermaid:find("&quot;present&quot;", 1, true) ~= nil)
check("native nested boxes and relationships", #render.native(validated, 60) > 10
  and table.concat(vim.tbl_map(function(r) return r.text end, render.native(validated, 60)), "\n"):find("─▶", 1, true) ~= nil)
local bad = vim.deepcopy(graph)
bad.nodes[1].parent = "lookup"
check("group cycles rejected", graphs.validate(bad, ctx, config.options.view) == nil)
bad = vim.deepcopy(graph)
bad.edges[1].to = "absent"
check("unknown relationship targets rejected", graphs.validate(bad, ctx, config.options.view) == nil)
bad = vim.deepcopy(graph)
bad.nodes[2].sources = { { path = "../outside.py", start_line = 1, end_line = 1 } }
check("missing evidence visible", #assert(graphs.validate(bad, ctx, config.options.view)).omissions > 0)
local component_ctx = vim.deepcopy(ctx)
component_ctx.scope.view = "components"
bad = vim.deepcopy(graph)
for _, node in ipairs(bad.nodes) do node.parent = "" end
check("flat components trigger structural correction", graphs.validate(bad, component_ctx, config.options.view) == nil)

local function reply(obj)
  requests[#requests].cb(nil, vim.deepcopy(obj))
  settle()
end
vim.cmd("Inkling view flow")
check("diagrams work with completions disabled", #requests == 1 and requests[1].job.schema ~= nil)
bad = vim.deepcopy(graph)
bad.nodes[1].parent = "lookup"
reply(bad)
check("invalid graph gets one corrective request", #requests == 2 and requests[2].job.tail:find("Group cycle", 1, true) ~= nil)
reply(graph)
local s = view._state()
check("diagram opens beside original source", s.entry and vim.api.nvim_win_is_valid(original_win) and s.win ~= original_win)
check("initial view follows source", s.follow and vim.api.nvim_get_current_win() == original_win)
local count = #requests
vim.api.nvim_win_set_cursor(original_win, { 3, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
settle()
check("movement within scope reuses diagram", #requests == count)

local picker = require("inkling.view.picker")
local picker_open, menu = picker.open
local ui_select, fallback = vim.ui.select
vim.ui.select = function(items, opts, callback)
  fallback = opts.format_item(items[1])
  callback(items[1])
end
local picked
picker_open({ { label = "Without Telescope" } }, { title = "Fallback" }, function(item) picked = item end)
vim.ui.select = ui_select
check("picker works without Telescope", fallback == "Without Telescope" and picked.label == fallback)
picker.open = function(items, opts, callback) menu = { items = items, opts = opts, choose = callback } end
view.select()
check("element picker previews checked source", menu.opts.preview(menu.items[2])[1]:find('User "present"?', 1, true)
  and table.concat(menu.opts.preview(menu.items[2]), "\n"):find("2|     if user is None:", 1, true))
menu.choose(nil)
check("cancel selection leaves source and graph unchanged", s.selection == nil and #requests == count)
menu.choose(menu.items[2])
check("selection focuses diagram without AI requests", s.selection == "guard" and vim.api.nvim_get_current_win() == s.win and #requests == count)
view.deselect()
view.source()
check("Enter without a selection offers source search", menu.opts.title == "Open element source")
menu.choose(menu.items[2])
check("source picker opens evidence in existing code pane", vim.api.nvim_get_current_win() == original_win
  and vim.api.nvim_win_get_cursor(original_win)[1] == 2)
view.actions()
check("action menu exposes source and coverage", menu.opts.title:find("Inkling actions", 1, true)
  and menu.items[1].label:find("coverage", 1, true))
view.choose_view()
menu.choose(menu.items[2])
check("choosing current view does not regenerate", #requests == count)
view.ask()
local empty_draft = s.input
check("first question does not open an empty conversation", empty_draft and not s.chat_win)
empty_draft.close(false)
view.select()
local old_selection_menu = menu
picker.open = picker_open

vim.api.nvim_set_current_win(s.win)
settle()
s.selection = "guard"
view.source()
check("source navigation pins and opens correct line", not s.follow and vim.api.nvim_win_get_cursor(original_win)[1] == 2)
view.ask("Can a missing user reach the name access?")
check("question inherits selection and source", requests[#requests].job.tail:find("guard", 1, true) ~= nil
  and requests[#requests].job.head:find("if user is None", 1, true) ~= nil)
reply({ answer = "", sources = {}, highlight_nodes = {}, highlight_edges = {},
  read_paths = { "helpers/check.py", "../outside.py" }, search = "" })
check("question can gather additional source", requests[#requests].job.head:find("return user.admin", 1, true) ~= nil)
reply({ answer = "The missing-user branch returns before accessing the name.", sources = refs(2, 4),
  highlight_nodes = { "guard", "name", "unknown" }, highlight_edges = { "success" }, read_paths = {}, search = "" })
check("answer displayed with checked references", #s.entry.messages == 2 and #s.entry.messages[2].sources == 1)
check("answer highlights path", s.entry.highlights.success and s.entry.highlights.guard and not s.entry.highlights.unknown)
check("conversation stays pinned", not s.follow and s.pending == nil)
check("new answer starts at its beginning", vim.api.nvim_win_get_cursor(s.chat_win)[1] == 7)
vim.api.nvim_win_set_cursor(s.chat_win, { 4, 0 })
view.pin()
check("redrawing preserves conversation reading position", vim.api.nvim_win_get_cursor(s.chat_win)[1] == 4)

local narrow_entry = s.entry
vim.cmd("Inkling view out")
check("step out pins and requests a wider component scope", s.target.level == "file"
  and s.target.view == "components" and not s.follow and s.entry == narrow_entry)
local widening = requests[#requests]
view.pin()
check("inspecting a pinned generation does not cancel step out", not widening.killed)
view.back()
widening.cb(nil, graph)
settle()
check("back cancels pending step out and ignores late results", widening.killed and s.entry == narrow_entry and not s.busy)
view.out()
reply(graph)
check("wider view starts its own conversation", s.entry.scope.level == "file" and #s.entry.messages == 0)
view.out()
check("file at root widens to project", s.target.level == "project" and s.target.directory == tmp)
reply(graph)
local wide_entry = s.entry
check("project diagram exposes partial coverage", table.concat(wide_entry.graph.omissions, "\n"):find("Partial perspective", 1, true))
count = #requests
view.out()
check("step out stops at project without a request", #requests == count and s.entry == wide_entry)
view.set_view("flow")
check("switching view preserves a widened subject", s.target.level == "project" and s.target.directory == tmp and s.target.view == "flow")
reply(graph)
view.refresh()
check("refresh preserves the project perspective", s.target.level == "project" and s.target.directory == tmp)
reply(graph)
while s.entry ~= narrow_entry and #s.history > 0 do view.back() end
check("back restores narrower diagram and conversation", s.entry == narrow_entry and #s.entry.messages == 2)

vim.api.nvim_set_current_win(s.win)
s.selection = "guard"
count = #requests
view.expand()
check("focus step in opens a prompt before generating", s.input and #requests == count)
vim.api.nvim_buf_set_lines(s.input.buf, 0, -1, false, { "Trace how the guard delegates validation" })
s.input.close(true)
check("focus step in sends the requested direction", requests[#requests].job.tail:find("delegates validation", 1, true))
vim.fn.writefile({ "def validate(user):", "    return user.verified" }, tmp .. "/deep.py")
reply({ nodes = {}, edges = {}, read_paths = { "deep.py" }, search = "" })
check("step in can gather deeper implementation", requests[#requests].job.head:find("return user.verified", 1, true)
  and s.busy and s.entry == narrow_entry)
reply(graph)
check("focus step in starts its own conversation", s.entry.scope.expanded and #s.entry.messages == 0)
view.back()
check("focus step-in back preserves old conversation", s.entry == narrow_entry and #s.entry.messages == 2)

count = #requests
view.ask()
local draft = s.input
check("asking opens an editable pane without sending", draft and vim.bo[draft.buf].modifiable
  and vim.api.nvim_win_get_config(draft.win).relative == "" and #requests == count)
vim.api.nvim_buf_set_lines(draft.buf, 0, -1, false, { "What happens on failure?", "Include early returns." })
draft.close(false)
view.ask()
check("cancelled question draft is restored", #vim.api.nvim_buf_get_lines(s.input.buf, 0, -1, false) == 2
  and #requests == count)
local draft_win = s.input.win

vim.cmd("Inkling view components")
check("switching view through command does not cancel generation", not requests[#requests].killed)
check("loading another view does not relabel the old diagram", vim.api.nvim_buf_get_lines(s.buf, 0, 1, false)[1]:match("^Flow") ~= nil)
reply(graph)
check("replacing diagram safely closes and saves its draft", not vim.api.nvim_win_is_valid(draft_win)
  and s.history[#s.history].drafts.ask:find("Include early returns.", 1, true))
local old_selection = s.selection
old_selection_menu.choose(old_selection_menu.items[2])
check("picker callback cannot select into a different diagram", s.selection == old_selection)
check("switching lens keeps conversation", #s.entry.messages == 2 and s.entry.scope.view == "components")
check("components lens restores the file scope", s.entry.scope.first == 1 and s.entry.scope.last == 7)
local component_entry = s.entry
table.insert(component_entry.messages, { role = "user", text = "Remember this current question when changing views" })
count = #requests
view.set_view("flow")
check("cached lens changes keep the current conversation", #requests == count and #s.entry.messages == 3
  and s.entry.messages[3].text:find("current question", 1, true))
view.back()
table.remove(component_entry.messages)
vim.api.nvim_win_set_cursor(original_win, { 7, 0 })
view.set_view("flow")
check("flow lens uses the current source function", s.target.first == 6 and s.target.last == 7)
reply(graph)
view.back()
view.back()
check("back restores prior view and conversation", s.entry.scope.view == "flow" and #s.entry.messages == 2)
local chat_height = vim.api.nvim_win_get_height(s.chat_win)
view.export()
check("Mermaid export stays inside Neovim", vim.bo.filetype == "mermaid" and vim.api.nvim_get_current_line():find("flowchart") ~= nil)
vim.cmd("close")
check("export preserves conversation split height", vim.api.nvim_win_get_height(s.chat_win) == chat_height)

vim.api.nvim_set_current_win(original_win)
vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "    return user.email" })
vim.api.nvim_exec_autocmds("TextChanged", {})
check("changed source marks snapshot stale", s.entry.stale and not source.current(s.entry.context))
check("preview retains original evidence after source changes", table.concat(picker.evidence(s.entry, s.entry.graph.by_id.name), "\n")
  :find("return user.name", 1, true) ~= nil)
count = #requests
view.out()
check("stale source blocks step out", #requests == count)
view.ask("What changed?")
check("stale questions require refresh", #requests == count)
view.refresh()
reply(graph)
check("refresh creates a new conversation", not s.entry.stale and #s.entry.messages == 0)

view.ask()
vim.api.nvim_buf_set_lines(s.input.buf, 0, -1, false, { "Explain this condition", "and its failure case." })
count = #requests
s.input.close(true)
check("sending multiline question closes editor and preserves text", s.input == nil and #requests == count + 1
  and s.entry.messages[1].text == "Explain this condition\nand its failure case.")
reply({ answer = "The guard exits on a missing user.", sources = refs(2, 3), highlight_nodes = {}, highlight_edges = {}, read_paths = {}, search = "" })

view.ask("Find permission checks")
local pending = requests[#requests]
view.close()
pending.cb(nil, { answer = "Late answer", sources = {}, highlight_nodes = {}, highlight_edges = {}, read_paths = {}, search = "" })
settle()
check("close kills requests and discards late answers", pending.killed and view._state() == nil)
check("close preserves source buffer", vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_lines(buf, 3, 4, false)[1] == "    return user.email")

vim.api.nvim_set_current_win(original_win)
vim.api.nvim_win_set_cursor(original_win, { 2, 0 })
view.open("flow")
settle()
s = view._state()
-- The unchanged snapshot may already be cached.
if not s.entry then reply(graph) end
view.resume()
settle()
if not s.entry then reply(graph) end
vim.api.nvim_win_set_cursor(original_win, { 7, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
settle()
local old_request = requests[#requests]
vim.api.nvim_win_set_cursor(original_win, { 2, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
settle()
old_request.cb(nil, graph)
settle()
check("superseded scope cannot replace current view", s.entry and s.entry.scope.first == 1 and old_request.killed)
view.close()

-- A failed first request can be retried from the pinned diagram window.
vim.api.nvim_set_current_win(original_win)
vim.api.nvim_win_set_cursor(original_win, { 7, 0 })
view.open("flow")
s = view._state()
requests[#requests].cb("fixture timeout")
settle()
vim.api.nvim_set_current_win(s.win)
view.pin()
count = #requests
view.refresh()
check("retry works in pinned empty workspace", #requests == count + 1)
count = #requests
view.set_view("components")
check("view switching works before the first diagram succeeds", #requests == count + 1 and s.target.view == "components")
reply(graph)
view.ask("Investigate a condition outside the evidence budget")
count = #requests
local need = { answer = "", sources = {}, highlight_nodes = {}, highlight_edges = {}, read_paths = {}, search = "" }
reply(need); reply(need); reply(need)
check("evidence loop has a hard round limit", #requests == count + 2 and not s.busy
  and s.entry.messages[#s.entry.messages].text:find("evidence budget", 1, true) ~= nil)
-- Replacing the scratch diagram buffer must preserve the replacement window.
vim.api.nvim_set_current_win(s.win)
local replacement_win = s.win
vim.cmd("enew")
settle()
check("hiding diagram stops workspace without closing replacement", view._state() == nil
  and vim.api.nvim_win_is_valid(replacement_win))
vim.cmd("close")

-- Source evidence reads are bounded and can search for files outside initial context.
local search_ctx = assert(source.collect(source.focus(buf, 2, "flow")))
local done = false
source.search(search_ctx, "user.admin", function() done = true end)
vim.wait(3000, function() return done end, 10)
check("literal search discovers relevant project source", done and search_ctx.files["helpers/check.py"] ~= nil)
local long_lines = {}
for i = 1, 100 do table.insert(long_lines, "value_" .. i .. " = " .. i) end
vim.fn.writefile(long_lines, tmp .. "/long.py")
local long_buf = vim.fn.bufadd(tmp .. "/long.py")
vim.fn.bufload(long_buf)
local narrow = assert(source.focus(long_buf, 50, "flow"))
narrow.first, narrow.last = 50, 55
local excerpts = assert(source.collect(narrow))
local ref = { { path = "long.py", start_line = 95, end_line = 95 } }
check("unread portion of a known file is not citable", #source.references(ref, excerpts) == 0)
done = false
source.search(excerpts, "value_95", function() done = true end)
vim.wait(3000, function() return done end, 10)
check("search extends a previously inspected file", done and #source.references(ref, excerpts) == 1)
check("evidence cannot bridge an unread gap", #source.references({ { path = "long.py", start_line = 66, end_line = 71 } }, excerpts) == 0)
source.extend(excerpts, { "long.py" })
check("full-file read fills missing excerpts", #source.references({ { path = "long.py", start_line = 1, end_line = 100 } }, excerpts) == 1
  and excerpts.chars <= excerpts.max_chars)

-- The rendered view owns its camera independently of provider requests.
local available, image = render.image_available, render.image
local renders, cleared, restored = 0, 0, 0
render.image_available = function() return true end
render.image = function(_, _, _, _, _, _, cb)
  renders = renders + 1
  local c = require("inkling.view.canvas").new(800, 600, 8, 16)
  vim.schedule(function() cb(nil) end)
  return { id = 42, camera = c,
    clear = function() cleared = cleared + 1 end,
    restore = function() restored = restored + 1 end,
    draw = function(_, columns, rows)
      return require("inkling.view.kitty").grid(require("inkling.view.canvas").layout(c, columns, rows))
    end }
end
config.options.view.renderer = "native"
vim.api.nvim_set_current_win(original_win)
vim.api.nvim_win_set_cursor(original_win, { 2, 0 })
view.open("flow")
if not view._state().entry then reply(graph) end
count = #requests
s = view._state()
s.status = "Previous render failed; using native diagrams."
vim.cmd("Inkling view mermaid")
settle()
s = view._state()
check("Mermaid command renders the diagram instead of source", s.renderer == "mermaid" and vim.bo.filetype == "inkling-view")
check("retrying Mermaid clears the previous rendering error", s.status == "")
view.zoom(2)
view.pan(4, 3)
check("camera controls do not regenerate diagram or image", #requests == count and renders == 1 and s.image.camera.zoom == 2)
local previous_camera = vim.deepcopy(s.image.camera)
local previous_restores = restored
vim.cmd("Inkling view mermaid")
check("render command restores an existing image without regeneration", restored > previous_restores
  and #requests == count and renders == 1 and s.image.camera.zoom == 2)
previous_restores = restored
vim.api.nvim_exec_autocmds("FocusGained", {})
vim.wait(150)
check("terminal focus restores the canvas without losing zoom", restored > previous_restores
  and renders == 1 and s.image.camera.zoom == 2)
view.ask("Explain this element")
reply({ answer = "Guard evidence", sources = refs(2, 3), highlight_nodes = { "guard" }, highlight_edges = {}, read_paths = {}, search = "" })
check("answer highlights retain the camera position", renders == 2 and s.image.camera.zoom == previous_camera.zoom)
vim.cmd("Inkling view export")
check("source export has its own command", vim.bo.filetype == "mermaid")
vim.cmd("close")
view.renderer()
check("switching to text releases terminal graphics", s.renderer == "native" and s.image == nil and cleared >= 2)
view.close()
render.image_available, render.image = available, image
vim.fn.delete(tmp, "rf")
vim.fn.delete(outside)
os.exit(failures == 0 and 0 or 1)
