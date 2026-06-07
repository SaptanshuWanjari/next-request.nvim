if vim.g.loaded_next_request == 1 then return end
vim.g.loaded_next_request = 1

local ok, mod = pcall(require, "next-request")
if not ok then return end

if type(mod.setup) == "function" then
  mod.setup(vim.g.next_request_opts or {})
end
