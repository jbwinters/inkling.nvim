-- Optional Telescope UI. Keep selection usable with only Neovim installed.
local M = {}

function M.open(items, opts, choose)
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    vim.ui.select(items, { prompt = opts.title, format_item = function(item) return item.label end }, choose)
    return
  end
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")
  local options = {
    sorting_strategy = "ascending",
    layout_strategy = "flex",
    layout_config = { width = 0.9, height = math.min(36, vim.o.lines - 4),
      horizontal = { preview_width = 0.52, prompt_position = "top" },
      vertical = { preview_height = 0.5, preview_cutoff = 12, prompt_position = "top", height = 0.85 },
      flip_columns = 110, flip_lines = 18 },
  }
  local picker = pickers.new(options, {
    prompt_title = opts.title,
    results_title = opts.hint or "Enter choose · Esc cancel",
    finder = require("telescope.finders").new_table({ results = items, entry_maker = function(item)
      return { value = item, display = item.label, ordinal = item.label .. " " .. (item.search or "") }
    end }),
    sorter = require("telescope.config").values.generic_sorter(options),
    previewer = previewers.new_buffer_previewer({ title = "Details / source evidence", define_preview = function(self, entry)
      local lines = opts.preview and opts.preview(entry.value) or entry.value.preview or { entry.value.label }
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
      vim.bo[self.state.bufnr].filetype = "markdown"
      vim.wo[self.state.winid].wrap = true
      vim.wo[self.state.winid].linebreak = true
    end }),
    attach_mappings = function(prompt_bufnr, map)
      local function accept(callback)
        local entry = action_state.get_selected_entry()
        if not entry then return end
        actions.close(prompt_bufnr)
        -- Telescope restores focus before an action opens another pane/picker.
        vim.schedule(function() callback(entry.value) end)
      end
      actions.select_default:replace(function() accept(choose) end)
      for key, callback in pairs(opts.actions or {}) do
        map({ "i", "n" }, key, function() accept(callback) end)
      end
      map({ "i", "n" }, "<Esc>", actions.close)
      return true
    end,
  })
  picker:find()
end

-- Preview the exact evidence used by this diagram, even if the file has changed.
function M.evidence(entry, element)
  local label = element.from and (entry.graph.by_id[element.from].label .. " → " .. entry.graph.by_id[element.to].label
    .. ": " .. element.label) or element.label
  local lines = { "# " .. label, "", element.detail or "", "", "Source snapshot" }
  if entry.stale then table.insert(lines, "Source has changed. Refresh before opening exact lines.") end
  if element.inferred then table.insert(lines, "This relationship is inferred; verify it against the source.") end
  if #element.sources == 0 then table.insert(lines, "No checked source reference for this element.") end
  for _, ref in ipairs(element.sources) do
    table.insert(lines, "")
    table.insert(lines, require("inkling.view.source").ref_label(ref))
    table.insert(lines, "```")
    local file = require("inkling.view.source").file(entry.context, ref)
    for row = ref.start_line, math.min(ref.end_line, ref.start_line + 79) do
      table.insert(lines, file and file.lines[row] or (row .. "| (not inspected)"))
    end
    if ref.end_line > ref.start_line + 79 then table.insert(lines, "… open source to read the rest") end
    table.insert(lines, "```")
  end
  return lines
end

return M
