local config = require("inkling.config")
local providers = require("inkling.providers")
local source = require("inkling.view.source")
local graphlib = require("inkling.view.graph")
local render = require("inkling.view.render")
local picker = require("inkling.view.picker")
local input = require("inkling.view.input")
local uv = vim.uv or vim.loop
local M = {}
local state
local ns = vim.api.nvim_create_namespace("inkling_view")
local cache, cache_order = {}, {}
local draw, draw_chat, generate, follow, compose

local function win_ok(win) return win and vim.api.nvim_win_is_valid(win) end
local function buf_ok(buf) return buf and vim.api.nvim_buf_is_valid(buf) end
local function visible(s)
  return s and buf_ok(s.buf) and win_ok(s.win) and vim.api.nvim_win_get_buf(s.win) == s.buf
    and vim.api.nvim_win_get_tabpage(s.win) == vim.api.nvim_get_current_tabpage()
end
local function notify(msg) vim.notify("inkling view: " .. msg, vim.log.levels.INFO) end
local function current(entry)
  if not source.current(entry.context) then return false end
  for _, message in ipairs(entry.messages) do
    if message.context and not source.current(message.context) then return false end
  end
  return true
end
local function write(buf, lines)
  if not buf_ok(buf) then return end
  lines = vim.tbl_map(function(line) return line:gsub("[\r\n]", " ") end, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end
local function scratch(kind)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "inkling-view"
  vim.api.nvim_buf_set_name(buf, "inkling://" .. kind .. "/" .. buf)
  return buf
end
local function window_options(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].spell = false
end

local function stop(s)
  s.serial = s.serial + 1
  if s.timer then s.timer:stop() end
  for _, key in ipairs({ "process", "search" }) do
    if s[key] then pcall(s[key].kill, s[key], 15); s[key] = nil end
  end
  if s.pending then
    table.insert(s.pending.messages, { role = "assistant", text = "Request cancelled." })
    s.pending = nil
  end
  s.busy = false
end

local function selected(s)
  if not s or not s.entry then return nil end
  if vim.api.nvim_get_current_win() == s.win then
    local row = vim.api.nvim_win_get_cursor(s.win)[1]
    s.selection = s.rows[row] or s.selection
  end
  return s.selection and s.entry.graph.by_id[s.selection]
end

local function snapshot_label(e)
  return source.label(e.scope)
end

local function element_label(e, node)
  if node.from then return e.graph.by_id[node.from].label .. " → " .. e.graph.by_id[node.to].label .. ": " .. node.label end
  return node.label
end

draw_chat = function()
  local s = state
  if not s or not buf_ok(s.chat_buf) then return end
  local e = s.entry
  local lines = { "Conversation · " .. (e and snapshot_label(e) or "no diagram"),
    "a ask · <Enter> open cited source · q close conversation", "" }
  local latest = 1
  s.chat_rows = {}
  if e then
    for _, message in ipairs(e.messages) do
      latest = #lines + 1
      table.insert(lines, message.role == "user" and "You" or "Inkling")
      for _, line in ipairs(vim.split(message.text, "\n", { plain = true })) do table.insert(lines, line) end
      for _, ref in ipairs(message.sources or {}) do
        table.insert(lines, "  ↳ " .. source.ref_label(ref))
        s.chat_rows[#lines] = { ref = ref, context = message.context or e.context }
      end
      table.insert(lines, "")
    end
    if e.stale then table.insert(lines, "Source changed since this conversation. Refresh to investigate the new revision.") end
  end
  if s.pending then table.insert(lines, "Investigating…") end
  local text = table.concat(lines, "\n")
  local changed = s.chat_text ~= text
  s.chat_text = text
  write(s.chat_buf, lines)
  if changed and win_ok(s.chat_win) then
    vim.api.nvim_win_set_cursor(s.chat_win, { latest, 0 })
    vim.api.nvim_win_call(s.chat_win, function() vim.cmd("normal! zt") end)
  end
end

draw = function()
  local s = state
  if not s or not buf_ok(s.buf) or not win_ok(s.win) then return end
  local e = s.entry
  local graphical = s.renderer == "mermaid"
  local mode = s.follow and "Following code · p pin" or "Pinned · p follow"
  if e and e.scope.review then
    mode = e.scope.review.base_ref .. "…" .. e.scope.review.head_ref .. " · c compare · f files"
  end
  local lens = (e and e.scope.view or s.view) == "components" and "Components" or "Flow"
  local title = e and e.graph.title or "Inkling diagram"
  local c = s.image and s.image.camera
  local mode_hint = graphical and (c and (" · %d%% · 0 fit"):format(math.floor(c.zoom * 100 + 0.5)) or "") or " · text"
  local lines = { lens .. " · " .. title, e and snapshot_label(e) or "Waiting for source…",
    e and e.stale and "Source changed · r refresh" or mode .. mode_hint,
    "/ find · e in · u out · a ask · ? actions", "" }
  s.rows = {}
  local styled = {}
  local highlights = e and vim.deepcopy(e.highlights) or {}
  if s.selection then highlights[s.selection] = true end
  local columns = math.max(1, vim.api.nvim_win_get_width(s.win) - 2)
  if graphical then
    local image_height = math.max(1, vim.api.nvim_win_get_height(s.win) - 6)
    if e then
      local key = vim.fn.sha256(graphlib.mermaid(e.graph, highlights) .. vim.o.background
        .. tostring(config.options.view.mermaid.scale) .. tostring(config.options.view.image_backend))
      if key ~= s.image_key then
        local previous = s.image_entry == e and s.image and s.image.camera
        previous = previous and { zoom = previous.zoom, x = previous.x, y = previous.y }
        if s.image then s.image:clear(); s.image = nil end
        s.image_key, s.image_entry = key, e
        s.image = render.image(e.graph, highlights, s.win, s.buf, image_height, 5, function(err)
          if state ~= s or s.image_key ~= key then return end
          if err then
            s.renderer, s.image_key, s.status = "native", nil, err .. "; using native diagrams."
            if s.image then s.image:clear(); s.image = nil end
          elseif previous and s.image and s.image.camera then
            for k, value in pairs(previous) do s.image.camera[k] = value end
          end
          draw()
        end)
      end
      -- A synchronous capability failure can switch back to native.
      if s.renderer ~= "mermaid" then return end
    end
    local node = e and s.selection and e.graph.by_id[s.selection]
    lines[5] = s.status and s.status ~= "" and s.status or (s.image and s.image.camera
      and (node and ("Selected: " .. element_label(e, node)) or (e and e.context.coverage
        and ("Partial evidence · " .. #e.context.order .. " files · ? coverage") or "hjkl / drag pan · +/- / wheel zoom")) or "Rendering Mermaid…")
    local grid = s.image and s.image:draw(columns, image_height)
    s.canvas_top, s.canvas_height = 5, image_height
    if grid then
      vim.list_extend(lines, grid)
    else
      for _ = 1, image_height do table.insert(lines, "") end
    end
  else
    if s.image then s.image:clear(); s.image, s.image_key = nil, nil end
    table.insert(lines, "")
    if s.status and s.status ~= "" then table.insert(lines, s.status); table.insert(lines, "") end
    if e then
      vim.list_extend(lines, render.wrap(e.graph.summary, math.max(20, columns)))
      table.insert(lines, "")
      for _, row in ipairs(render.native(e.graph, vim.api.nvim_win_get_width(s.win), highlights)) do
        table.insert(lines, row.text)
        s.rows[#lines] = row.id
        if row.hl then table.insert(styled, { #lines - 1, row.hl }) end
      end
      table.insert(lines, "Coverage / uncertainty")
      if #e.graph.omissions == 0 then table.insert(lines, "  No additional omissions reported by the model.") end
      for _, note in ipairs(e.graph.omissions) do
        vim.list_extend(lines, render.wrap("• " .. note, math.max(20, columns)))
      end
      vim.list_extend(lines, render.wrap("References are range-checked; diagram meaning still needs review.", math.max(20, columns)))
    end
  end
  write(s.buf, lines)
  vim.wo[s.win].cursorline = not graphical
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  for row, hl in pairs({ [0] = "Title", [1] = "Comment", [2] = e and e.stale and "WarningMsg" or "Special",
    [3] = "Comment", [4] = "Comment" }) do
    vim.api.nvim_buf_set_extmark(s.buf, ns, row, 0, { line_hl_group = hl })
  end
  for _, style in ipairs(styled) do
    vim.api.nvim_buf_set_extmark(s.buf, ns, style[1], 0, { line_hl_group = style[2] })
  end
  if graphical and s.image and s.image.id then
    local hl = "InklingCanvas" .. s.image.id
    vim.api.nvim_set_hl(0, hl, { fg = s.image.id, nocombine = true })
    for row = s.canvas_top, #lines - 1 do
      vim.api.nvim_buf_set_extmark(s.buf, ns, row, 0, { end_col = #lines[row + 1], hl_group = hl, priority = 200 })
    end
  end
  if graphical then
    vim.api.nvim_win_call(s.win, function() vim.fn.winrestview({ topline = 1, leftcol = 0 }) end)
    if s.image and s.image.present then
      vim.schedule(function()
        if state == s and s.image and s.image.present then s.image:present() end
      end)
    end
  end
  draw_chat()
end

local function job(fields)
  local opts = config.options.view
  fields.provider, fields.model = opts.provider, opts.model
  fields.timeout, fields.max_tokens = opts.timeout, opts.max_tokens
  fields.purpose = fields.purpose or "diagram"
  fields.output = "json"
  fields.tail = fields.tail or ""
  fields.prompt_chars = #(fields.head or "") + #fields.tail
  return fields
end

local function remember(e)
  if not cache[e.key] then table.insert(cache_order, e.key) end
  cache[e.key] = e
  while #cache_order > 16 do cache[table.remove(cache_order, 1)] = nil end
end

local function install(s, e)
  if s.input then s.input.close(false) end
  if s.entry and s.entry ~= e then
    table.insert(s.history, s.entry)
    if #s.history > 20 then table.remove(s.history, 1) end
  end
  s.entry, s.selection, s.status, s.busy, s.view = e, nil, "", false, e.scope.view
  s.last_focus = e.scope.identity .. ":" .. e.scope.tick
  e.stale = not current(e)
  remember(e)
  draw()
end

generate = function(scope, refinement, force, keep_messages)
  local s = state
  if not visible(s) or not scope then return end
  stop(s)
  s.target = vim.deepcopy(scope)
  local ctx, err = source.collect(scope)
  if not ctx then s.status = err; draw(); return end
  local opts = config.options.view
  local p, name = config.provider()
  if opts.provider then name, p = opts.provider, config.options.providers[opts.provider] end
  if not p then s.status = "Unknown diagram provider"; draw(); return end
  local prompt = source.prompt(ctx)
  local key = vim.fn.sha256(prompt .. (ctx.inventory or "") .. scope.view .. (refinement or "") .. name .. (opts.model or p.model) .. (p.url or "")
    .. vim.json.encode(p.extra_body or {}) .. opts.max_nodes .. ":" .. opts.max_edges
    .. (scope.widened and ":wide" or ":focus") .. (scope.expanded and ":expanded" or ""))
  if not force and cache[key] and current(cache[key]) then
    local cached = cache[key]
    if keep_messages and s.entry and s.entry.scope.path == scope.path and current(s.entry) then
      cached = vim.deepcopy(cached)
      cached.messages, cached.highlights = vim.deepcopy(s.entry.messages), {}
    end
    install(s, cached)
    return
  end
  local id = s.serial
  local previous = s.entry
  s.busy, s.status = true, "Generating " .. scope.view .. " for " .. scope.label .. "…"
  draw()
  local investigate = scope.review or scope.expanded
  local request = job({ system = graphlib.system .. (scope.review and ("\n\n" .. graphlib.review_system) or "")
    .. (investigate and ("\n\n" .. graphlib.investigate_system) or ""),
    schema = graphlib.schema_for(scope.view, scope.review, investigate), head = prompt,
    tail = ("\nView: %s. At most %d nodes and %d edges.\n%s"):format(scope.view, opts.max_nodes,
      opts.max_edges, refinement and ("User's focus for this view: " .. refinement) or "") })
  local submit, reads = nil, 0
  submit = function(attempt)
    s.process = providers.run(request, nil, function(request_err, obj)
      vim.schedule(function()
        if state ~= s or s.serial ~= id then return end
        s.process, s.busy = nil, false
        if not visible(s) then return end
        if not source.current(ctx) then
          s.status = "Source changed during generation; refresh or resume following."
          if s.entry then s.entry.stale = true end
          draw()
          return
        end
        if not request_err and investigate and type(obj) == "table" and type(obj.nodes) == "table" and #obj.nodes == 0 then
          if reads >= opts.max_reads then
            s.status = "Diagram did not complete within the evidence budget; narrow the step-in prompt or choose a file."
            draw()
            return
          end
          reads = reads + 1
          local more = graphlib.answer({ answer = "", read_paths = obj.read_paths, search = obj.search }, ctx, { by_id = {} })
          source.extend(ctx, more.read_paths)
          s.busy, s.status = true, "Inspecting supporting source…"
          draw()
          local function next_request()
            if state ~= s or s.serial ~= id or not visible(s) then return end
            s.search = nil
            request.head = source.prompt(ctx)
            if reads >= opts.max_reads then
              request.tail = request.tail .. "\nEvidence budget exhausted. Return the diagram now and disclose unresolved gaps."
            end
            request.prompt_chars = #request.head + #request.tail
            submit(attempt)
          end
          if more.search ~= "" then s.search = source.search(ctx, more.search, next_request)
          else next_request() end
          return
        end
        local graph, validation_err
        if not request_err then graph, validation_err = graphlib.validate(obj, ctx, opts) end
        if not request_err and not graph and attempt == 1 then
          s.busy, s.status = true, "Correcting invalid diagram structure…"
          request.tail = request.tail .. "\nYour previous diagram failed validation: " .. validation_err
            .. "\nReturn a complete corrected diagram. Previous response:\n" .. vim.json.encode(obj):sub(1, 24000)
          request.prompt_chars = #request.head + #request.tail
          draw()
          submit(2)
          return
        end
        if request_err or not graph then
          s.status = "Diagram failed: " .. (request_err or validation_err or "empty response")
          draw()
          return
        end
        local messages = {}
        if keep_messages and previous and previous.scope.path == scope.path and current(previous) then
          messages = vim.deepcopy(previous.messages)
        end
        install(s, { key = key, graph = graph, context = ctx, scope = vim.deepcopy(scope),
          messages = messages, highlights = {}, refinement = refinement })
      end)
    end)
  end
  submit(1)
end

function M.pin()
  if state then
    local was_following = state.follow
    state.follow = false
    if state.timer then state.timer:stop() end
    if was_following and state.busy and not state.pending and state.entry then
      stop(state)
      state.status = "Pinned the displayed diagram."
    end
    draw()
  end
end

function M.resume()
  if not state then return end
  if not win_ok(state.source_win) or not source.eligible(vim.api.nvim_win_get_buf(state.source_win)) then
    notify("Open a working source file in the code pane before resuming focus following")
    return
  end
  state.follow, state.last_focus = true, nil
  if win_ok(state.source_win) then vim.api.nvim_set_current_win(state.source_win) end
  follow(true)
  draw()
end

local function refresh_scope(e)
  return source.refresh_scope(e.scope)
end

function M.refresh()
  local s = state
  if not s then return end
  if not s.entry then
    if s.target then generate(s.target, nil, true) else follow(true) end
    return
  end
  local scope = refresh_scope(s.entry)
  if not scope then notify("Cannot locate this source scope; resume following from its code"); return end
  generate(scope, s.entry.refinement, true)
end

function M.back()
  local s = state
  if not s then return end
  if s.busy and not s.pending and s.entry then
    stop(s)
    s.follow, s.target, s.status = false, vim.deepcopy(s.entry.scope), ""
    draw()
    return
  end
  if #s.history == 0 then return end
  if s.input then s.input.close(false) end
  stop(s)
  s.follow, s.entry, s.selection, s.status = false, table.remove(s.history), nil, ""
  s.view = s.entry.scope.view
  s.entry.stale = not current(s.entry)
  draw()
end

function M.out()
  local s = state
  if not s or not s.entry then notify("Open a diagram first with :Inkling view"); return end
  if not current(s.entry) then
    s.entry.stale = true
    draw()
    notify("Refresh the changed source before stepping out")
    return
  end
  local scope, err = source.parent(s.entry.scope)
  if not scope then notify(err); return end
  M.pin()
  -- A wider subject starts its own conversation. Back restores the old one.
  generate(scope)
end

local function open_ref(ref, context)
  local s = state
  if not s or not s.entry then return end
  M.pin()
  context = context or s.entry.context
  if not current(s.entry) or not source.current(context) then
    s.entry.stale = true
    draw()
    notify("Source changed since this view; refresh before jumping to exact lines")
    return
  end
  local buf
  if context.scope.review then
    local err
    buf, err = require("inkling.view.review").open_buffer(context, ref)
    if not buf then notify(err); return end
  else
    local path = source.path(context.root, ref.path)
    if not path then return end
    buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
  end
  s.internal = true
  if win_ok(s.source_win) and s.source_win ~= s.win and s.source_win ~= s.chat_win then
    vim.api.nvim_set_current_win(s.source_win)
  else
    vim.api.nvim_set_current_win(s.win)
    vim.cmd("leftabove vsplit")
    s.source_win = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_win_set_buf(s.source_win, buf)
  vim.api.nvim_win_set_cursor(s.source_win, { ref.start_line, 0 })
  vim.cmd("normal! zz")
  s.internal = false
end

function M.source()
  local s = state
  if not s or not s.entry then return end
  local refs
  if vim.api.nvim_get_current_win() == s.chat_win then
    local evidence = s.chat_rows[vim.api.nvim_win_get_cursor(s.chat_win)[1]]
    if evidence then open_ref(evidence.ref, evidence.context); return end
    refs = {}
  else
    local node = selected(s)
    refs = node and node.sources or {}
  end
  if #refs == 0 then
    if vim.api.nvim_get_current_win() ~= s.chat_win and not selected(s) then M.select("source")
    else notify("Select an element with a source reference") end
    return
  end
  if #refs == 1 then open_ref(refs[1]); return end
  local e, items = s.entry, {}
  for _, ref in ipairs(refs) do table.insert(items, { label = source.ref_label(ref), ref = ref }) end
  picker.open(items, { title = "Source evidence", preview = function(item)
    return picker.evidence(e, { label = item.label, sources = { item.ref } })
  end }, function(item) if state == s and s.entry == e and item then open_ref(item.ref) end end)
end

function M.select(action, prompt)
  local s = state
  if not s or not s.entry then return end
  M.pin()
  local e, items = s.entry, {}
  for _, n in ipairs(vim.list_extend(vim.list_slice(e.graph.nodes), e.graph.edges)) do
    local label = element_label(e, n)
    local paths = vim.tbl_map(function(ref) return ref.path end, n.sources)
    table.insert(items, { label = (n.kind or "link") .. " · " .. label, node = n, search = (n.detail or "") .. " " .. table.concat(paths, " ") })
  end
  local function choose(item, next_action)
    if state ~= s or s.entry ~= e or not item then return end
    local n = item.node
    s.selection = n.id
    draw()
    for row, id in pairs(s.rows) do
      if id == n.id then vim.api.nvim_win_set_cursor(s.win, { row, 0 }); break end
    end
    vim.api.nvim_set_current_win(s.win)
    if next_action == "source" then M.source() elseif next_action == "ask" then M.ask()
    elseif next_action == "expand" then M.expand(prompt) end
  end
  picker.open(items, { title = action == "source" and "Open element source" or "Find diagram element",
    hint = "Enter " .. (action == "source" and "source" or "select") .. " · Ctrl-O source · Ctrl-A ask · Esc cancel",
    preview = function(item) return picker.evidence(e, item.node) end,
    actions = { ["<C-o>"] = function(item) choose(item, "source") end, ["<C-a>"] = function(item) choose(item, "ask") end },
  }, function(item) choose(item, action) end)
end

function M.expand(text)
  local s = state
  local n = selected(s)
  if not n then M.select("expand", text); return end
  if #n.sources == 0 then notify("Select an element with source evidence to expand"); return end
  if not current(s.entry) then notify("Refresh the changed source before expanding"); return end
  M.pin()
  if not text or vim.trim(text) == "" then
    local selection = n.id
    vim.api.nvim_set_current_win(s.win)
    compose(s, s.entry, "in:" .. n.id, "Step into " .. n.label .. " · what should we explore?", function(answer)
      s.selection = selection
      M.expand(answer)
    end)
    return
  end
  local ref = n.sources[1]
  local scope
  if s.entry.scope.review then
    scope = require("inkling.view.review").drill(s.entry.scope, n.sources, n.label)
  else
    local path = source.path(s.entry.context.root, ref.path)
    if not path then return end
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    scope = source.focus(buf, ref.start_line, "flow")
  end
  if not scope then return end
  scope.view = s.entry.scope.view
  scope.first, scope.last = math.min(scope.first, ref.start_line), math.max(scope.last, ref.end_line)
  scope.label, scope.expanded = n.label, true
  scope.extra_refs = vim.deepcopy(n.sources)
  source.identify(scope)
  generate(scope, ("Step into %s. User's question/direction: %s\nShow the relevant implementation and evidenced dependencies.")
    :format(n.label, text:sub(1, 4000)))
end

function M.set_view(view)
  if view ~= "components" and view ~= "flow" then notify("Views: components, flow"); return end
  local s = state
  if not s then M.open(view); return end
  M.pin()
  s.view = view
  if s.entry then
    local old = s.entry.scope
    local row = old.first
    if win_ok(s.source_win) and vim.api.nvim_win_get_buf(s.source_win) == old.bufnr then
      row = vim.api.nvim_win_get_cursor(s.source_win)[1]
    end
    local scope = (old.review or old.expanded or old.widened) and refresh_scope(s.entry) or source.focus(old.bufnr, row, view)
    if not scope then return end
    scope.view = view
    source.identify(scope)
    generate(scope, s.entry.refinement, false, true)
  elseif s.target then
    if s.target.review then
      local scope = vim.deepcopy(s.target)
      scope.view = view
      generate(source.identify(scope))
    elseif source.eligible(s.target.bufnr) then generate(source.focus(s.target.bufnr, s.target.first, view)) end
  end
end

function M.choose_view()
  local s = state
  if not s then return end
  M.pin()
  local items = {
    { view = "components", label = "Components · boundaries and dependencies",
      preview = { "# Components", "", "Nested boxes group responsibilities in this file and its local dependencies.", "",
        "Use this to understand what owns each responsibility and how parts connect." } },
    { view = "flow", label = "Flow · decisions and execution paths",
      preview = { "# Flow", "", s.entry and s.entry.scope.widened
        and "Interactions and execution paths at the current wider scope. Step out preserves this boundary when switching views."
        or "Steps, decisions, branches, failures and exits in the function at your code cursor.", "",
        "Use this to check what happens under a condition and which paths can reach an action." } },
  }
  for _, item in ipairs(items) do if item.view == s.view then item.label = item.label .. " (current)" end end
  picker.open(items, { title = "Choose diagram view" }, function(item)
    if state == s and item and item.view ~= s.view then M.set_view(item.view) end
  end)
end

compose = function(s, subject, kind, title, submit)
  if s.input and win_ok(s.input.win) then
    if s.input.kind == kind then
      vim.api.nvim_set_current_win(s.input.win)
      vim.cmd("startinsert!")
      return
    end
    s.input.close(false)
  end
  subject.drafts = subject.drafts or {}
  s.input = input.open({ title = title, default = subject.drafts[kind],
    save = function(text) subject.drafts[kind], s.input = text, nil end,
    submit = function(text)
      if state == s and s.entry == subject then submit(text)
      else notify("Diagram changed; reopen the question for the current view") end
    end,
  })
  s.input.kind = kind
end

function M.refine(text)
  local s = state
  if not s or not s.entry then return end
  M.pin()
  if not text or vim.trim(text) == "" then
    vim.api.nvim_set_current_win(s.win)
    compose(s, s.entry, "refine", "Refine diagram · e.g. show failure paths", M.refine)
    return
  end
  local scope = refresh_scope(s.entry)
  if scope then generate(scope, text:sub(1, 4000), false, true) end
end

function M.export()
  local s = state
  if not s or not s.entry then return end
  M.pin()
  local text = graphlib.mermaid(s.entry.graph, s.entry.highlights)
  vim.api.nvim_set_current_win(s.win)
  vim.cmd("aboveleft new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "mermaid"
  vim.api.nvim_buf_set_name(buf, "inkling://mermaid/" .. buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n"))
end

function M.mermaid()
  local ok, err = render.image_available()
  if not ok then notify(err); return end
  if not state then M.open("components") end
  if not state then return end
  M.pin()
  if state.renderer ~= "mermaid" and not state.busy then state.status = "" end
  state.renderer = "mermaid"
  vim.api.nvim_set_current_win(state.win)
  if state.image then state.image:restore() end
  draw()
end

function M.renderer()
  if not state then return end
  if state.renderer == "native" then M.mermaid()
  else state.renderer = "native"; draw() end
end

function M.pan(dx, dy, normal)
  local s = state
  if s and s.renderer == "mermaid" then
    M.pin()
    if s.image and s.image.camera then
      require("inkling.view.canvas").pan(s.image.camera, dx * vim.v.count1, dy * vim.v.count1)
      draw()
    end
  elseif normal then vim.cmd("normal! " .. vim.v.count1 .. normal) end
end

function M.zoom(factor, x, y)
  local s = state
  if not s or s.renderer ~= "mermaid" or not s.image or not s.image.camera then return end
  M.pin()
  -- Pinning redraws and may replace the image or fall back to text.
  if not s.image or not s.image.camera then return end
  local camera = require("inkling.view.canvas")
  if factor == 0 then camera.fit(s.image.camera) else camera.zoom(s.image.camera, factor, x, y) end
  draw()
end

local function mouse(kind, pos)
  local s = state
  if not s or s.renderer ~= "mermaid" then return end
  if kind == "up" then s.drag = nil; return end
  pos = pos or vim.fn.getmousepos()
  if pos.winid ~= s.win then s.drag = nil; return end
  local x, y = pos.wincol - 1, pos.winrow - 1 - s.canvas_top
  if y < 0 or y >= s.canvas_height then return end
  vim.api.nvim_set_current_win(s.win)
  M.pin()
  if kind == "down" then s.drag = { x, y }
  elseif kind == "drag" and s.drag then
    local dx, dy = s.drag[1] - x, s.drag[2] - y
    s.drag = { x, y }
    M.pan(dx, dy)
  elseif kind == "in" then M.zoom(1.25, x, y)
  elseif kind == "out" then M.zoom(0.8, x, y) end
end

function M.focus()
  local s = state
  if not s or not win_ok(s.win) then return end
  M.pin()
  if s.restore then
    pcall(vim.cmd, s.restore)
    s.restore = nil
  else
    s.restore = vim.fn.winrestcmd()
    vim.api.nvim_set_current_win(s.win)
    vim.cmd("wincmd |")
    vim.cmd("wincmd _")
  end
  draw()
end

local function close_chat()
  if state and state.input then state.input.close(false) end
  if state and win_ok(state.chat_win) then pcall(vim.api.nvim_win_close, state.chat_win, true) end
end

local function chat_window(s)
  if win_ok(s.chat_win) then vim.api.nvim_set_current_win(s.chat_win); return end
  vim.api.nvim_set_current_win(s.win)
  vim.cmd("belowright 14split")
  s.chat_win = vim.api.nvim_get_current_win()
  s.chat_buf = scratch("conversation")
  s.chat_text = nil
  vim.api.nvim_win_set_buf(s.chat_win, s.chat_buf)
  window_options(s.chat_win)
  vim.wo[s.chat_win].wrap = true
  vim.wo[s.chat_win].linebreak = true
  vim.wo[s.chat_win].winfixheight = true
  vim.keymap.set("n", "a", function() M.ask() end, { buffer = s.chat_buf, desc = "inkling: ask about diagram" })
  vim.keymap.set("n", "?", M.actions, { buffer = s.chat_buf, desc = "inkling: actions" })
  vim.keymap.set("n", "<CR>", M.source, { buffer = s.chat_buf, desc = "inkling: open cited source" })
  vim.keymap.set("n", "q", close_chat, { buffer = s.chat_buf, desc = "inkling: close conversation" })
end

function M.ask(question)
  local s = state
  if not s or not s.entry then notify("Open a diagram first with :Inkling view"); return end
  local subject = s.entry
  local n = selected(s)
  if n then s.selection = n.id end
  M.pin()
  if not question or vim.trim(question) == "" then
    if win_ok(s.chat_win) then chat_window(s); draw_chat()
    else vim.api.nvim_set_current_win(s.win) end
    local selection = s.selection
    compose(s, subject, "ask", "Ask · " .. (n and element_label(subject, n) or s.entry.scope.label), function(answer)
      s.selection = selection
      M.ask(answer)
    end)
    return
  end
  local e = s.entry
  if not current(e) then e.stale = true; draw(); notify("Refresh before asking about changed source"); return end
  chat_window(s)
  draw_chat()
  stop(s)
  question = question:sub(1, 8000)
  table.insert(e.messages, { role = "user", text = question })
  s.pending, s.busy, s.status = e, true, "Investigating the question…"
  local id, round = s.serial, 0
  draw()
  local function alive() return state == s and s.serial == id and visible(s) and s.entry == e end
  local function finish(err, answer)
    if not alive() then return end
    s.process, s.search, s.pending, s.busy, s.status = nil, nil, nil, false, ""
    if not current(e) then
      e.stale = true
      err = "Source changed during investigation; refresh and ask again."
    end
    table.insert(e.messages, { role = "assistant", text = err or answer.answer,
      sources = not err and answer.sources or nil, context = not err and e.context or nil })
    if not err then e.highlights = answer.highlights end
    draw()
  end
  local request
  request = function()
    if not alive() then return end
    if not current(e) then return finish("Source changed; refresh and ask again.") end
    local conversation = {}
    for _, m in ipairs(vim.list_slice(e.messages, math.max(1, #e.messages - 11))) do
      table.insert(conversation, { role = m.role, text = m.text:sub(1, 4000) })
    end
    local head = source.prompt(e.context) .. "\n\nDiagram:\n" .. vim.json.encode({ nodes = e.graph.nodes, edges = e.graph.edges })
      .. "\n\nConversation:\n" .. vim.json.encode(conversation)
    local tail = "\nSelected element: " .. (s.selection or "whole diagram")
      .. (round >= config.options.view.max_reads and "\nEvidence budget exhausted. Give your answer now; describe any unresolved gaps."
        or "\nRequest additional source evidence only if needed to answer accurately.")
    s.process = providers.run(job({ purpose = "question", system = graphlib.chat_system
      .. (e.scope.review and ("\n\n" .. graphlib.review_chat_system) or ""),
      schema = graphlib.answer_schema_for(e.scope.review), head = head, tail = tail }),
      nil, function(err, obj)
        vim.schedule(function()
          if not alive() then return end
          s.process = nil
          if err then return finish(err) end
          local answer, validation_err = graphlib.answer(obj, e.context, e.graph)
          if not answer then return finish(validation_err) end
          if answer.answer ~= "" then return finish(nil, answer) end
          if round >= config.options.view.max_reads then
            return finish("The provider did not answer within the evidence budget. Narrow the question or expand the relevant component.")
          end
          round = round + 1
          source.extend(e.context, answer.read_paths)
          if answer.search ~= "" then
            s.search = source.search(e.context, answer.search, function()
              if alive() then s.search = nil; request() end
            end)
          else request() end
        end)
      end)
  end
  request()
end

function M.actions()
  local s = state
  if not s then return end
  M.pin()
  local e = s.entry
  local items = {}
  local function add(key, label, detail, run)
    table.insert(items, { label = key .. "  " .. label, preview = { "# " .. label, "", detail }, run = run })
  end
  add("/", "Find element", "Search names, relationships and source paths. Preview the exact evidence, then select an element or open its code.", M.select)
  add("Enter", "Open source", "Open the selected element's evidence in the code pane. With no selection, choose an element first.", M.source)
  add("a", "Ask a question", "Write a question below the diagram. Ctrl-S sends it; Enter adds a line. Answers cite source and can highlight a path.", function() M.ask() end)
  if s.selection then
    add("", "Ask about whole diagram", "Clear the selected element and ask about the whole view.", function() s.selection = nil; M.ask() end)
    add("Esc", "Clear selection", "Remove the selected element highlight. New questions will cover the whole diagram.", M.deselect)
  end
  add("v", "Choose view", "Components: nested responsibility boundaries and dependencies. Flow: decisions, conditions and execution paths.", M.choose_view)
  add("g", "Refine diagram", "Describe what to emphasize, for example: show only failure paths. This generates a new diagram and keeps the conversation.", function() M.refine() end)
  add("e", "Step in with a prompt", "Choose an element, then describe what to explore: implementation, failure paths, or a dependency. Ctrl-S sends; b returns.", function() M.expand() end)
  if e and e.scope.review then
    add("c", "Changes / Before / After", "Switch the comparison while keeping the same scope and pinned commits.", M.compare)
    add("f", "Changed files", "Browse every changed file, including files not sampled in the overview.", M.review_files)
  end
  local parent, boundary
  if e then parent, boundary = source.parent(e.scope) end
  if parent then
    add("u", "Step out · " .. source.label(parent), "Widen to " .. source.label(parent)
      .. ". Opens a component overview and pins it. Folder/project views sample source within the evidence budget. Press b to return with your conversation.", M.out)
  elseif e then
    add("u", e.scope.level == "project" and "Step out · project boundary" or "Step out · unavailable",
      boundary or "Already at the widest source boundary.", M.out)
  end
  add("p", "Follow code", "Resume following the code cursor. Entering the diagram pins it again so you can inspect it.", M.resume)
  add("r", "Regenerate diagram", e and e.scope.review
    and "Regenerate using these same pinned commits. Run :Inkling review again to capture new commits."
    or "Generate from current code. Starts a new conversation; the previous view remains in history.", M.refresh)
  if #s.history > 0 then add("b", "Previous view", "Return to the preceding diagram and its conversation.", M.back) end
  add("0", "Fit diagram", "Fit the whole diagram. Pan with hjkl, arrows or mouse drag. Zoom with +/-, or the mouse wheel.", function() M.zoom(0) end)
  add("z", "Maximize / restore", "Give the diagram more space, then restore the previous pane sizes.", M.focus)
  add("i", "Toggle text / canvas", "Switch between the native text view and the rendered Mermaid canvas.", M.renderer)
  add("m", "Render / restore image", "Render Mermaid or restore the cached image if the terminal lost it.", M.mermaid)
  add("M", "Export Mermaid source", "Open editable Mermaid source in a scratch pane. Use :write to save it.", M.export)
  add("q", "Close workspace", "Close the diagram and conversation. Your code panes stay open.", M.close)
  if e then
    local details = { "# " .. e.graph.title, "", snapshot_label(e), "", e.graph.summary, "", "Coverage / uncertainty" }
    vim.list_extend(details, e.graph.omissions)
    table.insert(details, "References are range-checked; diagram meaning still needs review.")
    table.insert(items, 1, { label = "About this diagram / coverage", preview = details, run = function()
      notify(table.concat(details, "\n"))
    end })
  end
  picker.open(items, { title = "Inkling actions · type to filter" }, function(item)
    if state == s and s.entry == e and item then item.run() end
  end)
end

function M.deselect()
  if state then
    state.selection = nil
    if state.renderer == "native" and win_ok(state.win) then vim.api.nvim_win_set_cursor(state.win, { 1, 0 }) end
    draw()
  end
end

follow = function(immediate)
  local s = state
  if not visible(s) or not s.follow or s.internal then return end
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  if not source.eligible(buf) or vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then return end
  local scope = source.focus(buf, vim.api.nvim_win_get_cursor(win)[1], s.view)
  if not scope then return end
  s.source_win = win
  local identity = scope.identity .. ":" .. scope.tick
  if not immediate and s.last_focus == identity then return end
  stop(s)
  s.last_focus = identity
  if not s.timer then s.timer = uv.new_timer() end
  s.timer:stop()
  local function run()
    if state == s and s.follow and visible(s) and source.eligible(buf) and win_ok(win)
      and vim.api.nvim_get_current_buf() == buf and vim.api.nvim_win_get_buf(win) == buf then
      generate(source.focus(buf, vim.api.nvim_win_get_cursor(win)[1], s.view))
    end
  end
  if immediate then run() else s.timer:start(config.options.view.debounce_ms, 0, vim.schedule_wrap(run)) end
end

function M.close()
  local s = state
  if not s then return end
  if s.input then s.input.close(false) end
  stop(s)
  state = nil
  if s.timer then s.timer:close() end
  if s.image then s.image:clear() end
  for _, pair in ipairs({ { s.chat_win, s.chat_buf }, { s.win, s.buf } }) do
    if win_ok(pair[1]) and vim.api.nvim_win_get_buf(pair[1]) == pair[2] then
      pcall(vim.api.nvim_win_close, pair[1], true)
    end
  end
end

function M.compare(comparison)
  local s = state
  local e = s and s.entry
  if not e or not e.scope.review then notify("Open a branch review with :Inkling review <base>"); return end
  M.pin()
  if not comparison then
    local items = {
      { value = "changes", label = "Changes · additions, removals and changed behavior", preview = {
        "# Changes", "", "Compare both revisions with unchanged context. Labels show change classifications; inspect the cited evidence." } },
      { value = "before", label = "Before · merge-base behavior", preview = {
        "# Before", "", "Show the source at the common ancestor: " .. e.scope.review.before } },
      { value = "after", label = "After · reviewed branch behavior", preview = {
        "# After", "", "Show the branch at the pinned commit: " .. e.scope.review.after } },
    }
    for _, item in ipairs(items) do if item.value == e.scope.comparison then item.label = item.label .. " (current)" end end
    picker.open(items, { title = "Review comparison" }, function(item)
      if state == s and s.entry == e and item then M.compare(item.value) end
    end)
    return
  end
  if comparison == e.scope.comparison then return end
  if not vim.tbl_contains({ "changes", "before", "after" }, comparison) then return end
  local scope = vim.deepcopy(e.scope)
  scope.comparison = comparison
  generate(source.identify(scope), e.refinement, false, true)
end

function M.review_files()
  local s = state
  local e = s and s.entry
  if not e or not e.scope.review then notify("Open a branch review with :Inkling review <base>"); return end
  M.pin()
  local items = {}
  local labels = { A = "Added", D = "Removed", R = "Renamed", M = "Modified", T = "Type changed", C = "Copied" }
  for _, change in ipairs(e.scope.review.changes) do
    local label = (labels[change.status] or change.status) .. " · " .. (change.after or change.before)
    if change.before and change.after and change.before ~= change.after then label = label .. " ← " .. change.before end
    table.insert(items, { label = label, change = change, preview = {
      "# " .. label, "", "Enter opens a diagram of this file at the review's pinned commits.",
      "Before: " .. (change.before or "(absent)"), "After: " .. (change.after or "(absent)"),
      "", "This list includes files not inspected by the overview. Binary and oversized files may have no diagram evidence.",
    } })
  end
  picker.open(items, { title = "Changed files · " .. #items }, function(item)
    if state == s and s.entry == e and item then
      generate(source.identify(require("inkling.view.review").file_scope(e.scope, item.change)))
    end
  end)
end

function M.review(base, head)
  local git = require("inkling.view.git")
  local buf = vim.api.nvim_get_current_buf()
  local cwd = source.eligible(buf) and vim.fs.dirname(vim.api.nvim_buf_get_name(buf))
    or (state and state.entry and state.entry.scope.root) or vim.fn.getcwd()
  if not base or base == "" then
    local items = vim.tbl_map(function(branch) return { label = branch } end, git.branches(cwd))
    if #items == 0 then notify("No local branches found; use :Inkling review <base> [head]"); return end
    picker.open(items, { title = "Review current branch · choose base" }, function(item)
      if item then M.review(item.label, head) end
    end)
    return
  end
  local review, err = git.start(cwd, base, head)
  if not review then notify(err); return end
  local scope = source.identify(require("inkling.view.review").scope(review))
  if state and visible(state) then
    M.pin()
    generate(scope)
    vim.api.nvim_set_current_win(state.win)
  else
    if state then M.close() end
    M.open("components", scope)
    vim.api.nvim_set_current_win(state.win)
  end
end

function M.open(view, provided_scope)
  view = view or (state and state.view) or "components"
  if view ~= "components" and view ~= "flow" then notify("Views: components, flow"); return end
  if state then
    if state.view ~= view then M.set_view(view) end
    if win_ok(state.win) then vim.api.nvim_set_current_win(state.win) end
    return
  end
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  if not provided_scope and not source.eligible(buf) then notify("Open a named source buffer first"); return end
  local scope = provided_scope or source.focus(buf, vim.api.nvim_win_get_cursor(win)[1], view)
  local s = { view = view, follow = not scope.review, internal = true, source_win = win, serial = 0,
    history = {}, rows = {}, renderer = config.options.view.renderer }
  state = s
  if s.renderer ~= "native" then
    local ok, err = render.image_available()
    s.renderer = ok and "mermaid" or "native"
    if not ok and config.options.view.renderer ~= "auto" then s.status = err end
  end
  vim.cmd("botright vsplit")
  s.win, s.buf = vim.api.nvim_get_current_win(), scratch("diagram")
  vim.api.nvim_win_set_buf(s.win, s.buf)
  window_options(s.win)
  local maps = {
    ["<CR>"] = { M.source, "open source" }, a = { function() M.ask() end, "ask" },
    e = { function() M.expand() end, "step in with a prompt" }, v = { M.choose_view, "choose view" },
    c = { function() M.compare() end, "review comparison" }, f = { M.review_files, "changed files" },
    u = { M.out, "step out to wider perspective" },
    ["?"] = { M.actions, "actions" }, ["<Esc>"] = { M.deselect, "clear selection" },
    p = { function() if s.follow then M.pin() else M.resume() end end, "pin / follow" },
    r = { M.refresh, "refresh" }, b = { M.back, "previous view" }, ["/"] = { M.select, "select element" },
    g = { function() M.refine() end, "refine diagram" }, m = { M.mermaid, "render Mermaid" }, M = { M.export, "export Mermaid source" },
    i = { M.renderer, "image / native" }, z = { M.focus, "focus diagram" }, q = { M.close, "close" },
  }
  for key, delta in pairs({ h = { -4, 0 }, l = { 4, 0 }, j = { 0, 2 }, k = { 0, -2 },
    ["<Left>"] = { -4, 0 }, ["<Right>"] = { 4, 0 }, ["<Down>"] = { 0, 2 }, ["<Up>"] = { 0, -2 } }) do
    local normal = ({ ["<Left>"] = "h", ["<Right>"] = "l", ["<Down>"] = "j", ["<Up>"] = "k" })[key] or key
    maps[key] = { function() M.pan(delta[1], delta[2], normal) end, "pan diagram" }
  end
  maps["+"] = { function() M.zoom(1.25) end, "zoom in" }
  maps["="] = maps["+"]
  maps["-"] = { function() M.zoom(0.8) end, "zoom out" }
  maps["0"] = { function() if s.renderer == "mermaid" then M.zoom(0) else vim.cmd("normal! 0") end end, "fit diagram" }
  for key, action in pairs({ ["<LeftMouse>"] = "down", ["<LeftDrag>"] = "drag", ["<LeftRelease>"] = "up",
    ["<ScrollWheelUp>"] = "in", ["<ScrollWheelDown>"] = "out" }) do
    vim.keymap.set("n", key, function()
      if s.renderer ~= "mermaid" then return key end
      local pos = vim.fn.getmousepos()
      vim.schedule(function() mouse(action, pos) end)
      return ""
    end, { buffer = s.buf, expr = true, silent = true, desc = "inkling: canvas mouse" })
  end
  for lhs, mapping in pairs(maps) do
    vim.keymap.set("n", lhs, mapping[1], { buffer = s.buf, desc = "inkling: " .. mapping[2], silent = true })
  end
  vim.api.nvim_set_current_win(win)
  s.internal = false
  generate(scope)
end

function M.setup()
  if state then M.close() end
  local group = vim.api.nvim_create_augroup("inkling_view", { clear = true })
  local function highlights()
    vim.api.nvim_set_hl(0, "InklingViewSelected", { link = "Visual", default = true })
  end
  highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = function() highlights(); draw() end })
  vim.api.nvim_create_autocmd({ "BufEnter", "CursorMoved", "InsertLeave", "BufWritePost" }, {
    group = group, callback = function()
      local s = state
      if not s or s.internal then return end
      local win = vim.api.nvim_get_current_win()
      if win == s.win or win == s.chat_win then
        if s.follow then M.pin() end
      else follow() end
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost", "FileChangedShellPost" }, {
    group = group, callback = function()
      local s = state
      if s and s.entry then
        if s.entry.stale and vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then return end
        local stale = not current(s.entry)
        if stale ~= s.entry.stale then
          s.entry.stale = stale
          draw()
        end
        if stale then follow() end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", { group = group, callback = function(ev)
    source.forget(ev.buf)
    local s = state
    if s and ev.buf == s.buf then vim.schedule(function() if state == s then M.close() end end) end
  end })
  vim.api.nvim_create_autocmd("WinClosed", { group = group, callback = function(ev)
    local s = state
    if s and tonumber(ev.match) == s.win then vim.schedule(function() if state == s then M.close() end end) end
  end })
  vim.api.nvim_create_autocmd("TabLeave", { group = group, callback = function()
    if state then
      stop(state)
      state.status, state.last_focus = "Paused while workspace is hidden", nil
      if state.image then state.image:clear(); state.image, state.image_key = nil, nil end
    end
  end })
  vim.api.nvim_create_autocmd("TabEnter", { group = group, callback = function() if visible(state) then draw(); follow() end end })
  local restore_serial = 0
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized", "FocusGained", "UIEnter" }, { group = group, callback = function()
    restore_serial = restore_serial + 1
    local serial, s = restore_serial, state
    -- Restore after the terminal/tmux redraw that can erase its image store.
    vim.defer_fn(function()
      if serial ~= restore_serial or state ~= s or not visible(s) then return end
      if s.image then s.image:restore() end
      draw()
    end, 100)
  end })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.close })
end

M.commands = { "components", "flow", "close", "pin", "follow", "refresh", "back", "source", "expand", "in", "out", "ask", "refine", "mermaid", "export", "focus", "fit", "zoom-in", "zoom-out", "actions", "select", "compare", "changes", "before", "after", "files" }
function M.command(args)
  local action = args[2]
  if not action or action == "components" or action == "flow" then return M.open(action) end
  local actions = { close = M.close, pin = M.pin, follow = M.resume, refresh = M.refresh, back = M.back,
    actions = M.actions, select = M.select, out = M.out,
    source = M.source, expand = function() M.expand(table.concat(args, " ", 3)) end,
    ["in"] = function() M.expand(table.concat(args, " ", 3)) end,
    compare = function() M.compare() end, changes = function() M.compare("changes") end,
    before = function() M.compare("before") end, after = function() M.compare("after") end, files = M.review_files,
    mermaid = M.mermaid, export = M.export, focus = M.focus,
    fit = function() M.zoom(0) end, ["zoom-in"] = function() M.zoom(1.25) end, ["zoom-out"] = function() M.zoom(0.8) end,
    ask = function() M.ask(table.concat(args, " ", 3)) end,
    refine = function() M.refine(table.concat(args, " ", 3)) end }
  if actions[action] then actions[action]() else notify("Unknown view action: " .. action) end
end

M._state = function() return state end
return M
