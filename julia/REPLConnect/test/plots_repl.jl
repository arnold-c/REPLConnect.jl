@testitem "plots capture implicit and explicit results on a real REPL backend" begin
    using REPL
    input = IOBuffer(
        """
    struct REPLConnectTestImage end; Base.showable(::MIME\"image/png\", ::REPLConnectTestImage) = true; Base.show(io::IO, ::MIME\"image/png\", ::REPLConnectTestImage) = write(io, \"image\");
    display(REPLConnectTestImage())
    REPLConnectTestImage()
    assigned_only = REPLConnectTestImage();
    """,
    )
    output = IOBuffer()
    terminal = REPL.Terminals.TTYTerminal("dumb", input, output, output)
    repl = REPL.BasicREPL(terminal)
    old_repl = isdefined(Base, :active_repl) ? Base.active_repl : nothing
    Core.eval(Base, :(active_repl = $repl))
    try
        REPLConnect.start(; dir = mktempdir())
        REPLConnect.capture_plots!(true)
        @test REPLConnect.PLOT_INSTALL_PENDING[]
        REPL.run_repl(repl)
        @test !REPLConnect.PLOT_INSTALL_PENDING[]
        @test length(REPLConnect.plot_history()["plots"]) == 2
        @test all(
            read(r["path"], String) == "image"
            for r in REPLConnect.plot_history()["plots"]
        )
    finally
        REPLConnect.stop()
        REPLConnect.uninstall_hook!()
        Core.eval(Base, :(active_repl = $old_repl))
    end
end

@testitem "capture enabled from top-level startup.jl waits for the REPL" begin
    using REPL
    input = IOBuffer(
        """
    struct TopLevelImage end; Base.showable(::MIME\"image/png\", ::TopLevelImage) = true; Base.show(io::IO, ::MIME\"image/png\", ::TopLevelImage) = write(io, \"image\");
    TopLevelImage()
    """,
    )
    output = IOBuffer()
    repl = REPL.BasicREPL(REPL.Terminals.TTYTerminal("dumb", input, output, output))
    old_repl = isdefined(Base, :active_repl) ? Base.active_repl : nothing
    old_interactive = isinteractive()
    # startup.jl runs in an interactive session before any REPL exists.
    Core.eval(Base, :(active_repl = nothing))
    Core.eval(Base, :(is_interactive = true))
    try
        REPLConnect.start(; dir = mktempdir())
        REPLConnect.capture_plots!(true)
        @test REPLConnect.PLOT_INSTALL_PENDING[] # not below the coming REPLDisplay
        @test !(REPLConnect.PLOT_DISPLAY in Base.Multimedia.displays)
        Core.eval(Base, :(active_repl = $repl))
        REPL.run_repl(repl) # pushes its REPLDisplay, then evaluates
        @test only(REPLConnect.plot_history()["plots"])["mime"] == "image/png"
    finally
        REPLConnect.stop()
        REPLConnect.uninstall_hook!()
        Core.eval(Base, :(is_interactive = $old_interactive))
        Core.eval(Base, :(active_repl = $old_repl))
    end
end

@testitem "plot fallback and later display owners are preserved" begin
    struct FailingPlot end
    Base.showable(::MIME"image/png", ::FailingPlot) = true
    Base.show(::IO, ::MIME"image/png", ::FailingPlot) = error("bad renderer")
    struct SVGPlot end
    Base.showable(::MIME"image/svg+xml", ::SVGPlot) = true
    Base.show(io::IO, ::MIME"image/svg+xml", ::SVGPlot) = print(io, "<svg/>")
    struct OtherDisplay <: AbstractDisplay
        values::Vector{Any}
    end
    Base.display(d::OtherDisplay, x) = push!(d.values, x)
    fallback = OtherDisplay(Any[])
    later = OtherDisplay(Any[])
    pushdisplay(fallback)
    try
        REPLConnect.start(; dir = mktempdir())
        REPLConnect.capture_plots!(true)
        REPLConnect.install_plot_display!()
        display(FailingPlot())
        display(123)
        @test length(fallback.values) == 2
        display(SVGPlot())
        @test only(REPLConnect.plot_history()["plots"])["mime"] == "image/svg+xml"
        pushdisplay(later)
        Core.eval(Main, REPLConnect.mark_transform(:(1 + 1)))
        display(SVGPlot())
        @test length(later.values) == 1
        @test length(REPLConnect.plot_history()["plots"]) == 1
        REPLConnect.stop()
        @test later in Base.Multimedia.displays
        @test fallback in Base.Multimedia.displays
    finally
        REPLConnect.stop()
        REPLConnect.uninstall_hook!()
        popdisplay(later)
        popdisplay(fallback)
    end
end
