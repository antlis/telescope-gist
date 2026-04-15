-- Telescope previewer for gists with filetype-aware syntax highlighting.
--
-- Per-gist content is fetched lazily on selection and cached under
-- `gist:<id>`. Cache reads are synchronous so navigating an already-browsed
-- list never re-hits the network.
--
-- Multi-file gists: all files are shown in the preview, separated by
-- `--- filename ---` headers. A single buffer can only have one filetype,
-- so highlighting follows the *first* file (alphabetically). The open action
-- handles multi-file properly with one buffer per file.

local previewers = require("telescope.previewers")
local cache = require("telescope-gist.cache")
local gh = require("telescope-gist.gh")

local M = {}

local CACHE_PREFIX = "gist:"

---@param bufnr integer
---@param files table<string, { content: string, truncated: boolean, raw_url: string, language: string|nil, size: integer|nil }>
local function render(bufnr, files)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local names = vim.tbl_keys(files)
  table.sort(names)

  local lines = {}
  local primary_filetype

  for i, name in ipairs(names) do
    if #names > 1 then
      if i > 1 then table.insert(lines, "") end
      table.insert(lines, "--- " .. name .. " ---")
      table.insert(lines, "")
    end
    for _, line in ipairs(vim.split(files[name].content or "", "\n", { plain = true })) do
      table.insert(lines, line)
    end
    if files[name].truncated then
      table.insert(lines, "")
      table.insert(lines, "[truncated — open the gist to see the full contents]")
    end
    if not primary_filetype then
      primary_filetype = vim.filetype.match({ filename = name })
    end
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  if primary_filetype and primary_filetype ~= "" then
    -- pcall: filetype detection occasionally returns names that fail to load
    -- (no parser, missing syntax file). Failure here shouldn't break the picker.
    pcall(vim.api.nvim_set_option_value, "filetype", primary_filetype, { buf = bufnr })
  end
end

---@return table  telescope previewer
function M.build()
  return previewers.new_buffer_previewer({
    title = "Gist Preview",
    define_preview = function(self, entry, _status)
      local bufnr = self.state.bufnr
      local gist = entry and entry.value
      if not gist or not gist.id then return end

      -- Async responses can arrive after the user moved selection. Stamp the
      -- buffer with the most recent request so stale callbacks bail out.
      vim.b[bufnr].telescope_gist_target = gist.id

      local function maybe_render(files)
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        if vim.b[bufnr].telescope_gist_target ~= gist.id then return end
        render(bufnr, files)
      end

      local cached = cache.get(CACHE_PREFIX .. gist.id)
      if cached then
        maybe_render(cached.data)
        return
      end

      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Loading…" })

      gh.view(gist.id, function(err, files)
        -- gh.view's callback is already on the main loop (gh_json schedules it).
        if err then
          if not vim.api.nvim_buf_is_valid(bufnr) then return end
          if vim.b[bufnr].telescope_gist_target ~= gist.id then return end
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
            "Failed to load gist " .. gist.id .. ":",
            "",
            err,
          })
          return
        end

        cache.set(CACHE_PREFIX .. gist.id, files)
        maybe_render(files)
      end)
    end,
  })
end

return M
