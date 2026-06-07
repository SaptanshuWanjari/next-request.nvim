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

-- Properties on body variables that should never be treated as body fields.
local PROP_EXCLUSIONS = {
  data = true, success = true, error = true, message = true,
  status = true, statusCode = true, ok = true, result = true,
  errors = true, meta = true, pagination = true,
}

-- ── Helpers ──────────────────────────────────────────────────────────────────

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

-- ── Query cache ─────────────────────────────────────────────────────────────
-- Compiled Tree-sitter queries are deterministic per language; cache them so
-- we only call vim.treesitter.query.parse() once per (lang, key) pair.

local _query_cache = {} -- _query_cache[lang][key] = compiled_query | false

local function cached_query(lang, key, query_str)
  _query_cache[lang] = _query_cache[lang] or {}
  if _query_cache[lang][key] == nil then
    local ok, query = pcall(vim.treesitter.query.parse, lang, query_str)
    _query_cache[lang][key] = ok and query or false
  end
  return _query_cache[lang][key] or nil
end

-- Non-cached parse_query for dynamic queries (e.g. with interpolated schema names).
local function parse_query(lang, query_str)
  local ok, query = pcall(vim.treesitter.query.parse, lang, query_str)
  if not ok then return nil end
  return query
end

-- ── Zod schema resolution ───────────────────────────────────────────────────

