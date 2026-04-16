-- Telescope extension entry point.
-- Loaded via: require("telescope").load_extension("gist")

local has_telescope, telescope = pcall(require, "telescope")
if not has_telescope then
  error("telescope-gist requires nvim-telescope/telescope.nvim")
end

local main = require("telescope-gist")

return telescope.register_extension({
  setup = function(opts)
    main.setup(opts)

    vim.api.nvim_create_user_command("GistCreate", function(cmd)
      main.create({ range = cmd.range, line1 = cmd.line1, line2 = cmd.line2 })
    end, { range = true, desc = "Create a gist from current buffer or visual selection" })
  end,
  exports = {
    -- :Telescope gist           -> default picker (list)
    -- :Telescope gist list      -> explicit
    gist = main.list,
    list = main.list,
  },
})
