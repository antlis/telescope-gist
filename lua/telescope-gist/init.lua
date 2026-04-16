-- Public entry: configuration + picker dispatch + gist creation.

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

---Create a gist from visual selection or the full current buffer.
---@param opts { range: integer, line1: integer, line2: integer }|nil
function M.create(opts)
  opts = opts or {}
  local range = opts.range or 0
  local lines
  if range > 0 then
    -- line1/line2 are 1-based; nvim_buf_get_lines is 0-based, end-exclusive.
    lines = vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false)
  else
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  end

  local content = table.concat(lines, "\n")
  if content == "" then
    vim.notify("telescope-gist: buffer is empty", vim.log.levels.WARN)
    return
  end

  local buf_name = vim.api.nvim_buf_get_name(0)
  local default_filename = (buf_name ~= "" and vim.fs.basename(buf_name)) or "gistfile1.txt"

  vim.ui.input({ prompt = "Gist filename: ", default = default_filename }, function(filename)
    if not filename or filename == "" then return end

    vim.ui.input({ prompt = "Description (optional): " }, function(description)
      if description == nil then return end -- Esc; empty string is a valid description

      local choice = vim.fn.confirm("Gist visibility?", "&Secret\n&Public", 1)
      if choice == 0 then return end
      local is_public = choice == 2

      local gh = require("telescope-gist.gh")
      local cache = require("telescope-gist.cache")

      gh.create({
        filename = filename,
        content = content,
        description = description,
        public = is_public,
      }, function(err, gist)
        if err then
          vim.notify("telescope-gist: create failed: " .. err, vim.log.levels.ERROR)
          return
        end

        cache.mutate("gists", function(list)
          local out = { gist }
          for _, g in ipairs(list or {}) do out[#out + 1] = g end
          return out
        end)

        if gist.html_url then
          vim.fn.setreg("+", gist.html_url)
          vim.notify("telescope-gist: created " .. gist.html_url .. " (URL copied)")
        else
          vim.notify("telescope-gist: created gist " .. (gist.id or "<unknown id>"))
        end
      end)
    end)
  end)
end

return M
