-- nvim --headless -u NONE -i NONE -l tests/view_review.lua
-- Real Git histories, immutable evidence and UI lifecycle; no network/model calls.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("filetype on")
vim.o.columns, vim.o.lines = 140, 55
require("inkling.usage").path = function() return vim.fn.tempname() end
local requests, failures = {}, 0
require("inkling.providers").run = function(job, _, cb)
  local request = { job = job, cb = cb }
  table.insert(requests, request)
  return { kill = function() request.killed = true end }
end
require("inkling").setup({ enabled = false, view = { renderer = "native", debounce_ms = 10 } })
local source, review, git = require("inkling.view.source"), require("inkling.view.review"), require("inkling.view.git")
local view, graphs, picker = require("inkling.view"), require("inkling.view.graph"), require("inkling.view.picker")
local function check(name, condition)
  print((condition and "ok   " or "FAIL ") .. name)
  if not condition then failures = failures + 1 end
end
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local function run(...)
  local command = { "git", "-C", tmp }
  vim.list_extend(command, { ... })
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function write(path, lines) vim.fn.writefile(lines, tmp .. "/" .. path) end
run("init", "-b", "main")
run("config", "user.name", "Inkling test")
run("config", "user.email", "inkling-test@example.invalid")
write("app.py", { "def run(user):", "    if user is None:", "        return None", "    return user.name" })
write("legacy.py", { "def obsolete():", "    return 'old behavior'" })
write("original name.py", { "def unchanged():", "    return 'renamed implementation'" })
write("helper.py", { "def allowed(user):", "    return user.admin" })
write("README.md", { "Before documentation" })
run("add", "."); run("commit", "-qm", "base")
local base = run("rev-parse", "HEAD")
run("checkout", "-qb", "feature")
write("app.py", { "def run(user):", "    return user.email", "", "def retry():", "    return run(None)" })
run("rm", "legacy.py")
run("mv", "original name.py", "renamed name.py")
write("new.py", { "def added():", "    return 42" })
write("README.md", { "After documentation" })
local binary = assert(io.open(tmp .. "/binary.dat", "wb"))
binary:write("binary\0content")
binary:close()
run("add", "."); run("commit", "-qm", "feature")
local head = run("rev-parse", "HEAD")
run("checkout", "-q", "main")
write("base-only.py", { "not part of the feature" })
run("add", "."); run("commit", "-qm", "advance base")
run("checkout", "-q", "feature")
local branch = assert(git.start(tmp, "main"))
check("review uses merge base rather than advanced base tip", branch.before == base and branch.base_tip ~= base and branch.after == head)
check("review excludes changes made only on the base branch", not vim.inspect(branch.changes):find("base%-only"))
local renamed, deleted
for _, change in ipairs(branch.changes) do
  if change.status == "R" then renamed = change end
  if change.status == "D" then deleted = change end
end
check("rename records both paths with spaces", renamed and renamed.before == "original name.py" and renamed.after == "renamed name.py")
check("deleted path is retained", deleted and deleted.before == "legacy.py" and not deleted.after)
check("invalid revision is recoverable", git.start(tmp, "--not-an-option") == nil)
check("identical comparison explains no changes", git.start(tmp, "HEAD") == nil)
check("revision paths reject traversal and absolute paths", not git.path("../secret") and not git.path("/etc/passwd"))
local scope = source.identify(review.scope(branch))
local ctx = assert(source.collect(scope))
check("paired revision excerpts carry exact source", source.prompt(ctx):find("return user.name", 1, true)
  and source.prompt(ctx):find("return user.email", 1, true))
