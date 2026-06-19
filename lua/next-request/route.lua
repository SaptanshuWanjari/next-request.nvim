local M = {}

local function normalize_path(path)
  local normalized = vim.fs.normalize(path)
  return normalized:gsub("\\", "/")
end

local function strip_route_file(path)
  local stripped, count = path:gsub("/route%.[tj]sx?$", "")
  if count == 0 then return nil end
  return stripped
end

local function apply_route_style(route, style)
  -- Remove Next.js catch-all syntax e.g. [[...slug]] or [...slug]
  route = route:gsub("%[%[%.%.%.(.-)%]%]", "[%1]")
  route = route:gsub("%[%.%.%.(.-)%]", "[%1]")

  if style == "colon" then
    return route:gsub("%[(.-)%]", ":%1")
  end
  return route:gsub("%[(.-)%]", "{{%1}}")
end

function M.from_file(path, style)
  if type(path) ~= "string" or path == "" then
    return nil, "Buffer has no file path"
  end

  local normalized = normalize_path(path)
  local marker = "/app/api/"
  local start = normalized:find(marker, 1, true)
  if not start then
    return nil, "Not an app/api route file"
  end

  local relative = normalized:sub(start + #marker)
  local without_route = strip_route_file("/" .. relative)
  if not without_route then
    return nil, "Not a route.{ts,js,tsx,jsx} file"
  end

  local route = "/api" .. without_route
  route = route:gsub("//+", "/")
  route = apply_route_style(route, style)
  if route == "/api/" then route = "/api" end

  return route
end

return M
