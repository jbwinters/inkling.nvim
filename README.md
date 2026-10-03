# inkling.nvim

Copilot-style inline completions for Neovim (0.10+) with your choice of model:
Anthropic, OpenAI, or a local Ollama model. While you type in insert mode, a
grey suggestion for the rest of the line or block appears at the cursor.

The model sees the whole current file plus the relevant parts of your project:
files it imports, files next to it, and files that use it.

## Install (vim-plug)

```vim
Plug '~/mydev/development_environment/inkling.nvim'
" after plug#end():
lua require('inkling').setup()
```

API keys come from `$ANTHROPIC_API_KEY` / `$OPENAI_API_KEY`, so start Neovim
with them set. You can also give a provider an `api_key` string or function,
e.g. `api_key = function() return vim.trim(vim.fn.system('pass show openai')) end`.

## Using it

| Insert-mode key | Does |
|---|---|
| `Tab` | accept the suggestion (a normal Tab when there is none) |
| `Alt-w` | accept the next word |
| `Alt-l` | accept the next line |
| `Ctrl-]` | dismiss |
| `Alt-\` | ask for a suggestion now |

Typing characters that match the suggestion keeps it on screen without a new
request. Suggestions hide while Vim's completion menu is open.

| Command | Does |
|---|---|
| `:Inkling` | status: on/off, provider, model, recent response times |
| `:Inkling on` / `off` / `toggle` | turn suggestions on or off |
| `:Inkling use anthropic` | switch provider |
| `:Inkling use gpt-5.4-mini` | switch model for the current provider |
| `:Inkling use openai/gpt-5.4-mini` | both |
| `:Inkling use default` | forget the choice, back to your config / automatic |
| `:Inkling context` | show exactly what the model would see at the cursor |
| `:Inkling spend` | spend today, last 7 days (by day), this month (by model), all time |

Set `vim.b.inkling_disabled = true` to turn it off for one buffer.

## Models

Which model is used, first match wins:

1. your last `:Inkling use …` choice (remembered across sessions)
2. `provider` in `setup()`
3. automatic: **gpt-6-luna** if `$OPENAI_API_KEY` is set (cheapest), otherwise
   **claude-sonnet-5-5** if `$ANTHROPIC_API_KEY` is set (most accurate)

| Provider | Default model | Notes |
|---|---|---|
| `openai` | `gpt-6-luna` | Cheapest (~$0.001/suggestion); 23/40 exact on a real-code benchmark, ~1.3–1.8s |
| `anthropic` | `claude-sonnet-5-5` | Most accurate (35/40 exact), ~1.5s, ~$0.01–0.02/suggestion |
| `ollama` | `qwen2.5-coder:7b` | Local fill-in-the-middle; small prompt, no project context |

Any OpenAI-compatible endpoint (OpenRouter, LM Studio, vLLM, ...) works as an
extra provider with `kind = 'openai'` (see Configuration).

## Spend

Every request's token usage (as reported by the provider) is priced and
appended to `~/.local/share/nvim/inkling/usage.jsonl`. `:Inkling` shows today's
total; `:Inkling spend` shows the breakdown. Prices for the default models are
built in; add others with `prices = { ['model'] = { input = …, output = …,
cache_read = …, cache_write = … } }` (USD per 1M tokens).

Requests cancelled because you kept typing are listed separately as an upper
bound: providers may or may not bill input they had already read.

Rough cost per suggestion with full project context (~10k input tokens):
Sonnet 5.5 about $0.01–0.02 (less when cached), luna about $0.001.

## What the model sees

1. **The whole current file**, with the cursor marked. Files over 60k characters
   are cut to a window around the cursor.
2. **Project context** (up to 40k characters), rebuilt in the background when you
   switch buffers, save, or leave insert mode, so it never delays a suggestion:
   - **Upstream**: project files this file imports. Small ones whole; larger ones
     as an outline plus the full definitions of the names this file uses.
   - **Peers**: same-directory files of the same language, as outlines, ranked by
     whether this file uses names they define, name similarity, and recent edits.
     Other files' tests are ranked last.
   - **Downstream**: files that import this one, as snippets around their uses of
     it (found with `rg`).

3. **Project instructions**: `.inkling.md`, `AGENTS.md`, `CLAUDE.md`, `.cursorrules`
   or `.github/copilot-instructions.md` from the file's directory up to the
   repository root, nearest first (up to 6k characters). Put conventions there,
   e.g. "use pytest fixtures, never unittest".
4. **Your recent edits**: diffs of what you changed in the last few minutes, in
   any file (up to 5 files, 4k characters). If you just renamed a method in one
   file, completions in another file use the new name. Updated when you leave
   insert mode or change text in normal mode.

Imports are resolved for Python, JS/TS, Lua, Elixir, Go, Rust and C/C++; outside
packages are skipped. Outlines come from per-language declaration patterns plus
indentation, so treesitter parsers aren't needed.

Unchanging parts of the prompt (project context, and the file above the cursor
line) are cached by the provider between requests, which makes repeat requests
faster and cheaper.

## Configuration

Everything is optional; these are the defaults.

```lua
require('inkling').setup({
  provider = nil,  -- automatic (see Models)
  debounce_ms = 250,
  max_tokens = 256,
  context = {
    current_file_max_chars = 60000,
    recent_edits = { enabled = true, max_chars = 4000 },
    project = {
      enabled = true, max_chars = 40000, small_file_chars = 3000,
      instructions = true, max_instructions_chars = 6000,
      upstream = true, max_upstream = 10,
      peers = true, max_peers = 15,
      downstream = true, max_downstream = 6,
    },
  },
  disabled_filetypes = { 'help', 'gitcommit', 'gitrebase', 'TelescopePrompt', 'NvimTree', 'nerdtree', 'qf', 'netrw' },
  keymaps = { accept = '<Tab>', accept_word = '<M-w>', accept_line = '<M-l>', dismiss = '<C-]>', trigger = '<M-\\>' },
  providers = {
    anthropic = { model = 'claude-sonnet-5-5' },
    openai    = { model = 'gpt-6-luna' },
    ollama    = { model = 'qwen2.5-coder:7b', url = 'http://localhost:11434/api/generate' },
    -- extra OpenAI-compatible provider:
    openrouter = {
      kind = 'openai',
      url = 'https://openrouter.ai/api/v1/chat/completions',
      model = 'qwen/qwen3-coder',
      api_key_env = 'OPENROUTER_API_KEY',
      output = 'json',   -- 'json' (structured output) or 'tags' if the endpoint lacks JSON schema support
      extra_body = {},
    },
  },
})
```

Change the suggestion colour with `:hi InklingSuggestion guifg=#665c54`.

## Tests

```
nvim --headless -u NONE -l tests/run.lua anthropic        # request, display, accept (real API)
nvim --headless -u NONE -l tests/context.lua              # outlines + import resolution fixtures
nvim --headless -u NONE -l tests/edits.lua                # recent-edit tracking
nvim --headless -u NONE -l tests/live_context.lua openai  # latency with full project context
INKLING_EVAL_DIR=~/code nvim --headless -u NONE -l tests/eval.lua anthropic 40   # accuracy benchmark
```

`tests/eval.lua` cuts real lines from the code under `INKLING_EVAL_DIR` (at the
start, mid-line, or with a gap in the middle), asks for completions with full
project context, and scores the first suggested line against the original.
