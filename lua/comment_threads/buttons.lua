local api = vim.api
local flash = api.nvim_create_namespace("comment_threads.button_press")
local pressed = {}
local M = {}

function M.label(label, key)
  return key and ("%s (%s)"):format(label, key) or label
end

local function gap(line)
  return line == "" and "" or " "
end

function M.fits(width, line, ...)
  for _, label in ipairs({ ... }) do
    line = line .. gap(line) .. " " .. label .. " "
  end
  return vim.fn.strdisplaywidth(line) <= width
end

function M.add(buttons, lines, label, run, style, key)
  local row = #lines
  local separator = gap(lines[row])
  local start = #lines[row] + #separator
  local face = " " .. M.label(label, key) .. " "
  lines[row] = lines[row] .. separator .. face
  buttons[row] = buttons[row] or {}
  buttons[row][#buttons[row] + 1] = {
    start = start,
    finish = start + #face,
    hint = key and start + #label + 2 or nil,
    run = run,
    style = style or "Neutral",
  }
end

local function plug(action)
  return "<Plug>(comment-threads-" .. action:gsub("_", "-") .. ")"
end

function M.keys(buf, legacy)
  local bindings = vim.tbl_extend("force", {}, legacy)
  for _, map in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
    local action = map.rhs and map.rhs:match("^<Plug>%(comment%-threads%-([%w%-]+)%)$")
    if action then
      bindings[action:gsub("-", "_")] = map.lhs
    end
  end
  return bindings
end

function M.bind(buf, action, run, legacy, mode, expr)
  mode = mode or "n"
  local target = plug(action)
  vim.keymap.set(mode, target, run, { buffer = buf, expr = expr, nowait = expr })
  if legacy then
    vim.keymap.set(mode, legacy, target, { buffer = buf, nowait = expr })
  end
end

function M.unbind(buf, action, legacy)
  pcall(vim.keymap.del, "n", plug(action), { buffer = buf })
  if legacy then
    pcall(vim.keymap.del, "n", legacy, { buffer = buf })
  end
end

function M.map_on_message(buf, action, key, legacy, at_row, run)
  M.bind(buf, action, function()
    local msg = at_row(api.nvim_win_get_cursor(0)[1])
    if not msg then
      return key or ""
    end
    vim.schedule(function()
      if api.nvim_get_current_buf() == buf then
        run(msg)
      end
    end)
    return ""
  end, legacy, "n", true)
end

function M.paint(buf, ns, buttons)
  for row, actions in pairs(buttons) do
    for _, action in ipairs(actions) do
      api.nvim_buf_set_extmark(buf, ns, row - 1, action.start, {
        end_col = action.hint or action.finish,
        hl_group = "CommentThreadsButton" .. action.style,
        priority = 100,
      })
      if action.hint then
        api.nvim_buf_set_extmark(buf, ns, row - 1, action.hint, {
          end_col = action.finish,
          hl_group = "CommentThreadsButtonHint" .. action.style,
          priority = 100,
        })
      end
    end
  end
end

function M.hit(buttons, row, col)
  for _, action in ipairs(buttons[row] or {}) do
    if col > action.start and col <= action.finish then
      return function()
        local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
        if pressed[buf] then
          return
        end
        pressed[buf] = true
        local tick = api.nvim_buf_get_changedtick(buf)
        local mark = api.nvim_buf_set_extmark(buf, flash, row - 1, action.start, {
          end_col = action.finish,
          hl_group = "CommentThreadsButtonPressed" .. action.style,
          priority = 250,
        })
        vim.defer_fn(function()
          pressed[buf] = nil
          if not api.nvim_buf_is_valid(buf) then
            return
          end
          api.nvim_buf_del_extmark(buf, flash, mark)
          if
            api.nvim_get_current_win() == win
            and api.nvim_get_current_buf() == buf
            and api.nvim_buf_get_changedtick(buf) == tick
          then
            action.run()
          end
        end, 95)
      end
    end
  end
end

return M
