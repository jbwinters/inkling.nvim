-- Camera math in terminal cells. Moving the camera never regenerates Mermaid.
local M = {}
local function clamp(x, lo, hi) return math.max(lo, math.min(x, hi)) end

function M.new(width, height, cell_width, cell_height)
  return { width = width, height = height, cell_width = cell_width or 8,
    cell_height = cell_height or 16, zoom = 1, x = 0, y = 0 }
end

function M.layout(c, columns, rows)
  c.columns, c.rows = math.max(1, math.min(297, columns)), math.max(1, math.min(297, rows))
  local scale = math.min(c.columns * c.cell_width / c.width, c.rows * c.cell_height / c.height)
  c.fit_columns = math.max(1, math.floor(c.width * scale / c.cell_width))
  c.fit_rows = math.max(1, math.floor(c.height * scale / c.cell_height))
  -- Kitty's Unicode coordinate alphabet contains 297 entries.
  c.max_zoom = math.min(16, 297 / math.max(c.fit_columns, c.fit_rows))
  c.zoom = clamp(c.zoom, 0.25, c.max_zoom)
  c.image_columns = math.max(1, math.floor(c.fit_columns * c.zoom))
  c.image_rows = math.max(1, math.floor(c.fit_rows * c.zoom))
  c.x = math.floor(clamp(c.x, 0, math.max(0, c.image_columns - c.columns)))
  c.y = math.floor(clamp(c.y, 0, math.max(0, c.image_rows - c.rows)))
  c.left = math.max(0, math.floor((c.columns - c.image_columns) / 2))
  c.top = math.max(0, math.floor((c.rows - c.image_rows) / 2))
  return c
end

function M.pan(c, dx, dy)
  c.x, c.y = c.x + dx, c.y + dy
  return M.layout(c, c.columns, c.rows)
end

function M.zoom(c, factor, ax, ay)
  ax, ay = ax or c.columns / 2, ay or c.rows / 2
  local fx = (c.x + ax - c.left) / c.image_columns
  local fy = (c.y + ay - c.top) / c.image_rows
  c.zoom = clamp(c.zoom * factor, 0.25, c.max_zoom)
  M.layout(c, c.columns, c.rows)
  c.x, c.y = fx * c.image_columns - ax + c.left, fy * c.image_rows - ay + c.top
  return M.layout(c, c.columns, c.rows)
end

function M.fit(c)
  c.zoom, c.x, c.y = 1, 0, 0
  return M.layout(c, c.columns, c.rows)
end

return M
