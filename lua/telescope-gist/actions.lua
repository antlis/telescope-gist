-- Telescope picker actions: open, edit-and-sync, delete, new, yank URL, refresh.
--
-- Each action receives the current prompt buffer number; use
-- action_state.get_selected_entry() to grab the gist behind the highlighted row.

local action_state = require("telescope.actions.state")
local actions = require("telescope.actions")

local cache = require("telescope-gist.cache")
local gh = require("telescope-gist.gh")

local M = {}

local CACHE_PREFIX = "gist:"

---Find an existing buffer by name, or create+name a new one.
---Buffer names use the `gist://<id>/<filename>` scheme so they're unique
---across gists and don't collide with real file paths.
---@param name string
---@return integer bufnr
local function get_or_create_buf(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then
      return b
    end
  end
  local b = vim.api.nvim_create_buf(true, false) -- listed, not scratch
  vim.api.nvim_buf_set_name(b, name)
  return b
end

---Populate a buffer with one gist file in edit mode.
---`buftype = "acwrite"` makes `:w` fire our BufWriteCmd autocmd (which pushes
---to GitHub) instead of trying to write the `gist://` URI to disk.
---@param bufnr integer
---@param content string
---@param filename string
local function populate_buffer(bufnr, content, filename)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(content, "\n", { plain = true }))
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].buftype = "acwrite"

  local ft = vim.filetype.match({ filename = filename })
  if ft and ft ~= "" then
    pcall(function() vim.bo[bufnr].filetype = ft end)
  end
end

---Install a BufWriteCmd autocmd on a gist buffer. On `:w` the buffer's
---contents are PATCHed back to GitHub via `gh.edit`. The autocmd is
---per-buffer (augroup name includes bufnr) and `clear = true` makes
---re-installation idempotent.
---
---Note on async: gh.edit runs asynchronously, so `:w` returns immediately.
---The buffer's `modified` flag is only cleared after a successful push;
---this means `:wq` correctly fails with "no write since last change" if
---the push hasn't completed yet — Vim's safety net protects against
---quitting with unsynced changes. A failed push leaves modified=true so
---the user can retry `:w`.
---@param bufnr integer
local function install_sync_autocmd(bufnr)
  local group = vim.api.nvim_create_augroup("TelescopeGistSync_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = bufnr,
    callback = function()
      local id = vim.b[bufnr].gist_id
      local filename = vim.b[bufnr].gist_filename
      if not id or not filename then
        vim.notify("telescope-gist: buffer missing gist metadata", vim.log.levels.ERROR)
        return
      end

      -- Truncated content was only the first ~1MB; pushing it back would
      -- silently overwrite the full gist with the prefix. Refuse rather than
      -- corrupt. TODO(v0.2): fetch raw_url to load full bytes before allowing
      -- edits, so this guard becomes unnecessary.
      if vim.b[bufnr].gist_truncated then
        vim.notify(
          ("telescope-gist: refusing to push truncated file (>1MB). Use `gh gist edit %s` directly."):format(id),
          vim.log.levels.ERROR
        )
        return
      end

      local content = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

      gh.edit(id, filename, content, function(err, gist)
        if err then
          vim.notify("telescope-gist: push failed: " .. err, vim.log.levels.ERROR)
          return
        end

        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.bo[bufnr].modified = false
        end

        -- Update per-gist content cache so the next preview/open shows the
        -- new bytes without a refetch.
        cache.mutate(CACHE_PREFIX .. id, function(files)
          files = files or {}
          files[filename] = files[filename] or {}
          files[filename].content = content
          files[filename].truncated = false
          return files
        end)

        -- Bump updated_at in the list cache so the row's "X ago" column
        -- reflects the edit on next picker open.
        if gist and gist.updated_at then
          cache.mutate("gists", function(list)
            for _, g in ipairs(list or {}) do
              if g.id == id then
                g.updated_at = gist.updated_at
                break
              end
            end
            return list
          end)
        end

        vim.notify(("telescope-gist: pushed %s → %s"):format(filename, id))
      end)
    end,
  })
end

