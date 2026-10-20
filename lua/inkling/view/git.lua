-- Read-only, bounded access to immutable Git objects. Never checks out a branch.
local M = {}
local MAX_BYTES = 300 * 1024

function M.run(root, args, limit)
  local command = { "git", "--no-pager", "--literal-pathspecs", "-C", root }
  vim.list_extend(command, args)
  local chunks, bytes, overflow = {}, 0, false
  local ok, process = pcall(vim.system, command, { timeout = 3000, stdout = function(_, data)
    if not data then return end
    bytes = bytes + #data
    if bytes > (limit or MAX_BYTES) then overflow = true end
    if not overflow then table.insert(chunks, data) end
  end })
  if not ok then return nil, "Cannot run Git: " .. tostring(process) end
  local result = process:wait()
  if overflow then return nil, "Git output exceeds the review size limit" end
  if result.code ~= 0 then
    return nil, vim.trim((result.stderr or "Git command failed"):sub(1, 500))
  end
  return table.concat(chunks)
end

function M.path(path)
  if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/" or path:find("[%z\r\n]") then return nil end
  for part in path:gmatch("[^/]+") do if part == ".." or part == "." then return nil end end
  return path
end

function M.resolve(root, ref)
  if type(ref) ~= "string" or ref == "" or ref:find("[%z\r\n]") then return nil, "Invalid Git revision" end
  local value, err = M.run(root, { "rev-parse", "--verify", "--end-of-options", ref .. "^{commit}" }, 200)
  if not value then return nil, "Cannot resolve " .. ref .. ": " .. (err or "") end
  value = vim.trim(value)
  if not value:match("^%x+$") then return nil, "Invalid Git commit ID" end
  return value
end

function M.read(review, side, path)
  if (side ~= "before" and side ~= "after") or not M.path(path) then return nil end
  local sha = side == "before" and review.before or review.after
  -- cat-file reads the blob itself; it never follows a filesystem symlink.
  local text = M.run(review.root, { "cat-file", "blob", sha .. ":" .. path })
  if not text or text:find("\0", 1, true) then return nil end
  text = text:gsub("\r\n", "\n"):gsub("\n$", "")
  return vim.split(text, "\n", { plain = true }), vim.fn.sha256(text)
end

function M.start(cwd, base, head)
  local root, err = M.run(cwd, { "rev-parse", "--show-toplevel" }, 4096)
  if not root then return nil, "Open a Git repository first: " .. (err or "") end
  root = vim.trim(root)
  local base_sha, base_err = M.resolve(root, base)
  if not base_sha then return nil, base_err end
  local head_sha, head_err = M.resolve(root, head or "HEAD")
  if not head_sha then return nil, head_err end
  local ancestor, ancestor_err = M.run(root, { "merge-base", "--all", base_sha, head_sha }, 300)
  if not ancestor then return nil, "No common ancestor: " .. (ancestor_err or "") end
  ancestor = vim.trim(ancestor)
  if not ancestor:match("^%x+$") then return nil, "Multiple merge bases; choose an unambiguous baseline" end
  local names, diff_err = M.run(root,
    { "diff", "--no-ext-diff", "--no-textconv", "--name-status", "-z", "--find-renames", ancestor, head_sha, "--" })
  if not names then return nil, diff_err end
  local fields, changes, index = vim.split(names, "\0", { plain = true, trimempty = true }), {}, 1
  while index <= #fields do
    local status, path = fields[index], fields[index + 1]
    if not status or not path then return nil, "Incomplete Git change list" end
    local kind = status:sub(1, 1)
    local change = { status = kind, before = kind ~= "A" and path or nil, after = kind ~= "D" and path or nil }
    index = index + 2
    if kind == "R" or kind == "C" then change.after = fields[index]; index = index + 1 end
    table.insert(changes, change)
    if #changes > 2000 then return nil, "Review exceeds 2,000 changed files; choose a smaller branch comparison" end
  end
  if #changes == 0 then return nil, "No committed changes between the merge base and " .. (head or "HEAD") end
  return { root = root, base_ref = base, head_ref = head or "HEAD", base_tip = base_sha,
    before = ancestor, after = head_sha, changes = changes }
end

function M.hunks(review, change)
  local args = { "diff", "--no-ext-diff", "--no-textconv", "--unified=0", "--find-renames",
    review.before, review.after, "--" }
  if change.before then table.insert(args, change.before) end
  if change.after and change.after ~= change.before then table.insert(args, change.after) end
  local diff = M.run(review.root, args, MAX_BYTES)
  local ranges = { before = {}, after = {} }
  if not diff then return ranges end
  for line in diff:gmatch("[^\n]+") do
    local a, ac, b, bc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if a then
      a, ac, b, bc = tonumber(a), tonumber(ac) or 1, tonumber(b), tonumber(bc) or 1
      table.insert(ranges.before, { math.max(1, a - 16), a + math.max(ac, 1) + 16 })
      table.insert(ranges.after, { math.max(1, b - 16), b + math.max(bc, 1) + 16 })
    end
  end
  return ranges
end

function M.branches(cwd)
  local text = M.run(cwd, { "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes" }, 32768)
  return text and vim.split(text, "\n", { trimempty = true }) or {}
end

return M
