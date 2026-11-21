# Release policy

Only the GitHub Actions **Release** workflow may build release binaries, upload
them to a draft, and publish the release. Use Release Please's `release_created`
output to start the normal release flow. If a draft needs a retry, rerun the
workflow; do not build, upload, or publish release assets by hand.
