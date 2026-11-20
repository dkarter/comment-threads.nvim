local api = vim.api
local controls = require("comment_threads.buttons")
local ns = api.nvim_create_namespace("comment_threads.browser")
local corner = "╭─"
local rail = "│"
local inset = rail .. "  "
local button_styles = { reply = "Primary", toggle = "Positive", delete = "Danger" }
local M = {}

function M.open(buf, win, source_win, filter, legacy, callbacks)
  local keys = controls.keys(buf, legacy)
  keys.jump = keys.jump or keys.activate
  local sections = {}
  local buttons, messages = {}, {}
  local folds = {}
  local active_id, last_source_position
  local function pin(row)
    api.nvim_win_call(win, function()
      vim.fn.winrestview({ lnum = row, col = 0, topline = row, topfill = 0, skipcol = 0, leftcol = 0 })
    end)
  end

  local function paint_header(section)
    local active = section.thread.id == active_id
    section.accent = api.nvim_buf_set_extmark(buf, ns, section.header - 1, 0, {
      id = section.accent,
      end_col = #corner,
      hl_group = active and "CommentThreadsCardAccent" or "CommentThreadsCardBorder",
    })
    section.label = api.nvim_buf_set_extmark(buf, ns, section.header - 1, section.header_start, {
      id = section.label,
      end_col = section.header_end,
      hl_group = section.thread.status == "resolved" and "CommentThreadsCardResolved"
        or (active and "CommentThreadsCardActive" or "CommentThreadsCardHeader"),
    })
  end

  local function current_section(row)
    for i = #sections, 1, -1 do
      if row >= sections[i].header then
        return sections[i]
      end
    end
  end
  local function set_active(section)
    local id = section and section.thread.id
    if id ~= active_id then
      local previous = active_id
      active_id = id
      for _, item in ipairs(sections) do
        if item.thread.id == previous or item.thread.id == id then
          paint_header(item)
        end
      end
    end
  end

  local function preview()
    if api.nvim_get_current_win() == win then
      local section = current_section(api.nvim_win_get_cursor(win)[1])
      set_active(section)
      callbacks.preview(section and section.thread)
      last_source_position = nil
    end
  end

  local function follow()
    if
      not api.nvim_win_is_valid(win)
      or not api.nvim_win_is_valid(source_win)
      or api.nvim_get_current_win() ~= source_win
    then
      return
    end
    local row, col = unpack(api.nvim_win_get_cursor(source_win))
    local position = ("%d:%d"):format(row, col)
    if position == last_source_position then
      return
    end
    last_source_position = position
    local first, before, on_line_first, on_line_before
    for _, section in ipairs(sections) do
      local range = callbacks.range(section.thread.id)
      if range then
        first = first or section
        if range[1] < row - 1 then
          before = section
        elseif range[1] == row - 1 then
          on_line_first = on_line_first or section
          if range[2] <= col then
            on_line_before = section
          end
        end
      end
    end
    local nearest = on_line_before or on_line_first or before or first
    if nearest then
      set_active(nearest)
      if vim.fn.line("w0", win) ~= nearest.header then
        pin(nearest.header)
      end
    end
  end

  local function render(state)
    local old_view = api.nvim_win_call(win, vim.fn.winsaveview)
    local previous = current_section(old_view.lnum)
    local previous_top = current_section(old_view.topline)
    local previous_offset = previous and old_view.lnum - previous.header or 0
    local items = {}
    for i, thread in ipairs(state.threads) do
      if filter == "all" or thread.status == filter then
        items[#items + 1] = { thread = thread, order = i, range = callbacks.range(thread.id) }
      end
    end
    table.sort(items, function(a, b)
      if not a.range or not b.range then
        return a.range ~= nil or (not b.range and a.order < b.order)
      end
      if a.range[1] ~= b.range[1] then
        return a.range[1] < b.range[1]
      end
      if a.range[2] ~= b.range[2] then
        return a.range[2] < b.range[2]
      end
      return a.order < b.order
    end)
    local lines = {
      "Comments · " .. state.path:gsub("[\r\n]", " "),
      "",
      ("%d %s"):format(#items, #items == 1 and "thread" or "threads"),
    }
    local hints = {}
    for _, action in ipairs({ { "jump", "go to text" }, { "open", "open thread" }, { "close", "close" } }) do
      if keys[action[1]] then
        hints[#hints + 1] = keys[action[1]] .. " " .. action[2]
      end
    end
    if #hints > 0 then
      lines[#lines + 1] = table.concat(hints, " · ")
    end
    local next_sections = {}
    buttons, messages = {}, {}
    local paint = {}
    local target, top
    local compact = api.nvim_win_get_width(win) < callbacks.compact_width
    local function button(label, action, thread, msg, style)
      controls.add(buttons, lines, compact and callbacks.action_icons[label] or label, function()
        callbacks.action(action, thread, msg)
      end, style or button_styles[action], compact and keys[action] or nil)
    end
    for index, item in ipairs(items) do
      local thread, range = item.thread, item.range
      local resolved = thread.status == "resolved"
      local fold = folds[thread.id]
      if fold and fold.status ~= thread.status then
        folds[thread.id] = nil
        fold = nil
      end
      local collapsed = resolved
      if fold then
        collapsed = fold.collapsed
      end
      lines[#lines + 1] = ""
      local header = #lines + 1
      local status = resolved and "Resolved" or "Open"
      local location = range and ("L%d:%d"):format(range[1] + 1, range[2] + 1)
        or (thread.status == "open" and "Needs reattach" or ("L%d"):format(thread.anchor.line))
      local function set_fold(value)
        if value == nil then
          value = not collapsed
        end
        if value == collapsed then
          return
        end
        folds[thread.id] = { status = thread.status, collapsed = value }
        render(state)
      end
      lines[header] = collapsed and "╶─" or corner
      controls.add(buttons, lines, collapsed and "▸" or "▾", set_fold)
      local header_start = #lines[header] + 1
      lines[header] = lines[header] .. (" %02d  %s · %s"):format(index, status, location)
      local header_end = #lines[header]
      if resolved then
        button("Reopen", "toggle", thread, nil, "Neutral")
      else
        button("Resolve", "toggle", thread)
      end
      if not collapsed then
        lines[#lines + 1] = rail
        for i, line in ipairs(vim.split(thread.anchor.quote, "\n", { plain = true })) do
          lines[#lines + 1] = inset
            .. (i == 1 and callbacks.icon or string.rep(" ", vim.fn.strdisplaywidth(callbacks.icon)))
            .. " "
            .. line
          paint[#lines] = "CommentThreadsCardQuote"
        end
        for _, msg in ipairs(thread.messages) do
          lines[#lines + 1] = rail
          lines[#lines + 1] = inset .. callbacks.author(msg.author) .. (msg.edited_at and " (edited)" or "")
          messages[#lines] = msg
          paint[#lines] = "CommentThreadsCardAuthor"
          button("Edit", "edit", thread, msg)
          button("Delete", "delete", thread, msg)
          for _, line in ipairs(vim.split(msg.body, "\n", { plain = true })) do
            lines[#lines + 1] = inset .. line
            messages[#lines] = msg
          end
        end
        lines[#lines + 1] = rail
        lines[#lines + 1] = inset:sub(1, -2)
        button("Reply", "reply", thread)
        lines[#lines + 1] = "╰─"
      end
      next_sections[#next_sections + 1] = {
        header = header,
        header_start = header_start,
        header_end = header_end,
        thread = thread,
        fold = set_fold,
        toggle_header = (collapsed or resolved) and set_fold or nil,
      }
      if previous and previous.thread.id == thread.id then
        target = math.min(header + previous_offset, #lines)
      end
      if previous_top and previous_top.thread.id == thread.id then
        top = math.min(header + old_view.topline - previous_top.header, #lines)
      end
    end
    local old_sections = sections
    sections = next_sections
    if not vim.deep_equal(lines, api.nvim_buf_get_lines(buf, 0, -1, false)) then
      vim.bo[buf].modifiable = true
      api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
      api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      for _, section in ipairs(sections) do
        paint_header(section)
      end
      for row, hl in pairs(paint) do
        local end_col = buttons[row] and buttons[row][1].start - 1 or #lines[row]
        api.nvim_buf_set_extmark(buf, ns, row - 1, #inset, { end_col = end_col, hl_group = hl })
      end
      controls.paint(buf, ns, buttons)
      for row, line in ipairs(lines) do
        if vim.startswith(line, rail) or line == "╰─" then
          api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
            end_col = line == "╰─" and #line or #rail,
            hl_group = "CommentThreadsCardBorder",
          })
        end
      end
      api.nvim_win_call(win, function()
        vim.fn.winrestview({
          lnum = target or math.min(old_view.lnum, #lines),
          col = math.min(old_view.col, #lines[target or math.min(old_view.lnum, #lines)]),
          topline = top or old_view.topline,
        })
      end)
      last_source_position = nil
    else
      for i, section in ipairs(sections) do
        section.accent = old_sections[i] and old_sections[i].accent
        section.label = old_sections[i] and old_sections[i].label
      end
    end
    preview()
  end

  local function map(action, fn)
    controls.bind(buf, action, fn, legacy[action])
  end
  map("close", function()
    api.nvim_win_close(win, false)
  end)
  map("open", function()
    local section = current_section(api.nvim_win_get_cursor(win)[1])
    if section then
      callbacks.open(section.thread)
    end
  end)
  local function fold(value)
    local section = current_section(api.nvim_win_get_cursor(win)[1])
    if section then
      section.fold(value)
    end
  end
  map("fold_toggle", function()
    fold()
  end)
  map("fold_open", function()
    fold(false)
  end)
  map("fold_close", function()
    fold(true)
  end)
  map("undo", function()
    callbacks.undo_redo("undo")
  end)
  map("redo", function()
    callbacks.undo_redo("redo")
  end)
  for _, action in ipairs({ "reply", "toggle" }) do
    map(action, function()
      local row = api.nvim_win_get_cursor(win)[1]
      local section = current_section(row)
      if section then
        callbacks.action(action, section.thread, messages[row])
      end
    end)
  end
  for _, action in ipairs({ "edit", "delete" }) do
    controls.map_on_message(buf, action, keys[action], legacy[action], function(row)
      local section = current_section(row)
      if section and messages[row] then
        return { thread = section.thread, msg = messages[row] }
      end
    end, function(item)
      callbacks.action(action, item.thread, item.msg)
    end)
  end
  map("jump", function()
    local row, col = unpack(api.nvim_win_get_cursor(win))
    local run = controls.hit(buttons, row, col + 1)
    if run then
      run()
      return
    end
    local section = current_section(row)
    if section and section.toggle_header and row == section.header then
      section.toggle_header()
      return
    end
    local range = section and callbacks.range(section.thread.id)
    if range and api.nvim_win_is_valid(source_win) then
      if api.nvim_win_get_config(win).relative ~= "" then
        api.nvim_win_close(win, false)
      end
      api.nvim_set_current_win(source_win)
      api.nvim_win_set_cursor(source_win, { range[1] + 1, range[2] })
      vim.cmd("normal! zv")
    end
  end)
  map("activate", "<Plug>(comment-threads-jump)")
  return {
    render = render,
    follow = follow,
    preview = preview,
    click = function(row, col)
      return controls.hit(buttons, row, col)
    end,
  }
end

return M
