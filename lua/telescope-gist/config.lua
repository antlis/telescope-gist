-- Default options and merge logic.

local M = {}

---@class TelescopeGistConfig
---@field limit integer        max gists to fetch (passed to `gh gist list --limit`)
---@field cache TelescopeGistCacheConfig
---@field keymaps TelescopeGistKeymaps

---@class TelescopeGistCacheConfig
---@field enabled boolean
---@field ttl_minutes integer  staleness threshold; cache is still served, but a refresh kicks off in the background
---@field dir string           absolute path; defaults to stdpath('cache')/telescope-gist

---@class TelescopeGistKeymaps
---@field open string          open gist in buffer (default <CR>)
---@field edit string          open + autosync on BufWritePost
---@field delete string        delete gist (with confirm)
---@field new string           create new gist from current buffer/selection
---@field yank_url string      copy gist URL to clipboard
---@field refresh string       force re-fetch and replace cache

---@type TelescopeGistConfig
local defaults = {
  limit = 100,
  cache = {
    enabled = true,
    ttl_minutes = 10,
    dir = vim.fn.stdpath("cache") .. "/telescope-gist",
  },
  keymaps = {
    open = "<CR>",
    edit = "<C-e>",
    delete = "<C-d>",
    new = "<C-n>",
    yank_url = "<C-y>",
    refresh = "<C-r>",
  },
}

---@type TelescopeGistConfig
M.options = vim.deepcopy(defaults)

---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

---@return TelescopeGistConfig
function M.get()
  return M.options
end

return M
