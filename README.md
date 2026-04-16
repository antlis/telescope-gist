# telescope-gist

A [Telescope](https://github.com/nvim-telescope/telescope.nvim) extension for managing
your GitHub Gists from inside Neovim — built for [LazyVim](https://www.lazyvim.org/), works anywhere.

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

## Requirements

- Neovim 0.10+
- [`gh`](https://cli.github.com/) CLI, authenticated via `gh auth login`
- [`telescope.nvim`](https://github.com/nvim-telescope/telescope.nvim)
- [`plenary.nvim`](https://github.com/nvim-lua/plenary.nvim) (transitively required by Telescope)

## Installation (LazyVim / lazy.nvim)

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

## Configuration

```lua
require("telescope-gist").setup({
  limit = 100,                        -- gh gist list --limit
  cache = {
    enabled = true,
    ttl_minutes = 10,
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

## Roadmap: data backend

v0.1 uses the `gh` CLI as the data source — zero auth code, ships fast, and
the two-layer cache hides subprocess overhead.

v0.2 will move to a **hybrid model**: keep `gh` for auth bootstrap (`gh auth token`)
but talk to the GitHub REST/GraphQL API directly via `plenary.curl`. Wins:

- **ETag / `If-None-Match`** — cache validation in <50ms with no payload transfer
- Lower per-call latency (no subprocess spawn)
- Single round-trip for list + first-file content (GraphQL)
- Still no PAT prompts: token comes from the user's existing `gh` auth

The boundary lives entirely inside `lua/telescope-gist/gh.lua` — every other
module already consumes a normalized shape that matches the REST API, so the
swap is contained.

## Architecture

```
lua/
├── telescope/_extensions/gist.lua   -- Telescope extension entry point
└── telescope-gist/
    ├── init.lua          -- public API: setup(), list()
    ├── config.lua        -- defaults + tbl_deep_extend merge
    ├── gh.lua            -- async wrapper around `gh` CLI
    ├── cache.lua         -- two-layer cache (memory + disk TTL)
    ├── pickers.lua       -- Telescope picker construction
    ├── previewer.lua     -- filetype-aware preview buffer
    └── actions.lua       -- open / edit / delete / new / yank / refresh
```

## License

MIT
