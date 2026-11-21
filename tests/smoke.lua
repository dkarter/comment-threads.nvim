local api = vim.api
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local anchors = require("comment_threads.anchor")
local cli = vim.env.COMMENT_THREADS_CLI or vim.fn.getcwd() .. "/target/debug/comment-threads"
local sandbox = vim.fn.tempname()
vim.fn.mkdir(sandbox .. "/worktree", "p")
vim.env.XDG_DATA_HOME = sandbox .. "/data"
local root = sandbox .. "/worktree"
vim.fn.writefile({ "Title", "", "Keep café and shorten this phrase." }, root .. "/sample.md")
vim.cmd.edit(vim.fn.fnameescape(root .. "/sample.md"))
local buf = api.nvim_get_current_buf()

local function run(args, input, cwd)
  local cmd = { cli, "--root", cwd or root }
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, { stdin = input, text = true }):wait()
  return result
end

local function call(args, input, cwd)
  local result = run(args, input, cwd)
  assert(result.code == 0, result.stderr)
  return vim.json.decode(result.stdout)
end

local function capture(a, b, mode)
  return assert(anchors.capture(buf, { 0, a[1], a[2], 0 }, { 0, b[1], b[2], 0 }, mode))
end

local function create(anchor, body)
  return call(
    { "create", "--author", "Human" },
    vim.json.encode({
      path = "sample.md",
      anchor = anchor,
      body = body,
    })
  )
end

local cafe = capture({ 3, 9 }, { 3, 6 }, "v")
local shorten = capture({ 3, 16 }, { 3, 22 }, "v")
local full = capture({ 2, 1 }, { 3, 1 }, "V")
assert(cafe.quote == "café")
assert(shorten.quote == "shorten")
assert(full.quote == "\nKeep café and shorten this phrase.")
local forged = vim.tbl_extend("force", cafe, { offset = 1000 })
assert(anchors.locate(anchors.snapshot(buf), forged) == nil)
vim.o.selection = "exclusive"
assert(capture({ 3, 6 }, { 3, 11 }, "v").quote == "café")
vim.o.selection = "inclusive"

