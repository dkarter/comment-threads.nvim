local api = vim.api
local anchor = require("comment_threads.anchor")
local controls = require("comment_threads.buttons")
local action_icons = {
  Reply = "",
  Resolve = "",
  Reopen = "",
  Refresh = "",
  Close = "",
  Edit = "",
  Delete = "",
}
local M = {}
local options
local states = {}
local pending = {}
local views = {}
local history = {}
local mutations =
  { create = true, reply = true, edit = true, delete = true, resolve = true, reopen = true, attach = true }
local watch
local refresh
local groups = {
  ranges = api.nvim_create_namespace("comment_threads.ranges"),
  signs = api.nvim_create_namespace("comment_threads.signs"),
  thread = api.nvim_create_namespace("comment_threads.view"),
  glyph = api.nvim_create_namespace("comment_threads.glyph"),
  preview = api.nvim_create_namespace("comment_threads.preview"),
}
local preview_owner = {}
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))

local function notice(message, level)
  vim.notify(message, level or vim.log.levels.WARN, { title = "Comment threads" })
end

local function call(root, args, input, callback)
  local argv = { options.cli, "--root", root }
  local record = mutations[args[1]]
  if record then
    argv[#argv + 1] = "--record"
  end
  vim.list_extend(argv, args)
  local function decode(result)
    if result.code ~= 0 then
      notice(vim.trim(result.stderr), vim.log.levels.ERROR)
      return nil
    end
    local data = vim.json.decode(result.stdout, { luanil = { object = true } })
    if record then
      local change = data.change
      if not vim.deep_equal(change.before, change.after) then
        local stack = history[root] or { undo = {}, redo = {} }
        history[root] = stack
        stack.undo[#stack.undo + 1] = change
        if #stack.undo > 100 then
          table.remove(stack.undo, 1)
        end
        stack.redo = {}
      end
      return data.result
    end
    return data
  end
  local opts = { stdin = input, text = true }
  if callback then
    vim.system(
      argv,
      opts,
      vim.schedule_wrap(function(result)
        callback(decode(result))
      end)
    )
    return
  end
  return decode(vim.system(argv, opts):wait())
end

local function source(buf)
  local name = api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= "" or name == "" then
    return nil
  end
  name = vim.uv.fs_realpath(name)
  if not name or vim.fn.filereadable(name) ~= 1 then
    return nil
  end
  local root = vim.fs.root(name, ".git") or vim.fs.dirname(name)
  return root, vim.fs.relpath(root, name)
end

local function mark_range(buf, mark)
  local data = api.nvim_buf_get_extmark_by_id(buf, groups.ranges, mark, { details = true })
  if #data > 0 and not data[3].invalid then
    return { data[1], data[2], data[3].end_row, data[3].end_col }
  end
end

local function forget_marker(buf, id)
  local state = states[buf]
  local item = state and state.markers[id]
  if item then
    api.nvim_buf_del_extmark(buf, groups.ranges, item.mark)
    if item.glyph then
      api.nvim_buf_del_extmark(buf, groups.glyph, item.glyph)
    end
    state.markers[id] = nil
  end
end

local function sync_glyph(buf, item, range)
  if range and item.anchor.kind == "text" and options.glyph then
    local row, col = range[3], range[4]
    local current = item.glyph and api.nvim_buf_get_extmark_by_id(buf, groups.glyph, item.glyph, {})
    if not current or current[1] ~= row or current[2] ~= col then
      item.glyph = api.nvim_buf_set_extmark(buf, groups.glyph, row, col, {
        id = item.glyph,
        virt_text = { { " " .. options.glyph, "CommentThreadsSign" } },
        virt_text_pos = "inline",
        right_gravity = false,
      })
    end
  elseif item.glyph then
    api.nvim_buf_del_extmark(buf, groups.glyph, item.glyph)
    item.glyph = nil
  end
end

local function render(buf, root, path, threads)
  local state = states[buf] or { markers = {} }
  states[buf] = state
  if state.root ~= root then
    state.key = vim.fn.sha256(root)
  end
  state.threads, state.root, state.path = threads, root, path
  local doc, counts = nil, {}
  api.nvim_buf_clear_namespace(buf, groups.signs, 0, -1)
  local active = {}
  for _, thread in ipairs(threads) do
    local old = state.markers[thread.id]
    if thread.status == "open" then
      active[thread.id] = true
      if not old or not vim.deep_equal(old.anchor, thread.anchor) then
        forget_marker(buf, thread.id)
        doc = doc or anchor.snapshot(buf)
        local range = anchor.locate(doc, thread.anchor)
        if range then
          local mark = api.nvim_buf_set_extmark(buf, groups.ranges, range[1], range[2], {
            end_row = range[3],
            end_col = range[4],
            hl_group = thread.anchor.kind == "text" and "CommentThreadsRange" or nil,
            priority = 100,
            invalidate = true,
            right_gravity = true,
            end_right_gravity = false,
          })
          state.markers[thread.id] = { mark = mark, anchor = thread.anchor }
        end
      end
      local entry = state.markers[thread.id]
      local range = entry and mark_range(buf, entry.mark)
      if entry then
        sync_glyph(buf, entry, range)
      end
      if range then
        counts[range[1]] = (counts[range[1]] or 0) + 1
      end
    end
  end
  for id in pairs(state.markers) do
    if not active[id] then
      forget_marker(buf, id)
    end
  end
  for row, count in pairs(counts) do
    api.nvim_buf_set_extmark(buf, groups.signs, row, 0, {
      sign_text = count == 1 and options.sign or count > 9 and "9+" or tostring(count),
      sign_hl_group = "CommentThreadsSign",
    })
  end
  state.dirty = nil
  for view_buf, view in pairs(views) do
    if
      view.source == buf
      and (view.kind == "browser" or (view.root == root and view.path == path))
      and api.nvim_buf_is_loaded(view_buf)
      and view.refresh
    then
      view.refresh(state)
    end
  end
  return state
end

local function watch_changes()
  if watch or not options.live_updates then
    return
  end
  local data_home = vim.env.XDG_DATA_HOME
  if not data_home or data_home == "" then
    data_home = vim.fs.joinpath(vim.uv.os_homedir(), ".local", "share")
  end
  local directory = vim.fs.joinpath(data_home, "comment-threads")
  vim.fn.mkdir(directory, "p", tonumber("700", 8))
  local handle = vim.uv.new_fs_event()
  if not handle then
    return
  end
  local queued, all, scheduled = {}, false, false
  local success = handle:start(
    directory,
    {},
    vim.schedule_wrap(function(err, filename)
      if err then
        return
      end
      local key = filename and vim.fs.basename(filename):match("^([a-f0-9]+)%.changed$")
      if not key and filename and not vim.endswith(filename, "/comment-threads") and filename ~= "comment-threads" then
        return
      end
      if key then
        queued[key] = true
      else
        all = true
      end
      if scheduled then
        return
      end
      scheduled = true
      vim.defer_fn(function()
        scheduled = false
        if watch ~= handle then
          return
        end
        local visible = {}
        for _, win in ipairs(api.nvim_list_wins()) do
          local shown = api.nvim_win_get_buf(win)
          visible[shown] = true
          if views[shown] then
            visible[views[shown].source] = true
          end
        end
        for buf, state in pairs(states) do
          if all or queued[state.key] then
            if visible[buf] then
              refresh(buf, true)
            else
              state.dirty = true
            end
          end
        end
        queued, all = {}, false
      end, 80)
    end)
  )
  if success == nil then
    handle:close()
  else
    watch = handle
  end
end

refresh = function(buf, automatic)
  local root, path = source(buf)
  if not root then
    return nil
  end
  watch_changes()
  local args = { "list", "--all", "--path=" .. path }
  if automatic then
    if pending[buf] then
      pending[buf].again = true
      return
    end
    local request = {}
    pending[buf] = request
    call(root, args, nil, function(threads)
      if pending[buf] ~= request then
        return
      end
      pending[buf] = nil
      if not api.nvim_buf_is_loaded(buf) then
        return
      end
      local current_root, current_path = source(buf)
      if threads and current_root == root and current_path == path then
        render(buf, root, path, threads)
      end
      if request.again then
        refresh(buf, true)
      end
    end)
    return
  end
  pending[buf] = nil
  local threads = call(root, args)
  return threads and render(buf, root, path, threads)
end

local function undo_redo(action)
  local buf = api.nvim_get_current_buf()
  local root = views[buf] and views[buf].root or source(buf)
  local stack = root and history[root]
  local entries = stack and stack[action]
  local change = entries and entries[#entries]
  if not change then
    notice("No comment change to " .. action, vim.log.levels.INFO)
    return
  end
  local expected, replacement = change.after, change.before
  if action == "redo" then
    expected, replacement = replacement, expected
  end
  local result =
    call(root, { "restore", change.id }, vim.json.encode({ expected = expected, replacement = replacement }))
  if result == nil then
    return
  end
  table.remove(entries)
  local other = stack[action == "undo" and "redo" or "undo"]
  other[#other + 1] = change
  local path = (replacement or expected).path
  for target, state in pairs(states) do
    if state.root == root and state.path == path and api.nvim_buf_is_loaded(target) then
      refresh(target)
    end
  end
end

local function float(buf, title)
  local width = math.min(76, math.max(1, vim.o.columns - 8))
  local height = math.min(18, math.max(1, vim.o.lines - 6))
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  return win
end

local function docked_window(src)
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local panel = views[api.nvim_win_get_buf(win)]
    if panel and panel.source == src and api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
end

local function open_thread_window(buf, title, src, force_float)
  local win = not force_float and docked_window(src)
  if not win then
    if force_float or not options.sidebar_min_width or api.nvim_win_get_width(0) < options.sidebar_min_width then
      return float(buf, title)
    end
    vim.cmd(("botright %dvsplit"):format(options.sidebar_width))
    win = api.nvim_get_current_win()
  end
  api.nvim_win_set_buf(win, buf)
  api.nvim_set_current_win(win)
  vim.wo[win].winfixwidth = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].showbreak = ""
  vim.wo[win].winbar = "%#Title#  " .. title
  return win
end

local function compose(title, body, save, insert)
  local previous_win, previous_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  local previous_config = api.nvim_win_get_config(previous_win)
  local replace = views[previous_buf] and previous_config.relative ~= ""
  local previous_view = replace and vim.fn.winsaveview()
  local previous_hidden = replace and vim.bo[previous_buf].bufhidden
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "hide"
  api.nvim_buf_set_name(buf, "thread-draft://" .. buf)
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(body, "\n", { plain = true }))
  vim.bo[buf].modified = false
  local function text()
    return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end
  local function close()
    if
      replace
      and api.nvim_win_is_valid(previous_win)
      and api.nvim_win_get_buf(previous_win) == buf
      and api.nvim_buf_is_valid(previous_buf)
    then
      api.nvim_win_set_buf(previous_win, previous_buf)
      api.nvim_win_set_config(previous_win, { title = previous_config.title, title_pos = previous_config.title_pos })
      api.nvim_win_call(previous_win, function()
        vim.fn.winrestview(previous_view)
      end)
    end
    if replace and api.nvim_buf_is_valid(previous_buf) then
      vim.bo[previous_buf].bufhidden = previous_hidden
    end
    vim.bo[buf].modified = false
    api.nvim_buf_delete(buf, {})
  end
  api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local draft = text()
      if vim.trim(draft) == "" then
        notice("Comment text cannot be empty")
        return
      end
      local saved = save(draft)
      if saved then
        close()
        saved()
      end
    end,
  })
  local keys = options.mappings.composer or {}
  if keys.close then
    vim.keymap.set("n", keys.close, function()
      local draft = text()
      if
        draft == body
        or vim.trim(draft) == ""
        or vim.fn.confirm("Discard this unsaved draft?", "&Discard\n&Keep editing", 2, "Warning") == 1
      then
        close()
      end
    end, { buffer = buf, desc = "Close comment composer" })
  end
  local caption = title .. " · :w to save" .. (keys.close and " · " .. keys.close .. " to cancel" or "")
  if replace then
    vim.bo[previous_buf].bufhidden = "hide"
    api.nvim_win_set_buf(previous_win, buf)
    api.nvim_win_set_config(previous_win, { title = " " .. caption .. " " })
  else
    float(buf, caption)
  end
  vim.bo[buf].filetype = "markdown"
  if keys.post then
    local mapping = { buffer = buf, desc = "Post comment" }
    vim.keymap.set("n", keys.post, "<cmd>write<cr>", mapping)
    vim.keymap.set("i", keys.post, "<esc><cmd>write<cr>", mapping)
  end
  if insert then
    vim.cmd.startinsert()
  end
