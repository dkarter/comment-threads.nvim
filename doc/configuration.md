# Configuring comment-threads.nvim

Local, threaded comments on Markdown, code, or other text files. The comments
live outside the files being reviewed. You write in Neovim; an agent can read
and reply from a neighboring terminal pane. Comments are stored locally; no
GitHub PR, hosted service, or agent-specific integration is required.

## Installation

Requires Neovim 0.11+, `python3` (3.9+ with SQLite) on your `PATH`, and Git
for worktree detection. A Nerd Font renders the sidebar icons.

With [lazy.nvim](https://github.com/folke/lazy.nvim), start with the following
spec. These mappings are opt-in; the plugin does not bind keys by default.

```lua
{
  "dkarter/comment-threads.nvim",
  main = "comment_threads",
  lazy = false,
  keys = {
    { "<leader>cn", "<cmd>ThreadAdd<cr>", desc = "New comment thread" },
    { "<leader>cn", function() require("comment_threads").add_selection() end, mode = "x", desc = "Comment on selection" },
    { "<leader>co", "<cmd>ThreadOpen<cr>", desc = "Open comment thread" },
    { "<leader>cl", "<cmd>ThreadList<cr>", desc = "List comment threads" },
    { "<leader>ch", "<cmd>ThreadHandoff<cr>", desc = "Copy agent handoff" },
    { "<leader>cr", "<cmd>ThreadReattach<cr>", desc = "Reattach comment thread" },
    { "<leader>cr", function() require("comment_threads").reattach_selection() end, mode = "x", desc = "Reattach to selection" },
    { "[v", function() require("comment_threads").jump(-1) end, desc = "Previous thread" },
    { "]v", function() require("comment_threads").jump(1) end, desc = "Next thread" },
    { "<LeftMouse>", function() return require("comment_threads").click() end, expr = true, desc = "Click comment action" },
  },
  opts = {
    mappings = {
      composer = { post = "<C-CR>", close = "q" },
      thread = {
        activate = "<CR>", reply = "r", edit = "e", delete = "d",
        toggle = "x", refresh = "R", close = "q", undo = "u", redo = "<C-r>",
      },
      browser = {
        jump = "<CR>", open = "o", reply = "r", edit = "e", delete = "d",
        toggle = "x", close = "q", undo = "u", redo = "<C-r>",
        fold_toggle = "za", fold_open = "zo", fold_close = "zc",
      },
    },
  },
}
```

With another plugin manager, add the repository to your runtime path and
call `require("comment_threads").setup(opts)`.

## In Neovim

The keys below refer to the example above. The `:Thread…` commands also work
without mappings.

| Key or command | Action |
| --- | --- |
| `<leader>cn` | Start a thread on the current line or a visual selection (characterwise or linewise). Save the source file first. |
| `<leader>co` | Open the highlighted thread under the cursor; pick if several match. |
| `<leader>cl` | Scroll through all threads and their replies for this file. Use `:ThreadList open` or `:ThreadList resolved` to filter. |
| `]v` / `[v` | Jump to the next or previous attached open thread in this file. |
| `<leader>cr` | Reattach a thread to the line or selection. |
| `:ThreadRefresh` | Reload the current file's comments and gutter signs from disk. |
| `<leader>ch` / `:ThreadHandoff` | Copy a prompt for the agent in the neighboring pane. Paste it when ready. |

Use `r` to reply, `e` on a message to edit it, `x` to resolve or reopen, and
`R` to see the agent's latest replies. Use `:w` or `Ctrl+Enter` to post from
the Markdown composer. `Ctrl+Enter` requires a terminal that reports it
separately from `Enter`. Customize buffer-local shortcuts under `mappings`
in `setup()` or Lazy's `opts`.

Threads open in a right-hand split when the source window is at least 108
columns wide, or in a float when it is narrower. Set `sidebar_min_width` or
`sidebar_width` to change the layout, or `sidebar_min_width = false` to always
use floats. The docked browser follows the source cursor. Press `Enter` on a
thread to jump to its text, `o` to open it for replies and edits, or `q` to
close the browser (bindings come from `mappings.browser`).
Moving through the browser previews the corresponding anchor in the source
window. Narrow panes use icon buttons, and individual thread views use shorter
timestamps.
Set `compact_width = 0` to keep text buttons at every width.

In the browser or an individual thread, click **Reply**, **Resolve/Reopen**,
**Edit**, or **Delete**, or put the Normal-mode cursor on a button and press
`Enter`. You can also use `r`, `x`, `e`, or `d` with the cursor on the
card or message. New comments and replies open in insert mode. When a
composer replaces a popup, saving or canceling returns to that popup.
Press `q` in Normal mode to close an empty draft or confirm discarding a
nonempty one. Deleting asks for confirmation and removes the thread only
if no messages remain.
Open threads start expanded; resolved threads start collapsed. Click the
`▸` / `▾` beside a thread or press `Enter` on it to expand or collapse the
conversation without changing its status. From anywhere in a card, `za`
toggles it, `zo` expands it, and `zc` collapses it.

Use `u` to undo and `Ctrl+r` to redo comment changes in either comment view.
From a source file, use `:ThreadUndo` or `:ThreadRedo`; Vim's file undo is
unchanged. History is scoped to this Neovim session and worktree. Undo and
redo refuse to overwrite newer changes to the same thread.
Mouse actions require Neovim mouse reporting and the `<LeftMouse>` expression
mapping above. Set `author` to change your displayed name and
`author_icons = { human = "●", opencode = "◆" }` to customize byline icons.

Exact selections get a yellow highlight and an inline comment glyph.
Whole-line comments use the gutter only; when several threads start on one
line the gutter shows their count. Override `CommentThreadsRange` and
`CommentThreadsSign` to change the colors, or set `glyph = false` to hide
inline glyphs and `sign = "!"` for a plain-text gutter icon.

The CLI signals Neovim after a successful write. One filesystem watcher per
Neovim instance batches changes and refreshes affected visible buffers
asynchronously; there is no periodic timer. This updates both the browser
and individual threads. Set `live_updates = false` to disable the watcher.

## In the agent pane

Run `:ThreadHandoff` to copy a prompt containing the absolute path to the
bundled CLI. To use the commands below, put the plugin's `bin` directory on
your `PATH` or replace `comment-threads` with that absolute path.

Run the CLI in the same Git worktree (or pass `--root /path/to/worktree`
before the subcommand). Check the quoted text and context before changing a
file; the recorded line number is only a hint.

```sh
comment-threads list
comment-threads show THREAD_ID
comment-threads reply THREAD_ID --author OpenCode --body 'Updated the wording.'
comment-threads resolve THREAD_ID --author OpenCode
comment-threads reopen THREAD_ID --author OpenCode
```

OpenCode, Codex, Claude Code, and Pi use the same CLI. Output is JSON. `list`
defaults to open threads; pass `--all`, `--status resolved`, or `--path FILE`.
For a multiline reply, pipe the body into `reply` without `--body`. By default,
`ThreadHandoff` asks the agent to leave threads open for your review.

## Anchors and storage

Neovim extmarks track ranges during edits. When a changed file is reopened or
reloaded, the plugin looks for the original quote and matching surrounding
text. Missing or ambiguous anchors appear as **needs reattach**, not at a
guessed line. Reattach manually after a rewrite. File renames and visual-block
selections are not handled yet.

SQLite stores one inbox per canonical worktree path under
`${XDG_DATA_HOME:-$HOME/.local/share}/comment-threads`. Nothing goes into Git.
Outside Git, Neovim uses the file's parent directory as the root; run the CLI
from that directory or use `--root`.
