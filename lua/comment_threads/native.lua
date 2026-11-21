local M = {}
local repo = "dkarter/comment-threads.nvim"

local function version(root)
  for _, line in ipairs(vim.fn.readfile(vim.fs.joinpath(root, "Cargo.toml"))) do
    local value = line:match('^version%s*=%s*"(%d+%.%d+%.%d+)"')
    if value then
      return value
    end
  end
  error("Cannot find the package version in Cargo.toml")
end

function M.installed(root)
  return vim.fs.joinpath(root, "bin", version(root), "comment-threads")
end

function M.command(root)
  local installed = M.installed(root)
  if vim.fn.executable(installed) == 1 then
    return installed
  end
  local built = vim.fs.joinpath(root, "target/release/comment-threads")
  return vim.fn.executable(built) == 1 and built or installed
end

function M.target(uname)
  local arch = ({ arm64 = "aarch64", aarch64 = "aarch64", x86_64 = "x86_64" })[uname.machine]
  local platform = ({ Darwin = "apple-darwin", Linux = "unknown-linux-musl" })[uname.sysname]
  assert(arch and platform, ("No prebuilt binary for %s/%s"):format(uname.sysname, uname.machine))
  return arch .. "-" .. platform
end

function M.digest(release, tag, name)
  assert(
    release.tag_name == tag and release.immutable == true and not release.draft,
    "Expected a published immutable release for " .. tag
  )
  for _, asset in ipairs(release.assets or {}) do
    if asset.name == name then
      local digest = type(asset.digest) == "string" and asset.digest:match("^sha256:([a-f0-9]+)$")
      assert(digest and #digest == 64, "Missing SHA-256 for release asset " .. name)
      return digest
    end
  end
  error("No release asset named " .. name)
end

local function run(argv)
  local result = vim.system(argv, { text = true }):wait()
  if result.code ~= 0 then
    error(vim.trim(result.stderr))
  end
  return vim.trim(result.stdout)
end

local function curl(...)
  return run({
    "curl",
    "--disable",
    "--fail",
    "--silent",
    "--show-error",
    "--location",
    "--retry",
    "2",
    "--max-time",
    "120",
    "--proto",
    "=https",
    "--proto-redir",
    "=https",
    ...,
  })
end

local function checksum(path)
  if vim.fn.executable("sha256sum") == 1 then
    return run({ "sha256sum", "--", path }):match("^([a-f0-9]+)")
  end
  assert(vim.fn.executable("shasum") == 1, "Install sha256sum or shasum to verify the release binary")
  return run({ "shasum", "-a", "256", "--", path }):match("^([a-f0-9]+)")
end

function M.install(root)
  local tag = "v" .. version(root)
  local at_head = run({ "git", "-C", root, "tag", "--points-at", "HEAD", "--list", tag })
  assert(
    at_head == tag,
    "No release for this checkout; use a versioned tag or build with `cargo build --locked --release`"
  )
  local name = "comment-threads-" .. M.target(vim.uv.os_uname())
  local release = vim.json.decode(curl("https://api.github.com/repos/" .. repo .. "/releases/tags/" .. tag))
  local digest = M.digest(release, tag, name)
  local path = M.installed(root)
  if vim.fn.executable(path) == 1 and checksum(path) == digest then
    return
  end
  local parent = vim.fs.dirname(path)
  vim.fn.mkdir(parent, "p", 448) -- 0700
  local fd, tmp = vim.uv.fs_mkstemp(vim.fs.joinpath(parent, ".download-XXXXXX"))
  assert(fd, tmp)
  vim.uv.fs_close(fd)
  local ok, err = pcall(function()
    curl("--output", tmp, "https://github.com/" .. repo .. "/releases/download/" .. tag .. "/" .. name)
    assert(checksum(tmp) == digest, "Release binary checksum mismatch")
    assert(vim.uv.fs_chmod(tmp, 493)) -- 0755
    assert(vim.uv.fs_rename(tmp, path))
  end)
  if not ok then
    vim.uv.fs_unlink(tmp)
    error(err)
  end
end

return M
