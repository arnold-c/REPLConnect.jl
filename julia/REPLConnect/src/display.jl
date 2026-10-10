# Opt-in static MIME capture. No plotting package or live plot objects retained.
mutable struct PlotStore
    dir::String
    limit::Int
    next_id::Int
    records::Vector{Dict{String, Any}}
end

struct PlotDisplay <: AbstractDisplay end
const PLOT_STORE = Ref{Union{Nothing, PlotStore}}(nothing)
const PLOT_DISPLAY = PlotDisplay()
const PLOT_INSTALL_PENDING = Ref(false)
const PLOT_MIMES = (MIME("image/png"), MIME("image/svg+xml"))
const DEFAULT_PLOT_LIMIT = 50

"""
    capturing_plots() -> Bool

Whether static image displays are currently captured; see [`capture_plots!`](@ref).
"""
capturing_plots() = PLOT_STORE[] !== nothing

"""
    capture_plots!(on::Bool = true; limit = nothing) -> Bool

Turn plot capture on or off for the running server and return the new state.

While on, PNG/SVG displays are written to a bounded private file history
(`limit` files, default 50) that an attached editor shows; otherwise they go
to the normal display stack (e.g. an external viewer). Turning capture off
deletes that history. Calling it while capture is on changes the limit,
pruning the oldest files, and otherwise keeps the history. Attached clients are
told about every change. Requires [`start`](@ref) first.
"""
function capture_plots!(on::Bool = true; limit::Union{Nothing, Int} = nothing)
    limit === nothing || limit > 0 || throw(ArgumentError("limit must be positive"))
    if !on
        disable_plots!()
    elseif capturing_plots()
        limit === nothing || set_plot_limit!(PLOT_STORE[], limit)
    else
        server = SERVER[]
        server === nothing &&
            throw(ArgumentError(
                "REPLConnect is not running; call REPLConnect.start() first",
            ))
        enable_plots!(server; limit = something(limit, DEFAULT_PLOT_LIMIT))
    end
    return capturing_plots()
end

function plot_history()
    capturing_plots() ||
        throw(RpcError(
            METHOD_NOT_FOUND,
            "Plot capture is off; REPLConnect.capture_plots!(true)",
        ))
    return Dict("plots" => copy(PLOT_STORE[].records))
end
handle_request(::Service, ::Val{:plots}, params) = plot_history()

"Drop the oldest records and their files beyond the store's limit."
function prune_plots!(store)
    while length(store.records) > store.limit
        rm(popfirst!(store.records)["path"]; force = true)
    end
    return nothing
end

function set_plot_limit!(store, limit::Int)
    store.limit = limit
    prune_plots!(store)
    return nothing
end

function enable_plots!(server; limit::Int)
    capturing_plots() && return
    dir = mktempdir(server.dir; prefix = "$(getpid())-plots-")
    ensure_private_dir(dir)
    PLOT_STORE[] = PlotStore(dir, limit, 0, Dict{String, Any}[])
    PLOT_INSTALL_PENDING[] = true
    # A REPL pushes its REPLDisplay when it starts, after `atreplinit` hooks and
    # after top-level `startup.jl` code; installing before that would leave it
    # below the REPLDisplay. Then install once at the first evaluation, not
    # above displays added later by the user.
    repl_expected = isinteractive() ||
        (isdefined(Base, :active_repl) && Base.active_repl !== nothing)
    if !repl_expected || any(d -> d isa REPL.REPLDisplay, Base.Multimedia.displays)
        install_plot_display!()
    end
    announce_capabilities()
    return nothing
end

"""
Stop capture at runtime: displays fall through to the rest of the display stack
again, retained plot files are removed and clients learn the capability is gone.
"""
function disable_plots!()
    capturing_plots() || return nothing
    stop_plots!()
    server = SERVER[]
    server === nothing || foreach(c -> c.subscribed = false, server.connections)
    announce_capabilities()
    return nothing
end

"Tell every connected client the current capabilities (they change with capture)."
function announce_capabilities()
    server = SERVER[]
    server === nothing && return nothing
    message = Dict(
        "jsonrpc" => "2.0",
        "method" => "capabilities",
        "params" => Dict("capabilities" => capabilities()),
    )
    foreach(c -> enqueue!(c, message), server.connections)
    return nothing
end

function install_plot_display!()
    PLOT_INSTALL_PENDING[] || return nothing
    PLOT_INSTALL_PENDING[] = false
    PLOT_DISPLAY in Base.Multimedia.displays || pushdisplay(PLOT_DISPLAY)
    return nothing
end

function stop_plots!()
    PLOT_INSTALL_PENDING[] = false
    filter!(d -> d !== PLOT_DISPLAY, Base.Multimedia.displays)
    store = PLOT_STORE[]
    PLOT_STORE[] = nothing
    store === nothing || rm(store.dir; recursive = true, force = true)
    return nothing
end

Base.displayable(::PlotDisplay, mime::MIME) = mime in PLOT_MIMES

function plot_showable(d, mime, value)
    try
        return Base.invokelatest(showable, mime, value)
    catch e
        server = SERVER[]
        server === nothing ||
            log_line(server.log_path, "plot showable failed: " * sprint(showerror, e))
        throw(MethodError(display, (d, mime, value)))
    end
end

function publish_plot!(store, record)
    # Rendering can yield; shutdown must not publish an obsolete artifact.
    store === PLOT_STORE[] || throw(ArgumentError("Plot capture stopped"))
    push!(store.records, record)
    sort!(store.records; by = r -> r["id"])
    prune_plots!(store)
    server = SERVER[]
    if server !== nothing
        message = Dict("jsonrpc" => "2.0", "method" => "display", "params" => record)
        for connection in server.connections
            connection.subscribed && enqueue!(connection, message)
        end
    end
    return nothing
