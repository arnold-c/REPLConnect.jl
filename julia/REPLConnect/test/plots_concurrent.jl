@testitem "yielding plot rendering publishes immutable files in id order" begin
    struct YieldingImage
        started::Channel{Nothing}
        resume::Channel{Nothing}
    end
    struct ImmediateImage end
    Base.showable(::MIME"image/png", ::Union{YieldingImage, ImmediateImage}) = true
    function Base.show(io::IO, ::MIME"image/png", value::YieldingImage)
        put!(value.started, nothing)
        take!(value.resume)
        write(io, "slow")
    end
    Base.show(io::IO, ::MIME"image/png", ::ImmediateImage) = write(io, "fast")
    started, resume = Channel{Nothing}(1), Channel{Nothing}(1)
    REPLConnect.start(; dir = mktempdir())
    REPLConnect.capture_plots!(true)
    task = @async display(REPLConnect.PLOT_DISPLAY, YieldingImage(started, resume))
    try
        take!(started)
        @test isempty(REPLConnect.plot_history()["plots"])
        display(REPLConnect.PLOT_DISPLAY, ImmediateImage())
        first = only(REPLConnect.plot_history()["plots"])
        @test first["id"] == 1
        @test read(first["path"], String) == "fast"
        put!(resume, nothing)
        wait(task)
        records = REPLConnect.plot_history()["plots"]
        @test [r["id"] for r in records] == [1, 2]
        @test read(records[2]["path"], String) == "slow"
        @test read(first["path"], String) == "fast" # no replacement
        @test length(readdir(REPLConnect.PLOT_STORE[].dir)) == 2
    finally
        isready(resume) || put!(resume, nothing)
        REPLConnect.stop()
        REPLConnect.uninstall_hook!()
    end
end
