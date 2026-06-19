local config      = require("next-request.config")
local route       = require("next-request.route")
local parser      = require("next-request.parser")
local http_writer = require("next-request.http_writer")
local env = require("next-request.env")

local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "NextRequest" })
end

local function set_keymap(mode, lhs, rhs, desc)
  if not lhs or lhs == "" then return end
  vim.keymap.set(mode, lhs, rhs, { desc = desc, silent = true })
end

local function get_context(cfg)
  local bufnr  = vim.api.nvim_get_current_buf()
  local file   = vim.api.nvim_buf_get_name(bufnr)

  local route_path, route_err = route.from_file(file, cfg.route_style)
  if not route_path then
    return nil, route_err or "Failed to derive route"
  end

  local root = vim.fn.getcwd()
  local env_vars = {}
  local env_files = cfg.env_files or { ".env", ".env.local" }
  for _, file in ipairs(env_files) do
    local env_path = vim.fs.normalize(root .. "/" .. file)
    local vars = env.parse_env(env_path)
    for k, v in pairs(vars) do
      env_vars[k] = v
    end
  end
  local env_base_url = env.get_base_url(env_vars)

  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local buf_text  = table.concat(buf_lines, "\n")
  local base_url  = parser.parse_base_url(buf_text) or env_base_url or cfg.base_url

  return {
    bufnr = bufnr,
    route_path = route_path,
    base_url = base_url,
  }
end

function M.run()
  local cfg = config.get()
  local ctx, err = get_context(cfg)
  if not ctx then
    notify(err, vim.log.levels.ERROR)
    return
  end

  local parsed, parse_err = parser.parse_current_function(ctx.bufnr)
  if not parsed then
    notify(parse_err or "Failed to parse handler", vim.log.levels.ERROR)
    return
  end

  http_writer.append_request({
    method          = parsed.method,
    route           = ctx.route_path,
    base_url        = ctx.base_url,
    body_fields     = parsed.body_fields,
    body_hints      = parsed.body_hints,
    query_params    = parsed.query_params,
    uses_auth       = parsed.uses_auth,
    custom_headers  = parsed.custom_headers or {},
    content_type    = parsed.content_type,
    response_status = parsed.response_status,
  }, cfg)
end

function M.run_in_buffer()
  local cfg = config.get()
  local ctx, err = get_context(cfg)
  if not ctx then
    notify(err, vim.log.levels.ERROR)
    return
  end

  local parsed, parse_err = parser.parse_current_function(ctx.bufnr)
  if not parsed then
    notify(parse_err or "Failed to parse handler", vim.log.levels.ERROR)
    return
  end

  http_writer.run_request({
    method          = parsed.method,
    route           = ctx.route_path,
    base_url        = ctx.base_url,
    body_fields     = parsed.body_fields,
    body_hints      = parsed.body_hints,
    query_params    = parsed.query_params,
    uses_auth       = parsed.uses_auth,
    custom_headers  = parsed.custom_headers or {},
    content_type    = parsed.content_type,
    response_status = parsed.response_status,
  }, cfg)
end

function M.run_all()
  local cfg = config.get()
  local ctx, err = get_context(cfg)
  if not ctx then
    notify(err, vim.log.levels.ERROR)
    return
  end

  local results = parser.parse_all_functions(ctx.bufnr)
  if #results == 0 then
    notify("No exported handler functions found", vim.log.levels.WARN)
    return
  end

  for _, parsed in ipairs(results) do
    http_writer.append_request({
      method          = parsed.method,
      route           = ctx.route_path,
      base_url        = ctx.base_url,
      body_fields     = parsed.body_fields,
      body_hints      = parsed.body_hints,
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

    local run_cmd = cfg.command .. "Run"
    pcall(vim.api.nvim_del_user_command, run_cmd)
    vim.api.nvim_create_user_command(run_cmd, function()
      M.run_in_buffer()
    end, { desc = "Generate Next.js request and run directly" })

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

  if cfg.run_keymap and cfg.run_keymap.enabled and cfg.run_keymap.lhs then
    local call = string.format("<cmd>%sRun<CR>", cfg.command or "NextRequest")
    set_keymap(cfg.run_keymap.mode or "n", cfg.run_keymap.lhs, call, cfg.run_keymap.desc or "Next request run")
  end
end

return M
