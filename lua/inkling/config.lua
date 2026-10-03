local M = {}

M.defaults = {
  enabled = true,
  -- Which entry in `providers` to use. nil = automatic: "openai" (gpt-6-luna,
  -- cheapest) when its API key is available, else "anthropic" (claude-sonnet-5-5).
  -- A choice made with `:Inkling use` is remembered and takes precedence.
  provider = nil,
  -- Milliseconds to wait after the last keystroke before requesting a completion.
  debounce_ms = 250,
  -- After an edit, predict the next one in the same file (Tab jumps / applies, Esc dismisses).
  next_edit = true,
  next_edit_delay_ms = 500,
  -- What to send with each request. Providers can override any of this with
  -- their own `context = {...}` table (see ollama below).
  context = {
    -- The whole current file is sent if it fits; otherwise a window around the cursor.
    current_file_max_chars = 60000,
    -- Diffs of what you changed recently (any file), so the model knows what you're doing.
    recent_edits = { enabled = true, max_chars = 4000 },
    project = {
      enabled = true,
      -- AGENTS.md / CLAUDE.md / .inkling.md / .cursorrules / .github/copilot-instructions.md,
      -- nearest first, from the file's directory up to the repository root
      instructions = true,
      max_instructions_chars = 6000,
      max_chars = 40000,        -- total budget for related files
      small_file_chars = 3000,  -- related files smaller than this are sent whole
      upstream = true,          -- files the current file imports: outline + definitions it uses
      max_upstream = 10,
      peers = true,             -- same-directory files of the same language: outline
      max_peers = 15,
      downstream = true,        -- files importing the current file: snippets where they use it
      max_downstream = 6,
    },
  },
  max_tokens = 256,
  -- USD per 1M tokens for spend tracking, keyed by model; extends the built-in
  -- list in lua/inkling/usage.lua. e.g. ["gpt-5.4-mini"] = { input = 0.25, output = 2, cache_read = 0.025 }
  prices = {},
  temperature = 0.1,
  -- Request timeout in seconds.
  timeout = 15,
  -- Filetypes where suggestions never trigger. `buftype ~= ""` buffers are always skipped.
  disabled_filetypes = {
    "help", "gitcommit", "gitrebase", "TelescopePrompt", "NvimTree", "nerdtree", "qf", "netrw",
  },
  keymaps = {
    accept = "<Tab>",       -- falls back to the previous <Tab> behaviour when no suggestion is shown
    accept_word = "<M-w>",
    accept_line = "<M-l>",
    dismiss = "<C-]>",
    trigger = "<M-\\>",     -- request a suggestion immediately
  },
  providers = {
    openai = {
      kind = "openai",
      url = "https://api.openai.com/v1/chat/completions",
      model = "gpt-6-luna",
      api_key_env = "OPENAI_API_KEY",
      output = "json", -- "json" or "tags": how the model returns the completion
      -- Merged into the request body. Reasoning off keeps latency around 1s.
      extra_body = { reasoning_effort = "none" },
    },
    anthropic = {
      kind = "anthropic",
      url = "https://api.anthropic.com/v1/messages",
      model = "claude-sonnet-5-5",
      api_key_env = "ANTHROPIC_API_KEY",
      output = "tags",
      -- No extended thinking: same accuracy for completions, faster.
      extra_body = { thinking = { type = "between_tools" } },
    },
    ollama = {
      kind = "ollama",
      url = "http://localhost:11434/api/generate",
      model = "qwen2.5-coder:7b",
      -- Use native fill-in-the-middle (prompt + suffix). Requires a FIM-capable model.
      -- Set to false to use a chat-style prompt instead.
      fim = true,
      -- Local models have small context windows; keep the prompt small.
      context = { current_file_max_chars = 8000, project = { enabled = false }, recent_edits = { enabled = false } },
      extra_body = { options = { num_ctx = 8192 } },
    },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  auto_choice = nil
end

local auto_choice = nil

-- First provider (in preference order) that has an API key.
local function auto_provider()
  if not auto_choice then
    auto_choice = "openai"
    for _, name in ipairs({ "openai", "anthropic" }) do
      local p = M.options.providers[name]
      if p and (M.api_key(p) or "") ~= "" then
        auto_choice = name
        break
      end
    end
  end
  return auto_choice
end

-- Is the provider picked automatically (nothing configured or saved)?
function M.is_auto()
  return M.options.provider == nil
end

function M.provider()
  local name = M.options.provider or auto_provider()
  local p = M.options.providers[name]
  if not p then
    error(("inkling: unknown provider %q"):format(name))
  end
  return p, name
end

---------------------------------------------------------------------------
-- `:Inkling use` choices persist across sessions
---------------------------------------------------------------------------

local function choice_path()
  return vim.fn.stdpath("data") .. "/inkling/choice.json"
end

function M.save_choice(provider, model)
  local path = choice_path()
  if not provider then
    os.remove(path)
    return
  end
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = io.open(path, "w")
  if fd then
    fd:write(vim.json.encode({ provider = provider, model = model }))
    fd:close()
  end
end

function M.load_choice()
  local fd = io.open(choice_path(), "r")
  if not fd then
    return
  end
  local ok, c = pcall(vim.json.decode, fd:read("*a"))
  fd:close()
  if ok and type(c) == "table" and c.provider and M.options.providers[c.provider] then
    M.options.provider = c.provider
    if c.model then
      M.options.providers[c.provider].model = c.model
    end
    return c
  end
end

-- Global context options with the active provider's overrides applied.
function M.context_opts()
  local p = M.provider()
  return vim.tbl_deep_extend("force", M.options.context, p.context or {})
end

-- api_key may be a string, a function returning a string, or read from api_key_env.
function M.api_key(p)
  local key = p.api_key
  if type(key) == "function" then
    key = key()
  end
  if (key == nil or key == "") and p.api_key_env then
    key = vim.env[p.api_key_env]
  end
  return key
end

return M