local first = create(cafe, "Keep this")
local second = create(shorten, "Trim this")
assert(first.id ~= second.id and #call({ "list" }) == 2)
assert(#call({ "list" }, nil, sandbox) == 0)
assert(run({ "reply", second.id, "--author", "Invalid\nAuthor" }, "Rejected").code ~= 0)
local reply = call({ "reply", second.id, "--author", "Agent" }, "Changed it.\nPlease review.")
assert(#reply.messages == 2 and reply.messages[2].author == "Agent")
local message = reply.messages[1]
local edit = { "edit", second.id, tostring(message.id), "--revision", tostring(message.revision) }
local edited = call(vim.list_extend(vim.deepcopy(edit), { "--body", "- Edited" })).messages[1]
assert(edited.revision == 2 and edited.body == "- Edited")
assert(run(edit, "Stale draft").code ~= 0)
call({ "resolve", second.id, "--author", "Agent" })
assert(#call({ "list" }) == 1)
assert(#call({ "list", "--status", "resolved" }) == 1)
assert(call({ "reopen", second.id, "--author", "Human" }).messages[2].body == reply.messages[2].body)

api.nvim_buf_set_lines(buf, 0, -1, false, { "New line", "Title", "", "Keep café and trim this phrase." })
local doc = anchors.snapshot(buf)
assert(vim.deep_equal(anchors.locate(doc, cafe), { 3, 5, 3, 10 }))
assert(anchors.locate(doc, shorten) == nil)
api.nvim_buf_set_lines(buf, 0, -1, false, { "café", "café" })
assert(anchors.locate(anchors.snapshot(buf), cafe) == nil)
api.nvim_buf_set_lines(buf, 0, -1, false, { "Unrelated café elsewhere" })
assert(anchors.locate(anchors.snapshot(buf), cafe) == nil)

vim.cmd("edit!")
vim.g.mapleader = " "
local plugin = require("comment_threads")
local options = {
  cli = cli,
  author = "Human",
  mappings = {
    composer = { post = "<C-CR>", close = "q" },
    thread = {
      activate = "<CR>",
      reply = "r",
      toggle = "x",
      refresh = "R",
      close = "q",
      edit = "e",
      delete = "d",
      undo = "u",
      redo = "<C-r>",
    },
    browser = {
      jump = "<CR>",
      edit = "e",
      reply = "r",
      toggle = "x",
      delete = "d",
      fold_toggle = "za",
      fold_open = "zo",
      fold_close = "zc",
    },
  },
}
plugin.setup(options)
assert(vim.fn.maparg("]v", "n") == "")
vim.keymap.set("n", "]v", function()
  plugin.jump(1)
end)
vim.keymap.set("n", "[v", function()
  plugin.jump(-1)
end)
vim.keymap.set("n", "<leader>cl", "<cmd>ThreadList all<cr>")
vim.keymap.set("n", "<leader>cn", "<cmd>ThreadAdd<cr>")
vim.cmd.ThreadRefresh()
api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("normal ]v")
assert(vim.deep_equal(api.nvim_win_get_cursor(0), { 3, 5 }))
vim.cmd("normal ]v")
assert(vim.deep_equal(api.nvim_win_get_cursor(0), { 3, 15 }))
vim.cmd("normal [v")
assert(vim.deep_equal(api.nvim_win_get_cursor(0), { 3, 5 }))
vim.cmd("normal 2]v")
assert(vim.deep_equal(api.nvim_win_get_cursor(0), { 3, 5 }))
call({ "resolve", second.id, "--author", "Agent" })
vim.cmd.ThreadRefresh()
vim.cmd("normal ]v")
assert(vim.deep_equal(api.nvim_win_get_cursor(0), { 3, 5 }))

api.nvim_feedkeys(" cl", "mx", false)
local listing = api.nvim_get_current_buf()
local function contents(target)
  return table.concat(api.nvim_buf_get_lines(target, 0, -1, false), "\n")
end
local function enter_button(label, in_header)
  for row, line in ipairs(api.nvim_buf_get_lines(0, 0, -1, false)) do
    local col = line:find(" " .. label .. " ", 1, true)
    if col and (not in_header or line:find(in_header, 1, true)) then
      api.nvim_win_set_cursor(0, { row, col })
      local pressed_buf = api.nvim_get_current_buf()
      local flash = api.nvim_get_namespaces()["comment_threads.button_press"]
      api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)
      assert(#api.nvim_buf_get_extmarks(pressed_buf, flash, 0, -1, {}) == 1)
      assert(vim.wait(1000, function()
        return not api.nvim_buf_is_valid(pressed_buf) or #api.nvim_buf_get_extmarks(pressed_buf, flash, 0, -1, {}) == 0
      end))
      return
    end
  end
  error("Missing button: " .. label)
end
assert(contents(listing):find("Keep this", 1, true))
assert(contents(listing):find("Resolved", 1, true))
assert(not contents(listing):find("Please review.", 1, true))
vim.fn.search("Keep this", "w")
vim.cmd("normal zc")
assert(not contents(listing):find("Keep this", 1, true))
vim.cmd("normal zo")
assert(contents(listing):find("Keep this", 1, true))
vim.cmd("normal za")
assert(not contents(listing):find("Keep this", 1, true))
vim.cmd("normal za")
assert(contents(listing):find("Keep this", 1, true))
enter_button("▾", "Open ·")
assert(not contents(listing):find("Keep this", 1, true))
assert(#call({ "list" }) == 1)
enter_button("▸", "Open ·")
assert(contents(listing):find("Keep this", 1, true))
enter_button("▸", "Resolved ·")
assert(contents(listing):find("Please review.", 1, true))
enter_button("▾", "Resolved ·")
assert(not contents(listing):find("Please review.", 1, true))
enter_button("Resolve")
assert(#call({ "list" }) == 0)
enter_button("Reopen")
assert(#call({ "list" }) == 1)
call({ "reply", first.id, "--author", "Agent" }, "An external reply in the browser.")
assert(vim.wait(5000, function()
  return contents(listing):find("An external reply in the browser.", 1, true)
end))
vim.cmd.close()

plugin.setup(vim.tbl_extend("force", options, { sidebar_min_width = 70, sidebar_width = 32 }))
vim.cmd.ThreadOpen()
assert(#api.nvim_tabpage_list_wins(0) == 2)
assert(api.nvim_win_get_config(0).relative == "")
assert(api.nvim_win_get_width(0) == 32)
local compact = contents(api.nvim_get_current_buf())
assert(compact:match("Human · %d%d:%d%d   %(e%)    %(d%)"))
assert(compact:find("\n  (r)    (x)    (R)    (q)", 1, true))
local dock = api.nvim_get_current_win()
vim.cmd.ThreadList()
assert(api.nvim_get_current_win() == dock)
assert(#api.nvim_tabpage_list_wins(0) == 2)
assert(contents(api.nvim_get_current_buf()):find("2 threads", 1, true))
vim.cmd("ThreadList open")
assert(api.nvim_get_current_win() == dock)
assert(contents(api.nvim_get_current_buf()):find("1 thread", 1, true))
local editor = vim.fn.bufwinid(buf)
api.nvim_set_current_win(editor)
vim.cmd.edit(vim.fn.fnameescape(root .. "/fresh.md"))
local fresh = api.nvim_get_current_buf()
assert(vim.wait(1000, function()
  return contents(api.nvim_win_get_buf(dock)):find("Comments · fresh.md", 1, true)
end))
assert(contents(api.nvim_win_get_buf(dock)):find("0 threads", 1, true))
assert(not contents(api.nvim_win_get_buf(dock)):find("Keep this", 1, true))
assert(api.nvim_get_current_win() == editor)
api.nvim_win_set_buf(editor, buf)
assert(vim.wait(1000, function()
  return contents(api.nvim_win_get_buf(dock)):find("Keep this", 1, true)
end))
assert(api.nvim_get_current_buf() == buf and fresh ~= buf)
api.nvim_set_current_win(dock)
vim.cmd.close()
plugin.setup(vim.tbl_extend("force", options, { sidebar_min_width = false }))
vim.cmd.ThreadOpen()
assert(api.nvim_win_get_config(0).relative == "editor")
local detail = api.nvim_get_current_buf()
assert(vim.fn.maparg("d", "n", false, true).nowait == 1)
assert(contents(detail):find("\n Reply (r)   Resolve (x)   Refresh (R)   Close (q)", 1, true))
assert(contents(detail):match("Human · [^\n]+  Edit %(e%)   Delete %(d%)[^\n]*\nKeep this"))
local footer_row = api.nvim_buf_line_count(detail)
api.nvim_win_set_cursor(0, { footer_row, 0 })
vim.cmd("normal! 2e")
local native_cursor = api.nvim_win_get_cursor(0)
api.nvim_win_set_cursor(0, { footer_row, 0 })
vim.cmd("normal 2e")
assert(vim.deep_equal(api.nvim_win_get_cursor(0), native_cursor))
vim.fn.search("Keep this", "w")
vim.cmd("normal e")
assert(vim.wait(1000, function()
  return vim.bo.buftype == "acwrite"
end))
assert(contents(api.nvim_get_current_buf()) == "Keep this")
vim.cmd("normal q")
assert(api.nvim_get_current_buf() == detail)
local primary = api.nvim_get_hl(0, { name = "CommentThreadsButtonPrimary" })
local primary_hint = api.nvim_get_hl(0, { name = "CommentThreadsButtonHintPrimary" })
assert(primary.bg and primary.bg == primary_hint.bg and primary.fg ~= primary_hint.fg)
enter_button("Resolve")
assert(contents(detail):find("Resolved by Human", 1, true))
enter_button("Reopen")
assert(contents(detail):find("Open by Human", 1, true))
call({ "reply", first.id, "--author", "Agent" }, "An external reply in the thread.")
assert(vim.wait(5000, function()
  return contents(detail):find("An external reply in the thread.", 1, true)
end))
local detail_win = api.nvim_get_current_win()
local layout_count = #api.nvim_tabpage_list_wins(0)
enter_button("Reply")
local draft_buf = api.nvim_get_current_buf()
assert(vim.bo.buftype == "acwrite" and draft_buf ~= detail)
assert(api.nvim_get_current_win() == detail_win and #api.nvim_tabpage_list_wins(0) == layout_count)
api.nvim_buf_set_lines(draft_buf, 0, -1, false, { "   ", "\t" })
vim.cmd.stopinsert()
vim.cmd("normal q")
assert(not api.nvim_buf_is_valid(draft_buf) and api.nvim_get_current_buf() == detail)
assert(api.nvim_get_current_win() == detail_win)
enter_button("Reply")
api.nvim_buf_set_lines(0, 0, -1, false, { "Saved from the replacement popup." })
vim.cmd.stopinsert()
vim.cmd.write()
assert(api.nvim_get_current_buf() == detail and contents(detail):find("Saved from the replacement popup.", 1, true))
vim.fn.search("Saved from the replacement popup.", "w")
local confirm = vim.fn.confirm
vim.fn.confirm = function()
  return 1
end
vim.cmd("normal d")
assert(vim.wait(1000, function()
  return not contents(detail):find("Saved from the replacement popup.", 1, true)
end))
vim.fn.confirm = confirm
vim.cmd("normal u")
assert(contents(detail):find("Saved from the replacement popup.", 1, true))
api.nvim_feedkeys(api.nvim_replace_termcodes("<C-r>", true, false, true), "mx", false)
assert(not contents(detail):find("Saved from the replacement popup.", 1, true))
vim.cmd.close()

api.nvim_feedkeys(" cn", "mx", false)
assert(vim.bo.buftype == "acwrite")
assert(vim.fn.maparg("<C-CR>", "i", false, true).buffer == 1)
api.nvim_feedkeys(api.nvim_replace_termcodes("iPosted with the composer mapping<C-CR>", true, false, true), "mx", false)
assert(#call({ "list" }) == 2)
local ranges =
  api.nvim_buf_get_extmarks(buf, api.nvim_get_namespaces()["comment_threads.ranges"], 0, -1, { details = true })
assert(#ranges == 2)
assert(not ranges[1][4].hl_group and not ranges[1][4].line_hl_group)
assert(ranges[2][4].hl_group == "CommentThreadsRange")
vim.cmd.close()
api.nvim_buf_set_lines(buf, -1, -1, false, { "", "Final phrase." })
vim.cmd.write()
create(capture({ 5, 7 }, { 5, 12 }, "v"), "The last card should be readable from its header.")
plugin.setup(vim.tbl_extend("force", options, { sidebar_min_width = 70, sidebar_width = 32 }))
local source_win = api.nvim_get_current_win()
api.nvim_win_set_cursor(source_win, { 1, 0 })
vim.cmd.ThreadList()
local browser_win = api.nvim_get_current_win()
local browser_buf = api.nvim_get_current_buf()
local final_header
for row, line in ipairs(api.nvim_buf_get_lines(browser_buf, 0, -1, false)) do
  if line:find("L5:7", 1, true) then
    final_header = row
  end
end
assert(final_header)
api.nvim_set_current_win(source_win)
api.nvim_win_set_cursor(source_win, { 5, 0 })
api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
assert(api.nvim_win_get_cursor(browser_win)[1] == final_header)
assert(api.nvim_win_call(browser_win, vim.fn.winsaveview).topline == final_header)
assert(contents(browser_buf):find("╰─", 1, true))
assert(contents(browser_buf):find(" phrase", 1, true))
local has_accent, has_quote = false, false
local cards = api.nvim_get_namespaces()["comment_threads.browser"]
for _, mark in ipairs(api.nvim_buf_get_extmarks(browser_buf, cards, 0, -1, { details = true })) do
  local details = mark[4]
  assert(not details.line_hl_group and details.hl_group ~= "CommentThreadsRange")
  has_accent = has_accent or (details.hl_group == "CommentThreadsCardAccent" and mark[2] == final_header - 1)
  has_quote = has_quote or details.hl_group == "CommentThreadsCardQuote"
end
assert(has_accent and has_quote)
assert(contents(browser_buf):find("L5:7   (x)", 1, true))
assert(contents(browser_buf):find("The last card should be readable from its header.\n│\n│    (r)", 1, true))
assert(contents(browser_buf):find(" (e)    (d)", 1, true))
local preview_ns = api.nvim_get_namespaces()["comment_threads.preview"]
api.nvim_set_current_win(browser_win)
api.nvim_exec_autocmds("CursorMoved", { buffer = browser_buf })
local preview = api.nvim_buf_get_extmarks(buf, preview_ns, 0, -1, { details = true })
assert(#preview == 1 and preview[1][2] == 4 and preview[1][3] == 6)
vim.fn.search("L3:6", "w")
api.nvim_exec_autocmds("CursorMoved", { buffer = browser_buf })
preview = api.nvim_buf_get_extmarks(buf, preview_ns, 0, -1, { details = true })
assert(#preview == 1 and preview[1][2] == 2 and preview[1][3] == 5)
api.nvim_set_current_win(source_win)
assert(#api.nvim_buf_get_extmarks(buf, preview_ns, 0, -1, {}) == 0)
local disposable = create(capture({ 5, 7 }, { 5, 12 }, "v"), "Remove only this message.")
local with_reply = call({ "reply", disposable.id, "--author", "OpenCode" }, "Keep the reply.")
local starter, remaining = unpack(with_reply.messages)
local function delete_args(msg, revision)
  return { "delete", disposable.id, tostring(msg.id), "--revision", tostring(revision) }
end
assert(run(delete_args(starter, starter.revision + 1)).code ~= 0)
assert(call(delete_args(starter, starter.revision)).deleted)
local kept = call({ "show", disposable.id })
assert(#kept.messages == 1 and kept.messages[1].id == remaining.id)
assert(call(delete_args(remaining, remaining.revision)).deleted)
assert(run({ "show", disposable.id }).code ~= 0)
local isolated = create(capture({ 5, 7 }, { 5, 12 }, "v"), "Restore this whole thread.")
local only = isolated.messages[1]
local deletion = call({ "--record", "delete", isolated.id, tostring(only.id), "--revision", tostring(only.revision) })
assert(deletion.change.after == false)
local after_delete = create(capture({ 5, 7 }, { 5, 12 }, "v"), "An unrelated thread.")
assert(after_delete.messages[1].id > only.id)
local function restore(expected, replacement)
  return run({ "restore", isolated.id }, vim.json.encode({ expected = expected, replacement = replacement }))
end
assert(restore(deletion.change.after, deletion.change.before).code == 0)
assert(call({ "show", isolated.id }).messages[1].id == only.id)
call({ "reply", isolated.id, "--author", "OpenCode" }, "Do not overwrite this later reply.")
assert(restore(deletion.change.before, deletion.change.after).code ~= 0)
assert(#call({ "show", isolated.id }).messages == 2)

vim.cmd.ThreadAdd()
api.nvim_buf_set_lines(0, 0, -1, false, { "Delete the only message in this thread." })
vim.cmd.stopinsert()
vim.cmd.write()
local last_thread = api.nvim_get_current_buf()
vim.fn.search("Delete the only message", "w")
vim.fn.confirm = function()
  return 1
end
vim.cmd("normal d")
assert(vim.wait(1000, function()
  return contents(last_thread):find("Thread deleted", 1, true)
end))
vim.fn.confirm = confirm
vim.cmd("normal u")
assert(api.nvim_get_current_buf() == last_thread and contents(last_thread):find("Delete the only message", 1, true))

api.nvim_create_autocmd("FileType", {
  pattern = { "comment-threads", "markdown.comment-thread-draft" },
  callback = function(ev)
    vim.keymap.set("n", "Q", "<Plug>(comment-threads-close)", { buffer = ev.buf })
    if vim.bo[ev.buf].filetype == "comment-threads" then
      vim.keymap.set("n", "gr", "<Plug>(comment-threads-reply)", { buffer = ev.buf })
    end
  end,
})
plugin.setup({ cli = cli, author = "Human", sidebar_min_width = false })
api.nvim_set_current_win(source_win)
vim.cmd.ThreadAdd()
assert(vim.bo.filetype == "markdown.comment-thread-draft")
vim.cmd.stopinsert()
vim.cmd("normal Q")
assert(api.nvim_get_current_buf() == buf)
local previous_panel = vim.fn.bufwinid(last_thread)
if previous_panel ~= -1 then
  api.nvim_win_close(previous_panel, false)
end
local select = vim.ui.select
vim.ui.select = function(items, _, cb)
  cb(items[1])
end
vim.cmd.ThreadOpen()
vim.ui.select = select
assert(contents(api.nvim_get_current_buf()):find("Reply (gr)", 1, true))
print("Anchor and CLI smoke tests passed")
