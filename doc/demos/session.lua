-- Recording-only setup. Fixed responses exercise the real workspace, pickers,
-- evidence validation, Git snapshots, and Mermaid renderer without API calls.
local root = assert(vim.env.INKLING_DEMO_ROOT)
local project = assert(vim.env.INKLING_DEMO_PROJECT)
vim.opt.rtp:prepend(root)
local plugins = vim.env.INKLING_DEMO_PLUGINS or (vim.fn.stdpath("data") .. "/plugged")
for _, name in ipairs({ "gruvbox-material", "plenary.nvim", "telescope.nvim" }) do
  vim.opt.rtp:append(plugins .. "/" .. name)
end
vim.cmd("filetype plugin indent on")
vim.cmd("syntax enable")
vim.o.termguicolors = true
vim.o.background = "dark"
vim.g.gruvbox_material_background = "hard"
vim.cmd("colorscheme gruvbox-material")
vim.o.number, vim.o.relativenumber = true, false
vim.o.signcolumn, vim.o.showmode, vim.o.ruler = "no", false, false
vim.o.mouse, vim.o.laststatus, vim.o.showtabline = "a", 3, 0
vim.o.swapfile, vim.o.backup, vim.o.writebackup = false, false, false
vim.o.scrolloff, vim.o.sidescrolloff = 3, 2
vim.o.guicursor = "n-v-c:block,i-ci-ve:ver25,r-cr:hor20,a:blinkon0"
vim.o.fillchars = "eob: ,vert:│"
vim.o.shortmess = vim.o.shortmess .. "I"
vim.api.nvim_set_hl(0, "InklingDemoKeys", { fg = "#1d2021", bg = "#a9b665", bold = true })
_G.InklingDemo = {}
function InklingDemo.caption(keys, text)
  local function escape(s) return s:gsub("%%", "%%%%") end
  vim.o.statusline = "%#InklingDemoKeys# " .. escape(keys) .. " %#StatusLine#  " .. escape(text)
    .. "%=%#Comment# inkling.nvim  "
  vim.cmd("redrawstatus")
end
InklingDemo.caption("INKLING", "Read code through diagrams")

