@testitem "plot capability can become available after the server is discovered" begin
    using Sockets
    dir = mktempdir()
    server = REPLConnect.start(; dir) # startup.jl starts ordinary inspection first
    sock = connect(server.socket_path)
    function ask(id, method)
        println(sock, REPLConnect.JSON.encode(Dict("id" => id, "method" => method)))
        while true
            # skip notifications, e.g. the capabilities announcement
            message = REPLConnect.JSON.decode(readline(sock))
            haskey(message, "id") && return message["result"]
        end
    end
    try
        first = ask(1, "initialize")
        @test "plots" ∉ first["capabilities"]
        @test REPLConnect.start(; dir) === server # :REPLStart calls it again
        @test REPLConnect.capture_plots!(true)    # launch hook enables capture later
        latest = ask(2, "initialize")
        @test latest["pid"] == first["pid"]
        @test "plots" in latest["capabilities"]
        @test isempty(ask(3, "plots_subscribe")["plots"])
    finally
        close(sock)
        REPLConnect.stop()
        REPLConnect.uninstall_hook!()
    end
end

@testitem "plot capture can be toggled at runtime and clients are told" begin
    using Sockets
    struct ToggleImage end
    Base.showable(::MIME"image/png", ::ToggleImage) = true
    Base.show(io::IO, ::MIME"image/png", ::ToggleImage) = write(io, "png")
    @test_throws ArgumentError REPLConnect.capture_plots!(true) # no server yet
    @test !REPLConnect.capturing_plots()
    dir = mktempdir()
    server = REPLConnect.start(; dir)
    sock = connect(server.socket_path)
    send(id, method) = println(
        sock,
        REPLConnect.JSON.encode(Dict("id" => id, "method" => method)),
    )
    receive() = REPLConnect.JSON.decode(readline(sock))
    announced() = (
        message = receive();
        @test message["method"] == "capabilities";
        message["params"]["capabilities"]
    )
    d = REPLConnect.PLOT_DISPLAY
    try
        send(1, "initialize")
        @test "plots" ∉ receive()["result"]["capabilities"]

        @test REPLConnect.capture_plots!(true; limit = 3)
        @test "plots" in announced()
        @test d in Base.Multimedia.displays
        send(2, "plots_subscribe")
        @test isempty(receive()["result"]["plots"])
        paths = map(1:3) do _
            display(d, ToggleImage())
            receive()["params"]["path"]
        end

        # Changing the limit while on keeps the history, pruning the oldest.
        @test REPLConnect.capture_plots!(true; limit = 2)
        @test [r["id"] for r in REPLConnect.plot_history()["plots"]] == [2, 3]
        @test !ispath(paths[1]) && ispath(paths[2])
        @test REPLConnect.capture_plots!(true) # no limit: unchanged
        @test REPLConnect.PLOT_STORE[].limit == 2
        @test REPLConnect.start(; dir) === server # repeated start changes nothing
        @test REPLConnect.capturing_plots()

        @test !REPLConnect.capture_plots!(false)
        @test "plots" ∉ announced()
        @test !REPLConnect.capturing_plots()
        @test d ∉ Base.Multimedia.displays # normal display stack again
        @test !any(ispath, paths)
        @test_throws MethodError display(d, ToggleImage())
        @test !REPLConnect.capture_plots!(false) # already off: nothing announced

        @test REPLConnect.capture_plots!(true)
        @test "plots" in announced() # next message: no stale announcements
        @test REPLConnect.PLOT_STORE[].limit == REPLConnect.DEFAULT_PLOT_LIMIT
        # Disabling unsubscribed the connection; a fresh subscription is needed.
        display(d, ToggleImage())
        send(3, "status")
        @test receive()["id"] == 3
        send(4, "plots_subscribe")
        @test only(receive()["result"]["plots"])["id"] == 1

        # History recording is a separate setter, also announced.
        REPLConnect.record_history!(false)
        @test "history" ∉ announced()
        REPLConnect.record_history!(true)
        @test "history" in announced()
    finally
        close(sock)
        REPLConnect.stop()
        REPLConnect.uninstall_hook!()
    end
end

@testitem "deprecated start keywords still configure, with a warning" begin
    dir = mktempdir()
    try
        @test_logs (:warn, r"capture_plots!") REPLConnect.start(;
            dir,
            plots = true,
            plot_limit = 4,
        )
        @test REPLConnect.capturing_plots() && REPLConnect.PLOT_STORE[].limit == 4
        @test_logs (:warn, r"record_history!") REPLConnect.start(; dir, history = false)
        @test !REPLConnect.RECORD_HISTORY[]
    finally
        REPLConnect.record_history!(true)
        REPLConnect.stop()
        REPLConnect.uninstall_hook!()
    end
end

@testitem "a client can shut the server down" begin
    using Sockets
    dir = mktempdir()
    server = REPLConnect.start(; dir)
    REPLConnect.capture_plots!(true)
    plot_dir = REPLConnect.PLOT_STORE[].dir
    sock = connect(server.socket_path)
    try
        println(sock, REPLConnect.JSON.encode(Dict("id" => 1, "method" => "initialize")))
        @test "shutdown" in
            REPLConnect.JSON.decode(readline(sock))["result"]["capabilities"]
        println(sock, REPLConnect.JSON.encode(Dict("id" => 2, "method" => "shutdown")))
        @test REPLConnect.JSON.decode(readline(sock)) ==
            Dict("jsonrpc" => "2.0", "id" => 2, "result" => Dict{String, Any}())
        @test timedwait(() -> REPLConnect.SERVER[] === nothing, 5) === :ok
        @test !ispath(server.socket_path) && !ispath(server.info_path)
        @test !ispath(plot_dir) && !REPLConnect.capturing_plots()
        @test REPLConnect.start(; dir) !== server # can be started again
    finally
        close(sock)
        REPLConnect.stop()
        REPLConnect.uninstall_hook!()
    end
end
