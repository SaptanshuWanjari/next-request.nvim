# next-request.nvim

Generate HTTP request snippets for Next.js route handlers using Tree-sitter and
path inference. HTTP files are resolved relative to your current working
directory. Requests are prefixed with `###` for .http file separation.

## Features
- `:NextRequest` builds a request from the handler under the cursor and appends to a `.http` file via `vim.ui.select`.
- `:NextRequestRun` builds and immediately runs the request in a side-by-side floating window using [kulala.nvim](https://github.com/mistweaverco/kulala.nvim).
- Detects method, body fields, query params, and dynamic route params (including Next.js catch-all routes).
- Generates smart mock data based on Zod schema types.
- Extracts `PORT` or `BASE_URL` dynamically from `.env` files to override the static base URL.

## Requirements
- Neovim >= 0.9
- Tree-sitter parser for TypeScript/JavaScript
- (Optional) `kulala.nvim` for direct execution via `:NextRequestRun`.

## Installation (lazy.nvim)

```lua
{
  "SaptanshuWanjari/next-request.nvim",
  opts = {
    base_url = "http://localhost:3000",
    route_style = "mustache",
    http_files = { "requests.http" },
    env_files = { ".env", ".env.local" },
    execution_client = "kulala",
    keymap = {
      enabled = true,
      lhs = "<leader>rq",
      mode = "n",
      desc = "Next request",
    },
    run_keymap = {
      enabled = true,
      lhs = "<leader>rr",
      mode = "n",
      desc = "Next request run",
    },
  },
  config = function(_, opts)
    require("next-request").setup(opts)
  end,
}
```

## Usage
- `:NextRequest` inside a route handler function to generate a `.http` snippet.
- `:NextRequestRun` inside a route handler to execute it instantly in a floating window.

## Configuration

```lua
require("next-request").setup({
  base_url = "http://localhost:3000",
  route_style = "mustache", -- or "colon"
  http_files = {
    "requests.http",
    "auth.http",
  },
  env_files = { ".env", ".env.local" }, -- Parses these to override base_url
  execution_client = "kulala", -- Client used for :NextRequestRun
  command = "NextRequest",
  keymap = {
    enabled = false,
    lhs = "<leader>rq",
    mode = "n",
    desc = "Next request",
  },
  run_keymap = {
    enabled = false,
    lhs = "<leader>rr",
    mode = "n",
    desc = "Next request run",
  },
})
```

## License
MIT
