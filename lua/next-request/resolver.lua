--- Cross-file Zod schema resolver for next-request.nvim.
---
--- When the parser detects a Schema.parse(body) call but cannot find
--- the schema definition in the current buffer, this module:
--- 1. Scans import statements to find where the schema is imported from
--- 2. Resolves the file path (handling @/ aliases via tsconfig.json)
--- 3. Loads and parses the target file to extract Zod schema keys
--- 4. Caches results to avoid repeated disk I/O

local M = {}

-- Cache: resolved_path -> { keys = {...}, mtime = number }
local _file_cache = {}

-- Cache: project_root -> { paths = {...} }
local _tsconfig_cache = {}

--- Find the project root by walking up from `start` until we find
--- tsconfig.json, package.json, or .git.
local function find_project_root(start)
  local markers = { "tsconfig.json", "package.json", ".git" }
  local found = vim.fs.find(markers, {
    path = start,
    upward = true,
    stop = vim.env.HOME,
    limit = 1,
  })
  if found and #found > 0 then
    return vim.fs.dirname(found[1])
  end
  return nil
end

--- Parse tsconfig.json to extract `compilerOptions.paths`.
--- Returns a table mapping alias prefixes to directory arrays.
--- e.g. { ["@/"] = { "./src/" } }
local function load_tsconfig_paths(project_root)
  if not project_root then return {} end
  if _tsconfig_cache[project_root] then return _tsconfig_cache[project_root] end

  local tsconfig_path = project_root .. "/tsconfig.json"
  local ok, lines = pcall(vim.fn.readfile, tsconfig_path)
  if not ok or type(lines) ~= "table" then
    _tsconfig_cache[project_root] = {}
    return {}
  end

  local text = table.concat(lines, "\n")
  -- Strip single-line comments (// ...) which tsconfig.json commonly uses
  text = text:gsub("//[^\n]*", "")

  local json_ok, config = pcall(vim.fn.json_decode, text)
  if not json_ok or type(config) ~= "table" then
    _tsconfig_cache[project_root] = {}
    return {}
  end

  local paths = {}
  local compiler_opts = config.compilerOptions or {}
  local base_url = compiler_opts.baseUrl or "."
  local raw_paths = compiler_opts.paths or {}

  for alias, dirs in pairs(raw_paths) do
    -- Convert "alias/*" → "alias/" prefix, "@/*" → "@/"
    local prefix = alias:gsub("%*$", "")
    paths[prefix] = {}
    for _, dir in ipairs(dirs) do
      -- Convert "./src/*" → "./src/" or "src/*" → "src/"
      local resolved = dir:gsub("%*$", "")
      -- Make it absolute relative to baseUrl
      if not resolved:match("^/") then
        resolved = vim.fs.normalize(project_root .. "/" .. base_url .. "/" .. resolved)
      end
      table.insert(paths[prefix], resolved)
    end
  end

  _tsconfig_cache[project_root] = paths
  return paths
end

--- Resolve an import specifier to an absolute file path.
--- Handles:
---   "@/lib/schemas"  → via tsconfig paths
---   "./schemas"      → relative to current file
---   "../shared/schemas" → relative to current file
local function resolve_import_path(specifier, current_file, project_root)
  local dir = vim.fs.dirname(current_file)
  local exts = { ".ts", ".tsx", ".js", ".jsx", "/index.ts", "/index.tsx", "/index.js", "/index.jsx" }
  local candidates = {}

  -- Relative imports
  if specifier:match("^%.%.?/") then
    local base = vim.fs.normalize(dir .. "/" .. specifier)
    table.insert(candidates, base)

  -- Aliased imports (e.g. @/lib/schemas)
  else
    local paths = load_tsconfig_paths(project_root)
    for prefix, dirs in pairs(paths) do
      if specifier:sub(1, #prefix) == prefix then
        local rest = specifier:sub(#prefix + 1)
        for _, base_dir in ipairs(dirs) do
          table.insert(candidates, vim.fs.normalize(base_dir .. "/" .. rest))
        end
      end
    end
  end

  -- Try each candidate with each extension
  for _, base in ipairs(candidates) do
    -- Try the exact path first (already has extension?)
    if vim.fn.filereadable(base) == 1 then
      return base
    end
    for _, ext in ipairs(exts) do
      local try = base .. ext
      if vim.fn.filereadable(try) == 1 then
        return try
      end
    end
  end

  return nil
end

--- Extract Zod schema keys from a file for a given schema name.
--- Returns a list of field names, or nil if the schema isn't found.
local function extract_schema_keys_from_file(file_path, schema_name)
  -- Check cache
  local stat = vim.uv.fs_stat(file_path)
  if not stat then return nil end

  local cached = _file_cache[file_path .. ":" .. schema_name]
  if cached and cached.mtime == stat.mtime.sec then
    return cached.keys, cached.hints
  end

  -- Load and parse the file
  local bufnr = vim.fn.bufadd(file_path)
  vim.fn.bufload(bufnr)

  local ts_ok = pcall(vim.treesitter.get_parser, bufnr)
  if not ts_ok then return nil end

  local parser = vim.treesitter.get_parser(bufnr)
  local lang = parser:lang()
  local tree = parser:parse()[1]
  if not tree then return nil end
  local root = tree:root()

  -- Build a helper that mirrors what our parser does
  local function get_node_text(node)
    if not node then return "" end
    if type(node) == "table" and not node.type then node = node[1] end
    if not node then return "" end
    return vim.treesitter.get_node_text(node, bufnr) or ""
  end

  local function find_child(node, node_type)
    if not node then return nil end
    for child in node:iter_children() do
      if child:type() == node_type then return child end
    end
  end

  local function pq(query_str)
    local ok2, query = pcall(vim.treesitter.query.parse, lang, query_str)
    if not ok2 then return nil end
    return query
  end

  -- Forward declaration for recursive calls
  local extract_keys_from_node
  local resolve_schema_node

  extract_keys_from_node = function(target_node)
    local fields = {}
    local hints = {}
    if type(target_node) == "table" and not target_node.type then target_node = target_node[1] end
    if not target_node then return fields, hints end

    local q = pq([[
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
            field = get_node_text(n)
          elseif q.captures[id] == "type_val" then
            type_val = n
          end
        end
        if field then
          table.insert(fields, field)
          if type_val then
            local pq_type = pq("(property_identifier) @prop")
            if pq_type then
              local found_hint
              for _, pm, _ in pq_type:iter_matches(type_val, bufnr, 0, -1) do
                for pid, pn in pairs(pm) do
                  pn = type(pn) == "table" and pn[1] or pn
                  local prop_name = get_node_text(pn)
                  if prop_name == "string" or prop_name == "number" or prop_name == "boolean" or prop_name == "enum" or prop_name == "array" or prop_name == "object" or prop_name == "date" then
                    found_hint = prop_name
                    break
                  end
                end
                if found_hint then break end
              end
              if found_hint then hints[field] = found_hint end
            end
          end
        end
      end
    end
    return fields, hints
  end

  resolve_schema_node = function(node)
    local fields = {}
    local hints = {}
    if type(node) == "table" and not node.type then node = node[1] end
    if not node then return fields, hints end

    local nt = node:type()

    local function merge_hints(h)
      for k, v in pairs(h or {}) do hints[k] = v end
    end

    if nt == "identifier" then
      local name = get_node_text(node)
      local vq = pq(string.format([[
        (variable_declarator
          name: (identifier) @name (#eq? @name "%s")
          value: (_) @value
        )
      ]], name))
      if vq then
        for _, match, _ in vq:iter_matches(root, bufnr, 0, -1) do
          local value_node
          for id, n in pairs(match) do
            if vq.captures[id] == "value" then value_node = n end
          end
          if value_node then
            local keys, h = resolve_schema_node(value_node)
            if #keys == 0 then keys, h = extract_keys_from_node(value_node) end
            for _, k in ipairs(keys) do table.insert(fields, k) end
            merge_hints(h)
          end
        end
      end

    elseif nt == "call_expression" then
      local fn_child = find_child(node, "member_expression")
      if fn_child then
        local prop = find_child(fn_child, "property_identifier")
        local method_name = prop and get_node_text(prop) or ""

        local base_node
        for child in fn_child:iter_children() do
          if child:type() ~= "property_identifier" and child:type() ~= "." then
            base_node = child
            break
          end
        end

        if method_name == "object" then
          local keys, h = extract_keys_from_node(node)
          for _, k in ipairs(keys) do table.insert(fields, k) end
          merge_hints(h)
        elseif method_name == "extend" then
          if base_node then
            local bk, h = resolve_schema_node(base_node)
            for _, k in ipairs(bk) do table.insert(fields, k) end
            merge_hints(h)
          end
          local ek, h = extract_keys_from_node(node)
          for _, k in ipairs(ek) do table.insert(fields, k) end
          merge_hints(h)
        elseif method_name == "merge" then
          if base_node then
            local bk, h = resolve_schema_node(base_node)
            for _, k in ipairs(bk) do table.insert(fields, k) end
            merge_hints(h)
          end
          local args = find_child(node, "arguments")
          if args then
            for child in args:iter_children() do
              if child:type() ~= "(" and child:type() ~= ")" and child:type() ~= "," then
                local mk, h = resolve_schema_node(child)
                for _, k in ipairs(mk) do table.insert(fields, k) end
                merge_hints(h)
              end
            end
          end
        elseif method_name == "pick" then
          if base_node then
            local bk, h = resolve_schema_node(base_node)
            local pick_set = {}
            local args = find_child(node, "arguments")
            if args then
              local obj = find_child(args, "object")
              if obj then
                for child in obj:iter_children() do
                  if child:type() == "pair" then
                    local key = find_child(child, "property_identifier")
                    if key then pick_set[get_node_text(key)] = true end
                  end
                end
              end
            end
            for _, k in ipairs(bk) do
              if pick_set[k] then
                table.insert(fields, k)
                if h[k] then hints[k] = h[k] end
              end
            end
          end
        elseif method_name == "omit" then
          if base_node then
            local bk, h = resolve_schema_node(base_node)
            local omit_set = {}
            local args = find_child(node, "arguments")
            if args then
              local obj = find_child(args, "object")
              if obj then
                for child in obj:iter_children() do
                  if child:type() == "pair" then
                    local key = find_child(child, "property_identifier")
                    if key then omit_set[get_node_text(key)] = true end
                  end
                end
              end
            end
            for _, k in ipairs(bk) do
              if not omit_set[k] then
                table.insert(fields, k)
                if h[k] then hints[k] = h[k] end
              end
            end
          end
        else
          if base_node then
            local bk, h = resolve_schema_node(base_node)
            for _, k in ipairs(bk) do table.insert(fields, k) end
            merge_hints(h)
          end
        end
      else
        local keys, h = extract_keys_from_node(node)
        for _, k in ipairs(keys) do table.insert(fields, k) end
        merge_hints(h)
      end

    else
      local keys, h = extract_keys_from_node(node)
      for _, k in ipairs(keys) do table.insert(fields, k) end
      merge_hints(h)
    end

    -- Dedupe
    local seen = {}
    local res = {}
    for _, item in ipairs(fields) do
      if item and item ~= "" and not seen[item] then
        table.insert(res, item)
        seen[item] = true
      end
    end
    return res, hints
  end

  -- Find the schema by name
  local find_q = pq(string.format([[
    (variable_declarator
      name: (identifier) @name (#eq? @name "%s")
      value: (_) @value
    )
  ]], schema_name))

  local keys = {}
  local hints = {}
  if find_q then
    for _, match, _ in find_q:iter_matches(root, bufnr, 0, -1) do
      local value_node
      for id, n in pairs(match) do
        if find_q.captures[id] == "value" then value_node = n end
      end
      if value_node then
        keys, hints = resolve_schema_node(value_node)
        break -- take the first definition
      end
    end
  end

  -- Also check for `export const SchemaName = ...` with type assertion
  if #keys == 0 then
    local export_q = pq(string.format([[
      (export_statement
        (lexical_declaration
          (variable_declarator
            name: (identifier) @name (#eq? @name "%s")
            value: (_) @value
          )
        )
      )
    ]], schema_name))
    if export_q then
      for _, match, _ in export_q:iter_matches(root, bufnr, 0, -1) do
        local value_node
        for id, n in pairs(match) do
          if export_q.captures[id] == "value" then value_node = n end
        end
        if value_node then
          keys, hints = resolve_schema_node(value_node)
          break
        end
      end
    end
  end

  -- Cache the result
  _file_cache[file_path .. ":" .. schema_name] = {
    keys = keys,
    hints = hints,
    mtime = stat.mtime.sec,
  }

  return #keys > 0 and keys or nil, hints
end

--- Given a buffer and a schema name that wasn't found locally,
--- scan import statements and try to resolve the schema from the imported file.
function M.resolve_imported_schema(bufnr, schema_name)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local current_file = vim.api.nvim_buf_get_name(bufnr)
  if not current_file or current_file == "" then return nil end

  local project_root = find_project_root(vim.fs.dirname(current_file))

  -- Parse the tree to find imports
  local ts_ok = pcall(vim.treesitter.get_parser, bufnr)
  if not ts_ok then return nil end

  local parser = vim.treesitter.get_parser(bufnr)
  local lang = parser:lang()
  local tree = parser:parse()[1]
  if not tree then return nil end
  local root = tree:root()

  -- Find import { SchemaName } from "path" or import { SchemaName as Alias } from "path"
  local import_q_ok, import_q = pcall(vim.treesitter.query.parse, lang, string.format([[
    (import_statement
      (import_clause
        (named_imports
          [(import_specifier name: (identifier) @name (#eq? @name "%s"))
           (import_specifier name: (identifier) @original alias: (identifier) @alias (#eq? @alias "%s"))
          ]
        )
      )
      source: (string (string_fragment) @source)
    )
  ]], schema_name, schema_name))

  if not import_q_ok or not import_q then return nil end

  for _, match, _ in import_q:iter_matches(root, bufnr, 0, -1) do
    local source, original_name
    for id, node in pairs(match) do
      local n = type(node) == "table" and node[1] or node
      if n then
        local cap = import_q.captures[id]
        if cap == "source" then
          source = vim.treesitter.get_node_text(n, bufnr)
        elseif cap == "original" then
          original_name = vim.treesitter.get_node_text(n, bufnr)
        end
      end
    end

    if source then
      local resolved_path = resolve_import_path(source, current_file, project_root)
      if resolved_path then
        -- If it was aliased (import { Foo as Bar }), look up Foo in the target file
        local lookup_name = original_name or schema_name
        local keys, hints = extract_schema_keys_from_file(resolved_path, lookup_name)
        if keys then return keys, hints end
      end
    end
  end

  return nil, nil
end

--- Clear all caches (useful for testing or when files change).
function M.clear_cache()
  _file_cache = {}
  _tsconfig_cache = {}
end

return M
