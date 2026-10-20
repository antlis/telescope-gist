-- GitHub REST/GraphQL backend over plenary.curl. Opt-in via `backend = "api"`.
-- Mirrors the public surface of the `gh` CLI backend in gh.lua, plus:
--   * ETag / If-None-Match on list and view (callers get `meta.not_modified`)
--   * prefetch(): one GraphQL round-trip that returns file contents for the
--     most recent gists, so previews/opens are served from cache.
--
-- Token: $GH_TOKEN, then $GITHUB_TOKEN, then `gh auth token`. Resolved once
-- per session; a 401 drops it so the next call re-resolves.

local curl = require("plenary.curl")

local M = {}

local API = "https://api.github.com"
local PREFETCH_FILES = 50

---@type string|nil
local token
---Set once token resolution fails; gh.lua then falls back to the CLI backend.
local unavailable = false

---@param cb fun(err: string|nil, token: string|nil)
local function resolve_token(cb)
  if token then return cb(nil, token) end

  local env = vim.env.GH_TOKEN or vim.env.GITHUB_TOKEN
  if env and env ~= "" then
    token = env
    return cb(nil, token)
  end

  local no_token = "no GitHub token: set GH_TOKEN/GITHUB_TOKEN or run `gh auth login`"
  local ok = pcall(vim.system, { "gh", "auth", "token" }, { text = true }, function(result)
    vim.schedule(function()
      local out = vim.trim(result.stdout or "")
      if result.code ~= 0 or out == "" then return cb(no_token, nil) end
      token = out
      cb(nil, token)
    end)
  end)
  if not ok then vim.schedule(function() cb(no_token, nil) end) end
end

---True after a failed token lookup (no env var, `gh` missing/unauthenticated).
---@return boolean
function M.is_unavailable() return unavailable end

---Resolve the token ahead of a call so the caller can pick a backend.
---@param cb fun(ok: boolean)
function M.ensure_token(cb)
  resolve_token(function(err)
    unavailable = err ~= nil
    cb(not unavailable)
  end)
end

---@param headers string[]|table|nil  plenary returns raw "Name: value" lines
---@return string|nil
local function find_etag(headers)
  for _, line in ipairs(headers or {}) do
    local value = type(line) == "string" and line:match("^[Ee][Tt]ag:%s*(.-)%s*$")
    if value then return value end
  end
end

---@param path string  "/gists" or a full URL
---@param opts { method: string, body: string|nil, etag: string|nil }
---@param cb fun(err: string|nil, decoded: any, meta: { etag: string|nil, not_modified: boolean }|nil)
local function request(path, opts, cb)
  resolve_token(function(terr, tok)
    if terr then return cb(terr) end

    local headers = {
      Authorization = "Bearer " .. tok,
      Accept = "application/vnd.github+json",
      ["X-GitHub-Api-Version"] = "2022-11-28",
      ["User-Agent"] = "telescope-gist.nvim",
    }
    if opts.body then headers["Content-Type"] = "application/json" end
    if opts.etag then headers["If-None-Match"] = opts.etag end

    local ok, err = pcall(curl.request, {
      method = opts.method,
      url = API .. path,
      headers = headers,
      body = opts.body,
      callback = function(res)
        vim.schedule(function()
          local meta = { etag = find_etag(res.headers), not_modified = res.status == 304 }
          if meta.not_modified then return cb(nil, nil, meta) end

          local body = res.body or ""
          local parsed_ok, decoded = true, nil
          if body ~= "" then
            parsed_ok, decoded = pcall(vim.json.decode, body, { luanil = { object = true } })
          end

          if res.status >= 400 then
            if res.status == 401 then token = nil end
            local msg = parsed_ok and type(decoded) == "table" and decoded.message or nil
            return cb(("GitHub API %d: %s"):format(res.status, msg or "request failed"))
          end
          if not parsed_ok then
            return cb("failed to parse GitHub API response: " .. tostring(decoded))
          end
          cb(nil, decoded, meta)
        end)
      end,
      on_error = function(e)
        vim.schedule(function()
          cb("request failed: " .. vim.trim(tostring(e and (e.stderr ~= "" and e.stderr or e.message) or "curl error")))
        end)
      end,
    })
    if not ok then vim.schedule(function() cb("failed to start request: " .. tostring(err)) end) end
  end)
end

---@param tbl table
---@return string|nil body, string|nil err
local function encode(tbl)
  local ok, body = pcall(vim.json.encode, tbl)
  if not ok then return nil, "failed to encode payload: " .. tostring(body) end
  return body
end

