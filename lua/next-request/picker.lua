local M = {}

function M.select(items, on_choice)
  vim.ui.select(items, { prompt = "Choose HTTP file" }, function(choice)
    if on_choice then on_choice(choice) end
  end)
end

return M
