# REPLConnect.jl

Connect to a plain Julia REPL from the outside. REPLConnect runs a small server
inside your interactive REPL process and exposes, over a Unix domain socket:

- **Variables**: list and inspect variables in `Main` (Positron-style
  `positron.variables` JSON-RPC).
- **Grid viewer**: browse tables and arrays (Tables.jl is used only if you
  have already loaded it).
- **Runtime completion**: completions from the live session.
- **Plots and history**: optionally capture plots and record REPL history.

It depends only on the standard library. The package lives in
`julia/REPLConnect`; see `docs/protocol.md` for the wire protocol and
`docs/attribution.md` for source provenance and third-party licenses.

## Install

Install the package into your global Julia environment (the one active when
the REPL starts). The package lives in a subdirectory of this repository:

```julia
using Pkg
Pkg.add(url = "https://github.com/arnold-c/REPLConnect.jl", subdir = "julia/REPLConnect")
```

For local development, use `Pkg.develop(path = "julia/REPLConnect")` from a
clone instead.

(`VimBindings` in the snippet below is a separate package and must be
installed the same way if you use it.)

## Neovim plugin

This repository is also a Neovim plugin (`replconnect-julia`) that registers
Julia with the core `replconnect.nvim` plugin, so both are needed. With
[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "arnold-c/REPLConnect.jl",
  dependencies = { "arnold-c/replconnect.nvim" },
  ft = "julia",
  opts = {}, -- optional: { command = { "julia", "--project=@." }, capture_plots = true }
}
```

REPLs launched from Neovim start REPLConnect automatically: they use an
installed `REPLConnect` package if there is one, and otherwise load the source
from this plugin checkout. The Install and Setup steps below are therefore only
needed to connect to a REPL you start yourself in a terminal.

### Completion (blink.cmp / nvim-cmp)

Runtime completions come through a normal LSP client, so the default `lsp`
source picks them up with no extra configuration. The client already
advertises `.`, `[`, `"` and `:` as trigger characters, so you do **not** need
to override `get_trigger_characters` for Julia.

Optionally, rank REPLConnect items above other language servers in blink.cmp:

```lua
sources = {
  providers = {
    lsp = {
      transform_items = function(_, items)
        for _, item in ipairs(items) do
          local client = vim.lsp.get_client_by_id(item.client_id)
          if client and client.name:match '^replconnect' then
            item.score_offset = (item.score_offset or 0) + 100
          end
        end
        return items
      end,
    },
  },
},
```

## Setup

Add this to your `~/.julia/config/startup.jl`

```julia
if isinteractive()
    # you likely want to disable VimBindings for a nvim
    # terminal if you use VimBindings
    if !haskey(ENV, "NVIM")
        using VimBindings
    end

    using REPLConnect: REPLConnect
    REPLConnect.start()
    REPLConnect.capture_plots!(true)
    REPLConnect.record_history!(true)
end
```

## API

| Function                    | Purpose                                      |
| --------------------------- | -------------------------------------------- |
| `REPLConnect.start()`       | Start the server in this REPL                |
| `REPLConnect.stop()`        | Stop it and remove the socket/discovery file |
| `capture_plots!(::Bool)`    | Enable or disable plot capture               |
| `capturing_plots()`         | Whether plot capture is on                   |
| `record_history!(::Bool)`   | Enable or disable history recording          |

## Discovery

Each REPL creates `<dir>/<pid>.sock` (mode `0600`) and `<dir>/<pid>.json`
describing it. `<dir>` is `$REPLCONNECT_DIR` if set, otherwise a short path
under `/tmp` (to stay within socket path length limits). Clients find running
REPLs by scanning that directory.

## Development

Tests are `@testitem` blocks next to the code; run them with `juliati` from
`julia/REPLConnect`.
