# Inkling diagram mode

Status: focus following and conversation are implemented. Mermaid now renders
inside Neovim with mouse and keyboard pan/zoom. Component boundaries and flow
steps use separate generation schemas. Step out widens the perspective through
recognized classes, files, containing folders, and the project boundary.
Prompted step-in and local Git branch review are implemented. ERDs and
diagram-detail presets remain follow-on work. No GitHub or GitLab integration
is required.

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
- Separate perspective (what surrounds this code) from detail (how much of the
  inside to show). Widening the subject is the next implemented navigation step;
  recursive investigation and detail presets are subsequent work.
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

## Perspective navigation

`u` / `:Inkling view out` steps out from the displayed subject. For a method,
prefer a recognized enclosing class, then the whole file. Standalone functions
step directly to their file. Files widen to their containing folder, then parent
folders until the existing project boundary. Class detection uses declaration and
indentation heuristics; unsupported structures skip to the file. Folder names
are source boundaries, not proof of a domain component or subsystem.

Each outward step opens a component overview and pins it. The header names the
actual boundary; the action menu previews the next boundary. The previous diagram
stays visible until the new one is ready. `b` restores it with its conversation,
or cancels an outward step still generating. `e` steps into a selected element:
choose an element if necessary, then describe what to inspect in an editable
prompt. Examples: "Trace retries into the provider" or "Show validation and failure
paths." Ctrl-S sends; cancellation retains the draft without generating. The
diagram can request bounded source reads or literal searches before drawing.
All selected evidence participates, rather than silently using only its first
reference. A new subject starts its own conversation; `b` restores the old one.
Refresh, refinement, and changing diagram
type preserve an explicitly widened scope; following code resumes cursor scope.

Folder/project views use bounded, ignore-aware file discovery with ripgrep.
Sample the anchor and sibling areas, preferring entry points, within existing
file/character budgets. Large files contribute numbered imports and declaration
excerpts. Source citations must still refer to inspected ranges. Display partial
coverage in the canvas and include it in omissions independently of the model.
Do not present a sampled project view as an exhaustive system model.

Wider subjects start their own conversations. Reject stepping out of a stale
snapshot until refreshed, stop at the project boundary, and keep scope metadata
in cache decisions so switching perspectives cannot silently change navigation.

The next detail-control iteration should keep the chosen perspective fixed:

- **Overview**: major responsibilities and interactions, little internal detail.
- **Structure**: nested subcomponents and the relationships between them.
- **Trace deeper**: investigate calls/dependencies across further implementation
  boundaries, showing what was inspected and where the evidence budget stopped.

These are planned product concepts, not controls shipped by this change. Pixel
zoom continues to change only canvas magnification; it never requests more code.

## Local branch review

`:Inkling review <base> [head]` reviews committed changes from the merge base of
base/head to head (HEAD by default). With no arguments, choose a baseline from
local and locally available remote branches. No fetch, checkout, hosting API,
comment publication, or working-tree mutation is performed.

Resolve and pin exact commits when the session starts. Display short commit IDs
and the named comparison. The initial component diagram describes changed
responsibilities, relationships, and surrounding behavior. `f` lists all changed
files, including files omitted from the sampled overview; choosing one narrows
the review. `u` widens through file/folder/project boundaries. `e`, `a`, `v`, `g`,
and `b` reuse the browsing workspace's step-in, chat, lens, refinement, and history.

`c` chooses Changes / Before / After without changing the review's commits or
scope. Changes uses labels and color to distinguish added, removed, modified,
unchanged-context, and unknown elements. These are model interpretations, not a
semantic proof. Modified/unchanged classifications require references from both
revisions or are downgraded to unknown. Before and After show only their own
revision's behavior; chat can still use both. Changing comparison retains the
conversation and caches each view. Stable descriptive IDs are requested, but
identical layouts across separately generated diagrams are not guaranteed.

Read source directly from Git objects. Every citation includes before/after,
path, and line range. Source jumps open read-only snapshot buffers, including
deleted files and pre-rename paths. Follow-up reads/searches inspect the pinned
commits only. Unsaved buffers, disk edits, and later branch movement cannot
change an existing review. `r` regenerates the same commits; start another
`:Inkling review` to capture new commits. Working-tree review is a future,
explicit mode.

