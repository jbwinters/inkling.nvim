# Inkling diagram mode

Status: focus following and conversation are implemented. Mermaid now renders
inside Neovim with mouse and keyboard pan/zoom. Component boundaries and flow
steps use separate generation schemas. Git branch review and ERDs remain
follow-on work; no GitHub or GitLab integration is required.

## Problem and outcome

When reviewing AI-generated code, Josh often asks an AI to generate diagrams and
then examines those diagrams in detail. Repeating the request, supplying context,
and moving between the diagram and code interrupts that workflow.

Inkling should provide a persistent way to read code through diagrams inside
Neovim. The primary loop is: follow code, inspect a diagram, ask about behavior,
and inspect the supporting source. Questions are part of the first release.

Success means a user can open an unfamiliar function, see its flow, investigate a
condition, and reach the code supporting the answer without composing a diagram
prompt or leaving Neovim.

## Product decisions

- Render inside Neovim. Keyboard navigation must work without a mouse.
- Start with following the user's focus. Git branch review is equally important
  to the longer-term product, but follows the browsing experience.
- Keep scope, diagram type, and source revision separate.
- Components use nested boundaries; flow shows decisions, failures, side effects,
  and exits. ERDs later show explicit entities, keys, and cardinalities.
- Chat inherits scope, diagram selection, and source revision. It can inspect
  additional project files to investigate a question.
- Questions and diagram interactions hold the scope in place. Inspecting an
  answer's source must not replace the diagram. Following resumes explicitly.
- Diagram mode works even when completion suggestions are disabled.

## First-release experience

`:Inkling view components` opens a split showing the current file and its local
dependencies as a component diagram. `:Inkling view flow` follows the enclosing
function when it can be identified, otherwise the current file. Scope detection
uses declaration/indentation heuristics and displays its exact source range.

The mode starts following source-buffer focus. A pause in another scope requests
a diagram; moving within the same unchanged scope reuses it. Generation happens
after leaving insert mode. The previous diagram remains visible while a new
one is generated. Source edits mark the displayed snapshot stale immediately.

Selecting a node or relationship permits opening its evidence, expanding it,
or asking a question. Back navigation restores prior views and their conversation.
Switching diagram type retains the conversation for the same subject. A question
opens a conversation split under the diagram. Source links are keyboard actions.
Diagram and conversation windows may be maximized using ordinary Neovim windows
or the mode's focus action.

Chat supports explanation, condition/path investigation, edge cases, and focused
diagram requests. Examples: "Can this retry forever?", "What if the request
finishes after switching buffers?", and "Show the failure paths". View changes
use a refinement command so the distinction between an answer and a new view is
explicit. Answers highlight relevant graph elements and cite source ranges.

## Evidence and revisions

Diagrams represent supplied source, not desired architecture. Each concrete
element should cite evidence. Source ranges and paths are checked against the
actual excerpts supplied to the model. This validates references, not semantic
correctness. Inferred relationships and coverage limitations remain visible.

Answers can request bounded reads or literal searches of the project. Reads stay
inside the project root, respect byte/file limits, and prefer unsaved buffers.
No shell commands supplied by the model are executed. Condition investigations
report source evidence and uncertainty; they do not claim tests were executed.

Questions and answers are attached to snapshots. Refresh starts a conversation
for the new snapshot; prior conversations remain in view history. Exact source
jumps from a stale snapshot require refresh. Late responses from cancelled,
superseded, or closed views cannot change the display.

## Rendering

The default auto renderer uses a graphical Mermaid canvas when Kitty and Mermaid
CLI are available. Components show nested responsibility boundaries with dependency
arrows; flow shows steps, decision diamonds, branches, and exits. Separate generation
schemas constrain node kinds, and flat component responses receive a correction.
The visible diagram retains its own view label while another view is generating.

`m` renders the canvas; `M` exports source. Keyboard pan uses hjkl/arrows, +/-
zooms, and 0 fits. Left mouse drag pans; the wheel zooms around the pointer.
A cached raster is transmitted once; camera moves only change terminal placement
and the visible viewport. No AI or Mermaid process runs for pan/zoom. Coordinates
are bounded to the image and terminal grid. Resize, hiding, and cleanup preserve
Neovim windows and remove only graphics owned by this workspace. Selecting evidence
remains available through /, Enter, and conversation citations.

Kitty Unicode placeholders anchor the image to Neovim text so it clips correctly
inside splits and follows terminal redraws. No image.nvim or ImageMagick dependency
is required. Native text remains available for other terminals. CLI and browser
paths are configurable. The plugin does not change terminal/tmux settings.

## Limits and lifecycle

Generation is opt-in by opening the mode. Follow requests are debounced, duplicate
snapshots are cached, and closing or hiding the workspace cancels pending work.
Provider/model overrides and request budgets are separate from completions.
Usage goes through Inkling's existing spend log. Source and conversations remain
in memory; Mermaid export opens an editable scratch buffer for an explicit save.

## Acceptance criteria

1. Components and flow can be opened entirely within Neovim.
2. Scope follows code after a pause, not every cursor movement or keystroke.
3. Pinning, asking, expanding, or opening evidence prevents unwanted following.
4. A selected node/edge opens its validated source range.
5. Questions use actual source and may gather bounded additional evidence.
6. Answers highlight relevant nodes/edges and expose source references.
7. Stale source is visible; stale callbacks and unsafe source paths are rejected.
8. History, refresh, and closing do not lose editor source buffers or leave jobs.
9. Both views export valid, escaped Mermaid generated from their graph data.
10. Mouse and keyboard can pan, zoom, and fit the rendered diagram without AI requests.
11. Components have nested boundaries; flow has distinct steps/decisions and execution arrows.
12. Existing completion and next-edit tests continue to pass.

