"""
    REPLConnect

Connect to a plain Julia REPL from outside: serves variables, a grid viewer and
runtime completion over a Unix domain socket (see `docs/protocol.md`).

The module can be `include`d into `Main` from `startup.jl` or loaded as a
regular package. It uses only stdlibs; packages such as Tables.jl are only
used if the user has already loaded them.

Source provenance and third-party licenses: `docs/attribution.md`.
"""
module REPLConnect

# Test items live next to the code they test (see https://julia-testitems.org).
# Test runners find `@testitem` blocks by scanning the source, so no dependency
# on TestItems.jl is needed here; this no-op keeps the files loadable.
"Ignore inline test-item bodies during normal loading; test runners discover them from source."
macro testitem(args...)
    return nothing
end

using REPL, Sockets

# Lifecycle (`start`/`stop`) is separate from behaviour (the setters).
public start, stop, capture_plots!, capturing_plots, record_history!

include("json.jl")
include("hook.jl")
include("variables.jl")
include("protocol.jl")
include("history.jl")
include("viewer.jl")
include("columns.jl")
include("complete.jl")
include("definition.jl")
include("server.jl")
include("display.jl")

end # module
