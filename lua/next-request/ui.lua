local M = {}

function M.fill_form(opts)
  local body_fields  = opts.body_fields  or {}
  local query_params = opts.query_params or {}
  local route_params = opts.route_params or {}
  local callback     = opts.callback

  local has_body   = #body_fields  > 0
  local has_params = #query_params > 0
  local has_route  = #route_params > 0

  -- Nothing to ask → immediately continue with empty value maps
  if not has_body and not has_params and not has_route then
    callback({}, {}, {})
    return
  end

  -- ── Build form content ────────────────────────────────────────────────────
  local lines = {}   -- raw line strings for the buffer
  local meta  = {}   -- [{lineno, section, name}]  — tracks editable field lines

  local function push_field(section, name)
    table.insert(lines, name .. " = ")
    table.insert(meta, { lineno = #lines, section = section, name = name })
  end

  local sections = 0
  if has_route then sections = sections + 1 end
  if has_params then sections = sections + 1 end
  if has_body then sections = sections + 1 end
  local multi = sections > 1

  if has_route then
    if multi then table.insert(lines, "# route") end
    for _, r in ipairs(route_params) do push_field("route", r) end
  end

  if has_params then
    if multi then
      if has_route then table.insert(lines, "") end
      table.insert(lines, "# query")
    end
    for _, p in ipairs(query_params) do push_field("query", p) end
  end

  if has_body then
    if multi then
      if has_route or has_params then table.insert(lines, "") end
      table.insert(lines, "# body")
    end
    for _, f in ipairs(body_fields)  do push_field("body",  f) end
  end

  -- ── Window geometry ───────────────────────────────────────────────────────
  local max_name = 0
  for _, f in ipairs(body_fields)  do max_name = math.max(max_name, #f) end
  for _, p in ipairs(query_params) do max_name = math.max(max_name, #p) end
  for _, r in ipairs(route_params) do max_name = math.max(max_name, #r) end

  local win_w  = math.max(52, max_name + 6 + 24)
  local win_h  = #lines
  local row    = math.floor((vim.o.lines   - win_h) / 2)
  local col    = math.floor((vim.o.columns - win_w)  / 2)

  -- ── Buffer ────────────────────────────────────────────────────────────────
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].buftype   = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile  = false
  -- Leave filetype empty so copilot picks context from field names / content

  -- ── Floating window ───────────────────────────────────────────────────────
  local title = " " .. opts.title .. " "
  local win_cfg = {
    relative  = "editor",
    width     = win_w,
    height    = win_h,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = "rounded",
    title     = title,
    title_pos = "center",
  }
  -- footer requires nvim >= 0.10
  if vim.fn.has("nvim-0.10") == 1 then
    win_cfg.footer     = "  <CR> send  ·  <Esc> skip  "
    win_cfg.footer_pos = "center"
  end

  local win = vim.api.nvim_open_win(bufnr, true, win_cfg)

  -- ── Helpers ───────────────────────────────────────────────────────────────
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  --- Read current buffer and extract field values from tracked lines.
  local function read_values()
    local cur_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local body_vals, param_vals, route_vals = {}, {}, {}
    for _, m in ipairs(meta) do
      local line = cur_lines[m.lineno] or ""
      -- Extract everything after the first `=`
      local val  = line:match("^[^=]+=%s*(.-)%s*$") or ""
      if m.section == "body"  then body_vals[m.name]  = val end
      if m.section == "query" then param_vals[m.name] = val end
      if m.section == "route" then route_vals[m.name] = val end
    end
    return body_vals, param_vals, route_vals
  end

  -- Guard: ensure submit/skip fire the callback at most once,
  -- regardless of how many keymaps trigger (e.g. stopinsert typeahead replay).
  local done = false

  local function submit()
    if done then return end
    done = true
    local bv, pv, rv = read_values()
    close()
    vim.schedule(function() callback(bv, pv, rv) end)
  end

  local function skip()
    if done then return end
    done = true
    close()
    vim.schedule(function() callback(nil, nil, nil) end)
  end

  -- ── Keymaps (buffer-local) ────────────────────────────────────────────────
  local ko = { buffer = bufnr, nowait = true, silent = true }

  -- Normal mode
  vim.keymap.set("n", "<CR>",  submit, ko)
  vim.keymap.set("n", "<Esc>", skip,   ko)
  vim.keymap.set("n", "q",     skip,   ko)

  -- Insert mode: <CR> submits.
  -- Use vim.schedule to decouple from the current keypress event loop so that
  -- stopinsert does NOT replay <CR> into normal mode via the typeahead buffer.
  vim.keymap.set("i", "<CR>", function()
    vim.cmd("stopinsert")
    vim.schedule(submit)
  end, ko)

  -- Insert mode: <Esc> skips
  vim.keymap.set("i", "<Esc>", function()
    vim.cmd("stopinsert")
    vim.schedule(skip)
  end, ko)

  -- Insert mode: <C-c> skips
  vim.keymap.set("i", "<C-c>", function()
    vim.schedule(skip)
  end, ko)

  -- Insert mode: <Tab> / <S-Tab> move between fields
  vim.keymap.set("i", "<Tab>", function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    for i, m in ipairs(meta) do
      if m.lineno == cur and meta[i + 1] then
        local nxt = meta[i + 1]
        local nxt_line = vim.api.nvim_buf_get_lines(bufnr, nxt.lineno - 1, nxt.lineno, false)[1] or ""
        vim.api.nvim_win_set_cursor(0, { nxt.lineno, #nxt_line })
        return
      end
    end
    -- Already on last field → submit
    vim.cmd("stopinsert")
    submit()
  end, ko)

  vim.keymap.set("i", "<S-Tab>", function()
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    for i, m in ipairs(meta) do
      if m.lineno == cur and meta[i - 1] then
        local prv = meta[i - 1]
        local prv_line = vim.api.nvim_buf_get_lines(bufnr, prv.lineno - 1, prv.lineno, false)[1] or ""
        vim.api.nvim_win_set_cursor(0, { prv.lineno, #prv_line })
        return
      end
    end
  end, ko)

  -- ── Start in insert mode, cursor after `= ` on first field ───────────────
  if #meta > 0 then
    local first_line = lines[meta[1].lineno] or ""
    vim.api.nvim_win_set_cursor(win, { meta[1].lineno, #first_line })
  end
  vim.cmd("startinsert!")
end

return M
