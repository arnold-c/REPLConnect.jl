# Unix-socket server running inside the user's REPL process.
#
# Wire format: newline-delimited JSON-RPC 2.0 (see docs/protocol.md). Every
# connection gets its own `Service` (and so its own change baseline). Handlers
# run as tasks on the REPL's thread, i.e. while the REPL is idle or yielding.
#
# Discovery: `<dir>/<pid>.sock` is the socket and `<dir>/<pid>.json` describes
# the session; `<dir>/<pid>.log` receives diagnostics (never the terminal).

const PARSE_ERROR = -32700
const INVALID_REQUEST = -32600

# Sockets paths are limited to ~104 bytes on macOS (108 on Linux).
const MAX_SOCKET_PATH = 100

"A bounded, serialized outbound stream. Enqueue never performs socket IO."
mutable struct Connection
    socket::IO
    queue::Vector{String}
    wake::Condition
    subscribed::Bool
    closed::Bool
end

function disconnect!(c::Connection)
    c.closed && return
    c.closed = true
    empty!(c.queue)
    notify(c.wake)
    @async close(c.socket)
    return nothing
end

function enqueue!(c::Connection, message)
    c.closed && return false
    if length(c.queue) >= 64
        disconnect!(c)
        return false
    end
    line = JSON.encode(message) * "\n"
    if sum(ncodeunits, c.queue; init = 0) + ncodeunits(line) > 16 * 1024 * 1024
        disconnect!(c)
        return false
    end
    push!(c.queue, line)
    notify(c.wake)
    return true
end

function write_loop(c::Connection)
    try
        while !c.closed
            isempty(c.queue) && wait(c.wake)
            c.closed && break
            while !isempty(c.queue) && !c.closed
                write(c.socket, popfirst!(c.queue))
            end
        end
    catch
    finally
        disconnect!(c)
    end
end

"Everything needed to shut a running server down."
mutable struct Server
    dir::String
    socket_path::String
    info_path::String
    log_path::String
    listener::Sockets.PipeServer
    mod::Module
    task::Task
    connections::Set{Connection}
end

const SERVER = Ref{Union{Nothing, Server}}(nothing)

current_uid() = Int(ccall(:getuid, Cuint, ()))

"""
Directory for sockets and discovery files: `\$REPLCONNECT_DIR` if set, else
`/tmp/replconnect-<uid>`.

The location deliberately ignores `TMPDIR`/`XDG_RUNTIME_DIR`: the REPL and
the editor are separate processes whose environments often differ (macOS
`TMPDIR` is not inherited by GUI apps or tmux servers), and both must agree.
The `/tmp` path is also short enough for socket path limits.
"""
function socket_dir(; env = ENV)
    custom = get(env, "REPLCONNECT_DIR", "")
    return isempty(custom) ? "/tmp/replconnect-$(current_uid())" : custom
end

"""
Create `dir` with mode 0700, or check that an existing one is a real directory
owned by this user (`/tmp` is shared, so another user could pre-create it).
"""
function ensure_private_dir(dir::AbstractString)
    if !ispath(dir)
        mkpath(dir; mode = 0o700)
    end
    st = lstat(dir)
    (isdir(st) && !islink(st)) || error("REPLConnect: $dir is not a directory")
    st.uid == current_uid() || error("REPLConnect: $dir is owned by another user")
    chmod(dir, 0o700)
    return nothing
end

"Fail early with a clear message if the socket path exceeds the OS limit."
function check_socket_path(path::AbstractString)
    ncodeunits(path) <= MAX_SOCKET_PATH ||
        error(
            "REPLConnect: socket path too long ($(ncodeunits(path)) > $MAX_SOCKET_PATH bytes): $path; " *
                "set REPLCONNECT_DIR to a shorter directory",
        )
    return nothing
end

