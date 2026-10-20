# telescope-gist

A [Telescope](https://github.com/nvim-telescope/telescope.nvim) extension for managing
your GitHub Gists from inside Neovim — built for [LazyVim](https://www.lazyvim.org/), works anywhere.

## Demo

[![demo](docs/demo.gif)](https://asciinema.org/a/OW6rlNlj65B3uZ3c)

## Why

Existing options are incomplete:

- `gh.nvim` ignores gists entirely.
- `gist.nvim` can list/open but editing is clunky and delete is missing.
- `telescope-github.nvim` shows gists with no syntax highlight in preview and is effectively unmaintained.

`telescope-gist` aims to be the missing piece: a Telescope-native picker with **list, preview, open-and-edit, delete, create, and refresh** — all with a fast cache so it never feels slow.

## Features

- `:Telescope gist list` — picker with visibility, description, file count, relative date
- Preview with **filetype-aware syntax highlighting**
- `:GistCreate` — create a gist from the current buffer; supports visual selection (`:'<,'>GistCreate` or `<leader>gn` in visual mode)
- Picker actions:
  - `<CR>` open gist for editing — one buffer per file for multi-file gists; `:w` PATCHes content back to GitHub
  - `<C-d>` delete gist (with confirm)
  - `<C-n>` new gist from current buffer
  - `<C-y>` yank gist URL to clipboard
  - `<C-r>` force-refresh cached list
- **Two-layer cache** (memory + disk JSON, TTL 10 min) — picker opens instantly after first load, even across Neovim restarts
- **Two data backends** — default `gh` CLI, or opt-in direct GitHub REST/GraphQL with ETag revalidation and batched content prefetch (see [Data backends](#data-backends))
- **Large files** — files over ~1MB are loaded in full when opened, so they can be edited and pushed back safely

## Requirements

- Neovim 0.10+
- [`gh`](https://cli.github.com/) CLI, authenticated via `gh auth login` (default `cli` backend), **or** a `GH_TOKEN` / `GITHUB_TOKEN` env var with the opt-in `api` backend (see [Data backends](#data-backends))
- [`telescope.nvim`](https://github.com/nvim-telescope/telescope.nvim)
- [`plenary.nvim`](https://github.com/nvim-lua/plenary.nvim) (transitively required by Telescope)

## Installation

### lazy.nvim / LazyVim

```lua
{
  "antlis/telescope-gist",
  dependencies = {
    {
      "nvim-telescope/telescope.nvim",
      cmd = "Telescope",
      dependencies = { "nvim-lua/plenary.nvim" },
    },
  },
  config = function()
    require("telescope-gist").setup({})
    require("telescope").load_extension("gist")
  end,
  keys = {
    { "<leader>gG", "<cmd>Telescope gist list<cr>", desc = "Gist List" },
    { "<leader>gn", ":GistCreate<CR>", desc = "Create Gist", mode = { "n", "v" } },
  },
}
```

### packer.nvim

```lua
use {
  "antlis/telescope-gist",
  requires = { "nvim-telescope/telescope.nvim", "nvim-lua/plenary.nvim" },
  config = function()
    require("telescope-gist").setup({})
    require("telescope").load_extension("gist")
  end,
}
```

### vim-plug

```vim
Plug 'nvim-lua/plenary.nvim'
Plug 'nvim-telescope/telescope.nvim'
Plug 'antlis/telescope-gist'
```

Then in your `init.lua`:

```lua
require("telescope-gist").setup({})
require("telescope").load_extension("gist")
```

### mini.deps

```lua
MiniDeps.add({
  source = "antlis/telescope-gist",
  depends = { "nvim-telescope/telescope.nvim", "nvim-lua/plenary.nvim" },
})
require("telescope-gist").setup({})
require("telescope").load_extension("gist")
```

### Manual / other managers

Clone the repo anywhere on your `runtimepath` and ensure `telescope.nvim` + `plenary.nvim` are installed. Then add to your config:

```lua
require("telescope-gist").setup({})
require("telescope").load_extension("gist")
```

## Configuration

```lua
require("telescope-gist").setup({
  limit = 100,                        -- gists to fetch (GitHub caps at 100; no pagination yet)
  backend = "cli",                    -- "cli" (gh) or "api" (REST/GraphQL, see Data backends)
  api = {
    prefetch_count = 10,              -- newest gists batch-fetched via GraphQL (0 disables, max 100)
  },
  cache = {
    enabled = true,
    ttl_minutes = 10,                 -- staleness threshold (see Caching)
    dir = vim.fn.stdpath("cache") .. "/telescope-gist",
  },
  keymaps = {
    open     = "<CR>",      -- opens for editing; :w pushes back via PATCH /gists/<id>
    delete   = "<C-d>",
    new      = "<C-n>",
    yank_url = "<C-y>",
    refresh  = "<C-r>",
  },
})
```

## Data backends

Two interchangeable backends, selected with `backend`. Both return the same
REST-shaped data, so the picker, previewer and actions behave identically.

| | `"cli"` (default) | `"api"` (opt-in) |
|---|---|---|
| Transport | `gh api` subprocess | GitHub REST/GraphQL via `plenary.curl` |
| Auth | `gh auth login` | `GH_TOKEN` / `GITHUB_TOKEN`, falling back to `gh auth token` |
| Cache validation | TTL only | TTL + **ETag / `If-None-Match`** (304 = no payload) |
| Stale list | served until `<C-r>` | served instantly, revalidated in the background |
| Preview latency | one subprocess per gist | newest `api.prefetch_count` (10) gists prefetched in **one GraphQL call** |

### Enabling the `api` backend

```lua
require("telescope-gist").setup({ backend = "api" })
```

**Authentication.** The token is resolved once per session, in this order:

1. `$GH_TOKEN`
2. `$GITHUB_TOKEN`
3. `gh auth token` (your existing `gh auth login`)

The token needs the `gist` scope. You don't need the `gh` CLI at all if you
export one of the env vars. A `401` response drops the cached token so the next
call re-resolves it.

**Fallback.** If no token can be found, telescope-gist warns once and uses the
`gh` CLI for the rest of the session (restart Neovim after logging in to switch
back). With `backend = "cli"` none of the API code is loaded.

### What the `api` backend adds

- **ETag revalidation.** List and per-gist responses are stored with their
  `ETag`. When the cache is older than `ttl_minutes`, the picker opens
  immediately with the cached list and a background request sends
  `If-None-Match`. A `304` just resets the timer; a `200` swaps the new list
  into the open picker without resetting your prompt.
- **GraphQL prefetch.** After a fresh list fetch, one GraphQL query loads the
  file contents of the newest `api.prefetch_count` gists into the content
  cache, so previews are instant. Gists with truncated files are skipped and
  load through REST on demand. Prefetch is best-effort; errors are silent.
- **Preview revalidation.** Stale cached previews are revalidated with the
  gist's `ETag` when selected, so edits made elsewhere show up.
- **No subprocess per call.** Requests go through `plenary.curl`.

### Large files

The API truncates inline file content at about 1MB. When you open a gist,
truncated files are downloaded in full from their `raw_url` (no auth needed,
even for secret gists) and saved to the cache, so they can be edited and
pushed back. If that download fails you get a warning, the file stays
truncated, and `:w` refuses to push it, so a partial prefix can never overwrite
the full gist. This applies to both backends.

## Caching

Two layers: in-memory for the session, and one JSON file per key under
`cache.dir` (atomic writes, schema-versioned). Keys are `gists` (the list) and
`gist:<id>` (file contents).

- The list and each gist's contents are served from cache when present.
- `cache.ttl_minutes` marks an entry stale. On the `api` backend a stale list
  or preview is revalidated in the background; on the `cli` backend the cache
  is served until you press `<C-r>`.
- `<C-r>` drops the list cache and refetches. Per-gist content caches are kept
  (they are updated when you edit, and by prefetch / ETag revalidation).
- Create, edit and delete update the cache locally, so no refetch is needed.
- Set `cache.enabled = false` to always fetch.

## Limitations

- Lists at most 100 gists (no pagination yet).
- Edits push one file per `:w` (`PATCH /gists/<id>`).
- Windows: cache writes use `os.rename`, which fails if the destination exists.

## Architecture

```
lua/
├── telescope/_extensions/gist.lua   -- Telescope extension entry point
└── telescope-gist/
    ├── init.lua          -- public API: setup(), list()
    ├── config.lua        -- defaults + vim.tbl_deep_extend merge
    ├── gh.lua            -- async wrapper around `gh` CLI + backend dispatch
    ├── api.lua           -- opt-in REST/GraphQL backend (plenary.curl, ETags)
    ├── cache.lua         -- two-layer cache (memory + disk TTL)
    ├── pickers.lua       -- Telescope picker construction
    ├── previewer.lua     -- filetype-aware preview buffer
    └── actions.lua       -- open / edit / delete / new / yank / refresh
```

## License

MIT
