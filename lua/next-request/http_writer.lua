local picker      = require("next-request.picker")
local http_reader = require("next-request.http_reader")
local generator   = require("next-request.generator")
local ui          = require("next-request.ui")

local M = {}

local BODY_METHODS = { POST = true, PUT = true, PATCH = true, DELETE = true }

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "NextRequest" })
end

local function resolve_files(files)
  local root = vim.fn.getcwd()
  local resolved = {}
  for _, file in ipairs(files) do
    if type(file) == "string" and file ~= "" then
      if file:match("^/") then
        table.insert(resolved, file)
      else
        table.insert(resolved, vim.fs.normalize(root .. "/" .. file))
      end
    end
  end
  return resolved
end

local function ensure_parent_dir(path)
  local dir = vim.fs.dirname(path)
  if dir and dir ~= "" then vim.fn.mkdir(dir, "p") end
end

--- Read file as a list of lines. Returns {} if file does not exist yet.
local function read_lines(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return (ok and type(lines) == "table") and lines or {}
end

--- Find the line index (1-based) immediately AFTER the last @var = ... line
--- in the header block at the top of the file.
--- Returns 1 when there are no existing @var declarations.
local function var_insert_point(lines)
  local insert_at = 1
  for i, line in ipairs(lines) do
    if line:match("^@") then
      insert_at = i + 1  -- place new vars after this one
    elseif line:match("^%s*$") then
      -- blank lines inside the var header block are OK; keep scanning
    elseif line:match("^###") then
      break  -- reached request separator, var block is over
    else
      break  -- first non-var, non-blank line means we've left the header
    end
  end
  return insert_at
end

--- Prepend @name = value declarations to the file after any existing @var block.
--- Inserts a blank separator line between the var block and the first request if needed.
local function write_var_declarations(path, new_vars)
  if #new_vars == 0 then return end

  local lines = read_lines(path)

  -- Second-layer dedup: check if @varName already exists in the file lines.
  -- This catches cases where the parsed variables table might have missed entries
  -- (e.g. due to Lua module caching or file timing).
  local existing = {}
  for _, line in ipairs(lines) do
    local name = line:match("^@([%w_]+)%s*=")
    if name then existing[name] = true end
  end

  local filtered = {}
  for _, var in ipairs(new_vars) do
    if not existing[var.name] then
      table.insert(filtered, var)
    end
  end
  if #filtered == 0 then return end

  local insert_at = var_insert_point(lines)

  -- Insert new lines in the correct forward order
  for i, var in ipairs(filtered) do
    table.insert(lines, insert_at + i - 1, string.format("@%s = %s", var.name, var.value))
  end

  -- Ensure a blank line exists between the var block and the first request
  local sep_pos = insert_at + #filtered
  if sep_pos > #lines or (lines[sep_pos] ~= "" and lines[sep_pos] ~= nil) then
    table.insert(lines, sep_pos, "")
  end

  ensure_parent_dir(path)
  pcall(vim.fn.writefile, lines, path)
end

--- Append the generated request block to the file.
local function append_request_string(path, request_str)
  if request_str:sub(-1) ~= "\n" then
    request_str = request_str .. "\n"
  end
  ensure_parent_dir(path)
  local lines = vim.split(request_str, "\n", { plain = true })
  local ok, err = pcall(vim.fn.writefile, lines, path, "a")
  if not ok then
    notify("Failed to write request: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  return true
end


--- request_info fields:
---   method, route, base_url, body_fields, query_params, uses_auth, custom_headers

--- Generate the request and append it to the file, optionally showing the
--- fill-form UI for body fields / query params.
local function do_write(path, request_info, base_var, prefix_var, file_ctx, route_params)
  -- For non-body methods (GET, HEAD, OPTIONS, DELETE-without-body), don't show body fields in the form.
  local show_body_fields = BODY_METHODS[request_info.method]
                           and (request_info.body_fields and #request_info.body_fields > 0)
  local effective_body   = show_body_fields and request_info.body_fields or {}

  local gen_opts = {
    method          = request_info.method,
    route           = request_info.route,
    base_url        = request_info.base_url,
    base_var        = base_var,
    prefix_var      = prefix_var,
    body_fields     = effective_body,
    body_hints      = request_info.body_hints,
    query_params    = request_info.query_params,
    route_params    = route_params,
    uses_auth       = request_info.uses_auth,
    custom_headers  = request_info.custom_headers,
    content_type    = request_info.content_type,
    response_status = request_info.response_status,
  }

  local function do_generate(body_vals, param_vals, route_vals)
    gen_opts.body_values  = body_vals
    gen_opts.param_values = param_vals
    gen_opts.route_values = route_vals
    local req_str, gen_err = generator.generate(gen_opts)
    if not req_str then
      notify(gen_err or "Failed to generate request", vim.log.levels.ERROR)
      return
    end
    if append_request_string(path, req_str) then
      notify("Appended to " .. vim.fn.fnamemodify(path, ":~:."))
    end
  end

  local needs_body   = show_body_fields
  local needs_params = #(request_info.query_params or {}) > 0
  local needs_route  = #(route_params or {}) > 0

  if needs_body or needs_params or needs_route then
    local title = request_info.method .. " " .. request_info.route
    ui.fill_form({
      title        = title,
      body_fields  = effective_body,
      body_hints   = request_info.body_hints or {},
      query_params = request_info.query_params or {},
      route_params = route_params or {},
      callback     = do_generate,
    })
  else
    do_generate(nil, nil, nil)
  end
end

local function write_to_file(path, request_info)
  -- ── 1. Parse existing .http file for context ──────────────────────────────
  local file_ctx = http_reader.parse_file(path)

  -- ── 2. Resolve @baseUrl variable ──────────────────────────────────────────
  local base_var = "baseUrl"
  local new_vars = {}
  local queued   = {}  -- tracks names already queued in this run

  if not file_ctx.variables.baseUrl then
    table.insert(new_vars, { name = "baseUrl", value = request_info.base_url })
    queued.baseUrl = true
  end

  -- ── 3. Route param stubs (B2) ─────────────────────────────────────────────
  local route_params = http_reader.extract_route_params(request_info.route)
  for _, param in ipairs(route_params) do
    if not file_ctx.variables[param] and not queued[param] then
      table.insert(new_vars, { name = param, value = "" })
      queued[param] = true
    end
  end

  -- ── 4. Common URL prefix variable ─────────────────────────────────────────
  local prefix_var
  local common_prefix = http_reader.find_common_prefix(
    request_info.route, file_ctx.requests
  )
  if common_prefix then
    local pname = http_reader.prefix_var_name(common_prefix)
    if not file_ctx.variables[pname] and not queued[pname] then
      local pvalue = "{{" .. base_var .. "}}" .. common_prefix
      table.insert(new_vars, { name = pname, value = pvalue })
      queued[pname] = true
    end
    prefix_var = { name = http_reader.prefix_var_name(common_prefix), path = common_prefix }
  end

  -- ── 5. Write @var declarations eagerly ────────────────────────────────────
  -- Done before the UI so the file header is set up regardless of submit/skip.
  write_var_declarations(path, new_vars)

  -- ── 6. Duplicate request check ────────────────────────────────────────────
  -- Re-read file after var declarations are written (parse_file was called at top
  -- but requests list is from the same read, so it's fine for checking).
  if http_reader.request_exists(request_info.method, request_info.route, file_ctx.requests) then
    vim.ui.select(
      { "Append anyway", "Cancel" },
      { prompt = "⚠ " .. request_info.method .. " " .. request_info.route .. " already exists" },
      function(choice)
        if choice == "Append anyway" then
          do_write(path, request_info, base_var, prefix_var, file_ctx, route_params)
        else
          notify("Skipped (duplicate request)", vim.log.levels.WARN)
        end
      end
    )
    return
  end

  do_write(path, request_info, base_var, prefix_var, file_ctx, route_params)
end

--- Public entry point.
--- request_info = { method, route, base_url, body_fields, query_params,
---                  uses_auth, custom_headers }
function M.append_request(request_info, cfg)
  local files = cfg.http_files or {}
  if #files == 0 then
    notify("No http_files configured", vim.log.levels.ERROR)
    return
  end

  local resolved = resolve_files(files)
  if #resolved == 0 then
    notify("No valid http_files found", vim.log.levels.ERROR)
    return
  end

  if #resolved == 1 then
    write_to_file(resolved[1], request_info)
    return
  end

  picker.select(resolved, function(choice)
    if not choice then return end
    write_to_file(choice, request_info)
  end)
end

return M
