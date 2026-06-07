local M = {}

local BODY_METHODS = {
  POST = true,
  PUT = true,
  PATCH = true,
  DELETE = true,
}

local function join_url(base, route)
  local normalized = base or ""
  if normalized:sub(-1) == "/" then
    normalized = normalized:sub(1, -2)
  end
  local path = route or ""
  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end
  return normalized .. path
end

--- Build query string. param_values fills in literal values for this run.
local function build_query(params, param_values)
  if not params or #params == 0 then return "" end
  param_values = param_values or {}
  local parts = {}
  for _, key in ipairs(params) do
    table.insert(parts, key .. "=" .. (param_values[key] or ""))
  end
  return "?" .. table.concat(parts, "&")
end

--- Build JSON body. values fills in literal values for this run;
--- falls back to empty strings so the template is always valid.
local function build_body(fields, values, hints)
  values = values or {}
  hints = hints or {}
  local lines = { "{" }
  for i, field in ipairs(fields) do
    local comma = (i < #fields) and "," or ""
    local val   = values[field] or ""
    
    local is_number = hints[field] == "number"
    local is_boolean = hints[field] == "boolean"
    
    if val == "" then
      -- If user left it blank, output as string so it's a valid JSON placeholder
      table.insert(lines, string.format("  \"%s\": \"%s\"%s", field, val, comma))
    elseif is_number then
      -- Don't quote numbers
      table.insert(lines, string.format("  \"%s\": %s%s", field, val, comma))
    elseif is_boolean then
      -- Don't quote booleans
      table.insert(lines, string.format("  \"%s\": %s%s", field, val, comma))
    else
      -- Quote strings, enums, etc.
      table.insert(lines, string.format("  \"%s\": \"%s\"%s", field, val, comma))
    end
  end
  table.insert(lines, "}")
  return lines
end

--- Build multipart/form-data body.
local function build_formdata_body(fields, values)
  values = values or {}
  local lines = {}
  for _, field in ipairs(fields) do
    local val = values[field] or ""
    table.insert(lines, field .. "=" .. val)
  end
  return lines
end

--- Derive a human-readable title from the last non-param path segment.
---   /api/auth/login       -> "Login"
---   /api/users/{{id}}     -> "Users"
---   /api/posts/{{postId}}/comments -> "Comments"
local function route_title(route_path)
  if not route_path then return nil end
  for seg in route_path:reverse():gmatch("([^/]+)") do
    local s = seg:reverse()
    if not s:match("{{.+}}") and not s:match("^:[%w_]+$") then
      return s:sub(1, 1):upper() .. s:sub(2)
    end
  end
  return nil
end

--- Build the request URL, substituting variable references where available.
---
--- Priority:
---   1. If opts.prefix_var matches the route prefix  -> {{prefixVar}}/rest
---   2. Else if opts.base_var is set                 -> {{baseVar}}/route
---   3. Fallback                                     -> opts.base_url/route
---
--- opts fields used here:
---   base_url    string   raw base URL (fallback)
---   base_var    string?  name of the @baseUrl var declared in the http file
---   prefix_var  {name, path}?  common-prefix variable
---   route       string   the api route path
---   query_params string[]
local function build_url(opts)
  local route = opts.route or ""
  
  if opts.route_values then
    for k, v in pairs(opts.route_values) do
      if v and v ~= "" then
        -- Replace {{param}} style
        route = route:gsub("{{" .. k .. "}}", v)
        -- Replace :param style (ensuring we don't accidentally match prefixes)
        route = route:gsub(":" .. k .. "(/?)$", v .. "%1")
        route = route:gsub(":" .. k .. "/", v .. "/")
      end
    end
  end

  local query  = build_query(opts.query_params, opts.param_values)

  -- 1. Common-prefix variable takes highest priority
  if opts.prefix_var then
    local ppath = opts.prefix_var.path
    if route:sub(1, #ppath) == ppath then
      local suffix = route:sub(#ppath + 1)  -- e.g. "/members" or ""
      return "{{" .. opts.prefix_var.name .. "}}" .. suffix .. query
    end
  end

  -- 2. baseUrl variable reference
  if opts.base_var then
    return "{{" .. opts.base_var .. "}}" .. route .. query
  end

  -- 3. Raw base URL fallback
  return join_url(opts.base_url, route) .. query
end

--- Generate the full .http request block as a string.
---
--- opts:
---   method          string      HTTP method
---   route           string      API route path
---   base_url        string      Raw base URL (fallback)
---   base_var        string?     Name of @baseUrl variable in http file
---   prefix_var      {name,path}?  Common-prefix variable
---   body_fields     string[]
---   query_params    string[]
---   uses_auth       bool
---   custom_headers  string[]    Header names from request.headers.get(...)
---   body_values     {name->value}?  Literal values to embed in body (from UI)
---   param_values    {name->value}?  Literal values to embed in query (from UI)
---   route_values    {name->value}?  Literal values for route params (from UI)
---   content_type    string?     "json" | "form-data" | "text" (default: "json")
---   response_status number?     Expected HTTP response status code
function M.generate(opts)
  if not opts or not opts.method or not opts.route then
    return nil, "Missing required request data (method, route)"
  end
  if not opts.base_url and not opts.base_var then
    return nil, "Missing base_url or base_var"
  end

  local url   = build_url(opts)
  local title = route_title(opts.route)

  -- # @name decorator for VSCode REST Client chaining (B4)
  local req_name = title and (opts.method:lower() .. "_" .. title:lower()) or nil
  local separator = title and ("### " .. title) or "###"

  local lines = {}

  -- ### separator comes FIRST — ensures the HTTP client treats everything
  -- that follows as a new request, not as the body of the previous one.
  table.insert(lines, separator)

  -- B4: # @name decorator for VSCode REST Client chaining (must be after ###)
  if req_name then
    table.insert(lines, "# @name " .. req_name)
  end

  -- Response status comment (e.g. "# Expected: 201 Created")
  if opts.response_status then
    local STATUS_LABELS = {
      [200] = "OK", [201] = "Created", [202] = "Accepted",
      [204] = "No Content", [301] = "Moved Permanently",
      [302] = "Found", [304] = "Not Modified",
      [400] = "Bad Request", [401] = "Unauthorized", [403] = "Forbidden",
      [404] = "Not Found", [409] = "Conflict",
      [422] = "Unprocessable Entity", [429] = "Too Many Requests",
      [500] = "Internal Server Error",
    }
    local label = STATUS_LABELS[opts.response_status] or ""
    local status_str = tostring(opts.response_status)
    if label ~= "" then status_str = status_str .. " " .. label end
    table.insert(lines, "# Expected: " .. status_str)
  end

  table.insert(lines, string.format("%s %s", opts.method, url))

  -- Auth header (from requireAuth / getSession detection)
  if opts.uses_auth then
    table.insert(lines, "Authorization: Bearer {{token}}")
  end

  -- Custom headers from request.headers.get(...) calls (B3)
  for _, hname in ipairs(opts.custom_headers or {}) do
    -- Skip authorization if already emitted via uses_auth
    if hname:lower() ~= "authorization" or not opts.uses_auth then
      table.insert(lines, hname .. ": ")
    end
  end

  -- Body (only for body methods with detected fields)
  local ct = opts.content_type or "json"
  if BODY_METHODS[opts.method] and opts.body_fields and #opts.body_fields > 0 then
    if ct == "form-data" then
      table.insert(lines, "Content-Type: multipart/form-data")
      table.insert(lines, "")
      vim.list_extend(lines, build_formdata_body(opts.body_fields, opts.body_values))
    else
      table.insert(lines, "Content-Type: application/json")
      table.insert(lines, "")
      vim.list_extend(lines, build_body(opts.body_fields, opts.body_values, opts.body_hints))
    end
  elseif BODY_METHODS[opts.method] and ct == "text" then
    table.insert(lines, "Content-Type: text/plain")
    table.insert(lines, "")
    table.insert(lines, "")
  end

  table.insert(lines, "")
  return table.concat(lines, "\n")
end

return M