end

local function author_label(author)
  local name = author:gsub("[\r\n]", " ")
  local key = name:lower():gsub("[^%w]", "")
  local icons = options.author_icons
  local icon = icons[key] or (key == "claudecode" and icons.claude) or icons.human or "●"
  return icon .. " " .. name
end

local function reply(root, thread, on_saved)
  compose("Reply", "", function(body)
    local updated = call(root, { "reply", thread.id, "--author", options.author }, body)
    return updated and function()
      on_saved(updated)
    end
  end, true)
end

local function edit(root, thread, msg, on_saved)
  compose("Edit comment", msg.body, function(body)
    local updated = call(root, { "edit", thread.id, tostring(msg.id), "--revision", tostring(msg.revision) }, body)
    return updated and function()
      on_saved(updated)
    end
  end)
end

local function toggle(root, thread)
  local action = thread.status == "open" and "resolve" or "reopen"
  return call(root, { action, thread.id, "--author", options.author })
end

local function delete(root, thread, msg, on_deleted)
  local prompt = "Delete this message from " .. msg.author .. "?"
  if #thread.messages == 1 then
    prompt = prompt .. "\nIf it is still the last message, this also removes the thread."
  end
  if vim.fn.confirm(prompt, "&Delete\n&Cancel", 2, "Warning") == 1 then
    if call(root, { "delete", thread.id, tostring(msg.id), "--revision", tostring(msg.revision) }) then
      on_deleted()
    end
  end
