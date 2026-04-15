-- Telescope extension entry point.
-- Loaded via: require("telescope").load_extension("gist")

local has_telescope, telescope = pcall(require, "telescope")
if not has_telescope then
  error("telescope-gist requires nvim-telescope/telescope.nvim")
end

local main = require("telescope-gist")

return telescope.register_extension({
  setup = main.setup,
  exports = {
    -- :Telescope gist           -> default picker (list)
    -- :Telescope gist list      -> explicit
    gist = main.list,
    list = main.list,
  },
})
