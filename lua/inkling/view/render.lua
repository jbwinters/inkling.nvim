-- Native diagrams and a cached Mermaid raster for interactive image backends.
local graphlib = require("inkling.view.graph")
local M = {}

local function width(s) return vim.fn.strdisplaywidth(s) end
local function wrap(text, columns)
  text = text:gsub("[\r\n\t]", " ")
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    local joined = line == "" and word or (line .. " " .. word)
    if width(joined) <= columns then
      line = joined
    else
      if line ~= "" then table.insert(lines, line) end
      line = ""
      for _, ch in ipairs(vim.fn.split(word, "\\zs")) do
        if width(line .. ch) > columns then table.insert(lines, line); line = "" end
        line = line .. ch
      end
    end
  end
  if line ~= "" or #lines == 0 then table.insert(lines, line) end
  return lines
end
M.wrap = wrap

function M.native(graph, columns, highlights)
  columns = math.max(30, math.min(columns - 2, 110))
  local rows = {}
  local function push(text, id, hl) table.insert(rows, { text = text, id = id, hl = hl }) end
  local function node(n, box_width)
    local inner, content = box_width - 4, {}
    local function add(text, id, hl)
      for _, line in ipairs(wrap(text, inner)) do table.insert(content, { text = line, id = id, hl = hl }) end
    end
    local hl = highlights and highlights[n.id] and "InklingViewSelected" or "Title"
    add((n.kind == "decision" and "◇ " or "") .. graphlib.label(n, graph), n.id, hl)
    if n.detail ~= "" then add(n.detail, n.id, "Comment") end
    if #n.sources == 0 then add("[source unverified]", n.id, "DiagnosticWarn") end
    for _, child in ipairs(graph.nodes) do
      if child.parent == n.id then
        table.insert(content, { text = "", id = n.id })
        for _, r in ipairs(node(child, math.max(14, box_width - 4))) do table.insert(content, r) end
      end
    end
    for _, e in ipairs(graph.edges) do
      if e.from == n.id then
        local eh = highlights and highlights[e.id] and "InklingViewSelected" or "Special"
        add((e.inferred and "┄▶ " or "─▶ ") .. graph.by_id[e.to].label .. " · " .. graphlib.label(e, graph)
          .. (e.inferred and " [inferred]" or ""), e.id, eh)
      end
    end
    local out = { { text = "┌" .. string.rep("─", box_width - 2) .. "┐", id = n.id, hl = hl } }
    for _, r in ipairs(content) do
      table.insert(out, { text = "│ " .. r.text .. string.rep(" ", math.max(0, inner - width(r.text))) .. " │",
        id = r.id, hl = r.hl })
    end
    table.insert(out, { text = "└" .. string.rep("─", box_width - 2) .. "┘", id = n.id, hl = hl })
    return out
  end
  for _, n in ipairs(graph.nodes) do
    if n.parent == "" then
      for _, r in ipairs(node(n, columns)) do table.insert(rows, r) end
      push("")
    end
  end
  push("Arrows define relationships; vertical order does not.", nil, "Comment")
  return rows
end

local camera = require("inkling.view.canvas")
local kitty = require("inkling.view.kitty")
local config = require("inkling.config")

function M.mermaid_command()
  local command = config.options.view.mermaid.command
  if vim.fn.executable(command) == 1 then return command end
  if command == "mmdc" then
    local managed = vim.fn.stdpath("data") .. "/inkling/mermaid/node_modules/.bin/mmdc"
    if vim.fn.executable(managed) == 1 then return managed end
  end
end

function M.image_available()
  if not M.mermaid_command() then return false, "Mermaid canvas needs Mermaid CLI (mmdc); see :help inkling-view" end
  local backend = config.options.view.image_backend or "auto"
  if backend ~= "auto" and backend ~= "kitty" and backend ~= "image.nvim" then
    return false, "Unknown view.image_backend: " .. tostring(backend)
  end
  local kitty_err
  if backend ~= "image.nvim" then
    local ok, err = kitty.available(backend == "kitty")
    if ok then return true, nil, "kitty" end
    if backend == "kitty" then return false, err end
    kitty_err = err
  end
  local ok, err = require("inkling.view.image_nvim").available()
  if ok then return true, nil, "image.nvim" end
  return false, kitty_err and (kitty_err .. "; " .. err) or err
end

