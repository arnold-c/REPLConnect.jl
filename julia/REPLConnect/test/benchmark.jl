# Benchmarks for the work REPLConnect does on the REPL thread (plan step 0.3).
# Run with: juliati julia/REPLConnect --filter 'contains(name, "benchmark")' --output all
# They report timings (Chairmarks: minimum over many samples, so compilation
# and GC noise drop out) and only assert loose sanity bounds.

@testitem "benchmark: server work on typical and awkward workspaces" begin
    using Chairmarks

    struct SlowShow end
    Base.show(io::IO, ::SlowShow) = (sleep(0.05); print(io, "SlowShow()"))

    # Workspaces, each in its own module like a REPL's `Main`.
    function workspace(fill!)
        m = Module(:Bench) # with Base, like a real `Main`
        fill!(m)
        return m
    end
    small = workspace() do m
        for i in 1:1000
            Core.eval(m, :($(Symbol("v", i)) = $i))
        end
    end
    bigdict = workspace() do m
        Core.eval(m, :(d = Dict(i => Dict("k$j" => j for j in 1:20) for i in 1:5_000)))
    end
    bigarray = workspace() do m
        Core.eval(m, :(a = zeros(10^7)))
    end
    slowshow = workspace() do m
        Core.eval(m, :(s = $(SlowShow())))
    end
    mixed = workspace() do m
        for i in 1:1000
            Core.eval(m, :($(Symbol("v", i)) = $i))
        end
        Core.eval(m, :(d = Dict(i => i for i in 1:10^5)))
        Core.eval(m, :(a = zeros(10^7)))
    end
    cases = [
        "1000 small globals" => small,
        "nested Dict (5000x20)" => bigdict,
        "10^7 Float64 array" => bigarray,
        "slow show (50 ms)" => slowshow,
        "mixed" => mixed,
    ]

    "Human-readable duration from seconds."
    function fmt(seconds)
        seconds < 1.0e-6 && return string(round(seconds * 1.0e9; digits = 1), " ns")
        seconds < 1.0e-3 && return string(round(seconds * 1.0e6; digits = 2), " µs")
        seconds < 1 && return string(round(seconds * 1.0e3; digits = 2), " ms")
        return string(round(seconds; digits = 2), " s")
    end

    println("\n--- list / snapshot cost on the REPL thread (min of samples) ---")
    println(rpad("workspace", 26), rpad("list (collect)", 16), "snapshot (diff base)")
    for (name, m) in cases
        t_list = (@b REPLConnect.collect_variables(m) seconds = 1).time
        t_snap = (@b REPLConnect.snapshot(m) seconds = 1).time
        println(rpad(name, 26), rpad(fmt(t_list), 16), fmt(t_snap))
    end

    # Budgets: a snapshot must not depend on `show` or on the size of values.
    @test (@b REPLConnect.snapshot(slowshow)).time < 1.0e-3
    @test (@b REPLConnect.snapshot(bigdict)).time < 1.0e-3
    @test (@b REPLConnect.snapshot(bigarray)).time < 1.0e-3

    println("\n--- changes: unchanged version, and one reassigned variable ---")
    service = REPLConnect.Service("bench", mixed)
    REPLConnect.refresh!(service)
    t_same = (@b REPLConnect.changes!(service, service.version)).time
    println("unchanged (O(1) short-circuit): ", fmt(t_same))
    @test t_same < 1.0e-4 # never touches the workspace

    # Each sample needs a fresh change, so one evaluation per setup. The setup
    # reassigns `v1` like a REPL line would and returns the version the client holds.
    function reassign!(service, m)
        REPLConnect.mark_dirty!()
        Core.eval(m, Expr(:(=), :v1, rand(1:10^6)))
        return service.version
    end
    t_once = (
        @b reassign!(service, mixed) REPLConnect.changes!(service, _) evals = 1 seconds = 2
    ).time
    println("one change on the mixed workspace: ", fmt(t_once))

    println("\n--- per-evaluation overhead of the REPL hook ---")
    t_mark = (@b REPLConnect.mark_dirty!()).time
    println("mark_dirty!: ", fmt(t_mark), " per call")
    @test t_mark < 1.0e-6 # plan: under 1 microsecond

    raw = :(1 + 1)
    wrapped = REPLConnect.mark_transform(raw)
    t_raw = (@b Core.eval(Main, raw)).time
    t_wrapped = (@b Core.eval(Main, wrapped)).time
    println("eval of `1 + 1`: ", fmt(t_raw), " plain, ", fmt(t_wrapped), " wrapped")
end
