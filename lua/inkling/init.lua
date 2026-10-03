local config = require("inkling.config")
local providers = require("inkling.providers")
local project = require("inkling.context.project")
local edits = require("inkling.context.edits")
local usage = require("inkling.usage")
local nextedit = require("inkling.nextedit")

local M = {}

local ns = vim.api.nvim_create_namespace("inkling")
local uv = vim.uv or vim.loop

-- The suggestion currently displayed (or nil):
--   id        request it came from (keeps receiving streamed text)
--   full      the whole suggestion so far, relative to where it was requested
--   offset    how much of `full` has been typed over or accepted
--   text      what's left to show: full:sub(offset + 1)
--   row, col, before   cursor position / line text before it, as of `offset`
--   streaming still receiving text
local current = nil
local timer = nil
local inflight = nil
local request_id = 0
local last_error = nil

-- Recent requests, newest last: { ms, chars, outcome, text }.
local history = {}
local function record(entry)
  table.insert(history, entry)
  if #history > 50 then
    table.remove(history, 1)
  end
end

local cache = {}
local cache_order = {}
local CACHE_SIZE = 64

local function cache_put(key, text)
  if cache[key] == nil then
    table.insert(cache_order, key)
    if #cache_order > CACHE_SIZE then
      cache[table.remove(cache_order, 1)] = nil
    end
  end
  cache[key] = text
end

local err_ns = vim.api.nvim_create_namespace("inkling_error")

local function clear_error_hint()
  pcall(vim.api.nvim_buf_clear_namespace, 0, err_ns, 0, -1)
end

local function report_error(msg)
  if msg == "cancelled" then
    return
  end
  local first = msg ~= last_error
  last_error = msg
  if first then
    vim.notify("inkling: " .. msg, vim.log.levels.WARN)
  end
  -- Messages get overwritten by "-- INSERT --", so also show the problem
  -- where the suggestion would have appeared (until the next keystroke).
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    clear_error_hint()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    pcall(vim.api.nvim_buf_set_extmark, 0, err_ns, row - 1, col, {
      virt_text = { { "  inkling: " .. msg, "DiagnosticWarn" } },
      virt_text_pos = "eol",
    })
  end
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local function display(s)
  return (s:gsub("\t", string.rep(" ", vim.bo.tabstop)))
end

local function clear()
  if current then
    pcall(vim.api.nvim_buf_clear_namespace, current.bufnr, ns, 0, -1)
  end
  current = nil
end

local function render()
  if not current then
    return
  end
  vim.api.nvim_buf_clear_namespace(current.bufnr, ns, 0, -1)
  local lines = vim.split(current.text, "\n", { plain = true })
  local hl = "InklingSuggestion"
  local opts = {
    virt_text = { { display(lines[1]), hl } },
    virt_text_pos = "inline",
    hl_mode = "combine",
  }
  if #lines > 1 then
    local virt_lines = {}
    for i = 2, #lines do
      table.insert(virt_lines, { { display(lines[i]), hl } })
    end
    opts.virt_lines = virt_lines
  end
  current.extmark = vim.api.nvim_buf_set_extmark(current.bufnr, ns, current.row, current.col, opts)
end

local function refresh_text()
  current.text = current.full:sub(current.offset + 1)
end

---------------------------------------------------------------------------
-- Context + cleanup
---------------------------------------------------------------------------

local function cursor_state()
  local bufnr = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local row, col = pos[1] - 1, pos[2]
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  return bufnr, row, col, line:sub(1, col), line:sub(col + 1)
end

