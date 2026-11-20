local api = vim.api
local M = {}

function M.snapshot(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local offsets, offset = {}, 0
  for row, line in ipairs(lines) do
    offsets[row] = offset
    offset = offset + #line + 1
  end
  local text = table.concat(lines, "\n")
  return { lines = lines, offsets = offsets, text = text, digest = vim.fn.sha256(text) }
end

local function position(doc, offset)
  local lo, hi = 1, #doc.offsets
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if doc.offsets[mid] <= offset then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return lo - 1, offset - doc.offsets[lo]
end

local function char_boundary(text, offset)
  while true do
    local byte = text:byte(offset + 1)
    if not byte or byte < 128 or byte >= 192 then
      return offset
    end
    offset = offset + 1
  end
end

function M.capture(buf, first, last, mode)
  local doc = M.snapshot(buf)
  local start, finish, kind
  if mode == "V" then
    kind = "line"
    start = doc.offsets[first[2]]
    finish = doc.offsets[last[2]] + #doc.lines[last[2]]
  elseif mode == "v" then
    kind = "text"
    local opts = { type = mode, exclusive = vim.o.selection == "exclusive", eol = true }
    local region = vim.fn.getregionpos(first, last, opts)
    local head = region[1][1]
    if head[4] ~= 0 or region[#region][2][4] ~= 0 then
      return nil, "Select actual text, not virtual columns"
    end
    start = doc.offsets[head[2]] + math.max(0, head[3] - 1)
    local quote = table.concat(vim.fn.getregion(first, last, opts), "\n")
    finish = start + #quote
    if quote == "" or doc.text:sub(start + 1, finish) ~= quote then
      return nil, "Select actual text to start a thread"
    end
  else
    return nil, "Use a characterwise or linewise selection"
  end
  local row = position(doc, start)
  return {
    kind = kind,
    quote = doc.text:sub(start + 1, finish),
    prefix = doc.text:sub(char_boundary(doc.text, math.max(0, start - 96)) + 1, start),
    suffix = doc.text:sub(finish + 1, char_boundary(doc.text, math.min(#doc.text, finish + 96))),
    offset = start,
    line = row + 1,
    digest = doc.digest,
  }
end

function M.locate(doc, anchor)
  local text, quote = doc.text, anchor.quote
  local function range(offset)
    if offset + #quote > #text then
      return nil
    end
    local row, col = position(doc, offset)
    local end_row, end_col = position(doc, offset + #quote)
    if anchor.kind == "line" and (col ~= 0 or end_col ~= #doc.lines[end_row + 1]) then
      return nil
    end
    return { row, col, end_row, end_col }
  end
  if doc.digest == anchor.digest then
    local offset = anchor.offset
    local finish = offset + #quote
    if
      text:sub(offset + 1, finish) == quote
      and char_boundary(text, offset) == offset
      and char_boundary(text, finish) == finish
    then
      return range(offset)
    end
    return nil
  end
  if quote == "" then
    return nil -- An empty line has no text to search for.
  end

  local best, best_score, tied = nil, -1, false
  local at = 1
  while true do
    local found, finish = text:find(quote, at, true)
    if not found then
      break
    end
    at = found + 1
    local candidate = range(found - 1)
    if candidate then
      local before, after = 0, 0
      while
        before < #anchor.prefix
        and found - 1 - before > 0
        and text:byte(found - 1 - before) == anchor.prefix:byte(#anchor.prefix - before)
      do
        before = before + 1
      end
      while after < #anchor.suffix and text:byte(finish + 1 + after) == anchor.suffix:byte(after + 1) do
        after = after + 1
      end
      -- The quote alone is not enough: a rewrite can leave a different copy elsewhere.
      local prefix_matches = before > 0
        and before >= math.min(12, #anchor.prefix)
        and anchor.prefix:sub(-before):find("%S")
      local suffix_matches = after > 0
        and after >= math.min(12, #anchor.suffix)
        and anchor.suffix:sub(1, after):find("%S")
      if prefix_matches or suffix_matches then
        local score = before + after
        if score > best_score then
          best, best_score, tied = candidate, score, false
        elseif score == best_score then
          tied = true
        end
      end
    end
  end
  return not tied and best or nil
end

return M
