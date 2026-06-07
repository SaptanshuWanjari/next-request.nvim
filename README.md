# next-request.nvim

Generate HTTP request snippets for Next.js route handlers using Tree-sitter and
path inference. HTTP files are resolved relative to your current working
directory. Requests are prefixed with `###` for .http file separation.

## Features
- `:NextRequest` builds a request from the handler under the cursor.
- Detects method, body fields, query params, and dynamic route params.
- Appends to a selected `.http` file via `vim.ui.select`.

## Requirements
- Neovim >= 0.9
- Tree-sitter parser for TypeScript/JavaScript

## Installation (lazy.nvim)

```lua
{
  "SaptanshuWanjari/next-request.nvim",
  opts = {
    base_url = "http://localhost:3000",
    route_style = "mustache",
    http_files = { "requests.http" },
    keymap = {
      enabled = false,
      lhs = "<leader>nr",
      mode = "n",
      desc = "Next request",
    },
  },
  config = function(_, opts)
    require("next-request").setup(opts)
  end,
}
```

## Usage
- `:NextRequest` inside a route handler function.

## Configuration

```lua
require("next-request").setup({
  base_url = "http://localhost:3000",
  route_style = "mustache", -- or "colon"
  http_files = {
    "requests.http",
    "auth.http",
  },
  command = "NextRequest",
  keymap = {
    enabled = false,
    lhs = "<leader>nr",
    mode = "n",
    desc = "Next request",
  },
})
```

## License
MIT