-- The whole file if it fits in the budget, else a window around the cursor
-- (3/4 of the budget before it), cut at line boundaries.
local function file_window(bufnr, row, before, after, max_chars)
  local above = vim.api.nvim_buf_get_lines(bufnr, 0, row, false)
  local below = vim.api.nvim_buf_get_lines(bufnr, row + 1, -1, false)
  table.insert(above, before)
  table.insert(below, 1, after)
  local prefix, suffix = table.concat(above, "\n"), table.concat(below, "\n")
  if #prefix + #suffix <= max_chars then
    return prefix, suffix, false
  end
  local suffix_budget = math.min(#suffix, math.floor(max_chars / 4))
  local prefix_budget = max_chars - suffix_budget
  if #prefix > prefix_budget then
    prefix = prefix:sub(-prefix_budget)
    local nl = prefix:find("\n", 1, true)
    if nl and nl < #prefix - #before then
      prefix = prefix:sub(nl + 1)
    end
  end
  if #suffix > suffix_budget then
    suffix = suffix:sub(1, suffix_budget)
    local nl = suffix:match(".*()\n")
    if nl and nl > #after then
      suffix = suffix:sub(1, nl - 1)
    end
  end
  return prefix, suffix, true
end

local function build_context()
  local bufnr, row, col, before, after = cursor_state()
  local opts = config.context_opts()
  local prefix, suffix, truncated = file_window(bufnr, row, before, after, opts.current_file_max_chars)
  local proj, proj_version = "", 0
  if opts.project.enabled then
    proj, proj_version = project.get(bufnr)
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local recent, edits_version = "", 0
  if opts.recent_edits.enabled then
    local root = name ~= "" and project.root(vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))) or nil
    recent, edits_version = edits.render(root, opts.recent_edits.max_chars)
  end
  return {
    project = proj,
    project_version = proj_version,
    edits = recent,
    edits_version = edits_version,
    truncated = truncated,
    bufnr = bufnr,
    row = row,
    col = col,
    before = before,
    after = after,
    tick = vim.api.nvim_buf_get_changedtick(bufnr),
    prefix = prefix,
    suffix = suffix,
    filename = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[No Name]",
    filetype = vim.bo[bufnr].filetype ~= "" and vim.bo[bufnr].filetype or "text",
  }
end

local function starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

