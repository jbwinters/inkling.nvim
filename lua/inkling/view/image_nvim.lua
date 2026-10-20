-- Optional adapter for image.nvim's Sixel, Überzug++, and Kitty backends.
-- Crop the cached Mermaid PNG before handing it off: image.nvim's document
-- sizing/vertical clipping alone cannot implement a two-dimensional camera.
local M = {}
local terminal = require("inkling.view.kitty")

local function processor()
  for _, name in ipairs({ "magick", "convert" }) do
    if vim.fn.executable(name) == 1 then return name end
  end
end

function M.available()
  if #vim.api.nvim_list_uis() == 0 then return false, "image.nvim needs a terminal UI" end
  if vim.env.TMUX and (vim.env.TMUX_PANE or "") == "" then
    return false, "Cannot identify tmux pane (TMUX_PANE is missing)"
  end
  local ok, api = pcall(require, "image")
  if not ok or type(api.from_file) ~= "function" then
    return false, "Install and configure image.nvim for other image backends"
  end
  if api.is_enabled and not api.is_enabled() then return false, "image.nvim is disabled" end
  if not processor() then return false, "The image.nvim canvas needs ImageMagick (magick or convert)" end
  return true
end

local function unobscured(win, buf, geometry)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf
    or vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage() then return false end
  local pos = vim.api.nvim_win_get_position(win)
  local height, width = vim.api.nvim_win_get_height(win), vim.api.nvim_win_get_width(win)
  -- image.nvim's global sizing limits are disabled for our cropped viewport.
  -- Hide an old crop after shrinking its window until the new crop is ready.
  if geometry and (geometry.x + geometry.width > width or geometry.y + geometry.height > height) then return false end
  local bottom, right = pos[1] + height, pos[2] + width
  for _, other in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if other ~= win and vim.api.nvim_win_get_config(other).relative ~= "" then
      local p = vim.api.nvim_win_get_position(other)
      -- Include a border cell. Hiding a little too much is preferable to
      -- painting a Sixel/Überzug image over a picker, prompt, or chat window.
      if p[1] - 1 < bottom and p[2] - 1 < right
        and p[1] + vim.api.nvim_win_get_height(other) + 1 > pos[1]
        and p[2] + vim.api.nvim_win_get_width(other) + 1 > pos[2] then return false end
    end
  end
  return true
end

function M.new(path, win, buf, top, on_error)
  assert(not vim.env.TMUX or (vim.env.TMUX_PANE or "") ~= "", "Cannot identify tmux pane (TMUX_PANE is missing)")
  local api, command = require("image"), assert(processor(), "ImageMagick is unavailable")
  local self = { version = 0, visible = not vim.env.TMUX, id = "inkling:" .. vim.fn.tempname() }
  local function discard(image, file)
    if image then pcall(image.clear, image) end
    if file then os.remove(file) end
  end
  function self:clear()
    if self.closed then return end
    self.closed, self.version = true, self.version + 1
    if self.job then pcall(self.job.process.kill, self.job.process, 15) end
    if self.unwatch then self.unwatch() end
    if self.events then vim.api.nvim_del_autocmd(self.events) end
    discard(self.image, self.file)
    self.image, self.file = nil, nil
  end
  local function fail(err)
    if self.closed then return end
    self:clear()
    on_error("image.nvim canvas: " .. tostring(err):sub(1, 240))
  end
  function self:present()
    if self.closed or not self.image then return end
    local ok, err = pcall(self.image.render, self.image)
    if not ok then fail(err); return end
    -- Some backends report encoding/initialization errors only in their log.
    -- Do not leave an empty canvas forever when no image was ever displayed.
    local image = self.image
    if image.is_rendered == false and self.visible and unobscured(win, buf, self.geometry) and not image.inkling_checked then
      image.inkling_checked = true
      vim.defer_fn(function()
        image.inkling_checked = nil
        if self.closed or self.image ~= image then return end
        if image.is_rendered == false and self.visible and unobscured(win, buf, self.geometry) then
          fail("backend did not display the image; check image.nvim's backend and terminal setup")
        end
      end, 10000)
    end
  end
  function self:restore()
    if self.closed or not self.image then return end
    local ok, err = pcall(self.image.clear, self.image, true)
    if not ok then fail(err); return end
    self:present()
  end
  function self:draw(c)
    local width, height = math.min(c.columns, c.image_columns), math.min(c.rows, c.image_rows)
    local geometry = { x = c.left, y = top + c.top, width = width, height = height }
    local function pixels(cells, size) return math.max(1, math.floor(cells * size + 0.5)) end
    local resized = ("%dx%d!"):format(pixels(c.image_columns, c.cell_width), pixels(c.image_rows, c.cell_height))
    local crop = ("%dx%d+%d+%d"):format(pixels(width, c.cell_width), pixels(height, c.cell_height),
      math.floor(c.x * c.cell_width + 0.5), math.floor(c.y * c.cell_height + 0.5))
    local signature = resized .. ":" .. crop .. ":" .. geometry.x .. ":" .. geometry.y
    if not self.closed and signature ~= self.signature then
      self.signature, self.version = signature, self.version + 1
      local version = self.version
      if self.job then pcall(self.job.process.kill, self.job.process, 15) end
      -- Coalesce wheel/drag bursts. Never regenerate Mermaid to move the camera.
      vim.defer_fn(function()
        if self.closed or version ~= self.version then return end
        local output = vim.fn.tempname() .. ".png"
        local ok, process = pcall(vim.system, { command, path, "-resize", resized, "-crop", crop, "+repage", output },
          { text = true, timeout = 10000 }, vim.schedule_wrap(function(result)
            if self.job and self.job.version == version then self.job = nil end
            if self.closed or version ~= self.version then os.remove(output); return end
            if result.code ~= 0 then
              os.remove(output)
              fail("viewport conversion failed: " .. vim.trim(result.stderr or "")); return
            end
            local image
            local success, err = pcall(function()
              -- A stable ID also replaces queued frames in asynchronous backends.
              -- Clear first: from_file returns an existing object for a known ID.
              discard(self.image, self.file)
              self.image, self.file = nil, nil
              image = assert(api.from_file(output, {
                id = self.id, namespace = "inkling",
                window = win, buffer = buf, x = geometry.x, y = geometry.y,
                width = width, height = height, with_virtual_padding = false,
              }), "image.nvim did not create an image; check its setup")
              image.ignore_global_max_size = true
              local render = image.render
              -- Also guard redraws initiated by image.nvim itself.
              image.render = function(img, ...)
                if self.closed or self.image ~= img then return end
                local good, failure
                if not self.visible or not unobscured(win, buf, geometry) then good, failure = pcall(img.clear, img, true)
                else good, failure = pcall(render, img, ...) end
                if not good then
                  vim.schedule(function() if self.image == img then fail(failure) end end)
                end
              end
              self.image, self.file, self.geometry = image, output, geometry
              self:present()
            end)
            if not success then discard(image, output); fail(err) end
          end))
        if not ok then os.remove(output); fail(process)
        else self.job = { process = process, version = version } end
      end, 45)
    end
    local lines = {}
    for _ = 1, c.rows do lines[#lines + 1] = string.rep(" ", c.columns) end
    return lines
  end
  self.events = vim.api.nvim_create_autocmd({ "WinNew", "WinEnter", "WinClosed", "WinResized", "TabEnter" }, {
    callback = function() vim.schedule(function() self:present() end) end,
  })
  self.unwatch = terminal.watch(function()
    self.visible = true
    self:restore()
  end, function()
    self.visible = false
    self:present()
  end)
  return self
end

return M
