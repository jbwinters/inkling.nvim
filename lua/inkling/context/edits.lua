-- Recent edits across files, sent to the model as unified diffs so it knows
-- what you're in the middle of (renaming something, adding a field, ...).
--
-- Each file keeps a `base`: its text when you started changing it. A file's
-- entry is the diff from base to its last checkpoint. Checkpoints happen on
-- InsertLeave and normal-mode changes, never per keystroke, so the prompt
-- section stays stable (and cacheable) while you type.
local M = {}

local IDLE_RESET = 10 * 60 -- a file untouched this long starts a fresh base
local MAX_FILES = 5
local MAX_CHARS_PER_FILE = 1500

local diff = (vim.text and vim.text.diff) or vim.diff

local snapshots = {} -- bufnr -> text at last checkpoint
local files = {} -- path -> { base, text, t, bufnr }
local version = 0

local function buf_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

local function path_of(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and vim.fs.normalize(vim.fn.fnamemodify(name, ":p")) or nil
end

-- Remember a buffer's starting text (BufEnter / first sight).
function M.track(bufnr)
  if not snapshots[bufnr] and vim.api.nvim_buf_is_loaded(bufnr) then
    snapshots[bufnr] = buf_text(bufnr)
  end
end

-- Record the buffer's current text as a checkpoint. Returns the changed
-- line range { first, last } (1-based, in the new text) if anything changed.
function M.checkpoint(bufnr)
  local path = path_of(bufnr)
  if not path or not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil
  end
  local text = buf_text(bufnr)
  local prev = snapshots[bufnr]
  snapshots[bufnr] = text
  if prev == nil or prev == text then
    return nil
  end
  local now = os.time()
  local f = files[path]
  if not f or now - f.t > IDLE_RESET then
    f = { base = prev }
    files[path] = f
  end
  version = version + 1
  f.text, f.t, f.bufnr, f.seq = text, now, bufnr, version
  -- changed range of this checkpoint, for next-edit prediction
  local hunks = diff(prev .. "\n", text .. "\n", { result_type = "indices" }) or {}
  local first, last
  for _, h in ipairs(hunks) do
    local s, n = h[3], h[4]
    first = math.min(first or s, s)
    last = math.max(last or s, s + math.max(n, 1) - 1)
  end
  return first and { first, last } or nil
end

-- Unified diffs of recently edited files, newest last.
---@param root string|nil paths are shown relative to this
---@param budget integer max characters
function M.render(root, budget)
  local list = {}
  for path, f in pairs(files) do
    if f.base ~= f.text then
      table.insert(list, { path = path, f = f })
    end
  end
  table.sort(list, function(a, b)
    return a.f.seq > b.f.seq
  end)
  local parts, total = {}, 0
  for _, item in ipairs(vim.list_slice(list, 1, MAX_FILES)) do
    local d = diff(item.f.base .. "\n", item.f.text .. "\n", { result_type = "unified", ctxlen = 2 }) or ""
    if #d > MAX_CHARS_PER_FILE then
      -- keep the most recent-looking end of the diff
      d = "...\n" .. d:sub(-MAX_CHARS_PER_FILE)
    end
    local rel = (root and item.path:sub(1, #root + 1) == root .. "/") and item.path:sub(#root + 2)
      or vim.fn.fnamemodify(item.path, ":~:.")
    local block = ("--- %s\n%s"):format(rel, d)
    if total + #block > budget then
      break
    end
    table.insert(parts, 1, block) -- newest last
    total = total + #block
  end
  return table.concat(parts, "\n"), version
end

function M.forget(bufnr)
  snapshots[bufnr] = nil
end

function M._reset()
  snapshots, files, version = {}, {}, 0
end

return M