local function extract_zod_keys_from_node(target_node, bufnr, lang)
  local fields = {}
  local hints = {}
  if type(target_node) == "table" and not target_node.type then target_node = target_node[1] end
  if not target_node then return fields, hints end

  -- Known Zod type methods → canonical hint label
  local ZOD_TYPES = {
    string = "string", number = "number", boolean = "boolean",
    enum = "enum",     nativeEnum = "enum",
    array = "array",   tuple = "array",
    object = "object", record = "object", map = "object",
    date = "date",     bigint = "number",
    union = "union",   discriminatedUnion = "union",
    literal = "literal", set = "array",
  }
  -- Modifier methods that appear AFTER the type and should be skipped
  local ZOD_MODIFIERS = {
    optional=true, nullable=true, nullish=true,
    default=true, catch=true, transform=true, pipe=true,
    refine=true, superRefine=true, parse=true, safeParse=true,
    min=true, max=true, length=true, email=true, url=true, uuid=true,
    startsWith=true, endsWith=true, regex=true, trim=true,
    toLowerCase=true, toUpperCase=true,
    int=true, positive=true, negative=true, nonpositive=true,
    nonnegative=true, finite=true, step=true,
    describe=true, brand=true, readonly=true,
  }

  local q = cached_query(lang, "zod_object_keys", [[
    (call_expression
      function: (member_expression property: (property_identifier) @method (#any-of? @method "object" "extend"))
      arguments: (arguments (object (pair
        key: [(property_identifier) @field (string (string_fragment) @field)]
        value: (_) @type_val
      ))))
  ]])
  if q then
    for _, match, _ in q:iter_matches(target_node, bufnr, 0, -1) do
      local field, type_val
      for id, n in pairs(match) do
        n = type(n) == "table" and n[1] or n
        if q.captures[id] == "field" then
          field = get_node_text(n, bufnr)
        elseif q.captures[id] == "type_val" then
          type_val = n
        end
      end
      if field then
        table.insert(fields, field)
        if type_val then
          local pq = cached_query(lang, "zod_type_prop", "(property_identifier) @prop")
          if pq then
            local found_hint
            -- Collect all property_identifiers in the type_val expression
            local all_props = {}
            for _, pm, _ in pq:iter_matches(type_val, bufnr, 0, -1) do
              for pid, pn in pairs(pm) do
                pn = type(pn) == "table" and pn[1] or pn
                table.insert(all_props, get_node_text(pn, bufnr))
              end
            end

            -- If type_val is just an identifier (e.g. role: RoleEnum), try to resolve it locally
            if #all_props == 0 and type_val:type() == "identifier" then
              local var_name = get_node_text(type_val, bufnr)
              local root = type_val:tree():root()
              local vq = parse_query(lang, string.format([[
                (variable_declarator
                  name: (identifier) @name (#eq? @name "%s")
                  value: (_) @value
                )
              ]], var_name))
              if vq then
                for _, match, _ in vq:iter_matches(root, bufnr, 0, -1) do
                  local val_node
                  for id, n in pairs(match) do
                    if vq.captures[id] == "value" then val_node = type(n) == "table" and n[1] or n end
                  end
                  if val_node then
                    for _, pm, _ in pq:iter_matches(val_node, bufnr, 0, -1) do
                      for pid, pn in pairs(pm) do
                        pn = type(pn) == "table" and pn[1] or pn
                        table.insert(all_props, get_node_text(pn, bufnr))
                      end
                    end
                  end
                end
              end
            end
            -- Find the first prop that is a known Zod type (skip "z", modifiers, and unknown methods)
            for _, prop_name in ipairs(all_props) do
              if prop_name ~= "z" and not ZOD_MODIFIERS[prop_name] then
                if ZOD_TYPES[prop_name] then
                  found_hint = ZOD_TYPES[prop_name]
                  break
                end
              end
            end
            if found_hint then hints[field] = found_hint end
          end
        end
      end
    end
  end
  return fields, hints
end


--- Resolve a Zod schema node to its set of top-level keys.
--- Returns fields, hints
local function extract_zod_schema_keys(schema_obj_node, bufnr, lang, root)
  local fields = {}
  local hints = {}
  if type(schema_obj_node) == "table" and not schema_obj_node.type then schema_obj_node = schema_obj_node[1] end
  if not schema_obj_node then return fields, hints end
  local node_type = schema_obj_node:type()

  -- Helper to merge hints
  local function merge_hints(new_hints)
    for k, v in pairs(new_hints or {}) do hints[k] = v end
  end

  -- Identifier → look up the variable declaration in the file root
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
          local keys, h = extract_zod_schema_keys(value_node, bufnr, lang, root)
          if #keys == 0 then
            keys, h = extract_zod_keys_from_node(value_node, bufnr, lang)
          end
          for _, k in ipairs(keys) do table.insert(fields, k) end
          merge_hints(h)
        end
      end
    end

    -- If the schema wasn't found in the current file, try cross-file resolution
    if #fields == 0 then
      local resolver_ok, resolver = pcall(require, "next-request.resolver")
      if resolver_ok then
        local imported_keys, imported_hints = resolver.resolve_imported_schema(bufnr, schema_name)
        if imported_keys then
          for _, k in ipairs(imported_keys) do table.insert(fields, k) end
          merge_hints(imported_hints)
        end
      end
    end

    return dedupe(fields), hints
  end

  -- call_expression → could be .object(), .extend(), .merge(), .pick(), .omit()
  if node_type == "call_expression" then
    local fn_child = find_child(schema_obj_node, "member_expression")
    if fn_child then
      local prop_node = find_child(fn_child, "property_identifier")
      local method_name = prop_node and get_node_text(prop_node, bufnr) or ""

      local base_node
      for child in fn_child:iter_children() do
        if child:type() ~= "property_identifier" and child:type() ~= "." then
          base_node = child
          break
        end
      end

      if method_name == "object" then
        local keys, h = extract_zod_keys_from_node(schema_obj_node, bufnr, lang)
        for _, k in ipairs(keys) do table.insert(fields, k) end
        merge_hints(h)

      elseif method_name == "extend" then
        if base_node then
          local base_keys, h = extract_zod_schema_keys(base_node, bufnr, lang, root)
          for _, k in ipairs(base_keys) do table.insert(fields, k) end
          merge_hints(h)
        end
        local ext_keys, h = extract_zod_keys_from_node(schema_obj_node, bufnr, lang)
        for _, k in ipairs(ext_keys) do table.insert(fields, k) end
        merge_hints(h)

      elseif method_name == "merge" then
        if base_node then
          local base_keys, h = extract_zod_schema_keys(base_node, bufnr, lang, root)
          for _, k in ipairs(base_keys) do table.insert(fields, k) end
          merge_hints(h)
        end
        local args = find_child(schema_obj_node, "arguments")
        if args then
          for child in args:iter_children() do
            if child:type() ~= "(" and child:type() ~= ")" and child:type() ~= "," then
              local merge_keys, h = extract_zod_schema_keys(child, bufnr, lang, root)
              for _, k in ipairs(merge_keys) do table.insert(fields, k) end
              merge_hints(h)
            end
          end
        end

      elseif method_name == "pick" then
        if base_node then
          local base_keys, h = extract_zod_schema_keys(base_node, bufnr, lang, root)
          local pick_set = {}
          local args = find_child(schema_obj_node, "arguments")
          if args then
            local obj = find_child(args, "object")
            if obj then
              for child in obj:iter_children() do
                if child:type() == "pair" then
                  local key = find_child(child, "property_identifier")
                  if key then pick_set[get_node_text(key, bufnr)] = true end
                end
              end
            end
          end
          for _, k in ipairs(base_keys) do
            if pick_set[k] then
              table.insert(fields, k)
              if h[k] then hints[k] = h[k] end
            end
          end
        end

      elseif method_name == "omit" then
        if base_node then
          local base_keys, h = extract_zod_schema_keys(base_node, bufnr, lang, root)
          local omit_set = {}
          local args = find_child(schema_obj_node, "arguments")
          if args then
            local obj = find_child(args, "object")
            if obj then
              for child in obj:iter_children() do
                if child:type() == "pair" then
                  local key = find_child(child, "property_identifier")
                  if key then omit_set[get_node_text(key, bufnr)] = true end
                end
              end
            end
          end
          for _, k in ipairs(base_keys) do
            if not omit_set[k] then
              table.insert(fields, k)
              if h[k] then hints[k] = h[k] end
            end
          end
        end

      else
        if base_node then
          local base_keys, h = extract_zod_schema_keys(base_node, bufnr, lang, root)
          for _, k in ipairs(base_keys) do table.insert(fields, k) end
          merge_hints(h)
        end
      end

      return dedupe(fields), hints
    end

    local keys, h = extract_zod_keys_from_node(schema_obj_node, bufnr, lang)
    for _, k in ipairs(keys) do table.insert(fields, k) end
    merge_hints(h)
    return dedupe(fields), hints
  end

  local keys, h = extract_zod_keys_from_node(schema_obj_node, bufnr, lang)
  for _, k in ipairs(keys) do table.insert(fields, k) end
  merge_hints(h)
  return dedupe(fields), hints
end

-- ── Body field extraction ───────────────────────────────────────────────────

--- Detect the content type by looking at how the request body is parsed.
--- Returns "form-data" if formData() is used, "text" if text() is used,
--- "json" otherwise.
local function detect_content_type(body_node, bufnr, lang)
  -- Check for formData()
  local fd_q = cached_query(lang, "formdata_call", [[
    (call_expression
      function: (member_expression property: (property_identifier) @method (#eq? @method "formData")))
  ]])
  if fd_q then
    for _ in fd_q:iter_matches(body_node, bufnr, 0, -1) do
      return "form-data"
    end
  end

  -- Check for text()
  local text_q = cached_query(lang, "text_call", [[
    (call_expression
      function: (member_expression property: (property_identifier) @method (#eq? @method "text")))
  ]])
  if text_q then
    for _ in text_q:iter_matches(body_node, bufnr, 0, -1) do
      return "text"
    end
  end

  return "json"
end

--- Extract fields from formData.get("key") / formData.getAll("key") calls.
local function extract_formdata_fields(body_node, bufnr, lang)
  local fields = {}
  local fd_vars = {}

  -- Find variables assigned from .formData()
  local fd_var_q = cached_query(lang, "formdata_var", [[
    (variable_declarator
      name: (identifier) @var_name
      value: [(await_expression (call_expression function: (member_expression property: (property_identifier) @method (#eq? @method "formData"))))
              (call_expression function: (member_expression property: (property_identifier) @method (#eq? @method "formData")))])
  ]])
  if fd_var_q then
    for _, match, _ in fd_var_q:iter_matches(body_node, bufnr, 0, -1) do
      for id, node in pairs(match) do
        if fd_var_q.captures[id] == "var_name" then
          fd_vars[get_node_text(node, bufnr)] = true
        end
      end
    end
  end

  -- Find .get("key") / .getAll("key") / .has("key") calls on formData vars
  local get_q = cached_query(lang, "formdata_get", [[
    (call_expression
      function: (member_expression
        object: (identifier) @obj
        property: (property_identifier) @method (#any-of? @method "get" "getAll" "has"))
      arguments: (arguments
        (string (string_fragment) @val)))
  ]])
  if get_q then
    for _, match, _ in get_q:iter_matches(body_node, bufnr, 0, -1) do
      local obj_name, val
      for id, node in pairs(match) do
        if get_q.captures[id] == "obj" then obj_name = get_node_text(node, bufnr)
        elseif get_q.captures[id] == "val" then val = get_node_text(node, bufnr) end
      end
      if val and obj_name and fd_vars[obj_name] then
        table.insert(fields, val)
      end
    end
  end

  return dedupe(fields)
end

local function extract_body_fields(body_node, bufnr, lang)
  local fields = {}
  local hints = {}
  local body_vars = {}
  local root = body_node:tree():root()

  -- Helper to merge hints
  local function merge_hints(new_hints)
    for k, v in pairs(new_hints or {}) do hints[k] = v end
  end

  -- 1. Find known body variables from request.json()
  local json_q = cached_query(lang, "json_var", [[
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

  -- 1.1 Track variables assigned from Schema.parse(bodyVar)
  local parse_q = cached_query(lang, "parse_var", [[
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
  local direct_parse_q = cached_query(lang, "direct_parse_destruct", [[
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
  local any_parse_q = cached_query(lang, "any_parse", [[
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
        local schema_keys, h = extract_zod_schema_keys(schema_obj, bufnr, lang, root)
        for _, k in ipairs(schema_keys) do table.insert(fields, k) end
        merge_hints(h)
      end
    end
  end

  -- 2. Extract destructured fields from known body variables
  local destruct_q = cached_query(lang, "destruct_body", [[
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
  local direct_q = cached_query(lang, "direct_json_destruct", [[
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
  local prop_q = cached_query(lang, "prop_access", [[
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
        if not PROP_EXCLUSIONS[prop_name] then
          table.insert(fields, prop_name)
        end
      end
    end
  end

  return dedupe(fields), hints
end

-- ── Query params & headers ──────────────────────────────────────────────────

local function extract_get_calls(body_node, bufnr, lang)
  local query_params = {}
  local custom_headers = {}

  -- Match .get("key"), .has("key"), .getAll("key") on searchParams or headers
  local q1 = cached_query(lang, "get_calls", [[
    (call_expression
      function: (member_expression
        object: [
          (identifier) @obj
          (member_expression property: (property_identifier) @obj)
        ]
        property: (property_identifier) @method (#any-of? @method "get" "has" "getAll"))
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

-- ── Auth detection ──────────────────────────────────────────────────────────

local function extract_uses_auth(body_node, bufnr, lang)
  local q1 = cached_query(lang, "auth_calls", [[
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

-- ── Response status detection ───────────────────────────────────────────────

local function extract_response_status(body_node, bufnr, lang)
  -- Look for Response.json({...}, { status: NNN }) or NextResponse.json({...}, { status: NNN })
  local q = cached_query(lang, "response_status", [[
    (call_expression
      function: (member_expression
        object: (identifier) @obj (#any-of? @obj "Response" "NextResponse")
        property: (property_identifier) @method (#eq? @method "json"))
      arguments: (arguments
        (_)
        (object (pair
          key: (property_identifier) @key (#eq? @key "status")
          value: (number) @status_val))))
  ]])
  if q then
    for _, match, _ in q:iter_matches(body_node, bufnr, 0, -1) do
      for id, node in pairs(match) do
        if q.captures[id] == "status_val" then
          local val = get_node_text(node, bufnr)
          local num = tonumber(val)
          if num then return num end
        end
      end
    end
  end

  -- Also check: new Response(body, { status: NNN })
  local q2 = cached_query(lang, "new_response_status", [[
    (new_expression
      constructor: (identifier) @obj (#any-of? @obj "Response" "NextResponse")
      arguments: (arguments
        (_)
        (object (pair
          key: (property_identifier) @key (#eq? @key "status")
          value: (number) @status_val))))
  ]])
  if q2 then
    for _, match, _ in q2:iter_matches(body_node, bufnr, 0, -1) do
      for id, node in pairs(match) do
        if q2.captures[id] == "status_val" then
          local val = get_node_text(node, bufnr)
          local num = tonumber(val)
          if num then return num end
        end
      end
    end
  end

  return nil
end

-- ── Base URL ────────────────────────────────────────────────────────────────

function M.parse_base_url(text)
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

-- ── Main public API ─────────────────────────────────────────────────────────

--- Parse the handler function under the cursor.
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
    return {
      method = method, body_fields = {}, query_params = {},
      uses_auth = false, custom_headers = {}, content_type = "json",
      response_status = nil,
    }
  end

  local content_type = detect_content_type(body_node, bufnr, lang)

  local body_fields = {}
  local body_hints = {}
  if content_type == "form-data" then
    body_fields = extract_formdata_fields(body_node, bufnr, lang)
  elseif content_type == "text" then
    body_fields = {}
  else
    body_fields, body_hints = extract_body_fields(body_node, bufnr, lang)
  end

  local query_params, custom_headers = extract_get_calls(body_node, bufnr, lang)
  local uses_auth = extract_uses_auth(body_node, bufnr, lang)
  local response_status = extract_response_status(body_node, bufnr, lang)

  return {
    method = method,
    body_fields = body_fields,
    body_hints = body_hints,
    query_params = query_params,
    uses_auth = uses_auth,
    custom_headers = custom_headers,
    content_type = content_type,
    response_status = response_status,
  }
end

--- Parse ALL exported handler functions in a buffer.
--- Returns a list of results (same shape as parse_current_function).
function M.parse_all_functions(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local ok = pcall(vim.treesitter.get_parser, bufnr)
  if not ok then return {}, "Tree-sitter parser not available for this buffer" end

  local parser = vim.treesitter.get_parser(bufnr)
  local lang = parser:lang()
  local tree = parser:parse()[1]
  if not tree then return {}, "Failed to parse buffer" end
  local root = tree:root()

  local results = {}

  -- Find exported function declarations: export async function GET(...)
  local fn_q = cached_query(lang, "exported_functions", [[
    (export_statement
      (function_declaration
        name: (identifier) @name
      ) @fn
    )
  ]])
  if fn_q then
    for _, match, _ in fn_q:iter_matches(root, bufnr, 0, -1) do
      local fn_node, name
      for id, node in pairs(match) do
        if fn_q.captures[id] == "fn" then
          fn_node = type(node) == "table" and node[1] or node
        elseif fn_q.captures[id] == "name" then
          name = get_node_text(node, bufnr)
        end
      end
      local method = name and string.upper(name) or nil
      if method and METHODS[method] and fn_node then
        local body_node = find_child(fn_node, "statement_block")
        if body_node then
          local ct = detect_content_type(body_node, bufnr, lang)
          local bf, bh = {}, {}
          if ct == "form-data" then
            bf = extract_formdata_fields(body_node, bufnr, lang)
          elseif ct == "text" then
            bf = {}
          else
            bf, bh = extract_body_fields(body_node, bufnr, lang)
          end
          local qp, ch = extract_get_calls(body_node, bufnr, lang)
          table.insert(results, {
            method = method,
            body_fields = bf,
            body_hints = bh,
            query_params = qp,
            uses_auth = extract_uses_auth(body_node, bufnr, lang),
            custom_headers = ch,
            content_type = ct,
            response_status = extract_response_status(body_node, bufnr, lang),
          })
        end
      end
    end
  end

  -- Find exported arrow functions: export const GET = async (req) => { ... }
  local arrow_q = cached_query(lang, "exported_arrow_functions", [[
    (export_statement
      (lexical_declaration
        (variable_declarator
          name: (identifier) @name
          value: (arrow_function) @fn
        )
      )
    )
  ]])
  if arrow_q then
    for _, match, _ in arrow_q:iter_matches(root, bufnr, 0, -1) do
      local fn_node, name
      for id, node in pairs(match) do
        if arrow_q.captures[id] == "fn" then
          fn_node = type(node) == "table" and node[1] or node
        elseif arrow_q.captures[id] == "name" then
          name = get_node_text(node, bufnr)
        end
      end
      local method = name and string.upper(name) or nil
      if method and METHODS[method] and fn_node then
        local body_node = find_child(fn_node, "statement_block")
        if body_node then
          local ct = detect_content_type(body_node, bufnr, lang)
          local bf, bh = {}, {}
          if ct == "form-data" then
            bf = extract_formdata_fields(body_node, bufnr, lang)
          elseif ct == "text" then
            bf = {}
          else
            bf, bh = extract_body_fields(body_node, bufnr, lang)
          end
          local qp, ch = extract_get_calls(body_node, bufnr, lang)
          table.insert(results, {
            method = method,
            body_fields = bf,
            body_hints = bh,
            query_params = qp,
            uses_auth = extract_uses_auth(body_node, bufnr, lang),
            custom_headers = ch,
            content_type = ct,
            response_status = extract_response_status(body_node, bufnr, lang),
          })
        end
      end
    end
  end

  return results
end

return M
