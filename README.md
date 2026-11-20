# comment-threads.nvim

Leave comments on code or prose in Neovim, then let an agent reply from its
own terminal. Threads live outside your source files, so there’s nothing to
clean up before you commit.

![Markdown release notes with an active selection, an OpenCode reply, a whole-line comment, and a collapsed resolved thread](https://github.com/user-attachments/assets/b3ca9993-e860-44ca-bd24-c7dedb8e6259)

## Features

- Annotate whole lines or exact text ranges. Multiple threads can share a line.
- Browse threads in a sidebar that follows the current file and highlights
  the selected thread’s source. Narrow windows use a popup.
- Write and edit replies in a normal Markdown buffer. Fold, resolve, reopen,
  or delete threads with the keyboard or mouse. Undo and redo comment changes.
- Hand off open threads to OpenCode, Claude Code, Codex, or Pi with the bundled
  CLI. Replies appear live without polling, and data stays local to the worktree.

<details>
<summary>Elixir review and more screenshots</summary>

![Two comments on different parts of the same Elixir line, with replies from OpenCode and Claude](https://github.com/user-attachments/assets/f7a8c891-0e3f-46a2-96de-c193aa56cbbf)

[Thread controls](https://github.com/user-attachments/assets/0ce08508-059b-44b9-abc5-668803f3ffe2) · [Reply composer](https://github.com/user-attachments/assets/49e829d9-5569-4573-897b-54c3150a3e28) · [Screenshot gallery](https://github.com/dkarter/comment-threads.nvim/issues/1)

</details>

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

[MIT license](LICENSE)
