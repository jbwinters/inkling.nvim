-- Spend tracking. Every finished request appends its token usage and cost to
-- a JSONL log (safe with several Neovim instances open), and `:Inkling spend`
-- summarises it.
local config = require("inkling.config")

local M = {}

-- USD per 1M tokens. Checked 2026-10; override or extend with `prices` in setup().
M.PRICES = {
  ["claude-sonnet-5-5"] = { input = 2, output = 10, cache_read = 0.2, cache_write = 2.5 },
  ["claude-sonnet-5"] = { input = 2, output = 10, cache_read = 0.2, cache_write = 2.5 },
  ["claude-opus-5-5"] = { input = 4, output = 20, cache_read = 0.2, cache_write = 5 },
  ["claude-haiku-4-5"] = { input = 1, output = 5, cache_read = 0.1, cache_write = 1.25 },
  ["claude-haiku-4-5-20251001"] = { input = 1, output = 5, cache_read = 0.1, cache_write = 1.25 },
  ["gpt-6-luna"] = { input = 0.1, output = 0.5, cache_read = 0.01, cache_write = 0.125 },
}

function M.path()
  return vim.fn.stdpath("data") .. "/inkling/usage.jsonl"
end

local function price(model)
  local custom = config.options.prices or {}
  return custom[model] or M.PRICES[model]
end

-- Cost of normalized usage { input, output, cache_read, cache_write } (input
-- excludes cached tokens). nil when the model's price is unknown.
function M.cost(model, u)
  local p = price(model)
  if not p then
    return nil
  end
  return ((u.input or 0) * p.input + (u.output or 0) * p.output + (u.cache_read or 0) * (p.cache_read or p.input)
    + (u.cache_write or 0) * (p.cache_write or p.input)) / 1e6
end

-- Provider response -> normalized usage.
function M.normalize(kind, resp)
  local u = resp.usage
  if kind == "anthropic" and u then
    return {
      input = u.input_tokens or 0,
      output = u.output_tokens or 0,
      cache_read = u.cache_read_input_tokens or 0,
      cache_write = u.cache_creation_input_tokens or 0,
    }
  elseif kind == "openai" and u then
    local d = u.prompt_tokens_details or {}
    local cached, written = d.cached_tokens or 0, d.cache_write_tokens or 0
    return {
      input = math.max(0, (u.prompt_tokens or 0) - cached - written),
      output = u.completion_tokens or 0,
      cache_read = cached,
      cache_write = written,
    }
  elseif kind == "ollama" then
    return { input = resp.prompt_eval_count or 0, output = resp.eval_count or 0, cache_read = 0, cache_write = 0, free = true }
  end
end

local function append(entry)
  local path = M.path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = io.open(path, "a")
  if fd then
    fd:write(vim.json.encode(entry), "\n")
    fd:close()
  end
end

function M.record(provider, model, u)
  local cost = u.free and 0 or M.cost(model, u)
  cost = cost and math.floor(cost * 1e8 + 0.5) / 1e8
  append({ t = os.time(), p = provider, m = model, i = u.input, o = u.output, cr = u.cache_read, cw = u.cache_write, c = cost })
end

-- Acceptance events. kind: "c" completion | "e" next edit; ev: "s" shown | "a" accepted
function M.event(kind, ev, provider, model, ft)
  append({ t = os.time(), ev = ev, k = kind, p = provider, m = model, ft = ft ~= "" and ft or nil })
end

-- A request cancelled mid-flight (you kept typing). The provider may still bill
-- the input it read, so log an upper-bound estimate: every prompt character at
-- ~3.5 chars/token, at the uncached input price.
function M.record_cancelled(provider, model, chars)
  local est = math.floor(chars / 3.5)
  local p = price(model)
  append({ t = os.time(), p = provider, m = model, x = 1, i = est, c = p and est * p.input / 1e6 or nil })
end

local function read_all()
  local out = {}
  local fd = io.open(M.path(), "r")
  if not fd then
    return out
  end
  for line in fd:lines() do
    local ok, e = pcall(vim.json.decode, line)
    if ok and type(e) == "table" and e.t then
      table.insert(out, e)
    end
  end
  fd:close()
  return out
end

local function bucket()
  return { n = 0, cost = 0, unpriced = 0, tin = 0, tout = 0, xn = 0, xcost = 0, cs = 0, ca = 0, es = 0, ea = 0 }
end

local function add(b, e)
  if e.ev then
    local key = (e.k == "e" and "e" or "c") .. e.ev
    b[key] = (b[key] or 0) + 1
    return
  end
  if e.x then
    b.xn = b.xn + 1
    b.xcost = b.xcost + (e.c or 0)
    return
  end
  b.n = b.n + 1
  b.tin = b.tin + (e.i or 0) + (e.cr or 0) + (e.cw or 0)
  b.tout = b.tout + (e.o or 0)
  if e.c then
    b.cost = b.cost + e.c
  else
    b.unpriced = b.unpriced + 1
  end
end

local function period_starts()
  local now = os.date("*t")
  local today = os.time({ year = now.year, month = now.month, day = now.day, hour = 0 })
  return {
    today = today,
    week = today - 6 * 86400,
    month = os.time({ year = now.year, month = now.month, day = 1, hour = 0 }),
  }
