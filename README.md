# inkling.nvim

**AI code completion for Neovim, like GitHub Copilot, with your choice of model:
Claude (Anthropic), OpenAI, or a local LLM through Ollama.**

As you type, inkling shows an inline suggestion (grey "ghost text") for the rest
of the line or block. Press Tab to accept it. It also predicts your next edit:
rename a variable, and it offers to update the next place that uses it.

## Features

- **Inline completions** (ghost text) that stream in as the model writes, for the
  current line or a whole block
- **Bring your own model**: Claude Sonnet, OpenAI GPT, any OpenAI-compatible API
  (OpenRouter, LM Studio, vLLM), or a local model with Ollama
- **Project-aware context**: the whole current file, the files it imports, files
  next to it, files that use it, your recent edits, and your project's
  `AGENTS.md` / `CLAUDE.md` / `.cursorrules`
- **Next edit prediction**: after a change, jump to the related edit with Tab and
  apply it with Tab again
- **Spend and acceptance tracking**: cost per day and per model, and how many
  suggestions you actually used
- **Diagram workspace**: component and flow diagrams that follow your focus in
  Neovim, with questions, source evidence, and Mermaid export
- **Small interface**: one key to accept, one command (`:Inkling`), no
  subscription; you pay your provider per token

## Requirements

