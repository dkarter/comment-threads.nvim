# Development

Run the smoke suite from the repository root:

```sh
nvim --headless -u NONE -i NONE -l tests/smoke.lua
```

It uses a temporary workspace and data directory. It covers range anchors,
the SQLite CLI, live refresh, popup and sidebar behavior, and undo/redo.

Check Lua formatting with:

```sh
stylua --check --indent-type Spaces --indent-width 2 lua tests
```

For a manual check, open a file in a scratch worktree with the plugin on
Neovim's runtime path. Add a thread, post a reply with `bin/comment-threads`
from another terminal, and confirm it appears without a manual refresh.
