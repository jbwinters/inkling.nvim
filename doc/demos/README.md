# README screen recordings

These GIFs are screen captures of **Neovim running inside Kitty**. The plugin's
workspace, source collection, Git comparison, Telescope pickers, chat UI, and
Mermaid renderer run normally.

[`session.lua`](session.lua) substitutes fixed diagram and question responses
for the provider. No API calls are made. The recordings demonstrate interaction,
not model quality or generation speed. Key captions appear in Neovim's statusline.
The [small Python example](project) is a recording fixture, not a production client.

| Recording | Workflow |
| --- | --- |
| [Follow focus](follow-focus.gif) | Move between functions, reuse a diagram, zoom, pan, and fit |
| [Navigate and ask](navigate-and-ask.gif) | Step out, find a component with source preview, step in with a prompt, and ask a question |
| [Branch review](branch-review.gif) | Compare a temporary local branch against its merge base; inspect Changes / Before / After |

## Re-record

Linux prerequisites:

- Python 3, Git, Neovim 0.10+, Kitty, Xvfb, ImageMagick 7 with X11 support, and gifsicle.
- Mermaid CLI (`mmdc`) on PATH or in Inkling's managed data directory, plus Chrome/Chromium.
- `gruvbox-material`, `plenary.nvim`, and `telescope.nvim` checked out beneath
  `~/.local/share/nvim/plugged`, or another directory set with `INKLING_DEMO_PLUGINS`.

Use a dedicated X11 display. Capturing your normal desktop could include
unrelated windows. The recorder creates its own temporary Git repository and
Neovim session; it does not use your normal Neovim config or call an AI provider.

```sh
# Keep this running in a separate terminal. Pick a free display number.
Xvfb :98 -screen 0 1440x900x24 -ac -nolisten tcp -noreset

# From the inkling.nvim checkout:
python3 doc/demos/record.py --display :98 --browser /path/to/chromium
```

The script starts Kitty, captures the actual X11 display as PNG frames, and uses
ImageMagick and gifsicle to encode looping GIFs at their original 1440×900 resolution.
Duplicate frames share one delay to keep file sizes small. It closes its
terminal and removes its temporary project when finished; stop Xvfb yourself.

Use `--clip follow`, `--clip investigate`, or `--clip review` to update one clip.
`--kitty`, `--magick`, `--gifsicle`, and `--output` override executable/output paths.
`--server /path/to/nvim.sock` attaches to an existing recording session started
with `session.lua` instead of creating a new one; use only a disposable session.

For an existing session, set `INKLING_DEMO_ROOT` to this checkout,
`INKLING_DEMO_PROJECT` to the fixture project, and optionally
`INKLING_DEMO_BROWSER`. The project needs a `main` baseline and a current branch
with the timeout-retry change; `record.py` creates both automatically when it
starts its own session.
