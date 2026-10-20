-- Thin async wrapper around the `gh` CLI.
-- All functions are non-blocking; callers receive results via callbacks.
--
-- Backend boundary: the functions defined here are the `gh` CLI backend
-- (default). With `backend = "api"` in config, the exported functions at the
-- bottom of this file dispatch to api.lua (REST/GraphQL via plenary.curl).
-- Both return the same REST-shaped data, so callers don't care which is active.

local config = require("telescope-gist.config")

local M = {}

---Run a `gh` subcommand asynchronously, no parsing.
---Used for endpoints that return empty bodies (e.g. DELETE → 204).
---@param args string[]
---@param cb fun(err: string|nil)
local function gh_call(args, cb)
  local ok, err = pcall(vim.system, args, { text = true }, function(result)
    if result.code ~= 0 then
      local msg = result.stderr ~= "" and result.stderr or ("gh exited with code " .. result.code)
      vim.schedule(function() cb(vim.trim(msg)) end)
      return
    end
    vim.schedule(function() cb(nil) end)
  end)
  if not ok then
    vim.schedule(function() cb("failed to spawn gh: " .. tostring(err)) end)
  end
end

---Run a `gh` subcommand asynchronously and return parsed JSON to the callback.
---@param args string[]
---@param cb fun(err: string|nil, decoded: any)
---@param opts? { stdin?: string }  optional stdin payload (for POST/PATCH bodies)
local function gh_json(args, cb, opts)
  opts = opts or {}
  local sys_opts = { text = true }
  if opts.stdin then sys_opts.stdin = opts.stdin end

  local ok, err = pcall(vim.system, args, sys_opts, function(result)
    if result.code ~= 0 then
      local msg = result.stderr ~= "" and result.stderr or ("gh exited with code " .. result.code)
      vim.schedule(function() cb(vim.trim(msg), nil) end)
      return
    end

    -- luanil.object decodes JSON `null` as Lua `nil` instead of `vim.NIL`
    -- (a userdata that's truthy and explodes inside string ops). Many GitHub
    -- fields are nullable (description, updated_at on edge cases, owner, etc.),
    -- and forcing every caller to defend against `vim.NIL` is a footgun.
    local decoded_ok, decoded = pcall(vim.json.decode, result.stdout, { luanil = { object = true } })
    if not decoded_ok then
      vim.schedule(function() cb("failed to parse gh JSON output: " .. tostring(decoded), nil) end)
      return
    end

    vim.schedule(function() cb(nil, decoded) end)
  end)

  if not ok then
    -- vim.system throws synchronously if the binary cannot be spawned (e.g. gh not installed).
    vim.schedule(function() cb("failed to spawn gh: " .. tostring(err), nil) end)
  end
end

---@class Gist
---@field id string
---@field description string
---@field files table<string, { filename: string, language: string|nil }>
---@field public boolean
---@field updated_at string
---@field html_url string

---List the authenticated user's gists.
---
---Backed by `gh api /gists?per_page=N`, which returns the canonical REST API
---JSON shape. Because callers consume that shape directly, no normalization
---happens here — and the v0.2 swap to `plenary.curl + gh auth token` will not
---touch this function's output at all.
---
---Note: `gh gist list --json` is *not* supported by the gh CLI as of v2.87.x;
---`gh api /gists` is the only path that gives structured data.
---@param opts { limit: integer }
---@param cb fun(err: string|nil, gists: Gist[]|nil)
function M.list(opts, cb)
  -- TODO(pagination): GitHub caps per_page at 100. For limit > 100 we need to
  -- follow the `Link: <...>; rel="next"` header (use `gh api --paginate` or
  -- read headers via `gh api -i`). For v0.1 we cap at 100 silently.
  local per_page = math.min(opts.limit or 100, 100)

  local args = {
    "gh", "api",
    "-H", "Accept: application/vnd.github+json",
    "/gists?per_page=" .. per_page,
  }

  gh_json(args, function(err, decoded)
    if err then return cb(err, nil) end
    if type(decoded) ~= "table" then
      return cb("unexpected gh output (not a JSON array)", nil)
    end
    cb(nil, decoded)
  end)
end

---Fetch a single gist's file contents (single round-trip via `gh api /gists/<id>`).
---
---File contents are returned inline by GitHub up to ~1MB per file. Larger files
---come back with `truncated = true` and an empty/partial `content`; the full
---bytes have to be fetched separately from `raw_url`. v0.1 surfaces the
---truncated payload as-is and signals the condition via a second return value
---so callers can decide whether to follow up.
---@param id string
---@param cb fun(err: string|nil, files: table<string, { content: string, truncated: boolean, raw_url: string, language: string|nil, size: integer|nil }>|nil)
function M.view(id, cb)
  if type(id) ~= "string" or id == "" then
    return cb("gh.view: missing gist id", nil)
  end

  local args = {
    "gh", "api",
    "-H", "Accept: application/vnd.github+json",
    "/gists/" .. id,
  }

  gh_json(args, function(err, decoded)
    if err then return cb(err, nil) end
    if type(decoded) ~= "table" or type(decoded.files) ~= "table" then
      return cb("unexpected gh output: missing `files` object", nil)
    end

    local files = {}
    for name, f in pairs(decoded.files) do
      files[name] = {
        content = f.content or "",
        truncated = f.truncated == true,
        raw_url = f.raw_url,
        language = f.language,
        size = f.size,
      }
    end
    cb(nil, files)
  end)
end

---Push new content for a single file in an existing gist via PATCH /gists/<id>.
---Returns the updated gist object so callers can refresh `updated_at` etc.
---@param id string
---@param filename string
---@param content string
---@param cb fun(err: string|nil, gist: any|nil)
function M.edit(id, filename, content, cb)
  if type(id) ~= "string" or id == "" then
    return cb("gh.edit: missing gist id", nil)
  end
  if type(filename) ~= "string" or filename == "" then
    return cb("gh.edit: missing filename", nil)
  end

  local enc_ok, body = pcall(vim.json.encode, {
    files = { [filename] = { content = content or "" } },
  })
  if not enc_ok then
    return cb("failed to encode payload: " .. tostring(body), nil)
  end

  gh_json(
    { "gh", "api", "-X", "PATCH", "/gists/" .. id, "--input", "-" },
    function(err, decoded)
      if err then return cb(err, nil) end
      cb(nil, decoded)
    end,
    { stdin = body }
  )
end

---Delete a gist by id. GitHub returns 204 No Content; gh exits 0 with empty stdout.
---@param id string
---@param cb fun(err: string|nil)
function M.delete(id, cb)
  if type(id) ~= "string" or id == "" then
    return cb("gh.delete: missing gist id")
  end
  gh_call({ "gh", "api", "-X", "DELETE", "/gists/" .. id }, cb)
end

---Create a new gist via `POST /gists`. Returns the full gist object so callers
---can prepend it directly into the cached list without an extra fetch.
---@param opts { filename: string, content: string, description: string|nil, public: boolean|nil }
---@param cb fun(err: string|nil, gist: any|nil)
function M.create(opts, cb)
  if type(opts) ~= "table" or type(opts.filename) ~= "string" or opts.filename == ""
     or type(opts.content) ~= "string" then
    return cb("gh.create: requires { filename = string, content = string }", nil)
  end

  -- GitHub API body shape: { description, public, files: { "<name>": { content } } }
  local enc_ok, body = pcall(vim.json.encode, {
    description = opts.description or "",
    public = opts.public == true,
    files = { [opts.filename] = { content = opts.content } },
  })
  if not enc_ok then
    return cb("failed to encode payload: " .. tostring(body), nil)
  end

  gh_json(
    { "gh", "api", "-X", "POST", "/gists", "--input", "-" },
    function(err, decoded)
      if err then return cb(err, nil) end
      if type(decoded) ~= "table" or not decoded.id then
        return cb("unexpected gh output: missing gist id", nil)
      end
      cb(nil, decoded)
    end,
    { stdin = body }
  )
end

local warned_fallback = false

---True when the API backend is selected and has not failed to find a token.
---@return boolean
function M.uses_api()
  return config.get().backend == "api" and not require("telescope-gist.api").is_unavailable()
end

-- Route every public call to the configured backend. Extra args (etag opts)
-- are ignored by the CLI backend, which has no conditional requests.
-- If the API backend can't find a token, warn once and use the CLI instead.
for _, name in ipairs({ "list", "view", "edit", "delete", "create" }) do
  local cli_fn = M[name]
  M[name] = function(...)
    if not M.uses_api() then return cli_fn(...) end

    local args = vim.F.pack_len(...)
    local api = require("telescope-gist.api")
    api.ensure_token(function(ok)
      if ok then return api[name](vim.F.unpack_len(args)) end
      if not warned_fallback then
        warned_fallback = true
        vim.notify("telescope-gist: no GitHub token for backend = \"api\"; falling back to the gh CLI", vim.log.levels.WARN)
      end
      cli_fn(vim.F.unpack_len(args))
    end)
  end
end

---API-backend only: batch-fetch contents of the newest gists in one GraphQL
---call. No-op (empty result) otherwise.
---@param gists Gist[]
---@param cb fun(err: string|nil, by_id: table<string, table>|nil)
function M.prefetch(gists, cb)
  if not M.uses_api() then return cb(nil, {}) end
  require("telescope-gist.api").prefetch(gists, cb)
end

---Download a file's full bytes from its `raw_url` (used for >1MB truncated
---files). Raw gist URLs need no auth, even for secret gists.
---@param url string
---@param cb fun(err: string|nil, body: string|nil)
function M.fetch_raw(url, cb)
  local ok, err = pcall(require("plenary.curl").get, url, {
    callback = function(res)
      vim.schedule(function()
        if res.status ~= 200 then return cb("HTTP " .. tostring(res.status)) end
        cb(nil, res.body or "")
      end)
    end,
    on_error = function(e)
      vim.schedule(function() cb(tostring(e and e.message or "curl error")) end)
    end,
  })
  if not ok then vim.schedule(function() cb(tostring(err)) end) end
end

return M
