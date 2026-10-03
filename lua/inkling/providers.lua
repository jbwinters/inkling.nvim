-- Each provider kind turns a completion context into an HTTP request and pulls
-- the completion text back out of the response.
local config = require("inkling.config")
local http = require("inkling.http")

local M = {}

local CURSOR = "<|CURSOR|>"

local SYSTEM_PROMPT = table.concat({
  "You are a code completion engine embedded in a text editor.",
  "The user sends a file with the cursor position marked by " .. CURSOR .. ".",
  "Reply with ONLY the exact text to insert at the cursor: no explanations, no markdown fences,",
  "and never repeat text that already appears before or after the cursor.",
  "Complete the current line, or the current logical block (e.g. the rest of a function body) when that is clearly intended.",
  "Preserve the file's indentation style. If nothing sensible should be inserted, reply with an empty message.",
  "Related project files (imports, same-directory files, files that use this one) may be provided first as reference:",
  "use them to get names, signatures and conventions right, but only ever write text for the current file.",
}, " ")

-- The project context changes rarely, so it goes first: providers can cache
-- that prefix across requests. The current file changes on every keystroke.
local function project_prompt(ctx)
  if not ctx.project or ctx.project == "" then
    return nil
  end
  return "<project_context>\n" .. ctx.project .. "\n</project_context>"
end

local function file_prompt(ctx)
  local note = ctx.truncated and " (excerpt around the cursor; file is longer)" or ""
  return ('<current_file path="%s" language="%s"%s>\n%s%s%s\n</current_file>'):format(
    ctx.filename, ctx.filetype, note ~= "" and (' note="' .. note .. '"') or "", ctx.prefix, CURSOR, ctx.suffix)
end

local function user_prompt(ctx)
  local proj = project_prompt(ctx)
  return (proj and (proj .. "\n\n") or "") .. file_prompt(ctx)
end

M.SYSTEM_PROMPT = SYSTEM_PROMPT
M.user_prompt = user_prompt

local builders = {}

function builders.openai(p, ctx)
  local headers = {}
  local key = config.api_key(p)
  if key and key ~= "" then
    headers["Authorization"] = "Bearer " .. key
  end
  local body = vim.tbl_extend("force", {
    model = p.model,
    max_completion_tokens = config.options.max_tokens,
    messages = {
      { role = "system", content = SYSTEM_PROMPT },
      { role = "user", content = user_prompt(ctx) },
    },
  }, p.extra_body or {})
  return headers, body, function(resp)
    local choice = resp.choices and resp.choices[1]
    return choice and choice.message and choice.message.content
  end
end

function builders.anthropic(p, ctx)
  local headers = {
    ["x-api-key"] = config.api_key(p) or "",
    ["anthropic-version"] = "2023-06-01",
  }
  local content = {}
  local proj = project_prompt(ctx)
  if proj then
    table.insert(content, { type = "text", text = proj, cache_control = { type = "ephemeral" } })
  end
  table.insert(content, { type = "text", text = file_prompt(ctx) })
  local body = vim.tbl_extend("force", {
    model = p.model,
    max_tokens = config.options.max_tokens,
    system = SYSTEM_PROMPT,
    messages = { { role = "user", content = content } },
  }, p.extra_body or {})
  return headers, body, function(resp)
    local parts = {}
    for _, block in ipairs(resp.content or {}) do
      if block.type == "text" then
        table.insert(parts, block.text)
      end
    end
    return table.concat(parts)
  end
end

function builders.ollama(p, ctx)
  local body
  if p.fim then
    body = { model = p.model, prompt = ctx.prefix, suffix = ctx.suffix }
  else
    body = { model = p.model, system = SYSTEM_PROMPT, prompt = user_prompt(ctx) }
  end
  body.stream = false
  body.options = { num_predict = config.options.max_tokens, temperature = config.options.temperature }
  body = vim.tbl_deep_extend("force", body, p.extra_body or {})
  return {}, body, function(resp)
    return resp.response
  end
end

---@return vim.SystemObj|nil
function M.complete(ctx, cb)
  local p, name = config.provider()
  local build = builders[p.kind]
  if not build then
    cb(("provider %s has unknown kind %q"):format(name, tostring(p.kind)))
    return nil
  end
  if p.kind ~= "ollama" and (config.api_key(p) or "") == "" then
    cb(("no API key for provider %s (set $%s)"):format(name, p.api_key_env or "?"))
    return nil
  end
  local headers, body, extract = build(p, ctx)
  return http.post_json(p.url, headers, body, config.options.timeout, function(err, resp)
    if err then
      return cb(err)
    end
    cb(nil, extract(resp) or "")
  end)
end

return M
