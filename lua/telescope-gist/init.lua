-- Public entry: configuration + picker dispatch.

local config = require("telescope-gist.config")
local pickers = require("telescope-gist.pickers")

local M = {}

---@param opts table|nil user options merged into defaults
function M.setup(opts)
  config.setup(opts)
end

---@param opts table|nil per-call picker opts
function M.list(opts)
  pickers.list(opts)
end

return M