local source = require("inkling.view.source")
local providers = require("inkling.providers")
providers.run = function(job, _, callback)
  local view = require("inkling.view")
  local s = assert(view._state())
  local scope = s.target or s.entry.scope
  local filename = vim.fs.basename(scope.path)
  local ctx = job.purpose == "question" and s.entry.context or assert(source.collect(scope))
  local function refs(path, first, last, revision)
    local file = source.file(ctx, { path = path, revision = revision })
    if not file then return {} end
    for _, range in ipairs(file.ranges) do
      local a, b = math.max(first, range[1]), math.min(last or first, range[2])
      if a <= b then return { { path = path, start_line = a, end_line = b, revision = revision } } end
    end
    return { { path = path, start_line = file.first, end_line = file.first, revision = revision } }
  end
  local graph = { title = "", summary = "", nodes = {}, edges = {}, omissions = {}, read_paths = {}, search = "" }
  local function node(id, label, kind, parent, evidence, change)
    graph.nodes[#graph.nodes + 1] = { id = id, label = label, kind = kind, parent = parent or "",
      detail = "", sources = evidence, change = change }
  end
  local function edge(id, a, b, label, evidence, change)
    graph.edges[#graph.edges + 1] = { id = id, from = a, to = b, label = label, sources = evidence,
      inferred = false, change = change }
  end
  if job.purpose == "question" then
    graph = { answer = "No. The loop allows three attempts in total.\n\n"
      .. "Only Timeout is retried. On the third timeout, the exception is raised. "
      .. "Other HTTP errors propagate immediately.",
      sources = refs("transport.py", 12, 22, scope.review and "after" or nil),
      highlight_nodes = { "retry", "limit", "error" }, highlight_edges = { "exhausted" },
      read_paths = {}, search = "" }
  elseif scope.review then
    local comparison = scope.comparison or "changes"
    local before = comparison == "before"
    local revision = before and "before" or "after"
    local evidence = refs("transport.py", 7, 22, revision)
    graph.title = before and "Before: one attempt" or (comparison == "after" and "After: bounded retries" or "Add bounded timeout retries")
    graph.summary = "Review the transport change against pinned Git revisions."
    node("transport", "HttpTransport", "group", "", evidence, comparison == "changes" and "modified" or "unchanged")
    node("request", "HTTP request", "component", "transport", evidence, "unchanged")
    node("result", "JSON response", "component", "transport", evidence, "unchanged")
    node("error", before and "Propagate failure" or "Raise final timeout", "component", "transport", evidence,
      comparison == "changes" and "modified" or "unchanged")
    edge("success", "request", "result", "success", evidence, "unchanged")
    if before then
      edge("failure", "request", "error", "timeout", evidence, "unchanged")
    else
      node("retry", "Retry policy", "component", "transport", evidence, comparison == "changes" and "added" or "unchanged")
      edge("attempts", "retry", "request", "at most 3 attempts", evidence, comparison == "changes" and "added" or "unchanged")
      edge("exhausted", "retry", "error", "budget exhausted", evidence, comparison == "changes" and "added" or "unchanged")
    end
  elseif scope.view == "components" then
    if filename == "transport.py" then
      local evidence = refs("transport.py", 7, 22)
      graph.title, graph.summary = "Inside HttpTransport", "A bounded retry policy surrounds a single HTTP request."
      node("transport", "HttpTransport", "group", "", evidence)
      node("retry", "Retry policy", "component", "transport", evidence)
      node("request", "HTTP request", "component", "transport", evidence)
      node("error", "Failure propagation", "component", "transport", evidence)
      edge("attempts", "retry", "request", "up to 3 attempts", evidence)
      edge("exhausted", "retry", "error", "final timeout", evidence)
    else
      graph.title, graph.summary = "ApiClient and its collaborators", "The client checks memory before calling the HTTP transport."
      node("client", "ApiClient", "group", "", refs("client.py", 5, 20))
      node("fetch", "Fetch and cache", "component", "client", refs("client.py", 10, 17))
      node("invalidate", "Invalidate", "component", "client", refs("client.py", 19, 20))
      node("cache", "MemoryCache", "component", "", refs("cache.py", 1, 12))
      node("transport", "HttpTransport", "component", "", refs("transport.py", 7, 22))
      edge("cache_read", "fetch", "cache", "read / write", refs("client.py", 11, 17))
      edge("cache_delete", "invalidate", "cache", "delete", refs("client.py", 19, 20))
      edge("network", "fetch", "transport", "cache miss", refs("client.py", 15, 17))
    end
  elseif filename == "transport.py" then
    local evidence = refs("transport.py", 11, 22)
    graph.title, graph.summary = "Retry a timed-out request", "Three attempts, short backoff, and a final error."
    node("request", "Send HTTP request", "step", "", evidence)
    node("timeout", "Timed out?", "decision", "", evidence)
    node("result", "Return JSON", "step", "", evidence)
    node("limit", "Third attempt?", "decision", "", evidence)
    node("retry", "Back off and retry", "step", "", evidence)
    node("error", "Raise timeout", "step", "", evidence)
    edge("sent", "request", "timeout", "", evidence)
    edge("success", "timeout", "result", "no", evidence)
    edge("failure", "timeout", "limit", "yes", evidence)
    edge("exhausted", "limit", "error", "yes", evidence)
    edge("again", "limit", "retry", "no", evidence)
    edge("repeat", "retry", "request", "", evidence)
  elseif scope.first >= 19 then
    local evidence = refs("client.py", 19, 20)
    graph.title, graph.summary = "Invalidate a cached value", "Delete the requested key; missing keys are harmless."
    node("key", "Receive key", "step", "", evidence)
    node("delete", "Delete cached value", "step", "", evidence)
    node("done", "Return", "step", "", evidence)
    edge("remove", "key", "delete", "", evidence)
    edge("finish", "delete", "done", "", evidence)
  else
    local evidence = refs("client.py", 10, 17)
    graph.title, graph.summary = "Fetch with a cache", "A cache hit skips the network; a miss stores the response."
    node("lookup", "Look up key", "step", "", evidence)
    node("hit", "Cache hit?", "decision", "", evidence)
    node("cached", "Return cached value", "step", "", evidence)
    node("request", "Fetch from API", "step", "", evidence)
    node("store", "Cache response", "step", "", evidence)
    node("result", "Return response", "step", "", evidence)
    edge("lookup_hit", "lookup", "hit", "", evidence)
    edge("hit_yes", "hit", "cached", "yes", evidence)
    edge("hit_no", "hit", "request", "no", evidence)
    edge("save", "request", "store", "", evidence)
    edge("finish", "store", "result", "", evidence)
  end
  local cancelled = false
  vim.defer_fn(function() if not cancelled then callback(nil, graph) end end, 450)
  return { kill = function() cancelled = true end }
end
require("inkling.usage").path = function() return project .. "/.demo-usage.jsonl" end
require("inkling").setup({
  enabled = false, next_edit = false,
  provider = "demo",
  providers = { demo = { kind = "openai", model = "recording-fixture", api_key = "not-a-real-key" } },
  view = { debounce_ms = 250, max_files = 8, renderer = "mermaid",
    mermaid = { scale = 3, browser = vim.env.INKLING_DEMO_BROWSER } },
})
vim.cmd.cd(project)
vim.cmd.edit("client.py")
vim.api.nvim_win_set_cursor(0, { 11, 0 })
