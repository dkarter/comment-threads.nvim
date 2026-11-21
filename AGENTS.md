# Release policy

Only the GitHub Actions **Release** workflow may build release binaries, upload
them to a draft, and publish the release. Use Release Please's `release_created`
output to start the normal release flow. If a draft needs a retry, rerun the
workflow; do not build, upload, or publish release assets by hand.

# Interactive Neovim testing

Test interactive changes in Herdr with both setups:

- A minimal Neovim config, with only the plugin and the mappings needed for
  the test. Check that the feature works without the dotfiles or optional
  plugins.
- Dorian's dotfiles Neovim setup, with its actual mappings, theme, and
  highlights. Leave this test tab open for Dorian to try.

In both setups, load the local plugin and CLI and use disposable comment data.
For visual UI changes, capture and inspect the relevant Herdr states with
`mise exec -- tui-shot --pane <pane-id> -o <temporary-path>.png`. Use screenshots
selectively to check layout and highlights; don't require them for non-UI
changes or commit the captures by default.
