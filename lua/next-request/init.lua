local config      = require("next-request.config")
local route       = require("next-request.route")
local parser      = require("next-request.parser")
local http_writer = require("next-request.http_writer")

local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "NextRequest" })
end

local function set_keymap(mode, lhs, rhs, desc)
  if not lhs or lhs == "" then return end
  vim.keymap.set(mode, lhs, rhs, { desc = desc, silent = true })
end

function M.run()
  local cfg    = config.get()
  local bufnr  = vim.api.nvim_get_current_buf()
  local file   = vim.api.nvim_buf_get_name(bufnr)

  -- ── Route path from file location ─────────────────────────────────────────
  local route_path, route_err = route.from_file(file, cfg.route_style)
  if not route_path then
    notify(route_err or "Failed to derive route", vim.log.levels.ERROR)
    return
  end

  -- ── Scan full source buffer for a file-level baseUrl constant ─────────────
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local buf_text  = table.concat(buf_lines, "\n")
  local base_url  = parser.parse_base_url(buf_text) or cfg.base_url

  -- ── Parse the handler function under the cursor ───────────────────────────
  local parsed, parse_err = parser.parse_current_function(bufnr)
  if not parsed then
    notify(parse_err or "Failed to parse handler", vim.log.levels.ERROR)
    return
  end

  -- ── Hand off to http_writer (handles variables, generation, file write) ────
  http_writer.append_request({
    method          = parsed.method,
    route           = route_path,
    base_url        = base_url,
    body_fields     = parsed.body_fields,
    query_params    = parsed.query_params,
    uses_auth       = parsed.uses_auth,
    custom_headers  = parsed.custom_headers or {},
    content_type    = parsed.content_type,
    response_status = parsed.response_status,
  }, cfg)
end

function M.run_all()
  local cfg    = config.get()
  local bufnr  = vim.api.nvim_get_current_buf()
  local file   = vim.api.nvim_buf_get_name(bufnr)

  local route_path, route_err = route.from_file(file, cfg.route_style)
  if not route_path then
    notify(route_err or "Failed to derive route", vim.log.levels.ERROR)
    return
  end

  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local buf_text  = table.concat(buf_lines, "\n")
  local base_url  = parser.parse_base_url(buf_text) or cfg.base_url

  local results = parser.parse_all_functions(bufnr)
  if #results == 0 then
    notify("No exported handler functions found", vim.log.levels.WARN)
    return
  end

  for _, parsed in ipairs(results) do
    http_writer.append_request({
      method          = parsed.method,
      route           = route_path,
      base_url        = base_url,
      body_fields     = parsed.body_fields,
      query_params    = parsed.query_params,
      uses_auth       = parsed.uses_auth,
      custom_headers  = parsed.custom_headers or {},
      content_type    = parsed.content_type,
      response_status = parsed.response_status,
    }, cfg)
  end
end

function M.setup(opts)
  local cfg = config.setup(opts)

  if cfg.command and cfg.command ~= "" then
    pcall(vim.api.nvim_del_user_command, cfg.command)
    vim.api.nvim_create_user_command(cfg.command, function()
      M.run()
    end, { desc = "Generate Next.js request" })

    local all_cmd = cfg.command .. "All"
    pcall(vim.api.nvim_del_user_command, all_cmd)
    vim.api.nvim_create_user_command(all_cmd, function()
      M.run_all()
    end, { desc = "Generate ALL Next.js requests from this file" })
  end

  if cfg.keymap and cfg.keymap.enabled and cfg.keymap.lhs then
    local call = string.format("<cmd>%s<CR>", cfg.command or "NextRequest")
    set_keymap(cfg.keymap.mode or "n", cfg.keymap.lhs, call, cfg.keymap.desc or "Next request")
  end
end

return M
