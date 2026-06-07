local M = {}

--- Parse all @name = value declarations at the top of an .http file.
--- Returns {name -> value} table.
function M.parse_variables(text)
  local vars = {}
  -- Use * (zero-or-more) so empty-value stubs like `@teamId = ` are captured too.
  for name, value in text:gmatch("@([%w_]+)%s*=%s*([^\n\r]*)") do
    vars[name] = value:gsub("^%s+", ""):gsub("%s+$", "")
  end
  return vars
end

--- Parse all HTTP request lines from .http file content.
--- Returns [{method, url}, ...].
local REQUEST_METHODS = {
  GET = true, POST = true, PUT = true, PATCH = true,
  DELETE = true, HEAD = true, OPTIONS = true,
}

function M.parse_requests(text)
  local requests, seen = {}, {}
  for line in (text .. "\n"):gmatch("([^\n\r]*)\r?\n") do
    local method, url = line:match("^%s*(%u+)%s+(%S+)")
    if method and REQUEST_METHODS[method] and url and not seen[url] then
      table.insert(requests, { method = method, url = url })
      seen[url] = true
    end
  end
  return requests
end

--- Read and parse an existing .http file.
--- Returns {variables = {...}, requests = [{method, url}...]}.
--- Returns empty tables safely when the file does not exist yet.
function M.parse_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return { variables = {}, requests = {} }
  end
  local text = table.concat(lines, "\n")
  return {
    variables = M.parse_variables(text),
    requests  = M.parse_requests(text),
  }
end

--- Extract dynamic parameter names from a route path.
---   "/api/teams/{{teamId}}/projects" -> {"teamId"}
---   "/api/users/:id"                 -> {"id"}
function M.extract_route_params(route_path)
  local params, seen = {}, {}
  -- mustache style  {{paramName}}
  for name in route_path:gmatch("%{%{([%w_]+)%}%}") do
    if not seen[name] then table.insert(params, name); seen[name] = true end
  end
  -- colon style  :paramName
  for name in route_path:gmatch("/:([%w_]+)") do
    if not seen[name] then table.insert(params, name); seen[name] = true end
  end
  return params
end



--- Given a new route path and the existing requests in the .http file, find the
--- longest common path prefix that:
---   1. Is shared by the new route AND at least one existing request
---   2. Contains at least one dynamic parameter ({{param}} or :param)
---   3. Has at least two path segments
---
--- Returns the prefix string (e.g. "/api/teams/{{teamId}}") or nil.
function M.find_common_prefix(new_route, existing_requests)
  if not new_route or #existing_requests == 0 then return nil end

  local new_segs = {}
  for seg in new_route:gmatch("[^/]+") do
    table.insert(new_segs, seg)
  end
  -- Need at least 2 segments in new route, and prefix must be shorter
  if #new_segs < 2 then return nil end

  -- Normalize existing request URLs to paths
  local existing_paths = {}
  for _, req in ipairs(existing_requests) do
    local p = M.url_to_path(req.url)
    if p and p ~= new_route then
      table.insert(existing_paths, p)
    end
  end
  if #existing_paths == 0 then return nil end

  -- Try longest possible prefix down to 2 segments
  for prefix_len = #new_segs - 1, 2, -1 do
    local prefix = "/" .. table.concat(new_segs, "/", 1, prefix_len)

    -- Only useful as a variable if the prefix contains a dynamic param
    local has_param = prefix:match("%{%{[%w_]+%}%}") or prefix:match("/:[%w_]+")
    if has_param then
      for _, ep in ipairs(existing_paths) do
        -- existing path starts with this prefix
        if ep:sub(1, #prefix) == prefix then
          return prefix
        end
      end
    end
  end

  return nil
end

--- Derive a readable variable name for a common prefix.
---   "/api/teams/{{teamId}}"           -> "teamsBase"
---   "/api/posts/{{postId}}/comments"  -> "commentsBase"
---   "/api/v1/users/{{userId}}"        -> "usersBase"
function M.prefix_var_name(prefix)
  local SKIP = { api = true, v1 = true, v2 = true, v3 = true }
  local last_static
  for seg in prefix:gmatch("[^/]+") do
    if not seg:match("^%{%{") and not seg:match("^:") and not SKIP[seg] then
      last_static = seg
    end
  end
  return (last_static or "route") .. "Base"
end

--- Normalize a URL from an .http file to just its path component (public).
function M.url_to_path(url)
  -- {{baseUrl}}/api/... → /api/...
  local path = url:match("^%{%{[%w_]+%}%}(/?.*)$")
  if path then return (path == "" and "/") or path end
  -- {{prefixVar}}/rest → strip the var ref, keep rest
  -- e.g. {{teamsBase}}/projects → /projects (partial, but the method+suffix match still works)
  -- http://host/api/... → /api/...
  path = url:match("^https?://[^/]+(/.+)$")
  if path then return path end
  -- already a bare path
  if url:sub(1, 1) == "/" then return url end
  return nil
end

--- Check if a request with the given method and route already exists.
--- Compares by checking if any existing request's URL resolves to a path
--- that ends with the route_path (handles {{prefixVar}} substitution).
function M.request_exists(method, route_path, requests)
  if not method or not route_path or not requests then return false end
  for _, req in ipairs(requests) do
    if req.method == method then
      local existing_path = M.url_to_path(req.url)
      if existing_path then
        -- Exact match
        if existing_path == route_path then return true end
        -- The existing URL may use a prefix variable: {{teamsBase}}/projects
        -- which resolves to /api/teams/{{teamId}}/projects.
        -- Check if route_path ends with the existing URL's suffix.
        -- e.g. route_path = /api/teams/{{teamId}}/projects, existing = /projects (from {{teamsBase}})
        if route_path:sub(-#existing_path) == existing_path then return true end
      end
      -- Also compare the raw URL path tail against route_path tail
      -- (for cases where both use variable refs)
      local raw_suffix = req.url:match("%}%}(.+)$")
      if raw_suffix and route_path:sub(-#raw_suffix) == raw_suffix then
        return true
      end
    end
  end
  return false
end

return M
