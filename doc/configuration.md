# Configuring comment-threads.nvim

Local, threaded comments on Markdown, code, or other text files. The comments
live outside the files being reviewed. You write in Neovim; an agent can read
and reply from a neighboring terminal pane. Comments are stored locally; no
GitHub PR, hosted service, or agent-specific integration is required.

## Installation

Requires Neovim 0.11+, Git, curl, and `shasum` or `sha256sum`. The CLI is a
native binary with SQLite built in. Prebuilt binaries support macOS and Linux
on ARM64 and x86-64.
A Nerd Font renders the sidebar icons.

With [lazy.nvim](https://github.com/folke/lazy.nvim), start with the following
spec. These mappings are opt-in; the plugin does not bind keys by default.

```lua
{
  "dkarter/comment-threads.nvim",
  main = "comment_threads",
  version = "*",
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
    { "<CR>", "<Plug>(comment-threads-activate)", ft = "comment-threads", desc = "Activate comment action" },
    { "o", "<Plug>(comment-threads-open)", ft = "comment-threads", desc = "Open thread from list" },
    { "r", "<Plug>(comment-threads-reply)", ft = "comment-threads", desc = "Reply" },
    { "x", "<Plug>(comment-threads-toggle)", ft = "comment-threads", desc = "Resolve or reopen" },
    { "e", "<Plug>(comment-threads-edit)", ft = "comment-threads", nowait = true, desc = "Edit message" },
    { "d", "<Plug>(comment-threads-delete)", ft = "comment-threads", nowait = true, desc = "Delete message" },
    { "R", "<Plug>(comment-threads-refresh)", ft = "comment-threads", desc = "Refresh thread" },
    { "q", "<Plug>(comment-threads-close)", ft = { "comment-threads", "markdown.comment-thread-draft" }, desc = "Close comment view" },
    { "u", "<Plug>(comment-threads-undo)", ft = "comment-threads", desc = "Undo comment change" },
    { "<C-r>", "<Plug>(comment-threads-redo)", ft = "comment-threads", desc = "Redo comment change" },
    { "za", "<Plug>(comment-threads-fold-toggle)", ft = "comment-threads", desc = "Toggle thread fold" },
    { "zo", "<Plug>(comment-threads-fold-open)", ft = "comment-threads", desc = "Expand thread" },
    { "zc", "<Plug>(comment-threads-fold-close)", ft = "comment-threads", desc = "Collapse thread" },
    { "<C-CR>", "<Plug>(comment-threads-post)", ft = "markdown.comment-thread-draft", mode = { "n", "i" }, desc = "Post comment" },
  },
  opts = {},
}
```

Lazy runs the repository's `build.lua` on install and update. It downloads
the asset for the checked-out tag, requires an immutable GitHub release,
and verifies the SHA-256 before installing the executable. It does not
download anything at Neovim startup.

With another plugin manager, check out a release tag and run
`nvim --headless -u NONE -i NONE -l build.lua` from the plugin directory.
Add the repository to your runtime path and call
`require("comment_threads").setup(opts)`. Set `cli` in `opts` to use a
manually installed binary instead.

For a development checkout, run `cargo build --locked --release`. The plugin
finds the local build automatically. If you use Lazy with a local checkout,
set `build = "cargo build --locked --release"` in that spec.

GitHub publishes release and build attestations. For independent provenance
verification, run `gh attestation verify <binary> --repo dkarter/comment-threads.nvim`.
The installer checks the release metadata and digest; it does not verify
the build attestation.

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
separately from `Enter`. Change the left-hand sides in Lazy's `keys` to
customize the shortcuts; button hints use the actual mappings.

Threads open in a right-hand split when the source window is at least 108
columns wide, or in a float when it is narrower. Set `sidebar_min_width` or
`sidebar_width` to change the layout, or `sidebar_min_width = false` to always
use floats. The docked browser follows the source cursor. Press `Enter` on a
thread to jump to its text, `o` to open it for replies and edits, or `q` to
close the browser.
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
For the logos in the screenshots, install
[Agent Mono Nerd Font](https://github.com/dkarter/dotfiles/tree/master/assets/fonts)
and select that font in your terminal. Then set, for example:

```lua
author_icons = { human = "", opencode = "", claude = "", codex = "", pi = "" }
```

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
bundled CLI. To use the commands below, put the plugin's `bin/<version>`
directory on your `PATH` or replace `comment-threads` with that absolute path.

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