## Follow-on releases

- ERDs from explicit schemas and ORM declarations; unknown cardinality stays
  unknown. Sequence and state views can follow demonstrated need.
- Git branch review: select a baseline and branch, state whether the baseline is
  the merge base or tip, include surrounding unchanged behavior, retain removed
  paths, and compare before/after. Treat working-tree edits separately.
- Pin questions or conditions to a scope and explicitly recheck them; optional
  automatic rechecks after this workflow is proven useful.
- Persistent bookmarks and conversations, improved semantic layout stability,
  and larger-project context discovery.

## Validation

Use deterministic headless tests for focus, evidence, rendering, source changes,
conversation reads, cancellation, history, and lifecycle. Test the actual UI in
tmux pane `fm:5.1`, preserving its contents. Live provider validation is distinct
from deterministic tests, and image rendering depends on installed prerequisites.

Recorded validation (2026-10-19):

- 163 checks passed across context, edits, streaming, next-edit, diagram workspace,
  provider/accounting, image lifecycle, and camera/protocol suites.
- Neovim help tags generated successfully.
- With permission to use the configured OpenAI provider, fm:5.1 exercised live
  flow and nested component generation, questions with additional evidence reads,
  exact citation navigation, Mermaid export, and focus following into another file.
- Live testing exposed misleading flow exits and flat component output. Prompts
  now clarify focus and execution paths; components require a group boundary.
  Separate schemas constrain component and flow node kinds. References validate
  source ranges, not meaning; diagrams still require review.
- Live Mermaid images rendered through the managed CLI installation and system
  Chrome. Keyboard zoom/pan/fit and Neovim mouse wheel/drag events changed the
  camera while retaining the same uploaded image.
- Tests cover pointer-centered zoom, bounds, resize, fit, coordinate limits,
  clipped placeholders, chunked transfer, targeted cleanup, late callbacks,
  keeping camera position after answer highlights, and separating render/export.
- Chat opens at the beginning of a new answer, preserves reading position, and
  retains its height around export. Component scope covers the file; flow uses
  the function at the source cursor. Prior diagrams retain their view label
  while a different view is loading.
- Testing enabled tmux allow-passthrough for window fm:5 and mouse routing for
  session fm. No tmux configuration file was changed. Mermaid CLI is installed
  under ~/.local/share/nvim/inkling/mermaid for regular Neovim sessions.
- Desktop screenshot capture was unavailable; user visual confirmation was
  requested separately from the verified input/renderer state.

Follow-up validation (2026-10-19):

- User confirmed the actual image appeared after resending it to Kitty.
- Cache the PNG and resend it on focus/resize, tmux visibility changes, and m.
  This restores terminal image loss without regenerating the diagram or moving
  the camera. Stop the visibility watcher and release cached pixels on close.
- Increase default raster scale from 2 to 4 for sharper zoomed labels; expose
  view.mermaid.scale and retain pixel/file size limits.
- Live fm:5.1 now holds a 3136x1124 PNG. Deleting only its terminal image,
  then exercising FocusGained and m, restored the same image ID twice with zero
  Mermaid re-renders and no change to the camera.

- Fixed a terminal-output race: asynchronous image chunks could be split around
  Neovim TUI updates, leaving the loading label on screen after rendering ended.
  Use the TUI output queue where available; on older Neovim, reopen the terminal
  with a separate blocking descriptor and finish each bounded graphics packet.
- Live tracing reproduced the broken packet and stale loading label, with the
  actual Mermaid render finishing in 0.92 seconds. The corrected transport sent
  178 complete packets with no malformed payloads, and the visible status cleared.

Workspace UX refinement (2026-10-19):

- Keep the code, diagram, and conversation in normal panes. Use temporary
  Telescope pickers for finding elements and actions, with vim.ui.select as the
  dependency-free fallback. Keep the user's theme and global mappings.
- Replace the dense shortcut header with the current view, source scope,
  follow/pin state, zoom, and four entry points: / find, a ask, v view, ? actions.
- Element search previews checked source snapshots before committing to a jump.
  Enter selects; Ctrl-O opens evidence in the existing code pane; Ctrl-A asks
  about that element. Enter on an unselected diagram starts source selection.
- View selection explains responsibilities/dependencies versus execution paths.
  The action palette exposes shortcuts, descriptions, and coverage/uncertainty.
- Compose multiline questions and refinements in a small split. Ctrl-S sends;
  Enter adds a line; Esc then q saves the draft and closes it. Open conversation
  space when a question is sent, and keep code visible throughout.
- Protect picker callbacks from replacing selections in a newer diagram. Save
  and close drafts when the displayed view changes. Preview historical evidence
  without silently substituting edited source.
- Validation: exercised fuzzy search, source preview/jump, action and view menus,
  Escape cancellation, and multiline draft restoration in fm:5.1 with the user's
  normal gruvbox-material configuration. Reused its real cached diagram for UI
  checks without new model calls. Real Telescope integration checks cover wide
  and narrow layouts (155x75, 80x35, 60x24); deterministic workspace tests cover
  draft submission, stale callbacks, and the fallback without Telescope.
