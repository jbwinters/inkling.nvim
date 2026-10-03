-- Next-edit prediction: after you change something, ask the model whether
-- that implies another specific change in the same file (other uses of a
-- renamed symbol, call sites of a changed signature, a sibling branch that
-- should mirror the change, ...). The predicted lines are highlighted with
-- the replacement shown below them. Tab jumps there, Tab again applies it,
-- Esc dismisses. The keys are mapped only while a prediction is showing.
local config = require("inkling.config")
local providers = require("inkling.providers")
local edits = require("inkling.context.edits")
local project = require("inkling.context.project")

local M = {}

local ns = vim.api.nvim_create_namespace("inkling_next_edit")
local uv = vim.uv or vim.loop

local current = nil -- { bufnr, start_line, end_line, lines, reason, tick, saved_maps }
local inflight = nil
local timer = nil
local request_id = 0

M.on_shown, M.on_accepted = nil, nil -- hooks (acceptance stats)

local SYSTEM = table.concat({
  "You predict the next edit a programmer will make.",
  "You get the user's recent edits as unified diffs, then the current file with line numbers (`N| text`).",
  "If the most recent edit clearly implies another specific change in this file, propose that one change:",
  "other uses of a renamed symbol, call sites or callers of a changed signature, similar code that should mirror",
  "the change, an import or definition that is now needed, or code the edit left broken.",
  "Pick the location nearest to the cursor. Only propose an edit you are confident the user wants;",
  "never repeat or undo an edit that was already made. If nothing is clearly implied, answer has_edit false.",
  "start_line and end_line are the 1-based, inclusive lines to replace (from the line numbers);",
  "replacement is the complete new text for exactly those lines, without line numbers, keeping indentation.",
  "reason is at most 8 words.",
}, " ")

local SCHEMA = {
  type = "object",
  properties = {
    has_edit = { type = "boolean" },
    start_line = { type = "integer" },
    end_line = { type = "integer" },
    replacement = { type = "string" },
    reason = { type = "string" },
  },
  required = { "has_edit", "start_line", "end_line", "replacement", "reason" },
  additionalProperties = false,
}

local MAX_FILE_CHARS = 40000

---------------------------------------------------------------------------
-- Display + keys
---------------------------------------------------------------------------

local function restore_maps(c)
  for _, lhs in ipairs({ "<Tab>", "<Esc>" }) do
    pcall(vim.keymap.del, "n", lhs, { buffer = c.bufnr })
  end
  for _, m in ipairs(c.saved_maps or {}) do
    pcall(vim.fn.mapset, "n", false, m)
  end
end

function M.clear()
  if inflight then
    pcall(inflight.kill, inflight, 15)
    inflight = nil
  end
  if timer then
    timer:stop()
  end
  if current then
    pcall(vim.api.nvim_buf_clear_namespace, current.bufnr, ns, 0, -1)
    if vim.api.nvim_buf_is_valid(current.bufnr) then
      restore_maps(current)
    end
  end
  current = nil
end

function M.current()
  return current
end

local function in_view(line)
  local top, bot = vim.fn.line("w0"), vim.fn.line("w$")
  return line >= top and line <= bot
end

local function render()
  local c = current
  vim.api.nvim_buf_clear_namespace(c.bufnr, ns, 0, -1)
  for l = c.start_line, c.end_line do
    vim.api.nvim_buf_set_extmark(c.bufnr, ns, l - 1, 0, { line_hl_group = "InklingEditOld" })
  end
  local virt = {}
  for _, l in ipairs(c.lines) do
    table.insert(virt, { { "+ " .. l:gsub("\t", string.rep(" ", vim.bo[c.bufnr].tabstop)), "InklingEditNew" } })
  end
  if #c.lines == 0 then
    table.insert(virt, { { "(delete these lines)", "InklingEditNew" } })
  end
  vim.api.nvim_buf_set_extmark(c.bufnr, ns, c.end_line - 1, 0, { virt_lines = virt })
  local hint = ("  ⇥ Tab: next edit — %s (Esc to dismiss)"):format(c.reason ~= "" and c.reason or "suggested")
  vim.api.nvim_buf_set_extmark(c.bufnr, ns, c.start_line - 1, 0, { virt_text = { { hint, "InklingEditHint" } }, virt_text_pos = "eol" })
  -- point to it from the cursor when it's off screen
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  if not in_view(c.start_line) then
    vim.api.nvim_buf_set_extmark(c.bufnr, ns, cur - 1, 0, {
      virt_text = { { ("  ⇥ Tab: next edit at line %d — %s"):format(c.start_line, c.reason), "InklingEditHint" } },
      virt_text_pos = "eol",
    })
  end
end

local function apply()
  local c = current
  M.clear()
  vim.o.undolevels = vim.o.undolevels -- own undo step
  vim.api.nvim_buf_set_lines(c.bufnr, c.start_line - 1, c.end_line, false, c.lines)
  local row = math.min(c.start_line, vim.api.nvim_buf_line_count(c.bufnr))
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  vim.cmd("normal! ^")
  if M.on_accepted then
    M.on_accepted()
  end