end

function M.today_cost()
  local start = period_starts().today
  local b = bucket()
  for _, e in ipairs(read_all()) do
    if e.t >= start then
      add(b, e)
    end
  end
  return b.cost, b.n, b.cs, b.ca
end

local function tokens(n)
  if n >= 1e6 then
    return ("%.1fM"):format(n / 1e6)
  elseif n >= 1e3 then
    return ("%.0fk"):format(n / 1e3)
  end
  return tostring(n)
end

local function money(x)
  return x < 0.01 and x > 0 and "<$0.01" or ("$%.2f"):format(x)
end

local function pct(a, s)
  return s > 0 and ("%d%%"):format(math.floor(100 * a / s + 0.5)) or "-"
end

function M.report()
  local entries = read_all()
  local starts = period_starts()
  local periods = {
    { "today", starts.today, bucket() },
    { "last 7 days", starts.week, bucket() },
    { "this month", starts.month, bucket() },
    { "all time", 0, bucket() },
  }
  local by_model = {}
  local by_ft = {}
  local days = {}
  for _, e in ipairs(entries) do
    for _, p in ipairs(periods) do
      if e.t >= p[2] then
        add(p[3], e)
      end
    end
    if e.t >= starts.month then
      by_model[e.m] = by_model[e.m] or bucket()
      add(by_model[e.m], e)
      if e.ev and e.ft then
        by_ft[e.ft] = by_ft[e.ft] or bucket()
        add(by_ft[e.ft], e)
      end
    end
    if e.t >= starts.week then
      local d = os.date("%a %b %d", e.t)
      days[d] = days[d] or { t = e.t, b = bucket() }
      add(days[d].b, e)
    end
  end

  local lines = { "inkling spend", "", ("%-12s %9s %15s %10s"):format("", "requests", "tokens in/out", "cost") }
  for _, p in ipairs(periods) do
    local b = p[3]
    table.insert(lines, ("%-12s %9d %15s %10s"):format(p[1], b.n, tokens(b.tin) .. " / " .. tokens(b.tout), money(b.cost)))
  end

  local day_list = {}
  for name, d in pairs(days) do
    table.insert(day_list, { name = name, t = d.t, b = d.b })
  end
  table.sort(day_list, function(a, b)
    return a.t > b.t
  end)
  if #day_list > 0 then
    table.insert(lines, "")
    table.insert(lines, "last 7 days by day:")
    for _, d in ipairs(day_list) do
      table.insert(lines, ("  %-12s %7d req %10s"):format(d.name, d.b.n, money(d.b.cost)))
    end
  end

  local models = vim.tbl_keys(by_model)
  table.sort(models, function(a, b)
    return by_model[a].cost > by_model[b].cost
  end)
  local month = periods[3][3]
  if month.cs + month.es > 0 then
    table.insert(lines, "")
    table.insert(lines, ("this month: %d suggestions shown, %d accepted (%s) · %d next edits shown, %d applied (%s)"):format(
      month.cs, month.ca, pct(month.ca, month.cs), month.es, month.ea, pct(month.ea, month.es)))
  end
  if #models > 0 then
    table.insert(lines, "")
    table.insert(lines, "this month by model:")
    table.insert(lines, ("  %-22s %7s %9s %9s %12s"):format("", "requests", "cost", "accepted", "$/accepted"))
    for _, m in ipairs(models) do
      local b = by_model[m]
      local accepted = b.ca + b.ea
      local note = b.unpriced > 0 and ("  (%d requests unpriced: add it to `prices`)"):format(b.unpriced) or ""
      table.insert(lines, ("  %-22s %7d %9s %9s %12s%s"):format(m, b.n, money(b.cost), pct(b.ca, b.cs),
        accepted > 0 and ("$%.4f"):format(b.cost / accepted) or "-", note))
    end
  end
  local fts = vim.tbl_keys(by_ft)
  table.sort(fts, function(a, b)
    return by_ft[a].cs > by_ft[b].cs
  end)
  if #fts > 0 then
    table.insert(lines, "")
    table.insert(lines, "this month by language (suggestions accepted):")
    for _, ft in ipairs(vim.list_slice(fts, 1, 8)) do
      local b = by_ft[ft]
      table.insert(lines, ("  %-22s %4d of %4d  %s"):format(ft, b.ca, b.cs, pct(b.ca, b.cs)))
    end
  end

  local all = periods[4][3]
  if all.xn > 0 then
    table.insert(lines, "")
    table.insert(lines, ("%d requests were cancelled mid-flight because you kept typing (all time)."):format(all.xn))
    table.insert(lines, ("If the provider billed their input anyway, add up to %s. Not included above."):format(money(all.xcost)))
  end
  if #entries == 0 then
    table.insert(lines, "")
    table.insert(lines, "No requests logged yet.")
  end
  table.insert(lines, "")
  table.insert(lines, "Costs are estimated from reported token usage and the built-in price list.")
  table.insert(lines, "Log: " .. vim.fn.fnamemodify(M.path(), ":~"))
  return lines
end

return M
