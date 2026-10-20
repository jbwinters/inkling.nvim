-- nvim --headless -u NONE -i NONE -l tests/view_scope.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("filetype on")
require("inkling.config").setup({ enabled = false })
local source = require("inkling.view.source")
local discovery = require("inkling.view.discovery")
local failures = 0
local function check(name, ok)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failures = failures + 1 end
end
local tmp = vim.fn.tempname()
local function file(relative, lines)
  local path = tmp .. "/" .. relative
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
  return path
end
vim.fn.mkdir(tmp .. "/.git", "p")
local path = file("src/orders/service.py", {
  "class OrderService:", "    def create(self, order):", "        return order", "",
  "    def cancel(self, order):", "        return None", "",
  "def unrelated():", "    return 3",
})
vim.cmd("edit " .. vim.fn.fnameescape(path))
local buf = vim.api.nvim_get_current_buf()
local focus = source.focus(buf, 3, "flow")
local class = assert(source.parent(focus))
check("method steps out to enclosing class", class.level == "class" and class.label == "OrderService"
  and class.first == 1 and class.last == 6 and class.view == "components")
local module = assert(source.parent(class))
check("class steps out to whole file", module.level == "file" and module.first == 1 and module.last == 9)
local folder = assert(source.parent(module))
check("file steps out to containing folder", folder.level == "directory" and folder.directory == tmp .. "/src/orders")
local parent = assert(source.parent(folder))
check("folder steps out one containing level", parent.directory == tmp .. "/src")
local project = assert(source.parent(parent))
check("outer folder steps out to project", project.level == "project" and project.directory == tmp)
local beyond, reason = source.parent(project)
check("cannot step outside project", beyond == nil and reason:find("project boundary", 1, true))
check("step out leaves original scope untouched", focus.level == "function" and focus.view == "flow" and not focus.widened)
local no_class = source.parent(source.focus(buf, 9, "flow"))
check("standalone function skips class", no_class.level == "file")
local refreshed = source.refresh_scope(folder)
check("refresh preserves wider boundary", refreshed.directory == folder.directory and refreshed.widened)
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "# Added later", "" })
refreshed = source.refresh_scope(class)
check("class refresh relocates its declaration", refreshed and refreshed.last == 8 and refreshed.label == "OrderService")
check("file refresh includes new lines", source.refresh_scope(module).last == 11)

local ts = file("src/client.ts", { "export class Client {", "  send(value: string) {", "    return value;", "  }", "}", "" })
vim.cmd("edit " .. vim.fn.fnameescape(ts))
local ts_focus = source.focus(vim.api.nvim_get_current_buf(), 3, "flow")
check("TypeScript method has a function scope", ts_focus.level == "function" and ts_focus.first == 2)
check("TypeScript method steps out to class", source.parent(ts_focus).label == "Client")
local nested_path = file("nested.py", { "class Outer:", "    class Inner:", "        def run(self):", "            pass", "", "outside = True" })
vim.cmd("edit " .. vim.fn.fnameescape(nested_path))
local inner = source.parent(source.focus(vim.api.nvim_get_current_buf(), 4, "flow"))
check("nested classes use nearest container first", inner.label == "Inner" and source.parent(inner).label == "Outer")

file("src/orders/cache.py", { "CACHE = {}" })
file("src/payments/gateway.py", { "def charge(value):", "    return value" })
file("docs/README.md", { "# Example project", "Orders and payments" })
file("tests/test_orders.py", { "def test_orders():", "    pass" })
file(".gitignore", { "ignored.py", "ignored/" })
file("ignored.py", { "NEVER_READ = True" })
file("ignored/private.py", { "NEVER_READ = True" })
file("src/node_modules/third_party.js", { "NEVER_READ = true" })
file("dist/bundle.js", { "NEVER_READ = true" })
local outside = vim.fn.tempname()
vim.fn.writefile({ "NEVER_READ = True" }, outside)
vim.uv.fs_symlink(outside, tmp .. "/outside.py")
local inventory = assert(discovery.files(project))
local names = table.concat(inventory.paths, "\n")
check("discovery respects gitignore and build exclusions", not names:find("ignored", 1, true)
  and not names:find("third_party", 1, true) and not names:find("bundle", 1, true))
check("discovery samples sibling areas early", inventory.paths[1]:match("nested.py$")
  and inventory.paths[2]:match("docs/README.md$") and inventory.paths[3]:find("/src/", 1, true)
  and inventory.paths[4]:match("tests/test_orders.py$"))
local ctx = assert(source.collect(project))
check("project evidence spans multiple areas", ctx.files["src/orders/service.py"] and ctx.files["docs/README.md"]
  and ctx.files["tests/test_orders.py"])
check("project evidence stays bounded and reserves chat budget", #ctx.order <= ctx.max_files - 2
  and ctx.chars <= math.floor(ctx.max_chars * 0.7))
check("broader evidence respects project containment", not source.prompt(ctx):find("NEVER_READ", 1, true))
check("unsaved source is included in wider snapshot", source.prompt(ctx):find("Added later", 1, true))
check("prompt names broader focus and partial coverage", source.prompt(ctx):find("Focus: Project", 1, true)
  and source.prompt(ctx):find("Partial perspective", 1, true))
local previous = ctx.inventory
file("extra.py", { "NEW = True" })
check("new files change discovery cache identity", assert(source.collect(project)).inventory ~= previous)
local subctx = assert(source.collect(folder))
check("folder evidence stays within that folder", #subctx.order == 2 and subctx.files["src/orders/cache.py"] ~= nil
  and not subctx.files["src/payments/gateway.py"])

-- A large anchor must not spend the whole scope's budget or hide later declarations.
local large = { "# A large module" }
for i = 1, 160 do large[#large + 1] = "# " .. string.rep("body", 60) end
large[#large + 1], large[#large + 2] = "def later_api():", "    return True"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, large)
local broad = assert(source.collect(project))
check("large anchor leaves budget for other files", #broad.order > 2)
check("large file excerpts include later declarations", broad.files["src/orders/service.py"].lines[162] ~= nil)
check("unread internals are not citable", #source.references({ { path = "src/orders/service.py", start_line = 100, end_line = 100 } }, broad) == 0)
local graph = { title = "Project", summary = "Sample", omissions = {}, edges = {}, nodes = {
  { id = "area", label = "Orders", kind = "group", detail = "", parent = "", sources = {} },
  { id = "api", label = "API", kind = "component", detail = "", parent = "area", sources = {} },
} }
local validated = assert(require("inkling.view.graph").validate(graph, broad, require("inkling.config").options.view))
check("coverage cannot be omitted by model output", table.concat(validated.omissions, "\n"):find("Partial perspective", 1, true))
file("src/orders/init.py", { "from .service import OrderService" })
check("entry points precede arbitrary sibling files", assert(discovery.files(folder)).paths[1] == tmp .. "/src/orders/init.py")
local missing_folder = vim.deepcopy(folder)
missing_folder.directory = tmp .. "/removed-folder"
local missing, missing_err = discovery.files(missing_folder)
check("removed folders return a recoverable error", missing == nil and missing_err:find("no longer available", 1, true))
vim.fn.delete(tmp, "rf")
vim.fn.delete(outside)
os.exit(failures == 0 and 0 or 1)
