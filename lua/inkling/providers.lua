-- Each provider kind turns a completion context into an HTTP request and pulls
-- the completion text back out of the response.
local config = require("inkling.config")
local http = require("inkling.http")
local usage = require("inkling.usage")

local M = {}

local CURSOR = "<|CURSOR|>"

-- How chat models return the completion (provider `output` option):
--   "json": structured output with a single `text` field. The model can't
--           answer in prose, and whitespace survives exactly.
--   "tags": text wrapped in <completion></completion>; anything outside the
--           tags is dropped. Faster than JSON where the model reliably uses tags.
-- In testing, gpt-6-luna often forgets tags (json is much better) while
-- claude-sonnet-5-5 is as accurate with tags and ~0.4s faster.
M.opts = { cursor_hint = true }

local OUTPUT_RULES = {
  json = "Answer with JSON whose `text` field is the exact text to insert at the cursor (an empty string if nothing fits).",
  tags = "Reply with only the text to insert at the cursor, wrapped in <completion></completion> tags"
    .. " (<completion></completion> if nothing fits).",
}

function M.system_prompt(output)
  return table.concat({
    "You are a code completion engine embedded in a text editor.",
    "The user sends a file with the cursor position marked by " .. CURSOR .. ".",
    OUTPUT_RULES[output or "tags"],
    "Never explain, never use markdown fences, and never repeat text that already appears before or after the cursor.",
    "The text is inserted verbatim, so whitespace matters: start with a space when one is needed after the text",
    "before the cursor (e.g. after `return` or `from`), and with a newline to start a new line.",
    "Complete the current line, or the current logical block (e.g. the rest of a function body) when that is clearly intended.",
    "Preserve the file's indentation style. If the code around the cursor looks broken or mid-edit, still give your",
    "best short continuation; do not comment on it.",
    "Related project files (imports, same-directory files, files that use this one) may be provided first as reference:",
    "use them to get names, signatures and conventions right, but only ever write text for the current file.",
  }, " ")
end

-- The project context changes rarely, so it goes first: providers can cache
-- that prefix across requests. The current file changes on every keystroke.
local function project_prompt(ctx)
  if not ctx.project or ctx.project == "" then
    return nil
  end
  return "<project_context>\n" .. ctx.project .. "\n</project_context>"
end

-- The current file split in two: `head` is everything above the cursor line,
-- which doesn't change while you type on one line (so it can be cached);
-- `tail` is the cursor line onwards.
local function file_prompt_parts(ctx)
  local note = ctx.truncated and ' note="excerpt around the cursor; the file is longer"' or ""
  local above = ctx.prefix:sub(1, #ctx.prefix - #ctx.before)
  local head = ('<current_file path="%s" language="%s"%s>\n%s'):format(ctx.filename, ctx.filetype, note, above)
  local tail = ("%s%s%s\n</current_file>"):format(ctx.before, CURSOR, ctx.suffix)
  if M.opts.cursor_hint then
    -- Restating the cursor line helps chat models continue mid-identifier
    -- instead of starting a fresh token.
    tail = tail .. ("\n\nThe cursor line reads `%s%s%s`. Give exactly the text that goes at %s."):format(
      ctx.before, CURSOR, ctx.after, CURSOR)
  end
  return head, tail
end

local function file_prompt(ctx)
  local head, tail = file_prompt_parts(ctx)
  return head .. tail
end

function M.user_prompt(ctx)
  local proj = project_prompt(ctx)
  return (proj and (proj .. "\n\n") or "") .. file_prompt(ctx)
end

-- Text between the completion tags. A missing closing tag is fine (stop
-- sequences cut it off). No tags at all means the model ignored the format,
-- usually to think out loud, so the reply is discarded.
function M.untag(s)
  if not s then
    return nil
  end
  return s:match("<completion>(.-)</completion>") or s:match("<completion>(.*)$") or s:match("^(.-)</completion>") or ""
end

local TEXT_SCHEMA = {
  type = "object",
  properties = { text = { type = "string", description = "Exact text to insert at the cursor." } },
  required = { "text" },
  additionalProperties = false,
}

local builders = {}

function builders.openai(p, ctx)
  local headers = {}
  local key = config.api_key(p)
  if key and key ~= "" then
    headers["Authorization"] = "Bearer " .. key
  end
  local body = {
    model = p.model,
    max_completion_tokens = config.options.max_tokens,
    messages = {
      { role = "system", content = M.system_prompt(p.output) },
      { role = "user", content = M.user_prompt(ctx) },
    },
  }
  if p.output == "json" then
    body.response_format = { type = "json_schema", json_schema = { name = "insert", strict = true, schema = TEXT_SCHEMA } }
  end
  body = vim.tbl_extend("force", body, p.extra_body or {})
  return headers, body, function(resp)
    local choice = resp.choices and resp.choices[1]
    local content = choice and choice.message and choice.message.content
    resp._truncated = choice and choice.finish_reason == "length"
    if p.output == "json" then
      local ok, obj = pcall(vim.json.decode, content or "")
      return ok and type(obj) == "table" and obj.text or ""
    end
    return M.untag(content)
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
  local head, tail = file_prompt_parts(ctx)
  -- second cache breakpoint: the file above the cursor line (only worth it for big files)
  if #head > 4000 then
    table.insert(content, { type = "text", text = head, cache_control = { type = "ephemeral" } })
    table.insert(content, { type = "text", text = tail })
  else
    table.insert(content, { type = "text", text = head .. tail })
  end
  local body = {
    model = p.model,
    max_tokens = config.options.max_tokens,
    system = M.system_prompt(p.output),
    messages = { { role = "user", content = content } },
  }
  if p.output == "json" then
    body.output_config = { format = { type = "json_schema", schema = TEXT_SCHEMA } }
  else
    body.stop_sequences = { "</completion>" }
  end
  body = vim.tbl_deep_extend("force", body, p.extra_body or {})
  return headers, body, function(resp)
    local parts = {}
    for _, block in ipairs(resp.content or {}) do
      if block.type == "text" then
        table.insert(parts, block.text)
      end
    end
    local out = table.concat(parts)
    resp._truncated = resp.stop_reason == "max_tokens"
    M.last_usage = resp.usage
    if p.output == "json" then
      local ok, obj = pcall(vim.json.decode, out)
      return ok and type(obj) == "table" and obj.text or ""
    end
    return M.untag(out)
  end
end

function builders.ollama(p, ctx)
  local body
  if p.fim then
    body = { model = p.model, prompt = ctx.prefix, suffix = ctx.suffix }
  else
    body = { model = p.model, system = M.system_prompt("tags"), prompt = M.user_prompt(ctx) }
  end
  body.stream = false
  body.options = { num_predict = config.options.max_tokens, temperature = config.options.temperature }
  body = vim.tbl_deep_extend("force", body, p.extra_body or {})
  return {}, body, function(resp)
    resp._truncated = resp.done_reason == "length"
    return p.fim and resp.response or M.untag(resp.response)
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
    local u = usage.normalize(p.kind, resp)
    if u then
      vim.schedule(function()
        usage.record(name, p.model, u)
      end)
    end
    local text = extract(resp) or ""
    -- Cut off by max_tokens: keep only complete lines.
    if resp._truncated and text:find("\n") then
      text = text:match("^(.*)\n")
    end
    cb(nil, text)
  end)
end

return M