"The `<pid>.json` discovery record."
discovery_info(socket_path, mod) = Dict{String, Any}(
    "pid" => getpid(),
    "socket" => socket_path,
    "cwd" => pwd(),
    "project" => something(Base.active_project(), ""),
    "language" => "julia",
    "julia_version" => string(VERSION),
    "protocol_version" => PROTOCOL_VERSION,
    "started_at" => STARTED_AT[],
)

"Append a diagnostic line to the server log; never throws."
function log_line(path::AbstractString, msg)
    try
        open(io -> println(io, round(Int, time()), " ", msg), path, "a")
    catch
    end
    return nothing
end

"Decode one request line and produce the reply message (or `nothing` for notifications)."
function handle_line(service::Service, line::AbstractString, connection = nothing)
    request = try
        JSON.decode(line)
    catch
        return error_message(nothing, RpcError(PARSE_ERROR, "Parse error"))
    end
    request isa AbstractDict ||
        return error_message(nothing, RpcError(INVALID_REQUEST, "Invalid request"))
    haskey(request, "id") || return nothing # notification: no reply
    method = get(request, "method", nothing)
    if method == "shutdown" && connection !== nothing
        enqueue!(connection, result_message(request["id"], Dict{String, Any}()))
        @async stop_after_reply(connection)
        return nothing
    end
    if method == "plots_subscribe" && connection !== nothing && capturing_plots()
        # No yield between enabling delivery, taking the snapshot and queuing
        # its reply: subsequent events are serialized after this response.
        connection.subscribed = true
        return result_message(request["id"], plot_history())
    end
    return respond(service, request)
end

function serve_connection(server::Server, sock::IO)
    connection = Connection(sock, String[], Condition(), false, false)
    push!(server.connections, connection)
    @async write_loop(connection)
    service = Service("socket", server.mod)
    try
        for line in eachline(sock)
            isempty(strip(line)) && continue
            reply = try
                # Tasks keep the world age they were started in (Julia 1.12+);
                # without `invokelatest` globals defined after `serve` are invisible.
                Base.invokelatest(handle_line, service, line, connection)
            catch e
                log_line(server.log_path, "handler failed: " * sprint(showerror, e))
                error_message(nothing, rpc_error(e))
            end
            reply === nothing && continue
            enqueue!(connection, reply) || break
        end
    catch e
        # Client went away mid-request, or the server is stopping.
        isopen(sock) &&
            log_line(server.log_path, "connection failed: " * sprint(showerror, e))
    finally
        delete!(server.connections, connection)
        disconnect!(connection)
    end
    return nothing
end

"""
Stop the server once the `shutdown` reply has been written. Best effort:
clients also treat the connection closing as a completed shutdown.
"""
function stop_after_reply(connection::Connection)
    try
        deadline = time() + 1
        while !connection.closed && !isempty(connection.queue) && time() < deadline
            sleep(0.01)
        end
        sleep(0.05) # let the final write leave the socket
        stop()
    catch e
        server = SERVER[]
        server === nothing ||
            log_line(server.log_path, "shutdown failed: " * sprint(showerror, e))
    end
    return nothing
end

function accept_loop(server::Server)
    while isopen(server.listener)
        sock = try
            accept(server.listener)
        catch
            break # listener closed
        end
        @async serve_connection(server, sock)
    end
    return nothing
end

"Write `content` to `path` atomically with the given file mode."
function write_private(path::AbstractString, content; mode = 0o600)
    tmp = path * ".tmp"
    write(tmp, content)
    chmod(tmp, mode)
    mv(tmp, path; force = true)
    return nothing
end

