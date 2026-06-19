local ok, kulala = pcall(require, "kulala.config")
if ok then print(vim.inspect(kulala.get())) end
