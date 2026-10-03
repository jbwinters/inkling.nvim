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
    "Related project files (imports, same-directory files, files that use this one) may be provided first as reference,",
    "followed by diffs of the user's recent edits, which show what they are in the middle of doing.",
    "Use them to get names, signatures and conventions right and to continue the user's current change consistently,",
    "but only ever write text for the current file at the cursor.",
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
  if ctx.edits and ctx.edits ~= "" then
    -- recent changes only update when you leave insert mode, so they sit in the cached part
    head = "<recent_edits>\n" .. ctx.edits .. "\n</recent_edits>\n\n" .. head
  end
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

-- While streaming: the text inside <completion> so far, without a half-arrived
-- closing tag. nil until the opening tag has arrived.
local function partial_untag(s)
  local _, e = s:find("<completion>", 1, true)
  if not e then
    return nil
  end
  local body = s:sub(e + 1)
  local close = body:find("</completion>", 1, true)
  if close then
    return body:sub(1, close - 1)
  end
  -- drop a trailing prefix of "</completion>" that may still be arriving
  for k = math.min(#body, 12), 1, -1 do
    if ("</completion>"):sub(1, k) == body:sub(-k) then
      return body:sub(1, #body - k)
    end
  end
  return body
end

local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local ESCAPES = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

-- While streaming JSON: the value of string field `field` decoded so far.
-- Pure Lua (runs in a fast context).
function M.partial_json_field(s, field)
  local _, e = s:find('"' .. field .. '"%s*:%s*"')
  if not e then
    return nil
  end
  local out, i = {}, e + 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      break
    elseif c == "\\" then
      local n = s:sub(i + 1, i + 1)
      if n == "" then
        break
      elseif n == "u" then
        local hex = s:sub(i + 2, i + 5)
        if not hex:match("^%x%x%x%x$") then
          break
        end
        local cp = tonumber(hex, 16)
        i = i + 6
        if cp >= 0xD800 and cp <= 0xDBFF then
          local lo = s:match("^\\u(%x%x%x%x)", i)
          if not lo then
            break
          end
          cp = 0x10000 + (cp - 0xD800) * 0x400 + (tonumber(lo, 16) - 0xDC00)
          i = i + 6
        end
        table.insert(out, utf8_char(cp))
      else
        table.insert(out, ESCAPES[n] or n)
        i = i + 2
      end
    else
      table.insert(out, c)
      i = i + 1
    end
  end
  return table.concat(out)
end

M.TEXT_SCHEMA = {
  type = "object",
  properties = { text = { type = "string", description = "Exact text to insert at the cursor." } },
  required = { "text" },
  additionalProperties = false,
}

---------------------------------------------------------------------------
-- Jobs: what to send, independent of provider.
--   system, project (cached), head (cached when large), tail,
--   output = "tags" | "json", schema (json), field (json value to stream),
--   fim = { prefix, suffix } (ollama native FIM), max_tokens
---------------------------------------------------------------------------

function M.completion_job(ctx, p)
  local head, tail = file_prompt_parts(ctx)
  local output = p.kind == "ollama" and "tags" or (p.output or "tags")
  return {
    system = M.system_prompt(output),
    project = project_prompt(ctx),
    head = head,
    tail = tail,
    output = output,
    schema = M.TEXT_SCHEMA,
    field = "text",
    fim = p.kind == "ollama" and p.fim and { prefix = ctx.prefix, suffix = ctx.suffix } or nil,
    max_tokens = config.options.max_tokens,
    prompt_chars = #ctx.prefix + #ctx.suffix + #(ctx.project or "") + #(ctx.edits or ""),
  }
end

local function user_text(job)
  return (job.project and (job.project .. "\n\n") or "") .. job.head .. job.tail
end

-- Per kind: request headers/body, plus a stream parser that turns each
-- response line into state { text, usage, stop }.
local kinds = {}

kinds.openai = {
  request = function(p, job)
    local headers = {}
    local key = config.api_key(p)
    if key and key ~= "" then
      headers["Authorization"] = "Bearer " .. key
    end
    local body = {
      model = p.model,
      max_completion_tokens = job.max_tokens,
      stream = true,
      stream_options = { include_usage = true },
      messages = {
        { role = "system", content = job.system },
        { role = "user", content = user_text(job) },
      },
    }
    if job.output == "json" then
      body.response_format = { type = "json_schema", json_schema = { name = "reply", strict = true, schema = job.schema } }
    end
    return headers, vim.tbl_extend("force", body, p.extra_body or {})
  end,
  parse = function(st, line)
    local data = line:match("^data:%s*(.*)$")
    if not data or data == "[DONE]" then
      return
    end
    local ok, ev = pcall(vim.json.decode, data)
    if not ok or type(ev) ~= "table" then
      return
    end
    if ev.error then
      st.error = type(ev.error) == "table" and ev.error.message or tostring(ev.error)
    end
    local choice = ev.choices and ev.choices[1]
    if choice then
      if choice.delta and type(choice.delta.content) == "string" then
        st.text = st.text .. choice.delta.content
      end
      if choice.finish_reason and choice.finish_reason ~= vim.NIL then
        st.truncated = choice.finish_reason == "length"
      end
    end
    if type(ev.usage) == "table" then
      st.raw_usage = ev.usage
    end
  end,
}

kinds.anthropic = {
  request = function(p, job)
    local headers = {
      ["x-api-key"] = config.api_key(p) or "",
      ["anthropic-version"] = "2023-06-01",
    }
    local content = {}
    if job.project then
      table.insert(content, { type = "text", text = job.project, cache_control = { type = "ephemeral" } })
    end
    -- second cache breakpoint: the file above the cursor line (only worth it for big files)
    if #job.head > 4000 then
      table.insert(content, { type = "text", text = job.head, cache_control = { type = "ephemeral" } })
      table.insert(content, { type = "text", text = job.tail })
    else
      table.insert(content, { type = "text", text = job.head .. job.tail })
    end
    local body = {
      model = p.model,
      max_tokens = job.max_tokens,
      stream = true,
      system = job.system,
      messages = { { role = "user", content = content } },
    }
    if job.output == "json" then
      body.output_config = { format = { type = "json_schema", schema = job.schema } }
    else
      body.stop_sequences = { "</completion>" }
    end
    return headers, vim.tbl_deep_extend("force", body, p.extra_body or {})
  end,
  parse = function(st, line)
    local data = line:match("^data:%s*(.*)$")
    if not data then
      return
    end
    local ok, ev = pcall(vim.json.decode, data)
    if not ok or type(ev) ~= "table" then
      return
    end
    if ev.type == "message_start" and ev.message then
      st.raw_usage = ev.message.usage
    elseif ev.type == "content_block_delta" and ev.delta and ev.delta.type == "text_delta" then
      st.text = st.text .. ev.delta.text
    elseif ev.type == "message_delta" then
      if ev.usage and st.raw_usage then
        st.raw_usage.output_tokens = ev.usage.output_tokens
      end
      if ev.delta and ev.delta.stop_reason then
        st.truncated = ev.delta.stop_reason == "max_tokens"
      end
    elseif ev.type == "error" then
      st.error = ev.error and ev.error.message or "stream error"
    end
  end,
}

kinds.ollama = {
  request = function(p, job)
    local body
    if job.fim then
      body = { model = p.model, prompt = job.fim.prefix, suffix = job.fim.suffix }
    else
      body = { model = p.model, system = job.system, prompt = user_text(job) }
      if job.output == "json" then
        body.format = job.schema
      end
    end
    body.stream = true
    body.options = { num_predict = job.max_tokens, temperature = config.options.temperature }
    return {}, vim.tbl_deep_extend("force", body, p.extra_body or {})
  end,
  parse = function(st, line)
    local ok, ev = pcall(vim.json.decode, line)
    if not ok or type(ev) ~= "table" then
      return
    end
    if ev.error then
      st.error = tostring(ev.error)
    end
    if type(ev.response) == "string" then
      st.text = st.text .. ev.response
    end
    if ev.done then
      st.truncated = ev.done_reason == "length"
      st.raw_usage = { prompt_eval_count = ev.prompt_eval_count, eval_count = ev.eval_count }
    end
  end,
}

-- The usable result from raw model text: completion text (string) for tags /
-- FIM / json-with-field, or the decoded object for json without a field.
local function final_result(job, raw)
  if job.fim then
    return raw
  elseif job.output == "json" then
    local ok, obj = pcall(vim.json.decode, raw)
    if not ok or type(obj) ~= "table" then
      return job.field and "" or nil
    end
    if job.field then
      return type(obj[job.field]) == "string" and obj[job.field] or ""
    end
    return obj
  end
  return M.untag(raw)
end

local function partial_result(job, raw)
  if job.fim then
    return raw
  elseif job.output == "json" then
    return job.field and M.partial_json_field(raw, job.field) or nil
  end
  return partial_untag(raw)
end

-- Run a job on the active provider, streaming.
--   on_partial(text)        text so far (fast context; may be nil-skipped)
--   on_done(err, result)    final result (fast context)
-- Usage is logged when the request ends, including when it's cancelled.
---@return vim.SystemObj|nil
function M.run(job, on_partial, on_done)
  local p, name = config.provider()
  local kind = kinds[p.kind]
  if not kind then
    on_done(("provider %s has unknown kind %q"):format(name, tostring(p.kind)))
    return nil
  end
  if p.kind ~= "ollama" and (config.api_key(p) or "") == "" then
    on_done(("no API key for provider %s (set $%s)"):format(name, p.api_key_env or "?"))
    return nil
  end
  local headers, body = kind.request(p, job)
  local st = { text = "" }
  local last_partial = nil
  return http.post_stream(p.url, headers, body, config.options.timeout, function(line)
    kind.parse(st, line)
    if on_partial then
      local part = partial_result(job, st.text)
      if part and part ~= last_partial then
        last_partial = part
        on_partial(part)
      end
    end
  end, function(err)
    err = err or st.error
    local cancelled = err == "cancelled"
    -- spend: what the provider reported; for a cancelled request without a
    -- report yet, an upper-bound estimate
    local u = st.raw_usage and usage.normalize(p.kind, { usage = st.raw_usage, prompt_eval_count = st.raw_usage.prompt_eval_count, eval_count = st.raw_usage.eval_count })
    if u and cancelled then
      u.output = math.max(u.output or 0, math.floor(#st.text / 4))
    end
    vim.schedule(function()
      if u then
        usage.record(name, p.model, u)
      elseif cancelled and job.prompt_chars then
        usage.record_cancelled(name, p.model, job.prompt_chars)
      end
    end)
    if err then
      return on_done(err)
    end
    local result = final_result(job, st.text)
    -- cut off by max_tokens: keep only complete lines
    if type(result) == "string" and st.truncated and result:find("\n") then
      result = result:match("^(.*)\n")
    end
    on_done(nil, result)
  end)
end

-- Non-interactive completion (tests, benchmark): cb(err, text).
function M.complete(ctx, cb)
  local p = config.provider()
  return M.run(M.completion_job(ctx, p), nil, cb)
end

return M
