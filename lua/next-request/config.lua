local M = {}

local DEFAULTS = {
  base_url = "http://localhost:3000",
  route_style = "mustache",
  http_files = {},
  env_files = { ".env", ".env.local" },
  execution_client = "kulala",
  command = "NextRequest",
  keymap = {
    enabled = false,
    lhs = nil,
    mode = "n",
    desc = "Next request",
  },
}

M._state = {
  config = nil,
}

local function normalize_keymap(value)
  if value == false then
    return { enabled = false }
  end
  if type(value) == "string" then
    return {
      enabled = true,
      lhs = value,
      mode = DEFAULTS.keymap.mode,
      desc = DEFAULTS.keymap.desc,
    }
  end
  if type(value) == "table" then
    return vim.tbl_deep_extend("force", DEFAULTS.keymap, value)
  end
  return vim.deepcopy(DEFAULTS.keymap)
end

local function normalize(opts)
  local cfg = vim.tbl_deep_extend("force", DEFAULTS, opts or {})

  if type(cfg.http_files) == "string" then
    cfg.http_files = { cfg.http_files }
  end
  if type(cfg.http_files) ~= "table" then cfg.http_files = {} end

  if type(cfg.env_files) == "string" then
    cfg.env_files = { cfg.env_files }
  end
  if type(cfg.env_files) ~= "table" then cfg.env_files = { ".env", ".env.local" } end

  if cfg.route_style ~= "mustache" and cfg.route_style ~= "colon" then
    cfg.route_style = DEFAULTS.route_style
  end

  cfg.keymap = normalize_keymap(cfg.keymap)

  return cfg
end

function M.setup(opts)
  M._state.config = normalize(opts)
  return M._state.config
end

function M.get()
  if not M._state.config then
    M._state.config = normalize({})
  end
  return M._state.config
end

function M.defaults()
  return vim.deepcopy(DEFAULTS)
end

return M
