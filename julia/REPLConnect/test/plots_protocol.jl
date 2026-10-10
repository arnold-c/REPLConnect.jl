@testitem "plot protocol fixtures replay and round trip" begin
    # The protocol fixtures belong to the core plugin (REPLConnect.nvim): set
    # REPLCONNECT_CORE to its checkout, else it is expected next to this repo.
    # pathof: <repo>/julia/REPLConnect/src/REPLConnect.jl
    repo_root = dirname(dirname(dirname(dirname(pathof(REPLConnect)))))
    core = get(ENV, "REPLCONNECT_CORE", "")
    core = isempty(core) ? joinpath(dirname(repo_root), "REPLConnect.nvim") : core
    fixture_path = joinpath(core, "spec", "fixtures", "plots.json")
    isfile(fixture_path) ||
        error(
            "protocol fixtures not found at $fixture_path; set REPLCONNECT_CORE to the REPLConnect.nvim checkout",
        )
    fixture = REPLConnect.JSON.decode(read(fixture_path, String))
    @test REPLConnect.JSON.decode(REPLConnect.JSON.encode(fixture)) == fixture
    service = REPLConnect.Service("fixture", Main)
    connection = REPLConnect.Connection(IOBuffer(), String[], Condition(), false, false)
    REPLConnect.start(; dir = mktempdir())
    REPLConnect.capture_plots!(true)
    try
        for case in fixture["cases"]
            reply = REPLConnect.handle_line(
                service,
                REPLConnect.JSON.encode(case["request"]),
                connection,
            )
            @test reply == case["response"]
        end
        @test connection.subscribed
        @test !haskey(fixture["notification"], "id")
        @test fixture["notification"]["params"]["mime"] == "image/svg+xml"
    finally
        REPLConnect.stop()
        REPLConnect.uninstall_hook!()
    end
    @test "plots" ∉ REPLConnect.capabilities()
    @test REPLConnect.respond(service, fixture["cases"][1]["request"])["error"]["code"] ==
        REPLConnect.METHOD_NOT_FOUND
end

@testitem "plot startup, evaluation guard and synthetic display timings" begin
    struct TimingImage end
    Base.showable(::MIME"image/png", ::TimingImage) = true
    Base.show(io::IO, ::MIME"image/png", ::TimingImage) = write(io, "synthetic image")
    # Warm compilation separately; these numbers do not include backend rendering.
    dir = mktempdir()
    REPLConnect.start(; dir)
    REPLConnect.stop()
    REPLConnect.start(; dir)
    REPLConnect.capture_plots!(true)
    display(REPLConnect.PLOT_DISPLAY, TimingImage())
    REPLConnect.stop()
    try
        disabled_start = @elapsed REPLConnect.start(; dir)
        disabled_guard = @elapsed for _ in 1:100_000
            REPLConnect.install_plot_display!()
        end
        REPLConnect.stop()
        enabled_start = @elapsed (
            REPLConnect.start(; dir);
            REPLConnect.capture_plots!(true)
        )
        enabled_guard = @elapsed for _ in 1:100_000
            REPLConnect.install_plot_display!()
        end
        display_latency = @elapsed display(REPLConnect.PLOT_DISPLAY, TimingImage())
        @info "Opt-in plot timings (seconds; synthetic show, no editor)" disabled_start enabled_start disabled_guard enabled_guard display_latency
        @test REPLConnect.mark_dirty!() === nothing
    finally
        REPLConnect.stop()
        REPLConnect.uninstall_hook!()
    end
end
