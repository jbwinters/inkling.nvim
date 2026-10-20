-- nvim --headless -u NONE -l tests/view_provider.lua
-- Exercise the real provider job path with a local HTTP transport stub.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local config = require("inkling.config")
config.setup({ provider = "openai", providers = {
  openai = { api_key = "test-key", model = "completion-model" },
  diagrams = { kind = "openai", api_key = "fixture-key", model = "diagram-default", url = "http://fixture.invalid" },
} })
local log = vim.fn.tempname()
require("inkling.usage").path = function() return log end
local captured
require("inkling.http").post_stream = function(url, headers, body, timeout, line, done)
  captured = { url = url, headers = headers, body = body, timeout = timeout, line = line, done = done }
  return { kill = function() done("cancelled") end }
end
local providers = require("inkling.providers")
local schema = require("inkling.view.graph").schema
local failures = 0
local function check(name, condition)
  print((condition and "ok   " or "FAIL ") .. name)
  if not condition then failures = failures + 1 end
end
local result, err
providers.run({ provider = "diagrams", model = "diagram-override", purpose = "diagram", timeout = 60, max_tokens = 5000,
  output = "json", schema = schema, system = "fixture", head = "source fixture", tail = "" }, nil,
  function(e, r) err, result = e, r end)
check("diagram provider override chooses endpoint", captured.url == "http://fixture.invalid")
check("diagram model and timeout are independent", captured.body.model == "diagram-override" and captured.timeout == 60)
check("graph uses structured output", captured.body.response_format.json_schema.schema == schema)
check("completion configuration is unchanged", config.options.provider == "openai"
  and config.options.providers.openai.model == "completion-model" and config.options.providers.diagrams.model == "diagram-default")
local obj = { title = "Fixture", nodes = {}, edges = {}, omissions = {}, summary = "" }
captured.line("data: " .. vim.json.encode({ choices = { { delta = { content = vim.json.encode(obj) } } } }))
captured.line("data: " .. vim.json.encode({ usage = { prompt_tokens = 10, completion_tokens = 5 } }))
captured.done(nil)
vim.wait(20)
check("JSON object returned to diagram consumer", not err and type(result) == "table" and result.title == "Fixture")
check("diagram purpose is logged", vim.json.decode(vim.fn.readfile(log)[1]).purpose == "diagram")
local usage = require("inkling.usage")
config.options.prices["spend-fixture"] = { input = 1000000, output = 0 }
usage.record("diagrams", "spend-fixture", { input = 1 })
usage.record("diagrams", "spend-fixture", { input = 5 }, "diagram")
usage.event("c", "s", "diagrams", "spend-fixture", "lua")
usage.event("c", "a", "diagrams", "spend-fixture", "lua")
local report = table.concat(usage.report(), "\n")
check("diagram spend excluded from cost per acceptance", report:find("$1.0000", 1, true) ~= nil
  and report:find("Diagrams and questions: 2 requests", 1, true) ~= nil)
providers.run({ provider = "missing" }, nil, function(e) err = e end)
check("unknown diagram provider reports an error", err == "unknown provider: missing")
providers.run({ provider = "ollama", max_tokens = 5000, timeout = 60, output = "json", schema = schema,
  system = "fixture", head = "source fixture", tail = "" }, nil, function() end)
check("Ollama diagram uses schema not completion FIM", captured.body.format == schema and not captured.body.suffix)
vim.fn.delete(log)
os.exit(failures == 0 and 0 or 1)
