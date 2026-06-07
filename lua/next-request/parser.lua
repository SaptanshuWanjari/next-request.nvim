local M = {}

local METHODS = {
  GET = true,
  POST = true,
  PUT = true,
  PATCH = true,
  DELETE = true,
}

local AUTH_GUARDS = {
  requireAuth = true, getSession = true, verifyToken = true, validateToken = true,
  authenticate = true, currentUser = true, getServerSession = true, auth = true,
}

local URL_VAR_NAMES = {
  "baseUrl", "base_url", "BASE_URL",
  "apiUrl", "api_url", "API_URL",
  "serverUrl", "server_url", "SERVER_URL",
  "host", "HOST", "origin", "ORIGIN",
}

local function get_node_text(node, bufnr)
  if not node then return "" end
  if type(node) == "table" and not node.type then
    node = node[1]
  end
  if not node then return "" end
  return vim.treesitter.get_node_text(node, bufnr) or ""
end

local function find_parent_function(node)
  while node do
    if node:type() == "function_declaration" or node:type() == "arrow_function" or node:type() == "function" then
      return node
    end
    node = node:parent()
  end
end

local function find_child(node, node_type)
  if not node then return nil end
  for child in node:iter_children() do
    if child:type() == node_type then return child end
  end
end

local function get_method_name(fn_node, bufnr)
  if fn_node:type() == "function_declaration" then
    local id = find_child(fn_node, "identifier")
    if id then return string.upper(get_node_text(id, bufnr) or "") end
  elseif fn_node:type() == "arrow_function" then
    local parent = fn_node:parent()
    if parent and parent:type() == "variable_declarator" then
      local id = find_child(parent, "identifier")
      if id then return string.upper(get_node_text(id, bufnr) or "") end
    end
  end
  return nil
end

local function parse_query(lang, query_str)
  local ok, query = pcall(vim.treesitter.query.parse, lang, query_str)
  if not ok then return nil end
  return query
end

local function dedupe(list)
  local seen = {}
  local res = {}
  for _, item in ipairs(list or {}) do
    if item and item ~= "" and not seen[item] then
      table.insert(res, item)
      seen[item] = true
    end
  end
  return res
end