end

local function view(root, thread, src, existing)
  local id = thread.id
  local buf = existing
  local source_win = api.nvim_get_current_buf() == src and api.nvim_get_current_win() or vim.fn.bufwinid(src)
  if not buf then
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      local shown = api.nvim_win_get_buf(win)
      if
        views[shown]
        and views[shown].source == src
        and views[shown].kind == "thread"
        and api.nvim_win_get_config(win).relative == ""
      then
        api.nvim_set_current_win(win)
        buf = shown
        break
      end
    end
    if not buf then
      buf = api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "wipe"
      api.nvim_buf_set_name(buf, ("comments://%d/Thread"):format(buf))
      local win =
        open_thread_window(buf, options.sign .. "  Comment thread", src, views[api.nvim_get_current_buf()] ~= nil)
      vim.bo[buf].filetype = "comment-threads"
      vim.wo[win].spell = false
      vim.wo[win].list = false
    end
  end
  local function update(updated, repaint)
    if repaint and api.nvim_buf_is_loaded(src) then
      refresh(src)
    end
    if updated and api.nvim_buf_is_valid(buf) then
      view(root, updated, src, buf)
    end
  end
  local state = states[src]
  local mark = state and state.markers[id]
  local range = mark and mark_range(src, mark.mark)
  local location = range and ":" .. (range[1] + 1) or ""
  local buttons, messages, authors = {}, {}, {}
  local win = vim.fn.bufwinid(buf)
  local width = win ~= -1 and api.nvim_win_get_width(win) or (views[buf] and views[buf].width or options.sidebar_width)
  local compact = width < options.compact_width
  local keys = options.mappings.thread or {}
  local missing
  local function show_deleted()
    missing = true
    views[buf].click = nil
    views[buf].resize = nil
    for action, key in pairs(keys) do
      if action ~= "close" and action ~= "undo" and action ~= "redo" then
        pcall(vim.keymap.del, "n", key, { buffer = buf })
      end
    end
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, {
      "Thread deleted",
      keys.undo and ("Press " .. keys.undo .. " to undo.") or "Use :ThreadUndo to restore it.",
    })
    vim.bo[buf].modifiable = false
    api.nvim_buf_clear_namespace(buf, groups.thread, 0, -1)
  end
  local function button_label(label)
    return compact and action_icons[label] or label
  end
  views[buf] = {
    kind = "thread",
    source = src,
    source_win = views[buf] and views[buf].source_win or source_win,
    root = root,
    path = thread.path,
    width = width,
    resize = function(current_width)
      if current_width ~= width then
        view(root, thread, src, buf)
      end
    end,
    click = function(row, col)
      return controls.hit(buttons, row, col)
    end,
    refresh = function(fresh)
      local latest = vim.iter(fresh.threads):find(function(item)
        return item.id == id
      end)
      local marker = fresh.markers[id]
      local current = marker and mark_range(src, marker.mark)
      if not latest then
        if not missing then
          show_deleted()
        end
      elseif missing or not vim.deep_equal(latest, thread) or not vim.deep_equal(current, range) then
        view(root, latest, src, buf)
      end
    end,
  }
  local status = thread.status == "open" and "Open" or "Resolved"
  if thread.status_by then
    status = status .. " by " .. thread.status_by
  end
  if thread.status == "open" and not range then
    status = status .. " · needs reattach"
  end
  local function one_line(text)
    return (text:gsub("[\r\n]", " "))
  end
  local actions = {}
  actions.close = function()
    api.nvim_win_close(0, false)
  end
  actions.refresh = function()
    local source_state = api.nvim_buf_is_loaded(src) and refresh(src)
    local latest
    if source_state then
      latest = vim.iter(source_state.threads):find(function(item)
        return item.id == id
      end)
    end
    update(latest or (not source_state and call(root, { "show", id })))
  end
  actions.reply = function()
    reply(root, thread, update)
  end
  actions.toggle = function()
    local updated = toggle(root, thread)
    update(updated, updated ~= nil)
  end
  local lines = { one_line(status .. " · " .. thread.path .. location), "" }
  for i, line in ipairs(vim.split(thread.anchor.quote, "\n", { plain = true })) do
    lines[#lines + 1] = (i == 1 and options.sign or string.rep(" ", vim.fn.strdisplaywidth(options.sign)))
      .. "  "
      .. line
  end
  local quote_end = #lines
  for _, msg in ipairs(thread.messages) do
    lines[#lines + 1] = ""
    local time = compact and msg.created_at:match("%d%d:%d%d") or msg.created_at
    lines[#lines + 1] = author_label(msg.author) .. " · " .. time .. (msg.edited_at and " (edited)" or "")
    authors[#lines] = #lines[#lines]
    messages[#lines] = msg
    local edit_label, delete_label = button_label("Edit"), button_label("Delete")
    if
      not controls.fits(
        width,
        lines[#lines],
        controls.label(edit_label, keys.edit),
        controls.label(delete_label, keys.delete)
      )
    then
      lines[#lines + 1] = ""
      messages[#lines] = msg
    end
    controls.add(buttons, lines, edit_label, function()
      edit(root, thread, msg, update)
    end, nil, keys.edit)
    controls.add(buttons, lines, delete_label, function()
      delete(root, thread, msg, actions.refresh)
    end, "Danger", keys.delete)
    for _, line in ipairs(vim.split(msg.body, "\n", { plain = true })) do
      lines[#lines + 1] = line
      messages[#lines] = msg
    end
  end
  vim.list_extend(lines, { "", "" })
  local footer = {
    { "Reply", "reply", "Primary" },
    { thread.status == "open" and "Resolve" or "Reopen", "toggle", "Positive" },
    { "Refresh", "refresh" },
    { "Close", "close" },
  }
  local labels = vim.tbl_map(function(button)
    return controls.label(button_label(button[1]), keys[button[2]])
  end, footer)
  local two_rows = not controls.fits(width, "", unpack(labels))
  for i, button in ipairs(footer) do
    local label, action, style = unpack(button)
    local line = lines[#lines]
    if line ~= "" and ((two_rows and i == 3) or not controls.fits(width, line, labels[i])) then
      lines[#lines + 1] = ""
    end
    controls.add(buttons, lines, button_label(label), actions[action], style, keys[action])
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  if not existing then
    api.nvim_win_set_cursor(0, { 1, 0 })
  end
  api.nvim_buf_clear_namespace(buf, groups.thread, 0, -1)
  local function paint(row, hl, end_col)
    api.nvim_buf_set_extmark(buf, groups.thread, row - 1, 0, { end_col = end_col or #lines[row], hl_group = hl })
  end
  for row = 3, quote_end do
    paint(row, "CommentThreadsCardQuote")
  end
  for row, end_col in pairs(authors) do
    paint(row, "CommentThreadsCardAuthor", end_col)
  end
  controls.paint(buf, groups.thread, buttons)
  actions.activate = function()
    local row, col = unpack(api.nvim_win_get_cursor(0))
    local run = controls.hit(buttons, row, col + 1)
    if run then
      run()
    end
  end
  actions.undo = function()
    undo_redo("undo")
  end
  actions.redo = function()
    undo_redo("redo")
  end
  local message_actions = {
    edit = function(msg)
      edit(root, thread, msg, update)
    end,
    delete = function(msg)
      delete(root, thread, msg, actions.refresh)
    end,
  }
  for action, key in pairs(keys) do
    if message_actions[action] then
      controls.map_on_message(buf, key, function(row)
        return messages[row]
      end, message_actions[action])
    elseif actions[action] then
      vim.keymap.set("n", key, actions[action], { buffer = buf })
    end
  end
end

local function select_thread(buf, threads, title, cb)
  if #threads == 0 then
    notice("No matching comment threads")
    return
  end
  vim.ui.select(threads, {
    prompt = title,
    format_item = function(thread)
      local state = states[buf]
      local item = state and state.markers[thread.id]
      local range = item and mark_range(buf, item.mark)
      local where = range and ("L%d:%d"):format(range[1] + 1, range[2] + 1)
        or (thread.status == "resolved" and "Resolved" or "needs reattach")
      return where .. " · " .. thread.messages[1].body:gsub("\n.*", "")
    end,
  }, function(thread)
    if thread then
      cb(thread)
    end
  end)
end

local function show_browser(source_win, src, filter, dock)
  local name = api.nvim_buf_get_name(src)
  local state = states[src] or { path = name == "" and "[No file]" or vim.fs.basename(name), threads = {} }
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local title = ({ all = "Comments", open = "Open threads", resolved = "Resolved threads" })[filter]
  api.nvim_buf_set_name(buf, ("comments://%d/%s"):format(buf, title))
  local win = dock
  if dock then
    api.nvim_win_set_buf(dock, buf)
    vim.wo[dock].winbar = "%#Title#  " .. title
  else
    if api.nvim_get_current_win() ~= source_win then
      api.nvim_set_current_win(source_win)
    end
    win = open_thread_window(buf, title, src)
  end
  vim.bo[buf].filetype = "comment-threads"
  vim.wo[win].spell = false
  vim.wo[win].list = false
  vim.wo[win].scrolloff = 0
  vim.wo[win].showbreak = "│  "
  local function range_for(id)
    local current = states[src]
    local entry = current and current.markers[id]
    return entry and mark_range(src, entry.mark)
  end
  local preview_id, preview_range, resolved_anchor
  local function clear_preview()
    if preview_owner[src] == buf then
      if api.nvim_buf_is_loaded(src) then
        api.nvim_buf_clear_namespace(src, groups.preview, 0, -1)
      end
      preview_owner[src] = nil
    end
    preview_id, preview_range = nil, nil
  end
  local function preview(thread)
    if
      not thread
      or not api.nvim_buf_is_loaded(src)
      or not api.nvim_win_is_valid(source_win)
      or api.nvim_win_get_buf(source_win) ~= src
    then
      clear_preview()
      return
    end
    local range = range_for(thread.id)
    if not range and thread.status == "resolved" then
      local tick = api.nvim_buf_get_changedtick(src)
      if
        not resolved_anchor
        or resolved_anchor.tick ~= tick
        or resolved_anchor.id ~= thread.id
        or not vim.deep_equal(resolved_anchor.anchor, thread.anchor)
      then
        resolved_anchor = {
          tick = tick,
          id = thread.id,
          anchor = thread.anchor,
          range = anchor.locate(anchor.snapshot(src), thread.anchor),
        }
      end
      range = resolved_anchor.range
    end
    if preview_owner[src] == buf and preview_id == thread.id and vim.deep_equal(range, preview_range) then
      return
    end
    clear_preview()
    if not range then
      return
    end
    api.nvim_buf_clear_namespace(src, groups.preview, 0, -1)
    api.nvim_buf_set_extmark(src, groups.preview, range[1], range[2], {
      end_row = range[3],
      end_col = range[4],
      hl_group = "CommentThreadsFocusedRange",
      line_hl_group = thread.anchor.kind == "line" and range[1] == range[3] and "CommentThreadsFocusedRange" or nil,
      hl_eol = thread.anchor.kind == "line",
      priority = 250,
    })
    preview_owner[src], preview_id, preview_range = buf, thread.id, range
    local row = range[1] + 1
    if row < vim.fn.line("w0", source_win) or row > vim.fn.line("w$", source_win) then
      api.nvim_win_set_cursor(source_win, { row, range[2] })
    end
  end
  local browser =
    require("comment_threads.browser").open(buf, win, source_win, filter, options.mappings.browser or {}, {
      icon = options.sign,
      author = author_label,
      undo_redo = undo_redo,
      range = range_for,
      compact_width = options.compact_width,
      action_icons = action_icons,
      preview = preview,
      open = function(thread)
        local current = states[src]
        if current then
          view(current.root, thread, src)
        end
      end,
      action = function(action, thread, msg)
        local current = states[src]
        if not current then
          return
        end
        local root = current.root
        local function reload()
          if api.nvim_buf_is_loaded(src) then
            refresh(src)
          end
        end
        if action == "reply" then
          reply(root, thread, reload)
        elseif action == "toggle" then
          if toggle(root, thread) then
            reload()
          end
        elseif msg and action == "edit" then
          edit(root, thread, msg, reload)
        elseif msg and action == "delete" then
          delete(root, thread, msg, reload)
        end
      end,
    })
  local panel = {
    kind = "browser",
    source = src,
    source_win = source_win,
    root = state.root,
    path = state.path,
    filter = filter,
    resize = function()
      if states[src] then
        browser.render(states[src])
      end
    end,
    click = browser.click,
  }
  panel.refresh = function(fresh)
    panel.root, panel.path = fresh.root, fresh.path
    browser.render(fresh)
  end
  views[buf] = panel
  api.nvim_create_autocmd({ "CursorMoved", "BufEnter", "WinEnter" }, { buffer = buf, callback = browser.preview })
  api.nvim_create_autocmd({ "WinLeave", "BufWipeout" }, { buffer = buf, callback = clear_preview })
  if api.nvim_win_get_config(win).relative == "" then
    local follow = api.nvim_create_autocmd("CursorMoved", {
      buffer = src,
      callback = function()
        if
          api.nvim_win_is_valid(win)
          and api.nvim_win_get_buf(win) == buf
          and api.nvim_win_is_valid(source_win)
          and api.nvim_win_get_buf(source_win) == src
        then
          browser.follow()
        end
      end,
    })
    api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        pcall(api.nvim_del_autocmd, follow)
      end,
    })
  end
  browser.render(state)
end

local function browse(filter)
  local src = api.nvim_get_current_buf()
  local source_win = api.nvim_get_current_win()
  local panel = views[src]
  if panel then
    local previous = source_win
    src = panel.source
    source_win = panel.source_win or vim.fn.bufwinid(src)
    if source_win == -1 or not api.nvim_win_is_valid(source_win) or api.nvim_win_get_buf(source_win) ~= src then
      notice("Open the source file to browse its comments")
      return
    end
    if panel.kind == "thread" and api.nvim_win_get_config(previous).relative ~= "" then
      api.nvim_win_close(previous, false)
    end
  end
  refresh(src)
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local existing = views[api.nvim_win_get_buf(win)]
    if existing and existing.source == src and existing.kind == "browser" then
      if existing.filter == filter then
        api.nvim_set_current_win(win)
        return
      end
      if api.nvim_win_get_config(win).relative ~= "" then
        api.nvim_win_close(win, false)
      end
      break
    end
  end
  show_browser(source_win, src, filter)
end

local function retarget_sidebar(src)
  if views[src] or vim.bo[src].buftype == "acwrite" then
    return
  end
  local source_win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(source_win) ~= src then
    return
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local shown = api.nvim_win_get_buf(win)
    local panel = views[shown]
    if
      panel
      and panel.source_win == source_win
      and panel.source ~= src
      and api.nvim_win_get_config(win).relative == ""
    then
      vim.schedule(function()
        if
          api.nvim_win_is_valid(source_win)
          and api.nvim_win_get_buf(source_win) == src
          and api.nvim_win_is_valid(win)
          and api.nvim_win_get_buf(win) == shown
        then
          show_browser(source_win, src, panel.filter or "all", win)
        end
      end)
    end
  end
end

local function capture(mode, line1, line2)
  local buf = api.nvim_get_current_buf()
  local root, path = source(buf)
  if not root or vim.bo[buf].modified then
    notice("Save the source file before annotating it")
    return nil
  end
  local first, last
  if mode == "V" or mode == "v" or mode == "\22" then
    first, last = vim.fn.getpos("v"), vim.fn.getpos(".")
    if mode == "V" and first[2] > last[2] then
      first, last = last, first
    end
    vim.cmd("normal! \27")
  else
    first, last, mode = { 0, line1, 1, 0 }, { 0, line2, 1, 0 }, "V"
  end
  local target, error_msg = anchor.capture(buf, first, last, mode)
  if not target then
    notice(error_msg)
    return nil
  end
  return target, buf, root, path
end

local function add(mode, line1, line2)
  local target, buf, root, path = capture(mode, line1, line2)
  if target then
    compose("New comment", "", function(body)
      local thread = call(
        root,
        { "create", "--author", options.author },
        vim.json.encode({
          path = path,
          anchor = target,
          body = body,
        })
      )
      if thread then
        return function()
          if api.nvim_buf_is_loaded(buf) then
            refresh(buf)
          end
          view(root, thread, buf)
        end
      end
    end, true)
  end
end

local function reattach(mode, line1, line2)
  local target, buf, root = capture(mode, line1, line2)
  local state = target and refresh(buf)
  if state then
    select_thread(buf, state.threads, "Reattach which thread?", function(thread)
      local updated = call(root, { "attach", thread.id }, vim.json.encode(target))
      if updated and api.nvim_buf_is_loaded(buf) then
        forget_marker(buf, thread.id)
        refresh(buf)
        view(root, updated, buf)
      end
    end)
  end
end

local function at_cursor()
  local buf = api.nvim_get_current_buf()
  local state = refresh(buf)
  if not state then
    return
  end
  local row, col = unpack(api.nvim_win_get_cursor(0))
  row = row - 1
  local exact, on_line = {}, {}
  for _, thread in ipairs(state.threads) do
    local item = state.markers[thread.id]
    local range = item and mark_range(buf, item.mark)
    if range and range[1] <= row and row <= range[3] then
      on_line[#on_line + 1] = thread
      if
        thread.anchor.kind == "line"
        or ((row > range[1] or col >= range[2]) and (row < range[3] or col < range[4]))
      then
        exact[#exact + 1] = thread
      end
    end
  end
  local matches = #exact > 0 and exact or on_line
  if #matches == 1 then
    view(state.root, matches[1], buf)
  else
    select_thread(buf, matches, "Open thread", function(thread)
      view(state.root, thread, buf)
    end)
  end
end

local function jump(direction)
  local buf = api.nvim_get_current_buf()
  if not (states[buf] or refresh(buf)) then
    return
  end
  local positions = {}
  local line_count = api.nvim_buf_line_count(buf)
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, groups.ranges, 0, -1, { details = true })) do
    if not mark[4].invalid and mark[2] < line_count then
      local row, col = mark[2] + 1, mark[3]
      local line = api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
      if #line > 0 and col >= #line then
        col = vim.fn.byteidx(line, vim.fn.charidx(line, #line - 1))
      end
      local last = positions[#positions]
      if not last or row ~= last[1] or col ~= last[2] then
        positions[#positions + 1] = { row, col }
      end
    end
  end
  if #positions == 0 then
    notice("No attached open threads in this file")
    return
  end
  local row, col = unpack(api.nvim_win_get_cursor(0))
  local next_index, prev_index = 1, #positions
  for i, pos in ipairs(positions) do
    if pos[1] > row or (pos[1] == row and pos[2] > col) then
      next_index = i
      break
    end
  end
  for i = #positions, 1, -1 do
    local pos = positions[i]
    if pos[1] < row or (pos[1] == row and pos[2] < col) then
      prev_index = i
      break
    end
  end
  local start = direction > 0 and next_index or prev_index
  local index = (start - 1 + direction * (vim.v.count1 - 1)) % #positions + 1
  api.nvim_win_set_cursor(0, positions[index])
  vim.cmd("normal! zv")
end

function M.add_selection()
  add(vim.fn.mode())
end

function M.reattach_selection()
  reattach(vim.fn.mode())
end

function M.jump(direction)
  jump(direction)
end

function M.click()
  local pos = vim.fn.getmousepos()
  if not api.nvim_win_is_valid(pos.winid) or pos.winid == 0 then
    return "<LeftMouse>"
  end
  local buf = api.nvim_win_get_buf(pos.winid)
  local panel = views[buf]
  local action = panel and panel.click and panel.click(pos.line, pos.column)
  if not action then
    return "<LeftMouse>"
  end
  vim.schedule(function()
    if api.nvim_win_is_valid(pos.winid) and api.nvim_win_get_buf(pos.winid) == buf then
      api.nvim_set_current_win(pos.winid)
      api.nvim_win_set_cursor(pos.winid, { pos.line, pos.column - 1 })
      action()
    end
  end)
  return ""
end

function M.setup(opts)
  options = vim.tbl_extend("force", {
    cli = plugin .. "/bin/comment-threads",
    author = vim.env.USER or vim.env.USERNAME or "human",
    mappings = {},
    sidebar_min_width = 108,
    sidebar_width = 42,
    compact_width = 56,
    glyph = "",
    sign = "",
    live_updates = true,
    author_icons = {},
  }, opts or {})
  if watch and not options.live_updates then
    watch:close()
    watch = nil
  end
  if vim.fn.executable(options.cli) ~= 1 then
    notice("Cannot execute " .. options.cli)
    return
  end
  local function highlights()
    local light = vim.o.background == "light"
    api.nvim_set_hl(0, "CommentThreadsRange", {
      default = true,
      bg = light and "#fff0a8" or "#594719",
      fg = light and "#322600" or "#fff1ad",
      ctermbg = light and 229 or 58,
      ctermfg = light and 232 or 229,
    })
    api.nvim_set_hl(0, "CommentThreadsSign", { default = true, fg = light and "#765300" or "#efc75e", ctermfg = 178 })
    api.nvim_set_hl(0, "CommentThreadsCardHeader", {
      default = true,
      fg = light and "#566078" or "#aab3ca",
      bold = true,
    })
    api.nvim_set_hl(0, "CommentThreadsCardActive", {
      default = true,
      fg = light and "#252b38" or "#e7edf9",
      bold = true,
    })
    api.nvim_set_hl(0, "CommentThreadsCardAccent", { default = true, fg = light and "#46698d" or "#86aadd" })
    api.nvim_set_hl(0, "CommentThreadsFocusedRange", {
      default = true,
      fg = light and "#1c4269" or "#e7f2ff",
      bg = light and "#c2ddf7" or "#315783",
      bold = true,
    })
    api.nvim_set_hl(0, "CommentThreadsCardBorder", { default = true, link = "Comment" })
    api.nvim_set_hl(0, "CommentThreadsCardResolved", { default = true, link = "Comment" })
    api.nvim_set_hl(0, "CommentThreadsCardQuote", {
      default = true,
      fg = light and "#5c6271" or "#aab3ca",
      italic = true,
    })
    api.nvim_set_hl(0, "CommentThreadsCardAuthor", {
      default = true,
      fg = light and "#374151" or "#d6ddef",
      bold = true,
    })
    local button_colors = light
        and {
          Primary = { "#183c71", "#d9e8ff", "#506483", "#f1f6ff" },
          Positive = { "#21513a", "#d9efe2", "#506e5d", "#effaf2" },
          Neutral = { "#364052", "#e5e9f2", "#616a7b", "#f7f9fd" },
          Danger = { "#862f3d", "#f8dfe3", "#80545e", "#fff3f5" },
        }
      or {
        Primary = { "#e1edff", "#30466e", "#a6b9d7", "#4f6c9c" },
        Positive = { "#d3eddb", "#294837", "#a3bcad", "#426b53" },
        Neutral = { "#e2e7f1", "#323a50", "#aab4ca", "#535e78" },
        Danger = { "#ffd7df", "#542f3e", "#cfadb7", "#784859" },
      }
    for style, colors in pairs(button_colors) do
      api.nvim_set_hl(0, "CommentThreadsButton" .. style, {
        default = true,
        bold = true,
        fg = colors[1],
        bg = colors[2],
      })
      api.nvim_set_hl(0, "CommentThreadsButtonHint" .. style, {
        default = true,
        fg = colors[3],
        bg = colors[2],
      })
      api.nvim_set_hl(0, "CommentThreadsButtonPressed" .. style, {
        default = true,
        bold = true,
        fg = colors[1],
        bg = colors[4],
      })
    end
  end
  highlights()
  local group = api.nvim_create_augroup("CommentThreads", { clear = true })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })
  api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      for _, win in ipairs(vim.v.event.windows or {}) do
        if api.nvim_win_is_valid(win) then
          local panel = views[api.nvim_win_get_buf(win)]
          if panel and panel.resize then
            panel.resize(api.nvim_win_get_width(win))
          end
        end
      end
    end,
  })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    callback = function(ev)
      local state = states[ev.buf]
      if state then
        for _, item in pairs(state.markers) do
          if item.anchor.kind == "text" then
            sync_glyph(ev.buf, item, mark_range(ev.buf, item.mark))
          end
        end
      end
    end,
  })
  api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if watch then
        watch:close()
        watch = nil
      end
    end,
  })
  api.nvim_create_autocmd({ "BufReadPost", "BufFilePost", "BufWipeout" }, {
    group = group,
    callback = function(ev)
      states[ev.buf] = nil
      pending[ev.buf] = nil
      views[ev.buf] = nil
      if ev.event ~= "BufWipeout" then
        api.nvim_buf_clear_namespace(ev.buf, groups.ranges, 0, -1)
        api.nvim_buf_clear_namespace(ev.buf, groups.signs, 0, -1)
        api.nvim_buf_clear_namespace(ev.buf, groups.glyph, 0, -1)
        api.nvim_buf_clear_namespace(ev.buf, groups.preview, 0, -1)
        preview_owner[ev.buf] = nil
        refresh(ev.buf, true)
      end
    end,
  })
  api.nvim_create_autocmd({ "BufEnter", "FocusGained", "BufWritePost" }, {
    group = group,
    callback = function(ev)
      local state = states[ev.buf]
      if ev.event ~= "BufEnter" or ((not state or state.dirty) and not pending[ev.buf]) then
        refresh(ev.buf, true)
      end
    end,
  })
  api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      retarget_sidebar(ev.buf)
    end,
  })
  local function range_command(name, fn)
    api.nvim_create_user_command(name, function(cmd)
      fn(nil, cmd.line1, cmd.line2)
    end, { range = true })
  end
  range_command("ThreadAdd", add)
  range_command("ThreadReattach", reattach)
  api.nvim_create_user_command("ThreadOpen", at_cursor, {})
  api.nvim_create_user_command("ThreadUndo", function()
    undo_redo("undo")
  end, {})
  api.nvim_create_user_command("ThreadRedo", function()
    undo_redo("redo")
  end, {})
  api.nvim_create_user_command("ThreadRefresh", function()
    refresh(api.nvim_get_current_buf())
  end, {})
  api.nvim_create_user_command("ThreadList", function(cmd)
    local status = cmd.args == "" and "all" or cmd.args
    if status ~= "all" and status ~= "open" and status ~= "resolved" then
      notice("Use :ThreadList open, resolved, or all")
      return
    end
    browse(status)
  end, {
    nargs = "?",
    complete = function()
      return { "open", "resolved", "all" }
    end,
  })
  api.nvim_create_user_command("ThreadHandoff", function()
    local root = source(api.nvim_get_current_buf())
    if root then
      local command = vim.fn.shellescape(options.cli) .. " --root " .. vim.fn.shellescape(root)
      local prompt = "Review the open comment threads in this worktree: run "
        .. command
        .. " list. Verify each anchor quote before editing; ask if it no longer matches. "
        .. "Use the same CLI to reply with --author and the thread ID. Leave threads open for my review unless asked to resolve."
      vim.fn.setreg("+", prompt)
      notice("Agent handoff copied to the clipboard", vim.log.levels.INFO)
    end
  end, {})
  refresh(api.nvim_get_current_buf(), true)
end

return M