end

local function on_tab()
  local c = current
  if not c then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  if row >= c.start_line and row <= c.end_line then
    apply()
  else
    vim.cmd("normal! m'") -- so <C-o> returns
    vim.api.nvim_win_set_cursor(0, { c.start_line, 0 })
    vim.cmd("normal! ^")
    if not in_view(c.end_line) then
      vim.cmd("normal! zz")
    end
    render()
  end
end

local function show(c)
  current = c
  -- remember buffer-local mappings we're about to shadow
  c.saved_maps = {}
  for _, lhs in ipairs({ "<Tab>", "<Esc>" }) do
    local m = vim.fn.maparg(lhs, "n", false, true)
    if type(m) == "table" and m.buffer == 1 then
      table.insert(c.saved_maps, m)
    end
  end
  vim.keymap.set("n", "<Tab>", on_tab, { buffer = c.bufnr, desc = "inkling: jump to / apply next edit" })
  vim.keymap.set("n", "<Esc>", function()
    M.clear()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
  end, { buffer = c.bufnr, desc = "inkling: dismiss next edit" })
  render()
  if M.on_shown then
    M.on_shown()
  end
end

---------------------------------------------------------------------------
-- Request
---------------------------------------------------------------------------

local function numbered(lines, first, last)
  local out = {}
  for i = first, last do
    table.insert(out, ("%d| %s"):format(i, lines[i]))
  end
  return table.concat(out, "\n")
end

-- The file with line numbers; very large files are cut to a window around the cursor.
local function file_view(lines, cursor)
  local first, last, size = cursor, cursor, #(lines[cursor] or "")
  while (first > 1 or last < #lines) and size < MAX_FILE_CHARS do
    if first > 1 then
      first = first - 1
      size = size + #lines[first] + 8
    end
    if last < #lines then
      last = last + 1
      size = size + #lines[last] + 8
    end
  end
  return numbered(lines, first, last), first, last
end

local function strip_numbers(text)
  local lines = vim.split(text, "\n", { plain = true })
  local all = #lines > 0
  for _, l in ipairs(lines) do
    if not l:match("^%s*%d+| ") then
      all = false
      break
    end
  end
  if all then
    for i, l in ipairs(lines) do
      lines[i] = l:gsub("^%s*%d+| ", "", 1)
    end
  end
  return lines
end

function M.request(bufnr)
  M.clear()
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr then
    return
  end
  if vim.api.nvim_get_mode().mode ~= "n" then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local name = vim.api.nvim_buf_get_name(bufnr)
  local path = name ~= "" and vim.fs.normalize(vim.fn.fnamemodify(name, ":p")) or nil
  local recent = edits.render(path and project.root(path) or nil, 4000)
  if recent == "" then
    return
  end
  local view = file_view(lines, cursor)
  local fname = name ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[No Name]"
  local job = {
    system = SYSTEM,
    head = ("<recent_edits>\n%s\n</recent_edits>\n\n<current_file path=\"%s\" language=\"%s\">\n%s\n</current_file>"):format(
      recent, fname, vim.bo[bufnr].filetype, view),
    tail = ("\n\nThe cursor is on line %d. What is the next edit?"):format(cursor),
    output = "json",
    schema = SCHEMA,
    max_tokens = 800,
    prompt_chars = #recent + #view,
  }
  request_id = request_id + 1
  local id = request_id
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  inflight = providers.run(job, nil, function(err, obj)
    vim.schedule(function()
      if id ~= request_id then
        return
      end
      inflight = nil
      if err or type(obj) ~= "table" or not obj.has_edit then
        return
      end
      -- still the same buffer state, still in normal mode in that buffer?
      if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr
        or vim.api.nvim_buf_get_changedtick(bufnr) ~= tick or vim.api.nvim_get_mode().mode ~= "n" then
        return
      end
      local s, e = tonumber(obj.start_line), tonumber(obj.end_line)
      if not s or not e or s < 1 or e < s or e > #lines then
        return
      end
      local new = strip_numbers((obj.replacement or ""):gsub("\n$", ""))
      if obj.replacement == "" then
        new = {}
      end
      if table.concat(new, "\n") == table.concat(vim.list_slice(lines, s, e), "\n") then
        return -- no actual change
      end
      show({ bufnr = bufnr, start_line = s, end_line = e, lines = new, reason = vim.trim(obj.reason or "") })
    end)
  end)
end

-- After an edit checkpoint: predict the next edit once you've paused.
function M.schedule(bufnr)
  if not config.options.next_edit then
    return
  end
  -- not after undo/redo
  local ut = vim.fn.undotree(bufnr)
  if ut.seq_cur ~= ut.seq_last then
    return
  end
  if not timer then
    timer = uv.new_timer()
  end
  timer:stop()
  timer:start(config.options.next_edit_delay_ms or 500, 0, vim.schedule_wrap(function()
    M.request(bufnr)
  end))
end

M._show = show
M._on_tab = on_tab

return M