check("source budget leaves room for chat", ctx.chars <= ctx.max_chars * 0.7 and #ctx.order <= ctx.max_files - 2)
check("binary file is not supplied as source", not ctx.files["after:binary.dat"])
check("overview samples implementation before documentation", not ctx.files["after:README.md"] and ctx.files["after:app.py"])
local absent = review.file_scope(scope, { after = "new.py" })
absent.comparison = "before"
local absent_ctx, absent_err = source.collect(absent)
check("added file has no invented before diagram", not absent_ctx and absent_err:find("No before source", 1, true))
local function refs(side, path, a, b) return { { revision = side, path = path or "app.py", start_line = a or 1, end_line = b or 2 } } end
check("reference without revision is rejected", #source.references({ { path = "app.py", start_line = 1, end_line = 2 } }, ctx) == 0)
check("wrong revision range is rejected", #source.references(refs("before", "app.py", 5, 5), ctx) == 0)
check("deleted code can be cited", #source.references(refs("before", "legacy.py"), ctx) == 1)
local deleted_buf = assert(review.open_buffer(ctx, refs("before", "legacy.py")[1]))
check("deleted source opens in immutable scratch buffer", not vim.bo[deleted_buf].modifiable
  and vim.bo[deleted_buf].buftype == "nofile" and vim.api.nvim_buf_get_lines(deleted_buf, 1, 2, false)[1]:find("old behavior", 1, true))
vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/app.py"))
local code_buf, code_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(code_buf, 1, 2, false, { "    return 'unsaved poison'" })
write("app.py", { "working tree poison" })
check("unsaved and disk changes cannot alter review evidence", source.current(ctx)
  and table.concat(git.read(branch, "after", "app.py"), "\n"):find("user.email", 1, true))
source.extend(ctx, { "after:helper.py", "before:helper.py", "../secret", "after:../secret" })
check("chat can read unchanged dependencies from both revisions", ctx.files["after:helper.py"] and ctx.files["before:helper.py"])
local search_ctx = assert(source.collect(review.file_scope(scope, { before = "app.py", after = "app.py" })))
local done
source.search(search_ctx, "user.admin", function() done = true end)
vim.wait(4000, function() return done end, 10)
check("chat search reads pinned commits", done and search_ctx.files["after:helper.py"] and search_ctx.files["before:helper.py"])
check("search never reads poisoned working tree", not source.prompt(search_ctx):find("poison", 1, true))
local options = require("inkling.config").options.view
local function graph(comparison)
  local citations = comparison == "before" and refs("before") or comparison == "after" and refs("after")
    or vim.list_extend(refs("before"), refs("after"))
  local change = comparison == "changes" and "modified" or "unchanged"
  return { title = "User behavior", summary = "Review of user lookup", omissions = {},
    nodes = {
      { id = "app", label = "App", detail = "", parent = "", kind = "group", change = change, sources = citations },
      { id = "run", label = "Lookup", detail = "", parent = "app", kind = "component", change = change, sources = citations },
    }, edges = {} }
end
local validated = assert(graphs.validate(graph("changes"), ctx, options))
check("change labels appear in Mermaid and retain paired evidence", graphs.mermaid(validated):find("Changed · Lookup", 1, true)
  and #validated.nodes[2].sources == 2)
local bad = graph("changes")
bad.nodes[2].sources = refs("after")
check("unsupported changed classification becomes unknown", assert(graphs.validate(bad, ctx, options)).nodes[2].change == "unknown")
local schema = graphs.schema_for("components", branch)
check("review schema requires revision and change", schema.properties.nodes.items.properties.change
  and vim.tbl_contains(schema.properties.nodes.items.properties.sources.items.required, "revision"))
check("shared reference schemas never duplicate required fields",
  #schema.properties.nodes.items.properties.sources.items.required == 4
  and #schema.properties.edges.items.properties.sources.items.required == 4
  and #graphs.schema.properties.nodes.items.properties.sources.items.required == 3)
local function reply(obj)
  requests[#requests].cb(nil, obj or graph(view._state().target.comparison))
  vim.wait(50)
end
vim.cmd("Inkling review main")
local s = view._state()
check("command opens a pinned review", s and not s.follow and s.target.review.before == base and #requests == 1)
check("generation uses revision schema and comparison instructions", requests[1].job.system:find("pinned Git", 1, true)
  and requests[1].job.head:find(head, 1, true))
reply()
local overview = s.entry
local menu
picker.open = function(items, opts, choose) menu = { items = items, opts = opts, choose = choose } end
view.review_files()
check("changed-file picker includes unsampled and binary files", #menu.items == #branch.changes)
for _, item in ipairs(menu.items) do
  if item.change.after == "app.py" then menu.choose(item); break end
end
reply()
check("file review retains revisions and comparison", s.entry.scope.level == "file" and s.entry.scope.review.after == head)
view.out()
check("step out returns to whole branch without another generation", s.entry == overview)
local count = #requests
s.selection = "run"
vim.api.nvim_set_current_win(s.win)
view.expand()
check("step in asks for direction without a request", s.input and #requests == count and s.entry == overview)
vim.api.nvim_buf_set_lines(s.input.buf, 0, -1, false, { "Trace the failure paths into retry" })
s.input.close(false)
view.expand()
check("cancelled step-in draft is restored", vim.api.nvim_buf_get_lines(s.input.buf, 0, 1, false)[1]:find("failure paths", 1, true))
s.input.close(true)
check("step-in prompt and paired evidence reach generation", #requests == count + 1
  and requests[#requests].job.tail:find("failure paths", 1, true)
  and s.target.targets and s.target.review.after == head)
reply({ nodes = {}, edges = {}, read_paths = { "after:helper.py", "before:helper.py" }, search = "" })
check("step in can inspect deeper revision evidence before drawing", requests[#requests].job.head:find("return user.admin", 1, true)
  and s.busy and s.entry == overview)
reply()
check("step in starts a separate conversation", #s.entry.messages == 0 and s.entry.scope.level == "element")
view.back()
check("back restores overview after prompted step in", s.entry == overview)
view.compare("before")
reply()
check("before view keeps same comparison commits", s.entry.scope.comparison == "before" and s.entry.scope.review.after == head
  and s.entry.graph.nodes[2].sources[1].revision == "before")
s.selection = "run"
view.source()
check("source navigation opens correct revision without checkout", vim.b.inkling_revision.commit == base
  and vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]:find("if user is None", 1, true) and run("branch", "--show-current") == "feature")
view.ask("Was the missing-user guard removed?")
check("chat requests include revision-aware references", requests[#requests].job.schema.properties.sources.items.properties.revision
  and requests[#requests].job.head:find("return user.email", 1, true))
reply({ answer = "The before version had a guard.", sources = refs("before"), highlight_nodes = { "run" },
  highlight_edges = {}, read_paths = {}, search = "" })
check("answer retains its revision citation", s.entry.messages[2].sources[1].revision == "before")
local before = s.entry
view.compare("after")
reply()
check("comparison switch retains conversation", #s.entry.messages == 2 and s.entry.scope.comparison == "after")
view.compare("before")
check("comparison cache avoids another model call", s.entry.scope.comparison == "before" and not s.busy and #s.entry.messages == 2)
view.refresh()
check("refresh keeps pinned commits", s.target.review.before == base and s.target.review.after == head)
local pending = requests[#requests]
view.back()
pending.cb(nil, graph("before"))
vim.wait(50)
check("back cancels pending review generation", pending.killed and s.entry.scope.comparison == "before" and not s.busy)
view.compare("after")
if s.busy then reply() end
vim.api.nvim_set_current_win(code_win)
vim.api.nvim_win_set_buf(code_win, code_buf)
vim.api.nvim_exec_autocmds("TextChanged", {})
check("working-tree changes never stale a committed review", not s.entry.stale)
s.selection = "run"
local displayed, calls = s.entry, #requests
view.expand("Follow every dependency")
local more = { nodes = {}, edges = {}, read_paths = {}, search = "" }
reply(more); reply(more); reply(more)
check("diagram investigation has a hard round limit", #requests == calls + 3 and not s.busy
  and s.entry == displayed and s.status:find("evidence budget", 1, true))
view.close()
check("review preserves unsaved source buffer", vim.api.nvim_buf_get_lines(code_buf, 1, 2, false)[1]:find("unsaved poison", 1, true))
-- Advancing the branch does not mutate an already captured review.
write("newer.py", { "new revision" })
run("add", "newer.py"); run("commit", "-qm", "advance")
check("captured commits remain fixed after branch moves", source.current(ctx) and branch.after == head
  and assert(git.start(tmp, "main")).after ~= head)
vim.fn.delete(tmp, "rf")
os.exit(failures == 0 and 0 or 1)