---@param id string
---@param opts { editable: boolean }|nil
local function open_gist(id)
  local function show(files)
    if vim.tbl_isempty(files) then
      vim.notify("telescope-gist: gist " .. id .. " has no files", vim.log.levels.WARN)
      return
    end

    local names = vim.tbl_keys(files)
    table.sort(names)

    local first_buf
    for _, name in ipairs(names) do
      local f = files[name]
      local bufnr = get_or_create_buf("gist://" .. id .. "/" .. name)

      -- Defensive: if the buffer is already open with unsaved local edits,
      -- preserve them. Repopulating would silently drop the user's work.
      -- Autocmd / metadata are already in place from the prior open.
      if not vim.bo[bufnr].modified then
        populate_buffer(bufnr, f.content or "", name)

        vim.b[bufnr].gist_id = id
        vim.b[bufnr].gist_filename = name
        vim.b[bufnr].gist_truncated = f.truncated == true
        vim.b[bufnr].gist_raw_url = f.raw_url

        install_sync_autocmd(bufnr)
      end

      first_buf = first_buf or bufnr
    end

    if first_buf then
      vim.api.nvim_set_current_buf(first_buf)
    end

    if #names > 1 then
      vim.notify(("telescope-gist: opened %d files: %s"):format(#names, table.concat(names, ", ")))
    end
  end

  local cached = cache.get(CACHE_PREFIX .. id)
  if cached then
    show(cached.data)
    return
  end

  gh.view(id, function(err, files)
    if err then
      vim.notify("telescope-gist: " .. err, vim.log.levels.ERROR)
      return
    end
    cache.set(CACHE_PREFIX .. id, files)
    show(files)
  end)
end

---Open the selected gist in editable buffers wired to autosync on `:w`.
---Multi-file gists open one buffer per file; the first (alphabetical) is shown.
---Each buffer has `buftype=acwrite` and a BufWriteCmd autocmd that PATCHes
---content back via `gh.edit` — opening is non-destructive, only `:w` pushes.
---@param prompt_bufnr integer
function M.open(prompt_bufnr)
  local entry = action_state.get_selected_entry()
  actions.close(prompt_bufnr)
  if not entry or not entry.value or not entry.value.id then
    vim.notify("telescope-gist: no gist selected", vim.log.levels.WARN)
    return
  end
  open_gist(entry.value.id)
end

---Delete the selected gist after a y/N confirmation.
---On success the row disappears from the picker via in-place finder rebuild
---(no network refetch — the cache mutation IS the new truth).
---TODO(multi-select): respect Telescope's multi-selection so a user can mark
---several rows with <Tab> and delete them all at once.
---@param prompt_bufnr integer
function M.delete(prompt_bufnr)
  local entry = action_state.get_selected_entry()
  if not entry or not entry.value or not entry.value.id then
    vim.notify("telescope-gist: no gist selected", vim.log.levels.WARN)
    return
  end

  local gist = entry.value

  -- Build a human-readable label for the confirm prompt. Description first,
  -- then any filename, then bare id. Truncated so the prompt stays readable.
  local label = (gist.description and gist.description ~= "") and gist.description or nil
  if not label then
    for name in pairs(gist.files or {}) do label = name; break end
  end
  label = label or gist.id
  if #label > 50 then label = label:sub(1, 47) .. "…" end

  -- Default to "No" (button 2). vim.fn.confirm's first option is button 1.
  local choice = vim.fn.confirm(
    ("Delete gist?\n  %s\n  (%s)"):format(label, gist.id),
    "&Yes\n&No",
    2
  )
  if choice ~= 1 then return end

  gh.delete(gist.id, function(err)
    if err then
      vim.notify("telescope-gist: delete failed: " .. err, vim.log.levels.ERROR)
      return
    end

    -- Local truth now matches remote: drop the row from the list cache and
    -- nuke this gist's content cache (so a re-create with the same id — rare
    -- but possible — won't serve stale content).
    cache.mutate("gists", function(list)
      local kept = {}
      for _, g in ipairs(list or {}) do
        if g.id ~= gist.id then kept[#kept + 1] = g end
      end
      return kept
    end)
    cache.invalidate(CACHE_PREFIX .. gist.id)

    -- Lazy require: pickers.lua already requires this module at top level;
    -- requiring it back at top level would create an import cycle.
    require("telescope-gist.pickers").rebuild_finder(prompt_bufnr)

    vim.notify("telescope-gist: deleted " .. gist.id)
  end)
end

---Create a new gist from the buffer the picker was launched from.
---Closes the picker first, then delegates to the shared `init.create()` so
---the creation logic lives in one place (also used by `:GistCreate`).
---@param prompt_bufnr integer
function M.new(prompt_bufnr)
  -- The window the picker was launched from holds the buffer we want to gist.
  local picker = action_state.get_current_picker(prompt_bufnr)
  local source_win = picker and picker.original_win_id
  if not source_win or not vim.api.nvim_win_is_valid(source_win) then
    vim.notify("telescope-gist: cannot determine source buffer", vim.log.levels.WARN)
    return
  end

  actions.close(prompt_bufnr)

  -- Focus the source window so init.create() reads the correct buffer.
  vim.api.nvim_set_current_win(source_win)

  require("telescope-gist").create({ range = 0 })
end

---Yank the gist's HTML URL into the clipboard register.
---@param prompt_bufnr integer
function M.yank_url(prompt_bufnr)
  local entry = action_state.get_selected_entry()
  if entry and entry.value and entry.value.html_url then
    vim.fn.setreg("+", entry.value.html_url)
    vim.notify("Copied: " .. entry.value.html_url)
  end
  actions.close(prompt_bufnr)
end

---Force-refresh the cached gist list; the picker re-renders in place.
---Delegates to `pickers.refresh` (lazy-required to avoid an import cycle —
---pickers.lua already requires this module at top level).
---@param prompt_bufnr integer
function M.refresh(prompt_bufnr)
  require("telescope-gist.pickers").refresh(prompt_bufnr)
end

return M