"""
    serve(; dir = socket_dir(), mod = Main) -> Server

Start listening and write the discovery files. Idempotent: returns the
running server if there is one.
"""
function serve(; dir::AbstractString = socket_dir(), mod::Module = Main)
    SERVER[] === nothing || return SERVER[]
    dir = abspath(dir)
    ensure_private_dir(dir)
    pid = getpid()
    socket_path = joinpath(dir, "$pid.sock")
    check_socket_path(socket_path)
    ispath(socket_path) && rm(socket_path)
    STARTED_AT[] = round(Int, time())

    listener = Sockets.listen(socket_path)
    chmod(socket_path, 0o600)
    info_path = joinpath(dir, "$pid.json")
    write_private(info_path, JSON.encode(discovery_info(socket_path, mod)))

    server = Server(
        dir,
        socket_path,
        info_path,
        joinpath(dir, "$pid.log"),
        listener,
        mod,
        current_task(),
        Set{Connection}(),
    )
    server.task = @async accept_loop(server)
    SERVER[] = server
    return server
end

"Stop the server, close connections and remove the socket and discovery files. Idempotent."
function stop()
    server = SERVER[]
    server === nothing && return nothing
    SERVER[] = nothing
    close(server.listener)
    foreach(disconnect!, collect(server.connections))
    stop_plots!()
    for path in (server.socket_path, server.info_path)
        rm(path; force = true)
    end
    return nothing
end

"""
    start() -> Server

Serve this REPL and install the evaluation hook. Safe to call repeatedly: a
running server is returned unchanged, so `startup.jl` and Neovim's
`:REPLStart` can both call it. Behaviour is configured separately with
[`capture_plots!`](@ref) and [`record_history!`](@ref). Stop with [`stop`](@ref),
or `:REPLStop` from Neovim.

The former keywords `history`, `plots` and `plot_limit` still work but are
deprecated in favour of those setters.
"""
function start(;
    history::Union{Nothing, Bool} = nothing,
    plots::Union{Nothing, Bool} = nothing,
    plot_limit::Union{Nothing, Int} = nothing,
    kwargs...,
)
    STARTED_AT[] == 0 && (STARTED_AT[] = round(Int, time()))
    install_hook!()
    fresh = SERVER[] === nothing
    server = serve(; kwargs...)
    fresh && atexit(stop)
    apply_deprecated_options(history, plots, plot_limit)
    return server
end

"Pre-split `start` keywords keep working, with a pointer to their setters."
function apply_deprecated_options(history, plots, plot_limit)
    if history !== nothing
        @warn "`start(; history)` is deprecated; call `REPLConnect.record_history!($history)`" maxlog = 1
        record_history!(history)
    end
    if plots !== nothing || plot_limit !== nothing
        @warn "`start(; plots, plot_limit)` is deprecated; call `REPLConnect.capture_plots!(true; limit = 50)` or `capture_plots!(false)`" maxlog = 1
        if plots !== nothing
            capture_plots!(plots; limit = plots ? plot_limit : nothing)
        elseif capturing_plots()
            capture_plots!(true; limit = plot_limit)
        end
    end
    return nothing
end

