# Development

Install the repository tools and Git hooks:

```sh
mise install
mise exec -- hk install --mise
```

Before each commit, hk scans staged changes for secrets with Betterleaks and
lints changed GitHub Actions files with jactionlint. Use
`mise run lint-workflows` to check all workflows.

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
Please can open a versioned release PR. Merging that PR creates a draft.
Release Please's `release_created` output starts the workflow that builds,
tests, attests, and uploads the four platform binaries. The workflow verifies
the uploaded digests before publishing. The version tag becomes visible to
plugin managers only when GitHub publishes the release.

Do not publish or upload binaries by hand. If a release fails before
publication, run the **Release** workflow on `main` with the existing draft
tag. The retry rebuilds and verifies the assets before publishing.