---@param opts { limit: integer, etag: string|nil }
---@param cb fun(err: string|nil, gists: Gist[]|nil, meta: table|nil)  gists is nil when meta.not_modified
function M.list(opts, cb)
  local per_page = math.min(opts.limit or 100, 100)
  request("/gists?per_page=" .. per_page, { method = "GET", etag = opts.etag }, function(err, decoded, meta)
    if err then return cb(err) end
    if meta.not_modified then return cb(nil, nil, meta) end
    if type(decoded) ~= "table" then return cb("unexpected API response: expected a gist array") end
    cb(nil, decoded, meta)
  end)
end

---@param id string
---@param cb fun(err: string|nil, files: table|nil, meta: table|nil)  files is nil when meta.not_modified
---@param opts? { etag: string|nil }
function M.view(id, cb, opts)
  if type(id) ~= "string" or id == "" then return cb("gh.view: missing gist id") end

  request("/gists/" .. id, { method = "GET", etag = opts and opts.etag }, function(err, decoded, meta)
    if err then return cb(err) end
    if meta.not_modified then return cb(nil, nil, meta) end
    if type(decoded) ~= "table" or type(decoded.files) ~= "table" then
      return cb("unexpected API response: missing `files` object")
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
    cb(nil, files, meta)
  end)
end

---@param id string
---@param filename string
---@param content string
---@param cb fun(err: string|nil, gist: any|nil)
function M.edit(id, filename, content, cb)
  if type(id) ~= "string" or id == "" then return cb("gh.edit: missing gist id") end
  if type(filename) ~= "string" or filename == "" then return cb("gh.edit: missing filename") end

  local body, enc_err = encode({ files = { [filename] = { content = content or "" } } })
  if not body then return cb(enc_err) end

  request("/gists/" .. id, { method = "PATCH", body = body }, function(err, decoded)
    if err then return cb(err) end
    cb(nil, decoded)
  end)
end

---@param id string
---@param cb fun(err: string|nil)
function M.delete(id, cb)
  if type(id) ~= "string" or id == "" then return cb("gh.delete: missing gist id") end
  request("/gists/" .. id, { method = "DELETE" }, function(err) cb(err) end)
end

---@param opts { filename: string, content: string, description: string|nil, public: boolean|nil }
---@param cb fun(err: string|nil, gist: any|nil)
function M.create(opts, cb)
  if type(opts) ~= "table" or type(opts.filename) ~= "string" or opts.filename == ""
    or type(opts.content) ~= "string" then
    return cb("gh.create: requires { filename = string, content = string }")
  end

  local body, enc_err = encode({
    description = opts.description or "",
    public = opts.public == true,
    files = { [opts.filename] = { content = opts.content } },
  })
  if not body then return cb(enc_err) end

  request("/gists", { method = "POST", body = body }, function(err, decoded)
    if err then return cb(err) end
    if type(decoded) ~= "table" or not decoded.id then return cb("unexpected API response: missing gist id") end
    cb(nil, decoded)
  end)
end

local PREFETCH_QUERY = [[
query($n: Int!, $files: Int!) {
  viewer {
    gists(first: $n, orderBy: { field: UPDATED_AT, direction: DESC }) {
      nodes { name files(limit: $files) { name size isTruncated language { name } text } }
    }
  }
}]]

---Fetch full file contents for the most recent gists in ONE GraphQL call.
---Only gists whose files all came back complete (and match the file count
---already known from `gists`) are returned, so they're safe to drop straight
---into the `gist:<id>` content cache.
---@param gists Gist[]  list as returned by M.list
---@param cb fun(err: string|nil, by_id: table<string, table>|nil)
function M.prefetch(gists, cb)
  local count = math.min(require("telescope-gist.config").get().api.prefetch_count, 100)
  local expected = {}
  for i, g in ipairs(gists) do
    if i > count then break end
    expected[g.id] = vim.tbl_count(g.files or {})
  end
  if next(expected) == nil then return cb(nil, {}) end

  local body, enc_err = encode({
    query = PREFETCH_QUERY,
    variables = { n = count, files = PREFETCH_FILES },
  })
  if not body then return cb(enc_err) end

  request("/graphql", { method = "POST", body = body }, function(err, decoded)
    if err then return cb(err) end
    if type(decoded) ~= "table" or decoded.errors then
      return cb("GraphQL prefetch failed")
    end

    local nodes = vim.tbl_get(decoded, "data", "viewer", "gists", "nodes") or {}
    local by_id = {}
    for _, node in ipairs(nodes) do
      local want = expected[node.name]
      if want and #(node.files or {}) == want then
        local files, complete = {}, true
        for _, f in ipairs(node.files) do
          if f.text == nil or f.isTruncated then complete = false; break end
          files[f.name] = {
            content = f.text,
            truncated = false,
            language = f.language and f.language.name or nil,
            size = f.size,
          }
        end
        if complete then by_id[node.name] = files end
      end
    end
    cb(nil, by_id)
  end)
end

return M
