local M = {}

M.defaults = {
  enabled = true,
  -- Which entry in `providers` to use.
  provider = "anthropic",
  -- Milliseconds to wait after the last keystroke before requesting a completion.
  debounce_ms = 250,
  -- What to send with each request. Providers can override any of this with
  -- their own `context = {...}` table (see ollama below).
  context = {
    -- The whole current file is sent if it fits; otherwise a window around the cursor.
    current_file_max_chars = 60000,
    project = {
      enabled = true,
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
      context = { current_file_max_chars = 8000, project = { enabled = false } },
      extra_body = { options = { num_ctx = 8192 } },
    },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

function M.provider()
  local name = M.options.provider
  local p = M.options.providers[name]
  if not p then
    error(("inkling: unknown provider %q"):format(name))
  end
  return p, name
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