-- Models are imperfect at returning only the inserted text; trim the usual mistakes.
local function clean(text, ctx, partial)
  text = text:gsub("\r\n", "\n")
  local fenced = text:match("^%s*```[%w_+-]*\n(.-)\n?```%s*$")
  if fenced then
    text = fenced
  end
  text = text:gsub("[ \t\n]+$", "")
  -- Chat models occasionally echo prompt-style markup (<current_file>, </reasoning_effort>).
  -- Only snake_case tags, so real HTML/JSX closing tags like </div> survive.
  text = text:gsub("<|CURSOR|>", "")
  local prev
  repeat
    prev = text
    text = text:gsub("\n?%s*</?%w*_[%w_]*>%s*$", ""):gsub("[ \t\n]+$", "")
  until text == prev
  -- Model repeated what's already on the line before the cursor.
  local trimmed_before = vim.trim(ctx.before)
  if trimmed_before ~= "" and starts_with(text, ctx.before) then
    text = text:sub(#ctx.before + 1)
  elseif trimmed_before ~= "" and starts_with(vim.trim(text), trimmed_before) and #trimmed_before > 3 then
    text = vim.trim(text):sub(#trimmed_before + 1)
  elseif ctx.before ~= "" and trimmed_before == "" then
    -- Cursor sits after indentation already; don't indent the first line twice.
    text = text:gsub("^[ \t]+", "")
  end
  -- Model repeated what's already on the line after the cursor (e.g. a closing paren).
  -- For brackets, only strip when the completion would otherwise close too many.
  local after = vim.trim(ctx.after)
  local function balance(s)
    local _, opens = s:gsub("[%(%[{]", "")
    local _, closes = s:gsub("[%)%]}]", "")
    return opens - closes
  end
  local strip = not partial and after ~= "" and text:sub(-#after) == after
  if strip and after:find("[%(%)%[%]{}]") then
    strip = balance(text) < 0
  end
  if strip then
    text = text:sub(1, #text - #after)
    text = text:gsub("[ \t]+$", "")
  end
  return text
end

---------------------------------------------------------------------------
-- Requesting
---------------------------------------------------------------------------

local function eligible(bufnr)
  if not config.options.enabled or vim.b[bufnr].inkling_disabled then
    return false
  end
  if vim.bo[bufnr].buftype ~= "" or not vim.bo[bufnr].modifiable then
    return false
  end
  return not vim.tbl_contains(config.options.disabled_filetypes, vim.bo[bufnr].filetype)
end

local saved_opts = nil -- setup() options, to restore on `:Inkling use default`
local function cancel_inflight()
  if inflight then
    -- providers log the usage of cancelled requests themselves
    pcall(inflight.kill, inflight, 15)
    inflight = nil
  end
end

-- New text for request `id` (streamed so far, or final). Creates the
-- suggestion if the cursor is still where it was requested (or the user has
-- typed text that matches it), otherwise updates the one on screen.
local function update(ctx, id, full, done)
  if current and current.id == id then
    -- what has been typed over / accepted must still match
    if full:sub(1, current.offset) ~= current.full:sub(1, current.offset) then
      clear()
      return
    end
    current.full, current.streaming = full, not done
    refresh_text()
    if current.text == "" and done then
      clear()
    else
      render()
    end
    return
  end
  if current or full == "" or vim.fn.pumvisible() == 1 then
    return
  end
  if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" or vim.api.nvim_get_current_buf() ~= ctx.bufnr then
    return
  end
  local _, row, col, before = cursor_state()
  if row ~= ctx.row or not starts_with(before, ctx.before) then
    return
  end
  local typed = before:sub(#ctx.before + 1)
  if not starts_with(full, typed) or (#full == #typed and done) then
    return
  end
  current = {
    id = id, bufnr = ctx.bufnr, row = row, col = col, before = before,
    full = full, offset = #typed, streaming = not done,
  }
  refresh_text()
  render()
end

function M.request()
  local mode = vim.api.nvim_get_mode().mode
  if mode:sub(1, 1) ~= "i" then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if not eligible(bufnr) then
    return
  end
  local ctx = build_context()
  local key = ctx.project_version .. ":" .. ctx.edits_version .. "\0" .. ctx.prefix .. "\0" .. ctx.suffix
  cancel_inflight()
  request_id = request_id + 1
  local id = request_id
  if cache[key] then
    clear()
    update(ctx, id, cache[key], true)
    return
  end

  local started = uv.hrtime()
  local entry = { chars = #ctx.prefix + #ctx.suffix + #(ctx.project or ""), file = ctx.filename }
  local p = config.provider()
  inflight = providers.run(providers.completion_job(ctx, p), function(partial)
    vim.schedule(function()
      if id ~= request_id then
        return
      end
      entry.first_ms = entry.first_ms or math.floor((uv.hrtime() - started) / 1e6)
      update(ctx, id, clean(partial, ctx, true), false)
    end)
  end, function(err, text)
    vim.schedule(function()
      entry.ms = math.floor((uv.hrtime() - started) / 1e6)
      if id ~= request_id then
        entry.outcome = "superseded"
        return record(entry)
      end
      inflight = nil
      if err then
        entry.outcome = "error: " .. err
        record(entry)
        if current and current.id == id then
          clear()
        end
        return report_error(err)
      end
      last_error = nil
      entry.raw = text
      text = clean(text, ctx)
      entry.text = text
      cache_put(key, text)
      update(ctx, id, text, true)
      entry.outcome = text == "" and "empty" or ((current and current.id == id) and "shown" or "stale")
      record(entry)
    end)
  end)
end

local function schedule_request()
  if not timer then
    timer = uv.new_timer()
  end
  timer:stop()
  timer:start(config.options.debounce_ms, 0, vim.schedule_wrap(M.request))
end

-- If the user typed text that matches the start of the suggestion, consume it
-- instead of throwing the suggestion away. Returns true if a suggestion remains.
local function advance()
  if not current then
    return false
  end
  local bufnr, row, col, before = cursor_state()
  if bufnr ~= current.bufnr or row ~= current.row then
    return false
  end
  if before == current.before and col == current.col then
    return true
  end
  if not starts_with(before, current.before) then
    return false
  end
  local typed = before:sub(#current.before + 1)
  if typed == "" or not starts_with(current.text, typed) then
    return false
  end
  current.offset = current.offset + #typed
  current.before, current.col = before, col
  refresh_text()
  if current.text == "" and not current.streaming then
    return false
  end
  render()
  return true
end

---------------------------------------------------------------------------
-- Accepting
---------------------------------------------------------------------------

local function insert(text)
  -- start a new undo step so `u` takes back just the accepted suggestion
  vim.o.undolevels = vim.o.undolevels
  local _, row, col = cursor_state()
  local lines = vim.split(text, "\n", { plain = true })
  vim.api.nvim_buf_set_text(0, row, col, row, col, lines)
  local end_row = row + #lines - 1
  local end_col = (#lines == 1 and col or 0) + #lines[#lines]
  vim.api.nvim_win_set_cursor(0, { end_row + 1, end_col })
end

local function accept_part(part)
  if not current or part == nil or part == "" then
    return
  end
  local sugg = current
  pcall(vim.api.nvim_buf_clear_namespace, sugg.bufnr, ns, 0, -1)
  insert(part)
  -- keep the same suggestion (it may still be streaming), anchored at the new cursor
  local _, row, col, before = cursor_state()
  sugg.offset = sugg.offset + #part
  sugg.row, sugg.col, sugg.before = row, col, before
  current = sugg
  refresh_text()
  if current.text == "" and not current.streaming then
    clear()
  else
    render()
  end
end

function M.has_suggestion()
  if current and (vim.fn.pumvisible() == 1 or not advance()) then
    clear()
  end
  -- (a suggestion still streaming may have nothing to show yet)
  return current ~= nil and current.text ~= ""
end

function M.accept()
  if current then
    accept_part(current.text)
  end
end

function M.accept_word()
  if current then
    local t = current.text
    accept_part(t:match("^%s*[%w_]+") or t:match("^%s*[^%w_%s]+") or t:match("^%s+"))
  end
end

function M.accept_line()
  if current then
    accept_part(current.text:match("^\n?[^\n]*"))
  end
end

function M.dismiss()
  cancel_inflight()
  if timer then
    timer:stop()
  end
  clear()
end

---------------------------------------------------------------------------
-- Keymaps
---------------------------------------------------------------------------

-- Replay whatever the key did before we mapped it (e.g. a completion menu's <Tab>).
local function make_fallback(lhs)
  local prev = vim.fn.maparg(lhs, "i", false, true)
  local raw = vim.api.nvim_replace_termcodes(lhs, true, false, true)
  if type(prev) ~= "table" or vim.tbl_isempty(prev) or (prev.desc or ""):match("^inkling") then
    return function()
      vim.api.nvim_feedkeys(raw, "n", false)
    end
  end
  local mode = prev.noremap == 1 and "n" or "m"
  local termcodes = function(s)
    return vim.api.nvim_replace_termcodes(s, true, false, true)
  end
  return function()
    local keys
    if prev.callback then
      keys = prev.callback()
      if prev.expr ~= 1 then
        return
      end
      if prev.replace_keycodes == 1 and type(keys) == "string" then
        keys = termcodes(keys)
      end
    elseif prev.expr == 1 then
      keys = vim.api.nvim_eval(prev.rhs)
    else
      keys = termcodes(prev.rhs)
    end
    if type(keys) == "string" and keys ~= "" then
      vim.api.nvim_feedkeys(keys, mode, false)
    end
  end
end

-- `passthrough`: with no suggestion showing, the key does what it did before
-- (Tab indents, <C-]> expands abbreviations). Otherwise it does nothing.
local function map(lhs, action, desc, passthrough)
  if not lhs or lhs == "" then
    return
  end
  local fallback = passthrough and make_fallback(lhs) or function() end
  vim.keymap.set("i", lhs, function()
    if M.has_suggestion() then
      action()
    else
      fallback()
    end
  end, { desc = "inkling: " .. desc, silent = true })
end

local function set_keymaps()
  local k = config.options.keymaps
  map(k.accept, M.accept, "accept suggestion", true)
  map(k.accept_word, M.accept_word, "accept next word")
  map(k.accept_line, M.accept_line, "accept next line")
  map(k.dismiss, M.dismiss, "dismiss suggestion", true)
  if k.trigger and k.trigger ~= "" then
    vim.keymap.set("i", k.trigger, function()
      clear()
      M.request()
    end, { desc = "inkling: request suggestion", silent = true })
  end
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local function status()
  local p, name = config.provider()
  local parts = {
    "inkling " .. (config.options.enabled and "on" or "off"),
    name .. " " .. p.model .. (config.is_auto() and " (auto)" or ""),
  }
  if p.kind ~= "ollama" and (config.api_key(p) or "") == "" then
    table.insert(parts, "NO API KEY ($" .. (p.api_key_env or "?") .. ")")
  end
  local recent = vim.list_slice(history, math.max(1, #history - 9))
  if #recent > 0 then
    local total = 0
    for _, h in ipairs(recent) do
      total = total + h.ms
    end
    table.insert(parts, ("avg %.1fs over %d requests"):format(total / #recent / 1000, #recent))
  end
  local today, n = usage.today_cost()
  if n > 0 then
    table.insert(parts, ("today %s"):format(today < 0.01 and "<$0.01" or ("$%.2f"):format(today)))
  end
  local msg = table.concat(parts, " · ")
  if last_error then
    msg = msg .. "\nlast error: " .. last_error
  end
  vim.notify(msg)
end

-- Show exactly what would be sent for a completion at the cursor.
local function show_context()
  local bufnr = vim.api.nvim_get_current_buf()
  local ctx = build_context()
  local p, name = config.provider()
  project.build(bufnr, function(text, summary)
    ctx.project = config.context_opts().project.enabled and text or ""
    local header = {
      ("# %s %s"):format(name, p.model),
      ("# current file: %d chars%s"):format(#ctx.prefix + #ctx.suffix, ctx.truncated and " (window around cursor)" or " (whole file)"),
      ("# project context: %d chars"):format(#ctx.project),
      ("# recent edits: %d chars"):format(#(ctx.edits or "")),
    }
    for _, l in ipairs(summary) do
      table.insert(header, "#   " .. l)
    end
    local body
    if p.kind == "ollama" and p.fim then
      body = "[FIM prefix]\n" .. ctx.prefix .. "\n[FIM suffix]\n" .. ctx.suffix
    else
      body = "[system]\n" .. providers.system_prompt(p.output) .. "\n\n[user]\n" .. providers.user_prompt(ctx)
    end
    vim.cmd("botright new")
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_buf_set_name(buf, "inkling://context/" .. buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.list_extend(header, vim.split("\n" .. body, "\n", { plain = true })))
    vim.bo[buf].modifiable = false
  end)
end

local function set_enabled(on)
  config.options.enabled = on
  if not on then
    M.dismiss()
    nextedit.clear()
  end
  vim.notify("inkling " .. (on and "on" or "off"))
end

-- `:Inkling use anthropic`, `:Inkling use gpt-5.4-mini`, `:Inkling use openai/gpt-5.4-mini`,
-- `:Inkling use default` (forget it). The choice is remembered across sessions.
local function use(arg)
  if not arg then
    return status()
  end
  if arg == "default" then
    config.options.provider = nil
    config.save_choice(nil)
    config.setup(saved_opts) -- back to configured models
  else
    local prov, model = arg:match("^([^/]+)/(.+)$")
    if not prov then
      if config.options.providers[arg] then
        prov = arg
      else
        model = arg
      end
    end
    if prov then
      if not config.options.providers[prov] then
        return vim.notify("inkling: unknown provider " .. prov, vim.log.levels.ERROR)
      end
      config.options.provider = prov
    end
    local p, name = config.provider()
    if model then
      p.model = model
    end
    config.options.provider = name
    config.save_choice(name, model and p.model or nil)
  end
  cache, cache_order, last_error = {}, {}, nil
  -- providers can override context options (e.g. ollama turns project context off)
  project.refresh(vim.api.nvim_get_current_buf())
  local p, name = config.provider()
  vim.notify(("inkling: %s %s%s"):format(name, p.model, config.is_auto() and " (auto)" or ", remembered"))
end

local subcommands = {
  status = status,
  on = function()
    set_enabled(true)
  end,
  off = function()
    set_enabled(false)
  end,
  toggle = function()
    set_enabled(not config.options.enabled)
  end,
  use = use,
  context = show_context,
  spend = function()
    vim.notify(table.concat(usage.report(), "\n"))
  end,
}

local function create_command()
  vim.api.nvim_create_user_command("Inkling", function(cmd)
    local sub = cmd.fargs[1] or "status"
    local fn = subcommands[sub]
    if not fn then
      return vim.notify("inkling: unknown command " .. sub .. " (try: on, off, toggle, use, context, spend)", vim.log.levels.ERROR)
    end
    fn(cmd.fargs[2])
  end, {
    nargs = "*",
    desc = "inkling: status | on | off | toggle | use <provider or model> | context | spend",
    complete = function(_, line)
      local args = vim.split(line, "%s+")
      if #args <= 2 then
        return { "on", "off", "toggle", "use", "context", "spend", "status" }
      elseif args[2] == "use" then
        local out = { "default" }
        for name, p in pairs(config.options.providers) do
          table.insert(out, name)
          table.insert(out, name .. "/" .. p.model)
        end
        table.sort(out)
        return out
      end
      return {}
    end,
  })
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

function M.setup(opts)
  saved_opts = opts
  config.setup(opts)
  config.load_choice()
  local function set_highlights()
    vim.api.nvim_set_hl(0, "InklingSuggestion", { link = "Comment", default = true })
    vim.api.nvim_set_hl(0, "InklingEditOld", { link = "DiffDelete", default = true })
    vim.api.nvim_set_hl(0, "InklingEditNew", { link = "DiffAdd", default = true })
    vim.api.nvim_set_hl(0, "InklingEditHint", { link = "Comment", default = true })
  end
  set_highlights()

  local group = vim.api.nvim_create_augroup("inkling", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChangedI", "CursorMovedI", "InsertLeave" }, {
    group = group,
    callback = clear_error_hint,
  })
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    callback = function()
      if not advance() then
        clear()
        schedule_request()
      end
    end,
  })
  vim.api.nvim_create_autocmd("CursorMovedI", {
    group = group,
    callback = function()
      if current and not advance() then
        clear()
      end
    end,
  })
  vim.api.nvim_create_autocmd("InsertEnter", { group = group, callback = schedule_request })
  vim.api.nvim_create_autocmd("CompleteChanged", { group = group, callback = clear })
  vim.api.nvim_create_autocmd("CompleteDone", { group = group, callback = schedule_request })
  -- Project context is rebuilt in the background, never during a request.
  local refresh_timers = {}
  local function refresh_later(args)
    local bufnr = args.buf
    if not config.options.enabled or not eligible(bufnr) or not config.context_opts().project.enabled then
      return
    end
    if refresh_timers[bufnr] then
      refresh_timers[bufnr]:stop()
    else
      refresh_timers[bufnr] = uv.new_timer()
    end
    refresh_timers[bufnr]:start(300, 0, vim.schedule_wrap(function()
      project.refresh(bufnr)
    end))
  end
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "InsertLeave" }, { group = group, callback = refresh_later })
  -- Recent edits: remember each buffer's text, checkpoint after each change
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      if eligible(args.buf) then
        edits.track(args.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged", "BufLeave" }, {
    group = group,
    callback = function(args)
      if args.event ~= "InsertLeave" then
        nextedit.clear()
      end
      if eligible(args.buf) then
        local changed = edits.checkpoint(args.buf)
        if changed and args.event ~= "BufLeave" then
          nextedit.schedule(args.buf)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "InsertEnter", "BufLeave" }, { group = group, callback = nextedit.clear })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      project.forget(args.buf)
      edits.forget(args.buf)
      if refresh_timers[args.buf] then
        refresh_timers[args.buf]:close()
        refresh_timers[args.buf] = nil
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = group,
    callback = function()
      M.dismiss()
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = set_highlights,
  })

  create_command()

  -- Map after all plugins have loaded so we can fall back to their <Tab> etc.
  local function on_enter()
    set_keymaps()
    -- Say up front if suggestions can't work (only in interactive sessions).
    -- Deferred so the startup screen doesn't overwrite the message.
    vim.defer_fn(function()
      local p, name = config.provider()
      if config.options.enabled and p.kind ~= "ollama" and #vim.api.nvim_list_uis() > 0
        and (config.api_key(p) or "") == "" then
        local msg = config.is_auto() and "inkling: no API key found ($OPENAI_API_KEY or $ANTHROPIC_API_KEY), so suggestions are off"
          or ("inkling: $%s isn't set, so %s suggestions are off"):format(p.api_key_env or "?", name)
        vim.notify(msg, vim.log.levels.WARN)
      end
    end, 200)
  end
  if vim.v.vim_did_enter == 1 then
    on_enter()
  else
    vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = on_enter })
  end
end

-- Exposed for tests.
M._clean = clean
M._build_context = build_context
M._history = function()
  return history
end
M._clear_cache = function()
  cache, cache_order = {}, {}
end
M._last_error = function()
  return last_error
end
M._current = function()
  return current
end

return M