Use bounded changed-line windows plus surrounding source; reserve evidence
capacity for dependency investigations. Budgets count each revision excerpt
separately. Always disclose partial coverage. Large/binary files may be omitted;
empty comparisons, invalid refs, absent/multiple merge bases, oversized change
lists, and scopes without readable text return an explanation. The file picker
still exposes omitted files; it does not imply they were reviewed.

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

The default auto renderer uses a graphical Mermaid canvas when an image backend
and Mermaid CLI are available. Components show nested responsibility boundaries with dependency
arrows; flow shows steps, decision diamonds, branches, and exits. Separate generation
schemas constrain node kinds, and flat component responses receive a correction.
The visible diagram retains its own view label while another view is generating.

`m` renders the canvas; `M` exports source. Keyboard pan uses hjkl/arrows, +/-
zooms, and 0 fits. Left mouse drag pans; the wheel zooms around the pointer.
A cached raster supplies camera moves: the direct backend changes terminal
placement; the optional image.nvim adapter crops the viewport with ImageMagick.
No AI or Mermaid process runs for pan/zoom. Coordinates
are bounded to the image and terminal grid. Resize, hiding, and cleanup preserve
Neovim windows and remove only graphics owned by this workspace. Selecting evidence
remains available through /, Enter, and conversation citations.

Kitty and Ghostty use Unicode placeholders to anchor the image to Neovim text
and clip it inside splits without an image plugin or ImageMagick. Other terminals
can use a configured image.nvim backend (Sixel, Überzug++, or Kitty), with
ImageMagick for viewport transforms. The adapter hides graphics under overlapping
pickers and in hidden tmux panes, cancels superseded transforms, and retains only
the current viewport. Missing prerequisites and rendering errors fall back to
native text while retaining source navigation and chat. Backend selection,
CLI, and browser paths are configurable. The plugin does not change terminal,
tmux, or image.nvim settings.

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
13. Step out follows real enclosing boundaries, remains pinned, and stops at the project.
14. Back cancels pending widening or restores the previous scope and conversation.
15. Wider views preserve their scope across refresh/view changes and disclose partial evidence.

## Follow-on releases

- ERDs from explicit schemas and ORM declarations; unknown cardinality stays
  unknown. Sequence and state views can follow demonstrated need.
- Explicit working-tree review, branch-tip comparisons, and hosted MR/PR context
  can build on the pinned local comparison.
- Pin questions or conditions to a scope and explicitly recheck them; optional
  automatic rechecks after this workflow is proven useful.
- Persistent bookmarks and conversations, improved semantic layout stability,
  and larger-project context discovery.

## Validation

Use deterministic headless tests for focus, evidence, rendering, source changes,
conversation reads, cancellation, history, and lifecycle. Test the actual UI in
tmux pane `fm:5.1`, preserving its contents. Live provider validation is distinct
from deterministic tests, and image rendering depends on installed prerequisites.

Prompted step-in and branch-review validation:

- 272 checks passed across ten headless suites, including real temporary Git
  histories, renamed/deleted files, merge-base selection, local-edit isolation,
  revision citations/search, schema requirements, cache reuse, and cancellation.
- Eleven live UI checks passed in `fm:5.1` with fixture provider responses:
  Telescope file/comparison selection, prompt drafts/submission, read-only
  revision navigation, conversation citations, actions, and theme preservation.
- Actual Mermaid rasterization succeeded and its output was visually inspected.
  The original diagram, source buffer, and history were restored.
- Help tags generated and whitespace checks passed. New review/step-in model
  quality has not been validated against a live external provider in this pass.

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

Perspective-navigation validation (2026-10-19):

- 148 checks pass across workspace, scope/evidence, rendering, and canvas suites.
  Coverage includes Python/TypeScript class boundaries, nested classes, folder
  ancestry, project limits, ignore rules, source budgets, historical conversations,
  pending-step cancellation, stale snapshots, and keeping widened scopes on refresh.
- Loaded controls and verified the action preview and bounded source collection
  in fm:5.1 against the existing providers-module diagram. Live generation of the
  wider view is awaiting explicit authorization for the configured provider.