- Neovim 0.10 or later
- `curl`
- an API key for Anthropic or OpenAI, or a running [Ollama](https://ollama.com) server
- optional: [`rg`](https://github.com/BurntSushi/ripgrep) (ripgrep), used to find
  files that use the current file

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ 'jbwinters/inkling.nvim', config = function() require('inkling').setup() end }
```

With [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'jbwinters/inkling.nvim'
" after plug#end():
lua require('inkling').setup()
```

From a local checkout, use its path instead, e.g. `Plug '~/src/inkling.nvim'`.

Full documentation is also available in Neovim with `:help inkling`.

### API keys

inkling reads `$ANTHROPIC_API_KEY` and `$OPENAI_API_KEY`, so start Neovim with
them set. If the key for the active provider is missing, inkling warns you at
startup.

To keep keys out of your environment, give a provider an `api_key` string or
function instead:

```lua
providers = {
  openai = { api_key = function() return vim.trim(vim.fn.system('pass show openai')) end },
}
```

## Usage

Start typing in insert mode. Suggestions appear after a short pause.

| Insert-mode key | Action |
|---|---|
| `Tab` | accept the suggestion (a normal Tab when there is none) |
| `Alt-w` | accept the next word |
| `Alt-l` | accept the next line |
| `Ctrl-]` | dismiss |
| `Alt-\` | ask for a suggestion now |

- **Streaming**: the first line appears as soon as the model starts writing. You
  can type over it or accept part of it while the rest arrives.
- **Typing through**: typing characters that match the suggestion keeps it on
  screen without a new request.
- **Completion menu**: suggestions hide while Vim's completion menu is open, so
  Tab works the menu.

### Next edit prediction

After you change something (leave insert mode, or make a normal-mode edit such
as `cw`, `dd` or `:s`), inkling asks the model whether that change implies
another one in the same file: the next use of a renamed variable, a call site of
a changed signature, or a sibling branch that should match. If it does, the
lines are highlighted and the replacement is shown below them.

| Normal-mode key | Action |
|---|---|
| `Tab` | jump to the predicted edit; press again to apply it |
| `Esc` | dismiss |

These keys are mapped only while a prediction is showing, so Tab keeps its
usual meaning otherwise. Applying a prediction is a single undo step and often
leads to the next one (for example, the next call site).

Each prediction is one request with your recent edits and the current file
(about $0.005 with Sonnet, far less with luna). Turn it off with
`next_edit = false`.

### Commands

| Command | Action |
|---|---|
| `:Inkling` | status: on/off, provider, model, recent response times, today's spend and acceptance |
| `:Inkling on` / `off` / `toggle` | turn suggestions on or off |
| `:Inkling use anthropic` | switch provider |
| `:Inkling use gpt-5.4-mini` | switch model for the current provider |
| `:Inkling use openai/gpt-5.4-mini` | switch both |
| `:Inkling use default` | forget your choice and go back to your config (or automatic) |
| `:Inkling context` | show exactly what the model would see at the cursor |
| `:Inkling spend` | spend and acceptance: today, last 7 days (by day), this month (by model and language), all time |

To turn inkling off for one buffer, set `vim.b.inkling_disabled = true`.

## Read code through diagrams

Start with this loop:

1. Put your cursor inside a function and run `:Inkling view flow`. Code stays on
   the left; its diagram opens on the right. Allow time for the model to respond.
2. Keep browsing code. After you pause in another function, the diagram follows.
3. Press `Ctrl-w l` to enter the diagram. This **pins** its subject. Move with
   `hjkl` or arrow keys to pan; `+` / `-` to zoom; `0` fits the diagram.
   Use `/` to find an element and preview its evidence; `Enter` selects it.
   Press `?` whenever you want to search the available actions.
4. Ask from any window with `:Inkling ask What happens if this request fails?`,
   or press `a` in the diagram, write a question, and send with `Ctrl-S`.
   The answer appears below it. Press `Enter` on an
   answer's source citation to inspect the evidence.
5. Run `:Inkling view follow` to resume browsing, or `:Inkling view close` to
   close the workspace.

Use `:Inkling view components` for nested boxes covering the file and its local
dependencies. Flow view follows the enclosing function when it can identify one.
The scope and whether it is following or pinned appear at the top of the diagram.
Press `v` to choose a view with a description of what each one shows.

Press **`u` to step out** to a wider perspective: enclosing class when recognized,
then file, containing folders, and project. Each step opens a component overview
and stays pinned. **`b` returns** to the previous diagram and conversation; it
also cancels a wider view still generating. `e` expands a selected element.
Refresh and view changes preserve the wider boundary; `p` resumes following code.

Folder/project perspectives need `rg` and sample source within the existing
budget. The header names the scope and shows **partial evidence**; `?` exposes
coverage details. These boundaries come from code containment. Recursive detail
presets are planned; `+` / `-` still only change the image's magnification.

If [Telescope](https://github.com/nvim-telescope/telescope.nvim) is installed,
Inkling uses it for fuzzy element search, source previews, and the action menu.
Type to filter, use `Ctrl-n` / `Ctrl-p` to move, and `Esc` to cancel. In the element
picker, `Ctrl-O` opens evidence in your code pane and `Ctrl-A` asks about that
element. Previews show the source snapshot used to generate the diagram.
Without Telescope, selection uses Neovim's `vim.ui.select`.

With Mermaid CLI and Kitty configured, diagrams render as a graphical canvas in
Neovim. **Components** use nested responsibility boundaries and dependency arrows;
**flow** uses execution steps, decision diamonds, branches, and exits. Changing
views generates a new diagram; the old one remains labeled correctly while it loads.

Drag with the left mouse button to pan, and use the wheel to zoom at the pointer.
Keyboard controls are `hjkl` or arrows to pan, `+` / `-` to zoom, and `0` to fit.
Zoom is relative to fit; its upper limit depends on the terminal grid size. Pan and
zoom reuse the rendered image and make no AI requests.

The native text view remains available with `i`, and is the fallback for terminals
without graphics support. In that view, `j` / `k` navigate boxes and source evidence.

| Diagram key | Action |
|---|---|
| `?` | search actions and inspect diagram coverage |
| `Enter` | open selected source evidence, or find an element first |
| `/` | find nodes or relationships with source previews |
| `Esc` | clear the selected element |
| `a` | ask about the diagram or selected element |
| `e` | expand the selected element's implementation |
| `u` | step out to the enclosing class, file, folder, or project |
| `v` | choose components or flow with descriptions |
| `g` | refine the view, e.g. “show only failure paths” |
| `p` | pin / resume following source focus |
| `r` / `b` | refresh / return to the previous view |
| `m` | render Mermaid in the diagram canvas |
| `M` | export Mermaid source to an editable scratch buffer |
| `i` | switch between native text and Mermaid canvas |
| `hjkl` / arrows | pan the canvas |
| `+` / `-` / `0` | zoom in / out / fit |
| mouse drag / wheel | pan / zoom at the pointer |
| `z` / `q` | maximize or restore the diagram / close the workspace |

Ask with `a` or `:Inkling ask Can a cancelled request still update this buffer?`.
The question editor is a small split: `Enter` adds a line, `Ctrl-S` sends, and
`Esc` then `q` closes it while keeping the draft for that view. The action menu
also offers “Ask about whole diagram” when an element is selected.
The conversation opens below the diagram. Answers can highlight relevant paths
and cite source lines; press Enter on a citation to inspect it. Questions can
read or search additional project files within configured limits. No source code
is edited and no tests are run by the conversation.

Questions and source navigation pin the scope. `:Inkling view follow` resumes
browsing. Source edits mark the current view stale; refresh before investigating
the new revision. Previous views and conversations remain available with `b`.
References are checked against supplied source ranges; semantic correctness still
needs review. Missing evidence and coverage limitations appear below the diagram.

For rendered Mermaid, use **Kitty 0.28+**, `:set termguicolors`, and the
[Mermaid CLI](https://github.com/mermaid-js/mermaid-cli). Inkling sends images to
Kitty directly; image.nvim and ImageMagick are not required. Install the CLI on
PATH, or into Inkling's data directory (find it with `:echo stdpath('data')`):

```sh
npm install --prefix ~/.local/share/nvim/inkling/mermaid @mermaid-js/mermaid-cli
```

Mermaid needs a Chromium browser. Inkling uses `view.mermaid.browser` when set,
otherwise a detected Chrome/Chromium executable, otherwise Puppeteer's default.
In tmux, enable `allow-passthrough` for the window or pane. Enable Neovim mouse
input with `:set mouse=a`; tmux mouse routing helps when using multiple panes:

```tmux
set -g allow-passthrough on
set -g mouse on
```

The plugin does not change your tmux or terminal settings. `:Inkling view mermaid`
(or `m`) opens the canvas; `:Inkling view export` (or `M`) opens Mermaid source.
`:Inkling view fit`, `zoom-in`, and `zoom-out` also control the camera.
Images render at 4× resolution by default (`view.mermaid.scale`, from 1 to 6).
Inkling restores cached pixels after terminal focus, resize, and tmux visibility
changes. Press `m` to resend the image manually without another AI request.

Diagram mode is opt-in and works with `enabled = false` (completions off). It
uses the active provider and logs requests through the existing spend tracker.
The provider must support structured JSON output. Diagram and question costs are
included in spend totals and excluded from cost per accepted suggestion.
Optional settings:

```lua
view = {
  provider = nil, model = nil, -- inherit, or choose independently of completions
  debounce_ms = 700,
  max_tokens = 5000, timeout = 60,
  max_chars = 60000, max_files = 8,
  max_nodes = 24, max_edges = 48,
  max_reads = 2,               -- extra evidence rounds per question
  renderer = 'auto',          -- prefer Mermaid; or 'native' / 'mermaid'
  mermaid = { command = 'mmdc', browser = nil, scale = 4 },
},
```

Component and flow views are available now. ERDs and local Git branch comparison
are planned in the [product requirements](doc/diagram-mode-prd.md).

## Choosing a model

inkling uses the first of these that applies:

1. your last `:Inkling use …` choice, which is remembered across sessions
2. `provider` in `setup()`
3. automatic: **gpt-6-luna** if `$OPENAI_API_KEY` is set (cheapest), otherwise
   **claude-sonnet-5-5** if `$ANTHROPIC_API_KEY` is set (most accurate)

| Provider | Default model | Accuracy\* | Speed | Cost per suggestion |
|---|---|---|---|---|
| `anthropic` | `claude-sonnet-5-5` | 35/40 exact | ~1.5s | ~$0.01–0.02 (less when cached) |
| `openai` | `gpt-6-luna` | 23/40 exact | ~1.3–1.8s | ~$0.001 |
| `ollama` | `qwen2.5-coder:7b` | not measured | local | free |

\* Lines restored exactly on a benchmark of real code (`tests/eval.lua`).

- **Ollama** uses the model's native fill-in-the-middle mode with a small prompt
  (8k characters, no project context) to suit local context windows. It hasn't
  been tested against a live Ollama server yet.
- **Other OpenAI-compatible APIs** (OpenRouter, LM Studio, vLLM, ...) work as an
  extra provider with `kind = 'openai'`; see [Configuration](#configuration).

## Spend and acceptance tracking

inkling prices every request from the token usage the provider reports and
appends it to `~/.local/share/nvim/inkling/usage.jsonl`. `:Inkling` shows
today's total; `:Inkling spend` shows the breakdown.

- **Prices** for the default models are built in. Add others with `prices`
  (USD per 1M tokens):
  `prices = { ['model'] = { input = …, output = …, cache_read = …, cache_write = … } }`
- **Cancelled requests** (you kept typing before the reply finished) are listed
  separately as an upper bound, because providers may or may not bill input they
  had already read.
- **Acceptance**: a suggestion counts as accepted when you take it with Tab /
  Alt-w / Alt-l or type it out exactly. `:Inkling spend` shows the acceptance
  rate and the **cost per accepted suggestion** for each model (the best number
  for comparing models), acceptance by language, and how many next-edit
  predictions you applied.

With full project context (about 10k input tokens), a suggestion costs roughly
$0.01–0.02 with Sonnet 5.5 (less when cached) and about $0.001 with luna.

## What the model sees

Each completion request includes:

1. **The whole current file**, with the cursor marked. Files over 60k characters
   are cut to a window around the cursor.
2. **Project context** (up to 40k characters):
   - **Upstream**: project files the current file imports. Small files are sent
     whole; larger ones as an outline plus the full definitions of the names
     the current file uses.
   - **Peers**: same-directory files in the same language, as outlines. They're
     ranked by whether the current file uses names they define, by name
     similarity, and by recent edits; other files' tests come last.
   - **Downstream**: files that import the current file, as snippets around
     their uses of it (found with `rg`).
3. **Project instructions**: `.inkling.md`, `AGENTS.md`, `CLAUDE.md`,
   `.cursorrules` or `.github/copilot-instructions.md`, from the file's directory
   up to the repository root, nearest first (up to 6k characters). Put
   conventions there, e.g. "use pytest fixtures, never unittest".
4. **Your recent edits**: diffs of what you changed in the last few minutes, in
   any file (up to 5 files and 4k characters). If you just renamed a method in
   one file, completions in another file use the new name.

How it's built:

- **Language support**: imports are resolved for Python, JavaScript/TypeScript,
  Lua, Elixir, Go, Rust and C/C++; outside packages are skipped. Other languages
  get context from referenced file paths, same-extension files, and files that
  mention them. Outlines come from per-language declaration patterns plus
  indentation, so treesitter parsers aren't needed.
- **No waiting**: project context is rebuilt in the background when you switch
  buffers, save, or leave insert mode, so it never delays a suggestion. Recent
  edits update when you leave insert mode or change text in normal mode.
- **Caching**: the parts of the prompt that don't change (project context, and
  the file above the cursor line) are cached by the provider between requests,
  which makes repeat requests faster and cheaper.

To see the exact prompt for the cursor position, run `:Inkling context`.

## Configuration

Everything is optional. These are the defaults, plus an example extra provider:

```lua
require('inkling').setup({
  provider = nil,  -- automatic (see "Choosing a model")
  debounce_ms = 250,
  next_edit = true, next_edit_delay_ms = 500,
  max_tokens = 256,
  prices = {},     -- extra/override prices, USD per 1M tokens
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
    -- example: an extra OpenAI-compatible provider
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

### Colours

Change the suggestion colour with `:hi InklingSuggestion guifg=#665c54`. The
next-edit highlight groups are `InklingEditOld`, `InklingEditNew` and
`InklingEditHint`.

## Development

```
nvim --headless -u NONE -l tests/run.lua anthropic        # request, display, accept (real API)
nvim --headless -u NONE -l tests/context.lua              # outlines + import resolution fixtures
nvim --headless -u NONE -l tests/edits.lua                # recent-edit tracking
nvim --headless -u NONE -l tests/stream.lua               # streaming display (fake provider)
nvim --headless -u NONE -l tests/nextedit.lua             # next-edit prediction (fake provider)
nvim --headless -u NONE -l tests/view.lua                 # diagrams, focus, evidence, conversation (fake provider)
nvim --headless -u NONE -l tests/view_scope.lua           # enclosing scopes, wider evidence, ignore rules and budgets
nvim --headless -u NONE -l tests/view_provider.lua        # diagram provider overrides (fake HTTP)
nvim --headless -u NONE -l tests/view_render.lua          # image lifecycle (fake terminal)
nvim --headless -u NONE -l tests/view_canvas.lua          # camera geometry and graphics protocol
nvim --headless -u NONE -l tests/live_context.lua openai  # latency with full project context
INKLING_EVAL_DIR=~/code nvim --headless -u NONE -l tests/eval.lua anthropic 40   # accuracy benchmark
```

`tests/eval.lua` is the accuracy benchmark. It cuts real lines from the code
under `INKLING_EVAL_DIR` (at the start, mid-line, or with a gap in the middle),
asks for completions with full project context, and scores the first suggested
line against the original.

## License

MIT. See [LICENSE](LICENSE).
