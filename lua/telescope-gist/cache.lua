-- Two-layer cache: in-memory + on-disk JSON with TTL.
--
-- Lifecycle:
--   1. First read in a session: load disk -> memory.
--   2. Subsequent reads: serve memory immediately.
--   3. Staleness is wall-clock against `fetched_at`; serve regardless and let
--      the caller decide whether to revalidate.
--   4. Manual refresh (picker keymap) calls invalidate() then refetches.
--
-- Layout: one JSON file per key under `config.cache.dir`. Per-key files keep
-- invalidation surgical and writes atomic — no read-modify-write race when
-- many gist contents are cached concurrently.
--
-- Schema versioning: each on-disk file carries a `version` field. Bumping
-- SCHEMA_VERSION causes older files to be ignored as cache-misses, which is
-- safer than silently deserializing into a changed shape.

local config = require("telescope-gist.config")

local M = {}

local SCHEMA_VERSION = 1

---@class CacheEntry
---@field fetched_at integer  -- os.time()
---@field data any

---@type table<string, CacheEntry>
local mem = {}

---Map a cache key to a filesystem-safe filename.
---Replaces anything that isn't [A-Za-z0-9_-] with `_`. Collisions are
---theoretically possible but our keys are constrained: `gists`, `gist:<32-hex>`.
---@param key string
---@return string
local function key_to_filename(key)
  return (key:gsub("[^%w_-]", "_")) .. ".json"
end

---@param key string
---@return string  absolute path
local function key_to_path(key)
  return config.get().cache.dir .. "/" .. key_to_filename(key)
end

---@param path string
---@return CacheEntry|nil
local function read_disk(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local body = f:read("*a")
  f:close()

  local ok, decoded = pcall(vim.json.decode, body)
  if not ok or type(decoded) ~= "table" then return nil end
  if decoded.version ~= SCHEMA_VERSION then return nil end
  if type(decoded.fetched_at) ~= "number" then return nil end

  return { fetched_at = decoded.fetched_at, data = decoded.data }
end

---Atomic write: encode -> tmpfile -> rename. The rename is atomic on POSIX,
---which guarantees readers never observe a half-written file.
---TODO(windows): os.rename fails if destination exists on Windows. Switch to
---vim.uv.fs_rename (cross-platform) when there's demand.
---@param path string
---@param entry CacheEntry
---@return boolean ok
local function write_disk(path, entry)
  local dir = vim.fs.dirname(path)
  vim.fn.mkdir(dir, "p") -- idempotent

  local enc_ok, encoded = pcall(vim.json.encode, {
    version = SCHEMA_VERSION,
    fetched_at = entry.fetched_at,
    data = entry.data,
  })
  if not enc_ok then return false end

  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(encoded)
  f:close()

  return os.rename(tmp, path) == true
end

---@param path string
local function delete_disk(path)
  os.remove(path) -- silent if missing
end

---@param key string
---@return CacheEntry|nil
function M.get(key)
  local entry = mem[key]
  if entry then return entry end

  -- Memory miss: try disk and lift it into memory on hit.
  entry = read_disk(key_to_path(key))
  if entry then
    mem[key] = entry
    return entry
  end
  return nil
end

---@param key string
---@param data any
function M.set(key, data)
  local entry = { fetched_at = os.time(), data = data }
  mem[key] = entry
  -- Disk write failures must never break the picker. Memory cache still works.
  pcall(write_disk, key_to_path(key), entry)
end

---@param key string
---@param ttl_minutes integer
---@return boolean
function M.is_stale(key, ttl_minutes)
  local entry = M.get(key)
  if not entry then return true end
  return (os.time() - entry.fetched_at) > (ttl_minutes * 60)
end

---Drop both memory and disk copies.
---@param key string
function M.invalidate(key)
  mem[key] = nil
  pcall(delete_disk, key_to_path(key))
end

---Surgical update for a cached entry (post edit/delete/create on the list,
---or after writing a gist file). Bumps `fetched_at` because the local copy
---is now known-current with the remote.
---@param key string
---@param updater fun(data: any): any
function M.mutate(key, updater)
  local entry = M.get(key)
  if not entry then return end
  entry.data = updater(entry.data)
  entry.fetched_at = os.time()
  mem[key] = entry
  pcall(write_disk, key_to_path(key), entry)
end

return M
