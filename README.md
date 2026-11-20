# comment-threads.nvim

**Review code and prose with your agent, right in Neovim.** Highlight a
passage, leave a note, and see OpenCode’s reply land in the same thread.
No pasted excerpts, no review notes in your diff.

![Markdown release notes with an active selection, an OpenCode reply, a whole-line comment, and a collapsed resolved thread](https://github.com/user-attachments/assets/b3ca9993-e860-44ca-bd24-c7dedb8e6259)

## Features

- **Point to the exact words.** Comment on a phrase, a block, or a whole line.
  Put separate threads on different parts of the same line.
- **Hand off to OpenCode.** Copy a prompt with `:ThreadHandoff`. Agent replies
  appear live without polling. Claude Code, Codex, and Pi use the same CLI.
- **Keep your Vim motions.** Compose and edit in a Markdown buffer. Reply,
  resolve, reopen, or delete with keys or clicks. Undo and redo comment changes.
- **Keep open questions in view.** The sidebar follows your file and
  highlights the source for the selected thread. Resolved threads collapse
  out of the way.
- **Keep the diff clean.** Threads stay local to your worktree, separate from
  the files you’re reviewing.

## Install

Requires Neovim 0.11+, Python 3.9+ with SQLite for the bundled CLI, and Git
for worktree detection. The CLI uses Python’s standard library; no `pip`
install is needed.

A Nerd Font renders the UI icons. The agent logos in the screenshots use
[Agent Mono Nerd Font](https://github.com/dkarter/dotfiles/tree/master/assets/fonts).
Other fonts can use plain author markers instead.

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "dkarter/comment-threads.nvim",
  main = "comment_threads",
  lazy = false,
  opts = {},
  keys = {
    { "<leader>cn", "<cmd>ThreadAdd<cr>", desc = "New comment" },
    { "<leader>cn", function() require("comment_threads").add_selection() end, mode = "x", desc = "Comment on selection" },
    { "<leader>cl", "<cmd>ThreadList<cr>", desc = "List threads" },
    { "<CR>", "<Plug>(comment-threads-activate)", ft = "comment-threads" },
    { "o", "<Plug>(comment-threads-open)", ft = "comment-threads" },
    { "q", "<Plug>(comment-threads-close)", ft = { "comment-threads", "markdown.comment-thread-draft" } },
  },
}
```

With another plugin manager, add the plugin to your runtime path and call
`require("comment_threads").setup(opts)`. The plugin does not bind keys unless
configured. See [configuration](doc/configuration.md) for a full mapping
example, mouse controls, and CLI usage.

## Try it

- Press `<leader>cn` on a saved file to comment on the current line or visual
  selection. Write your comment and save with `:w`.
- Run `:ThreadList` to browse threads, or `:ThreadOpen` to open the thread
  under the cursor.
- Run `:ThreadHandoff` to copy a prompt for an agent in the same worktree.

## In action

**Two conversations on one Elixir line.** Review each sort key independently.

![Elixir query with two annotations on one line and replies from OpenCode and Claude](https://github.com/user-attachments/assets/f7a8c891-0e3f-46a2-96de-c193aa56cbbf)

**Resolved, but not lost.** Two settled threads fold down to one row each,
leaving the open Lua discussion front and center.

![An open Lua review thread with an OpenCode reply and two collapsed resolved threads below it](https://github.com/user-attachments/assets/edf0ebe9-68d8-4dce-9cf0-da4413ab5ac6)

[Thread controls](https://github.com/user-attachments/assets/0ce08508-059b-44b9-abc5-668803f3ffe2) · [Reply composer](https://github.com/user-attachments/assets/49e829d9-5569-4573-897b-54c3150a3e28) · [Full screenshot gallery](https://github.com/dkarter/comment-threads.nvim/issues/1)

[MIT license](LICENSE)