# Tests: a server on a temporary directory driven through a real socket.
@testitem "the server answers requests over a unix socket" begin
    using Sockets
    dir = mktempdir()
    sandbox = Module(:Sandbox, false)
    Core.eval(sandbox, :(x = 1))
    server = REPLConnect.serve(; dir, mod = sandbox)
    try
        @test REPLConnect.serve(; dir) === server # idempotent
        info = REPLConnect.JSON.decode(read(joinpath(dir, "$(getpid()).json"), String))
        @test info["socket"] == server.socket_path
        @test info["language"] == "julia"
        @test info["protocol_version"] == REPLConnect.PROTOCOL_VERSION
        @test filemode(server.socket_path) & 0o777 == 0o600

        sock = connect(server.socket_path)
        ask(req) = (
            println(sock, REPLConnect.JSON.encode(req));
            REPLConnect.JSON.decode(readline(sock))
        )

        init = ask(Dict("jsonrpc" => "2.0", "id" => 1, "method" => "initialize"))
        @test init["result"]["language"] == "julia"
        @test init["result"]["pid"] == getpid()

        status = ask(Dict("id" => 2, "method" => "status"))["result"]
        @test status["busy"] == false
        @test status["version"] == REPLConnect.version()

        list = ask(Dict("id" => 3, "method" => "list"))["result"]
        @test [v["access_key"] for v in list["variables"]] == ["x"]

        # no change since the list: nothing but the version
        same = ask(Dict(
            "id" => 4,
            "method" => "changes",
            "params" => Dict("since" => list["version"]),
        ))
        @test same["result"] == Dict("version" => list["version"])

        # globals defined after `serve` (a newer world) are seen
        Core.eval(sandbox, REPLConnect.mark_transform(:(late = [1, 2, 3])))
        changed = ask(Dict(
            "id" => 8,
            "method" => "changes",
            "params" => Dict("since" => list["version"]),
        ))["result"]
        @test [v["access_key"] for v in changed["assigned"]] == ["late"]
        @test changed["version"] == REPLConnect.version()
        relist = ask(Dict("id" => 9, "method" => "list"))["result"]
        @test [v["access_key"] for v in relist["variables"]] == ["late", "x"]

        # malformed input and unknown methods do not kill the connection
        println(sock, "{not json")
        @test REPLConnect.JSON.decode(readline(sock))["error"]["code"] ==
            REPLConnect.PARSE_ERROR
        println(sock, "[1]")
        @test REPLConnect.JSON.decode(readline(sock))["error"]["code"] ==
            REPLConnect.INVALID_REQUEST
        @test ask(Dict("id" => 5, "method" => "nope"))["error"]["code"] ==
            REPLConnect.METHOD_NOT_FOUND
        @test ask(Dict("id" => 6, "method" => "status"))["id"] == 6
        close(sock)

        # disconnect mid-request must not break the server
        sock2 = connect(server.socket_path)
        write(sock2, "{\"id\": 1, \"meth")
        close(sock2)
        sock3 = connect(server.socket_path)
        println(sock3, REPLConnect.JSON.encode(Dict("id" => 7, "method" => "status")))
        @test REPLConnect.JSON.decode(readline(sock3))["id"] == 7
        close(sock3)
    finally
        REPLConnect.stop()
    end
    @test !ispath(joinpath(dir, "$(getpid()).sock"))
    @test !ispath(joinpath(dir, "$(getpid()).json"))
    @test REPLConnect.stop() === nothing # idempotent
end

@testitem "socket_dir is fixed unless REPLCONNECT_DIR overrides it" begin
    uid = REPLConnect.current_uid()
    # TMPDIR and XDG_RUNTIME_DIR must not matter: the editor may not share them.
    for env in (
            Dict(),
            Dict("TMPDIR" => "/var/x"),
            Dict("XDG_RUNTIME_DIR" => "/run/user/1"),
        )
        @test REPLConnect.socket_dir(; env) == "/tmp/replconnect-$uid"
    end
    @test REPLConnect.socket_dir(; env = Dict("REPLCONNECT_DIR" => "/x/y")) == "/x/y"
    @test REPLConnect.socket_dir(; env = Dict("REPLCONNECT_DIR" => "")) ==
        "/tmp/replconnect-$uid"
end

@testitem "the socket directory is private and socket paths are bounded" begin
    dir = joinpath(mktempdir(), "sessions")
    REPLConnect.ensure_private_dir(dir)
    @test filemode(dir) & 0o777 == 0o700
    chmod(dir, 0o755)
    REPLConnect.ensure_private_dir(dir) # existing: tightened again
    @test filemode(dir) & 0o777 == 0o700

    file = joinpath(dir, "file")
    touch(file)
    @test_throws ErrorException REPLConnect.ensure_private_dir(file)
    link = joinpath(dirname(dir), "link")
    symlink(dir, link)
    @test_throws ErrorException REPLConnect.ensure_private_dir(link)

    @test_throws ErrorException REPLConnect.check_socket_path("/" * "a"^200)
    @test REPLConnect.check_socket_path("/tmp/replconnect-501/97508.sock") === nothing
end