local function extract_zod_keys_from_node(target_node, bufnr, lang)
  local fields = {}
  if type(target_node) == "table" and not target_node.type then target_node = target_node[1] end
  if not target_node then return fields end

  local q = parse_query(lang, [[
    (call_expression
      function: (member_expression property: (property_identifier) @method (#any-of? @method "object" "extend"))
      arguments: (arguments (object (pair key: [(property_identifier) @field (string (string_fragment) @field)])))
    )
  ]])
  if q then
    for _, match, _ in q:iter_matches(target_node, bufnr, 0, -1) do
      for id, n in pairs(match) do
        if q.captures[id] == "field" then
          table.insert(fields, get_node_text(n, bufnr))
        end
      end
    end
  end
  return fields
end

local function extract_zod_schema_keys(schema_obj_node, bufnr, lang, root)
  local fields = {}
  if type(schema_obj_node) == "table" and not schema_obj_node.type then schema_obj_node = schema_obj_node[1] end
  if not schema_obj_node then return fields end
  local node_type = schema_obj_node:type()

  if node_type == "identifier" then
    local schema_name = get_node_text(schema_obj_node, bufnr)
    local q = parse_query(lang, string.format([[
      (variable_declarator
        name: (identifier) @name (#eq? @name "%s")
        value: (_) @value
      )
    ]], schema_name))
    if q then
      for _, match, _ in q:iter_matches(root, bufnr, 0, -1) do
        local value_node
        for id, n in pairs(match) do
          if q.captures[id] == "value" then value_node = n end
        end
        if value_node then
          local keys = extract_zod_keys_from_node(value_node, bufnr, lang)
          for _, k in ipairs(keys) do table.insert(fields, k) end
        end
      end
    end
  else
    local keys = extract_zod_keys_from_node(schema_obj_node, bufnr, lang)
    for _, k in ipairs(keys) do table.insert(fields, k) end
  end
  return fields
end

local function extract_body_fields(body_node, bufnr, lang)
  local fields = {}
  local body_vars = {}
  local root = body_node:tree():root()

  -- 1. Find known body variables from request.json() and Schema.parse()
  local json_q = parse_query(lang, [[
    (variable_declarator
      name: (identifier) @var_name
      value: [(await_expression (call_expression function: (member_expression object: (identifier) @obj property: (property_identifier) @method (#eq? @method "json") (#not-any-of? @obj "NextResponse" "Response"))))
              (call_expression function: (member_expression object: (identifier) @obj property: (property_identifier) @method (#eq? @method "json") (#not-any-of? @obj "NextResponse" "Response")))])
  ]])
  if json_q then
    for _, match, _ in json_q:iter_matches(body_node, bufnr, 0, -1) do
      for id, node in pairs(match) do
        if json_q.captures[id] == "var_name" then
          body_vars[get_node_text(node, bufnr)] = true
        end
      end
    end
  end

  local parse_q = parse_query(lang, [[
    (variable_declarator
      name: (identifier) @var_name
      value: (call_expression
        function: (member_expression property: (property_identifier) @method (#any-of? @method "parse" "safeParse"))
        arguments: (arguments (identifier) @arg_name)))
  ]])
  if parse_q then
    for _, match, _ in parse_q:iter_matches(body_node, bufnr, 0, -1) do
      local var_name, arg_name
      for id, node in pairs(match) do
        if parse_q.captures[id] == "var_name" then var_name = get_node_text(node, bufnr)
        elseif parse_q.captures[id] == "arg_name" then arg_name = get_node_text(node, bufnr) end
      end
      if var_name and arg_name and body_vars[arg_name] then
        body_vars[var_name] = true
      end
    end
  end

  -- 1.5 Extract direct destructuring from .parse()
  local direct_parse_q = parse_query(lang, [[
    (variable_declarator
      name: (object_pattern
        [
          (shorthand_property_identifier_pattern) @field
          (pair_pattern key: (property_identifier) @field)
        ]
      )
      value: (call_expression
        function: (member_expression property: (property_identifier) @method (#any-of? @method "parse" "safeParse"))
        arguments: (arguments (identifier) @arg_name)
      )
    )
  ]])
  if direct_parse_q then
    for _, match, _ in direct_parse_q:iter_matches(body_node, bufnr, 0, -1) do
      local field, arg_name
      for id, node in pairs(match) do
        if direct_parse_q.captures[id] == "field" then field = get_node_text(node, bufnr)
        elseif direct_parse_q.captures[id] == "arg_name" then arg_name = get_node_text(node, bufnr) end
      end
      if field and arg_name and body_vars[arg_name] then
        table.insert(fields, field)
      end
    end
  end

  -- 1.6 Extract all Zod keys automatically when a schema parses a body var
  local any_parse_q = parse_query(lang, [[
    (call_expression
      function: (member_expression object: (_) @schema_obj property: (property_identifier) @method (#any-of? @method "parse" "safeParse"))
      arguments: (arguments (identifier) @arg_name)
    )
  ]])
  if any_parse_q then
    for _, match, _ in any_parse_q:iter_matches(body_node, bufnr, 0, -1) do
      local schema_obj, arg_name
      for id, node in pairs(match) do
        if any_parse_q.captures[id] == "schema_obj" then schema_obj = node
        elseif any_parse_q.captures[id] == "arg_name" then arg_name = get_node_text(node, bufnr) end
      end
      if schema_obj and arg_name and body_vars[arg_name] then
        local schema_keys = extract_zod_schema_keys(schema_obj, bufnr, lang, root)
        for _, k in ipairs(schema_keys) do table.insert(fields, k) end
      end
    end
  end

  -- 2. Extract destructured fields from known body variables
  local destruct_q = parse_query(lang, [[
    (variable_declarator
      name: (object_pattern
        [
          (shorthand_property_identifier_pattern) @field
          (pair_pattern key: (property_identifier) @field)
        ]
      )
      value: [
        (identifier) @source
        (member_expression object: (identifier) @source property: (property_identifier))
      ]
    )
  ]])
  if destruct_q then
    for _, match, _ in destruct_q:iter_matches(body_node, bufnr, 0, -1) do
      local field, source
      for id, node in pairs(match) do
        if destruct_q.captures[id] == "field" then field = get_node_text(node, bufnr)
        elseif destruct_q.captures[id] == "source" then source = get_node_text(node, bufnr) end
      end
      if field and source and body_vars[source] then
        table.insert(fields, field)
      end
    end
  end

  -- 3. Extract direct destructuring from .json()
  local direct_q = parse_query(lang, [[
    (variable_declarator
      name: (object_pattern
        [
          (shorthand_property_identifier_pattern) @field
          (pair_pattern key: (property_identifier) @field)
        ]
      )
      value: [(await_expression (call_expression function: (member_expression property: (property_identifier) @method (#eq? @method "json"))))
              (call_expression function: (member_expression property: (property_identifier) @method (#eq? @method "json")))])
  ]])
  if direct_q then
    for _, match, _ in direct_q:iter_matches(body_node, bufnr, 0, -1) do
      for id, node in pairs(match) do
        if direct_q.captures[id] == "field" then
          table.insert(fields, get_node_text(node, bufnr))
        end
      end
    end
  end

  -- 4. Property access on known body variables (e.g. body.email)
  local prop_q = parse_query(lang, [[
    (member_expression
      object: [
        (identifier) @obj
        (member_expression object: (identifier) @obj property: (property_identifier))
      ]
      property: (property_identifier) @prop)
  ]])
  if prop_q then
    for _, match, _ in prop_q:iter_matches(body_node, bufnr, 0, -1) do
      local obj_name, prop_name
      for id, node in pairs(match) do
        if prop_q.captures[id] == "obj" then obj_name = get_node_text(node, bufnr)
        elseif prop_q.captures[id] == "prop" then prop_name = get_node_text(node, bufnr) end
      end
      if obj_name and prop_name and body_vars[obj_name] then
        if prop_name ~= "data" and prop_name ~= "success" and prop_name ~= "error" then
          table.insert(fields, prop_name)
        end
      end
    end
  end

  return dedupe(fields)
end

local function extract_get_calls(body_node, bufnr, lang)
  local query_params = {}
  local custom_headers = {}

  local q1 = parse_query(lang, [[
    (call_expression
      function: (member_expression
        object: [
          (identifier) @obj
          (member_expression property: (property_identifier) @obj)
        ]
        property: (property_identifier) @method (#eq? @method "get"))
      arguments: (arguments
        (string (string_fragment) @val)))
  ]])
  
  if q1 then
    for _, match, _ in q1:iter_matches(body_node, bufnr, 0, -1) do
      local obj_name, val
      for id, node in pairs(match) do
        if q1.captures[id] == "obj" then obj_name = get_node_text(node, bufnr)
        elseif q1.captures[id] == "val" then val = get_node_text(node, bufnr) end
      end
      if val then
        if obj_name == "searchParams" then
          table.insert(query_params, val)
        elseif obj_name == "headers" then
          table.insert(custom_headers, val)
        end
      end
    end
  end
  
  return dedupe(query_params), dedupe(custom_headers)
end

local function extract_uses_auth(body_node, bufnr, lang)
  local q1 = parse_query(lang, [[
    (call_expression
      function: [
        (identifier) @func_name
        (member_expression property: (property_identifier) @func_name)
      ])
  ]])
  if q1 then
    for _, match, _ in q1:iter_matches(body_node, bufnr, 0, -1) do
      for id, node in pairs(match) do
        if q1.captures[id] == "func_name" then
          local fname = get_node_text(node, bufnr)
          if AUTH_GUARDS[fname] then return true end
        end
      end
    end
  end
  return false
end

function M.parse_base_url(text)
  -- Optional export for backward compatibility with tests/consumers.
  -- We parse using simple regex for baseUrl since it could be file-wide and very diverse.
  if not text or text == "" then return nil end
  for _, var in ipairs(URL_VAR_NAMES) do
    local url = text:match("%a[%w]*%s+" .. var .. "%s*=%s*['\"]([^'\"]+)['\"]")
    if url and url:match("^https?://") then return url end
  end
  local url = text:match("%a[%w]*%s+[%w_]*[Uu][Rr][Ll]%s*=%s*['\"]([^'\"]+)['\"]")
  if url and url:match("^https?://") then return url end
  url = text:match("%?%?%s*['\"]([^'\"]+)['\"]")
  if url and url:match("^https?://") then return url end
  return nil
end

function M.parse_current_function(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local ok = pcall(vim.treesitter.get_parser, bufnr)
  if not ok then
    return nil, "Tree-sitter parser not available for this buffer"
  end

  local parser = vim.treesitter.get_parser(bufnr)
  local lang = parser:lang()

  local node = vim.treesitter.get_node({ bufnr = bufnr })
  if not node then return nil, "No Tree-sitter node at cursor" end

  local fn = find_parent_function(node)
  if not fn then return nil, "No function declaration found" end

  local method = get_method_name(fn, bufnr)
  if not method or not METHODS[method] then
    return nil, "Function name is not a supported HTTP method"
  end

  local body_node = find_child(fn, "statement_block") or find_child(fn, "block")
  if not body_node then
    return { method = method, body_fields = {}, query_params = {}, uses_auth = false, custom_headers = {} }
  end

  local body_fields = extract_body_fields(body_node, bufnr, lang)
  local query_params, custom_headers = extract_get_calls(body_node, bufnr, lang)
  local uses_auth = extract_uses_auth(body_node, bufnr, lang)

  return {
    method = method,
    body_fields = body_fields,
    query_params = query_params,
    uses_auth = uses_auth,
    custom_headers = custom_headers,
  }
end

return M
