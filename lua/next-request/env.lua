local M = {}

--- Read and parse a .env file into a table of key-value pairs.
--- @param file_path string Path to the .env file
--- @return table map of variables
function M.parse_env(file_path)
  local vars = {}
  local ok, lines = pcall(vim.fn.readfile, file_path)
  if not ok or type(lines) ~= "table" then
    return vars
  end

  for _, line in ipairs(lines) do
    -- Trim whitespace
    line = line:match("^%s*(.-)%s*$")
    
    -- Ignore empty lines and comments
    if line ~= "" and not line:match("^#") then
      local key, value = line:match("^([%w_]+)%s*=%s*(.*)$")
      if key and value then
        -- Remove inline comments
        value = value:gsub("%s*#.*$", "")
        
        -- Remove quotes if present
        local unquoted = value:match('^"(.*)"$') or value:match("^'(.*)'$")
        if unquoted then
          value = unquoted
        end
        
        vars[key] = value
      end
    end
  end

  return vars
end

--- Get a URL from parsed env variables.
--- Prioritizes NEXT_PUBLIC_API_URL, API_URL, NEXT_PUBLIC_BASE_URL, BASE_URL.
--- Falls back to PORT -> http://localhost:PORT.
--- @param vars table
--- @return string|nil
function M.get_base_url(vars)
  local priority_keys = {
    "NEXT_PUBLIC_API_URL",
    "API_URL",
    "NEXT_PUBLIC_BASE_URL",
    "BASE_URL",
  }
  
  for _, key in ipairs(priority_keys) do
    if vars[key] and vars[key] ~= "" then
      return vars[key]
    end
  end
  
  if vars["PORT"] and vars["PORT"] ~= "" then
    return "http://localhost:" .. vars["PORT"]
  end
  
  return nil
end

return M