local function png_size(data)
  if data:sub(1, 8) ~= "\137PNG\r\n\26\n" or #data < 24 then return nil end
  local function integer(offset)
    local a, b, c, d = data:byte(offset, offset + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return integer(17), integer(21)
end

-- Render once, then pan and zoom the cached raster entirely in the terminal.
function M.image(graph, highlights, win, buf, height, top, cb)
  local ok, err, backend = M.image_available()
  if not ok then cb(err); return nil end
  local base = vim.fn.tempname()
  local input, output = base .. ".mmd", base .. ".png"
  vim.fn.writefile(vim.split(graphlib.mermaid(graph, highlights), "\n"), input)
  local handle = { cancelled = false, backend = backend }
  function handle:clear()
    self.cancelled = true
    if self.unwatch then self.unwatch(); self.unwatch = nil end
    if self.process then pcall(self.process.kill, self.process, 15); self.process = nil end
    if self.external then self.external:clear(); self.external = nil end
    if self.id then kitty.delete(self.id); self.id = nil end
    self.png = nil
    os.remove(input)
    os.remove(output)
  end
  function handle:restore()
    if self.cancelled or not self.png then return end
    if self.external then self.external:restore(); return end
    kitty.upload(self.png, self.id)
    self.placement = nil
    if self.camera then
      self:draw(self.camera.columns, self.camera.rows)
      self:present()
    end
  end
  function handle:draw(columns, rows)
    if not self.camera or self.cancelled then return nil end
    local c = camera.layout(self.camera, columns, rows)
    if self.external then return self.external:draw(c) end
    local size = c.image_columns .. ":" .. c.image_rows
    if self.placement ~= size then
      kitty.place(self.id, c.image_columns, c.image_rows)
      self.placement, self.needs_present = size, true
    end
    return kitty.grid(c)
  end
  function handle:present()
    if self.cancelled then return end
    if self.external then self.external:present(); return end
    local c = self.camera
    if not c or not self.id then return end
    if not self.needs_present or self.placing then return end
    -- Let the separate TUI finish its pending redraw before placement, then
    -- repaint even unchanged placeholders so the image appears while idle.
    self.placing, self.needs_present = true, false
    vim.cmd("redraw")
    vim.defer_fn(function()
      self.placing = false
      if self.cancelled or not vim.api.nvim_win_is_valid(win) then return end
      if vim.api.nvim_win_get_buf(win) ~= buf then return end
      local latest = self.camera
      kitty.place(self.id, latest.image_columns, latest.image_rows)
      self.placement = latest.image_columns .. ":" .. latest.image_rows
      self.needs_present = false
      vim.api.nvim__redraw({ win = win, valid = false, flush = true })
    end, 100)
  end
  local browser = config.options.view.mermaid.browser
  if not browser then
    for _, name in ipairs({ "google-chrome", "google-chrome-stable", "chromium", "chromium-browser" }) do
      if vim.fn.executable(name) == 1 then browser = vim.fn.exepath(name); break end
    end
  end
  handle.process = vim.system({ M.mermaid_command(), "-i", input, "-o", output, "-b", "transparent", "-t",
    vim.o.background == "light" and "default" or "dark", "-s",
    tostring(math.max(1, math.min(6, tonumber(config.options.view.mermaid.scale) or 4))) },
    { text = true, timeout = 30000, env = browser and { PUPPETEER_EXECUTABLE_PATH = browser } or nil },
    vim.schedule_wrap(function(res)
      handle.process = nil
      os.remove(input)
      if handle.cancelled or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
        os.remove(output)
        return
      end
      if res.code ~= 0 then
        os.remove(output)
        return cb("Mermaid rendering failed: " .. vim.trim(res.stderr or ""):sub(1, 240))
      end
      local success, failure = pcall(function()
        local file = assert(io.open(output, "rb"), "Mermaid did not create an image")
        local data = file:read(20 * 1024 * 1024 + 1)
        file:close()
        assert(#data <= 20 * 1024 * 1024, "Rendered diagram exceeds 20 MB")
        local w, h = png_size(data)
        assert(w and w > 0 and h > 0 and w <= 20000 and h <= 20000 and w * h <= 64000000,
          "Invalid or oversized Mermaid PNG; reduce view.mermaid.scale")
        handle.camera = camera.new(w, h, kitty.cell_size())
        handle.png = data
        if backend == "image.nvim" then
          handle.external = require("inkling.view.image_nvim").new(output, win, buf, top, function(failure)
            if handle.cancelled then return end
            handle:clear()
            cb(failure)
          end)
        else
          handle.id = kitty.upload(data)
          handle.unwatch = kitty.watch(function() handle:restore() end)
        end
        camera.layout(handle.camera, vim.api.nvim_win_get_width(win) - 2, height)
      end)
      if not handle.external then os.remove(output) end
      if not success then handle:clear(); cb(tostring(failure)) else cb(nil) end
    end))
  return handle
end

return M
