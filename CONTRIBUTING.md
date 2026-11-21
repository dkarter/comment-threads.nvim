# Development

Build the Rust CLI and run the smoke suite from the repository root:

```sh
cargo build --locked
nvim --headless -u NONE -i NONE -l tests/smoke.lua
```

It uses a temporary workspace and data directory. It covers range anchors,
the SQLite CLI, live refresh, popup and sidebar behavior, and undo/redo.

Check Lua formatting with:

```sh
cargo fmt --check
stylua --check --indent-type Spaces --indent-width 2 build.lua lua tests
```

For a manual check, open a file in a scratch worktree with the plugin on
Neovim's runtime path after `cargo build --locked --release`. Add a thread,
post a reply with `target/release/comment-threads` from another terminal,
and confirm it appears without a manual refresh.

## Releases

Enable **release immutability** and allow GitHub Actions to create pull
requests in the repository settings. Use Conventional Commits so Release
Please can open a versioned release PR. Merging that PR creates a draft
and builds, attests, and attaches the four platform binaries. The version
tag becomes visible to plugin managers only when you publish the release.

Review the workflow and publish the draft only after every binary is
attached. Publishing makes the tag and assets immutable. The **Release**
workflow can be run manually with an existing draft tag to retry a build.