end

function Base.display(d::PlotDisplay, mime::MIME, value)
    (displayable(d, mime) && capturing_plots() && plot_showable(d, mime, value)) ||
        throw(MethodError(display, (d, mime, value)))
    store = PLOT_STORE[]
    extension = mime == MIME("image/png") ? "png" : "svg"
    tmp = path = nothing
    try
        tmp, io = mktemp(store.dir)
        try
            chmod(tmp, 0o600)
            Base.invokelatest(show, io, mime, value)
        finally
            close(io)
        end
        store === PLOT_STORE[] || throw(ArgumentError("Plot capture stopped"))
        # Rendering may yield to another display. Assign ids only when the
        # completed image is ready, so events remain monotonically ordered.
        store.next_id += 1
        id = store.next_id
        path = joinpath(store.dir, "$id.$extension")
        mv(tmp, path) # immutable: never replace a published path
        publish_plot!(
            store,
            Dict{String, Any}("id" => id, "mime" => string(mime), "path" => path),
        )
    catch e
        tmp === nothing || rm(tmp; force = true)
        path === nothing || rm(path; force = true)
        server = SERVER[]
        server === nothing ||
            log_line(server.log_path, "plot capture failed: " * sprint(showerror, e))
        # Julia's display stack only falls through on MethodError(display/show).
        throw(MethodError(display, (d, mime, value)))
    end
    return nothing
end

function Base.display(d::PlotDisplay, value)
    for mime in PLOT_MIMES
        plot_showable(d, mime, value) || continue
        return display(d, mime, value)
    end
    throw(MethodError(display, (d, value)))
end

@testitem "plot capture MIME preference, retention, fallback and cleanup" begin
    struct SyntheticImage end
    Base.showable(::MIME"image/png", ::SyntheticImage) = true
    Base.showable(::MIME"image/svg+xml", ::SyntheticImage) = true
    Base.show(io::IO, ::MIME"image/png", ::SyntheticImage) = write(io, "png bytes")
    Base.show(io::IO, ::MIME"image/svg+xml", ::SyntheticImage) = write(io, "<svg/>")
    struct BrokenImage end
    Base.showable(::MIME"image/png", ::BrokenImage) = true
    Base.show(::IO, ::MIME"image/png", ::BrokenImage) = error("render failed")
    REPLConnect.start(; dir = mktempdir())
    @test REPLConnect.capture_plots!(true; limit = 2)
    d = REPLConnect.PLOT_DISPLAY
    try
        @test "plots" in REPLConnect.capabilities()
        @test isempty(REPLConnect.plot_history()["plots"])
        display(d, SyntheticImage())
        first = only(REPLConnect.plot_history()["plots"])
        @test first["mime"] == "image/png"
        @test read(first["path"], String) == "png bytes"
        @test filemode(first["path"]) & 0o777 == 0o600
        display(d, MIME("image/svg+xml"), SyntheticImage())
        display(d, SyntheticImage())
        records = REPLConnect.plot_history()["plots"]
        @test [r["id"] for r in records] == [2, 3]
        @test !isfile(first["path"])
        @test records[1]["mime"] == "image/svg+xml"
        @test_throws MethodError display(d, 1)
        @test_throws MethodError display(d, MIME("text/plain"), SyntheticImage())
        @test_throws MethodError display(d, BrokenImage())
        @test length(REPLConnect.plot_history()["plots"]) == 2
        @test !any(endswith(".tmp"), readdir(REPLConnect.PLOT_STORE[].dir))
        REPLConnect.install_plot_display!()
        @test count(==(d), Base.Multimedia.displays) == 1
    finally
        paths = [r["path"] for r in REPLConnect.plot_history()["plots"]]
        REPLConnect.stop()
        @test all(!ispath(p) for p in paths)
        @test d ∉ Base.Multimedia.displays
        REPLConnect.uninstall_hook!()
    end
end

@testitem "plot subscription snapshot and serialized events" begin
    using Sockets
    server = REPLConnect.start(; dir = mktempdir())
    REPLConnect.capture_plots!(true)
    sockets = [connect(server.socket_path) for _ in 1:3]
    ask(s, id, method) = (
        println(s, REPLConnect.JSON.encode(Dict("id" => id, "method" => method)));
        REPLConnect.JSON.decode(readline(s))
    )
    try
        for s in sockets[1:2]
            @test isempty(ask(s, 1, "plots_subscribe")["result"]["plots"])
        end
        store = REPLConnect.PLOT_STORE[]
        path = joinpath(store.dir, "1.png")
        REPLConnect.write_private(path, "image")
        REPLConnect.publish_plot!(
            store,
            Dict{String, Any}("id" => 1, "mime" => "image/png", "path" => path),
        )
        for s in sockets[1:2]
            println(s, REPLConnect.JSON.encode(Dict("id" => 2, "method" => "status")))
            @test REPLConnect.JSON.decode(readline(s))["method"] == "display"
            @test REPLConnect.JSON.decode(readline(s))["id"] == 2
        end
        @test ask(sockets[3], 3, "plots")["result"]["plots"][1]["id"] == 1
        # Full outbound queue disconnects without writing or waiting.
        c = REPLConnect.Connection(IOBuffer(), fill("x", 64), Condition(), true, false)
        @test !REPLConnect.enqueue!(c, Dict("method" => "display"))
        @test c.closed && isempty(c.queue)
    finally
        foreach(close, sockets)
        REPLConnect.stop()
        REPLConnect.uninstall_hook!()
    end
end
