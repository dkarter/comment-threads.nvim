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

![Two comments on different parts of the same Elixir line, with replies from Claude](https://github.com/user-attachments/assets/a0032c42-8a00-4bdf-8ccd-be1913debac0)

[Thread controls](https://github.com/user-attachments/assets/12cffa4b-8318-4eca-ad5c-7716b6e18ba2) · [Reply composer](https://github.com/user-attachments/assets/49e829d9-5569-4573-897b-54c3150a3e28) · [Screenshot gallery](https://github.com/dkarter/comment-threads.nvim/issues/1)

</details>

## Install

Requires Neovim 0.11+, Python 3.9+ with SQLite, and Git for worktree detection.
Use a Nerd Font for icons.

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "dkarter/comment-threads.nvim",
  main = "comment_threads",
  lazy = false,
  opts = {
    mappings = {
      composer = { post = "<C-CR>", close = "q" },
      thread = { activate = "<CR>", reply = "r", edit = "e", toggle = "x", close = "q" },
      browser = { jump = "<CR>", open = "o", close = "q" },
    },
  },
}
```

With another plugin manager, add the plugin to your runtime path and call
`require("comment_threads").setup(opts)`. The plugin does not bind keys unless
configured. See [configuration](doc/configuration.md) for a full mapping
example, mouse controls, and CLI usage.

## Try it

- Run `:ThreadAdd` on a saved file to comment on the current line. For exact
  selections, use the visual mapping in the configuration guide. Write your
  comment and save with `:w`.
- Run `:ThreadList` to browse threads, or `:ThreadOpen` to open the thread
  under the cursor.
- Run `:ThreadHandoff` to copy a prompt for an agent in the same worktree.

[MIT license](LICENSE)
