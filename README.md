# inkling.nvim

Copilot-style inline completions for Neovim (0.10+) with your choice of model:
OpenAI, Anthropic, or a local Ollama model. While you type in insert mode, a
grey "ghost" suggestion for the rest of the line or block appears at the cursor.

Defaults: OpenAI → `gpt-6-luna` (with `reasoning_effort = "none"` for about 1s latency),
Anthropic → `claude-sonnet-5-5`, Ollama → `qwen2.5-coder:7b` (FIM).

## Install (vim-plug)

```vim
Plug '~/mydev/development_environment/inkling.nvim'
" after plug#end():
lua require('inkling').setup({ provider = 'openai' })
```

API keys come from `$OPENAI_API_KEY` / `$ANTHROPIC_API_KEY` by default. Neovim
must be started with these set. You can also set `api_key` on a provider to a
string or a function, for example
`api_key = function() return vim.trim(vim.fn.system('pass show openai')) end`.

## What the model sees

Each request sends:

1. **The whole current file**, with the cursor marked. Files over 60k characters
   are cut to a window around the cursor (3/4 of it before the cursor).
2. **Project context** (up to 40k characters, rebuilt in the background on
   BufEnter / save / InsertLeave and cached, so it never slows a request down):
   - **Upstream**: project-local files the current file imports. Small files are
     sent whole; larger ones as an outline (signatures, classes, exports,
     schema fields, …) plus the full definitions of the names this file
     actually imports or calls.
   - **Peers**: files in the same directory and language, as outlines (or whole
     if small).
   - **Downstream**: files that import the current file, as snippets around
     their import lines and their uses of this file's public names (found
     with `rg`).

Imports are resolved for Python, JS/TS, Lua, Elixir, Go, Rust and C/C++.
Third-party packages are skipped. Outlines are built from per-language
declaration patterns plus indentation, so no treesitter parsers are needed.

The project context goes first in the prompt so it can be cached between
requests: Anthropic via `cache_control`, OpenAI automatically.

`:Inkling context` opens a split showing exactly what would be sent from
the cursor, with a per-file size breakdown.

## Keys (insert mode)

| key      | action                                               |
|----------|------------------------------------------------------|
| `<Tab>`  | accept the whole suggestion (otherwise a normal Tab) |
| `<M-w>`  | accept the next word                                 |
| `<M-l>`  | accept the next line                                 |
| `<C-]>`  | dismiss                                              |
| `<M-\>`  | request a suggestion now                             |

Typing characters that match the suggestion keeps it on screen and consumes
those characters, without making a new request.

## Commands

```
:Inkling status              " provider, model, key found?, last error
:Inkling toggle | enable | disable
:Inkling provider anthropic  " switch provider at runtime
:Inkling model gpt-5.4-mini  " switch model for the current provider
:Inkling context              " show the full prompt for the cursor position
:Inkling refresh              " rebuild the project context now
```

Set `vim.b.inkling_disabled = true` to turn it off for a single buffer.

## Configuration

```lua
require('inkling').setup({
  provider = 'anthropic',
  debounce_ms = 250,
  max_tokens = 256,
  context = {
    current_file_max_chars = 60000,
    project = {
      enabled = true, max_chars = 40000, small_file_chars = 3000,
      upstream = true, max_upstream = 10,
      peers = true, max_peers = 15,
      downstream = true, max_downstream = 6,
    },
  },
  disabled_filetypes = { 'help', 'gitcommit' },
  keymaps = { accept = '<Tab>', accept_word = '<M-w>', accept_line = '<M-l>', dismiss = '<C-]>', trigger = '<M-\\>' },
  providers = {
    openai    = { model = 'gpt-6-luna' },
    anthropic = { model = 'claude-sonnet-5-5' },
    -- Ollama defaults to an 8k-character window and no project context (small local context windows).
    ollama    = { model = 'qwen2.5-coder:7b', url = 'http://localhost:11434/api/generate', fim = true,
                  context = { current_file_max_chars = 8000, project = { enabled = false } } },
    -- Any OpenAI-compatible endpoint (OpenRouter, LM Studio, vLLM, ...):
    openrouter = {
      kind = 'openai',
      url = 'https://openrouter.ai/api/v1/chat/completions',
      model = 'qwen/qwen3-coder',
      api_key_env = 'OPENROUTER_API_KEY',
      extra_body = {},
    },
  },
})
```

Change the ghost text color with `:hi InklingSuggestion guifg=#665c54`.

## Tests

```
nvim --headless -u NONE -l tests/run.lua openai           # request/render/accept, real API
nvim --headless -u NONE -l tests/context.lua              # outlines + import resolution fixtures
nvim --headless -u NONE -l tests/live_context.lua openai  # latency with full project context
```
