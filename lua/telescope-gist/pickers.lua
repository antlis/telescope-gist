-- Telescope picker: gist list.

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")

local config = require("telescope-gist.config")
local cache = require("telescope-gist.cache")
local gh = require("telescope-gist.gh")
local actions = require("telescope-gist.actions")
local previewer = require("telescope-gist.previewer")

local M = {}

local CACHE_KEY = "gists"

---Local UTC offset in seconds. Computed once and cached for the session;
---DST transitions mid-session are rare enough not to matter for "minutes ago"
---granularity.
local UTC_OFFSET = (function()
  local now = os.time()
  return os.difftime(now, os.time(os.date("!*t", now)))
end)()

---Parse a GitHub ISO-8601 timestamp (`2026-04-14T18:09:51Z`) to a UNIX epoch.
---GitHub returns UTC; `os.time` interprets table input as local time, so we
---compensate with UTC_OFFSET to land on the true epoch.
---@param iso string|nil
---@return integer|nil
local function parse_iso(iso)
  if type(iso) ~= "string" then return nil end
  local y, mo, d, h, mi, s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  return os.time({
    year  = tonumber(y),  month = tonumber(mo), day = tonumber(d),
    hour  = tonumber(h),  min   = tonumber(mi), sec = tonumber(s),
  }) + UTC_OFFSET
end

---@param iso string|nil
---@return string  short relative time like "3d ago"
local function relative_time(iso)
  local t = parse_iso(iso)
  if not t then return iso or "" end
  local diff = math.max(0, os.difftime(os.time(), t))
  if diff < 60          then return "just now" end
  if diff < 3600        then return ("%dm ago"):format(diff / 60) end
  if diff < 86400       then return ("%dh ago"):format(diff / 3600) end
  if diff < 86400 * 7   then return ("%dd ago"):format(diff / 86400) end
  if diff < 86400 * 30  then return ("%dw ago"):format(diff / 86400 / 7) end
  if diff < 86400 * 365 then return ("%dmo ago"):format(diff / 86400 / 30) end
  return ("%dy ago"):format(diff / 86400 / 365)
end

---Pick the alphabetically-first filename from a gist's files map. Used as a
---description fallback when the gist has no description set.
---@param files table
---@return string|nil
local function first_filename(files)
  local first
  for name in pairs(files or {}) do
    if not first or name < first then first = name end
  end
  return first
end

---Telescope row displayer. Columns:
---  visibility (1ch) | description (40ch) | file count (7ch) | updated (rest)
local displayer = entry_display.create({
  separator = "  ",
  items = {
    { width = 1 },
    { width = 40 },
    { width = 7 },
    { remaining = true },
  },
})

---Build a Telescope entry from a Gist record.
---@param gist Gist
---@return table  telescope entry
local function entry_maker(gist)
  local files = gist.files or {}
  local file_count = vim.tbl_count(files)
  local first_name = first_filename(files)

  local desc = (gist.description and gist.description ~= "") and gist.description
    or first_name
    or gist.id

  -- "P"/"S" rather than nerd-font icons keeps this dependency-free; users with
  -- nerd fonts can override via setup() once we expose the formatter (TODO).
  local vis_label = gist.public and "P" or "S"
  local vis_hl    = gist.public and "Special" or "Comment"

  local files_label = file_count == 1 and "1 file" or (file_count .. " files")

  -- ordinal = everything searchable: description + id + every filename. Lets
  -- the user fuzzy-match by either gist title or any contained file name.
  local ordinal_parts = { gist.description or "", gist.id or "" }
  for name in pairs(files) do
    ordinal_parts[#ordinal_parts + 1] = name
  end

  return {
    value = gist,
    ordinal = table.concat(ordinal_parts, " "),
    display = function()
      return displayer({
        { vis_label, vis_hl },
        desc,
        { files_label, "Number" },
        { relative_time(gist.updated_at), "Comment" },
      })
    end,
  }
end

---Open the gist list picker.
---@param opts table|nil
function M.list(opts)
  opts = opts or {}
  local cfg = config.get()

  local function open_with(gists)
    pickers.new(opts, {
      prompt_title = "Gists",
      finder = finders.new_table({
        results = gists,
        entry_maker = entry_maker,
      }),
      sorter = conf.generic_sorter(opts),
      previewer = previewer.build(),
      attach_mappings = function(_prompt_bufnr, map)
        local km = cfg.keymaps
        map({ "i", "n" }, km.open,     actions.open)
        map({ "i", "n" }, km.delete,   actions.delete)
        map({ "i", "n" }, km.new,      actions.new)
        map({ "i", "n" }, km.yank_url, actions.yank_url)
        map({ "i", "n" }, km.refresh,  actions.refresh)
        return true -- keep default <CR> bound to whatever map returned for `open`
      end,
    }):find()
  end

  -- TODO(stale-while-revalidate): currently we only fetch when there's no
  -- cache at all. Next iteration: if cached but `cache.is_stale(...)`, open
  -- with cached data immediately AND kick off a background refresh that swaps
  -- the picker's finder via M.refresh-style logic when it lands.
  local cached = cfg.cache.enabled and cache.get(CACHE_KEY) or nil
  if cached then
    open_with(cached.data)
    return
  end

  gh.list({ limit = cfg.limit }, function(err, gists)
    if err then
      vim.notify("telescope-gist: " .. err, vim.log.levels.ERROR)
      return
    end
    if cfg.cache.enabled then cache.set(CACHE_KEY, gists) end
    open_with(gists)
  end)
end

---Re-render the picker from current cache contents WITHOUT hitting the network.
---Used by mutating actions (delete/new/edit) after they've already updated the
---cache locally — a network refetch would just confirm what we already know.
---@param prompt_bufnr integer
function M.rebuild_finder(prompt_bufnr)
  local current_picker = action_state.get_current_picker(prompt_bufnr)
  if not current_picker then return end
  local cached = cache.get(CACHE_KEY)
  local data = (cached and cached.data) or {}
  current_picker:refresh(
    finders.new_table({ results = data, entry_maker = entry_maker }),
    { reset_prompt = false }
  )
end

---Force-refresh the gist list inside an already-open picker.
---Drops the cached list, re-fetches, and swaps the picker's finder in place
---so the user keeps their current prompt text and selection state.
---Note: per-gist content cache (`gist:<id>`) is intentionally NOT dropped —
---it's keyed by gist id and stays valid until that specific gist mutates.
---@param prompt_bufnr integer
function M.refresh(prompt_bufnr)
  local cfg = config.get()
  local current_picker = action_state.get_current_picker(prompt_bufnr)
  if not current_picker then return end

  cache.invalidate(CACHE_KEY)
  vim.notify("telescope-gist: refreshing…")

  gh.list({ limit = cfg.limit }, function(err, gists)
    if err then
      vim.notify("telescope-gist: " .. err, vim.log.levels.ERROR)
      return
    end
    if cfg.cache.enabled then cache.set(CACHE_KEY, gists) end

    -- TODO(smart-invalidation): for any cached gist whose updated_at advanced,
    -- drop its `gist:<id>` content cache so the next preview/open re-fetches.

    current_picker:refresh(
      finders.new_table({ results = gists, entry_maker = entry_maker }),
      { reset_prompt = false }
    )
  end)
end

return M
