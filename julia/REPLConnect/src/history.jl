# Recent REPL inputs, for previewing a session before attaching to it.
#
# Per evaluation, `record_input!` only keeps a reference to the parsed
# input expression in a small ring buffer; no results are kept. Text is
# rendered on request.
#
# The REPL's own history is not used: on Julia 1.13 REPLs that share a
# history file merge each other's entries, so it is not per session.

"The most recent input expressions, oldest first."
const HISTORY = Any[]
const HISTORY_LIMIT = 10

"Whether inputs are recorded (default on); set by `record_history!`."
const RECORD_HISTORY = Ref(true)

"""
    record_history!(enabled::Bool) -> Bool

Turn recording of recent inputs (shown in Neovim's session picker) on or off.
Turning it off also forgets the inputs recorded so far. Attached clients are
told when this changes.
"""
function record_history!(enabled::Bool)
    changed = RECORD_HISTORY[] != enabled
    RECORD_HISTORY[] = enabled
    enabled || empty!(HISTORY)
    changed && announce_capabilities()
    return enabled
end

"Called at the start of each REPL evaluation, with the expression being evaluated."
function record_input!(ex)
    mark_dirty!()
    remember_definition!(ex)
    RECORD_HISTORY[] || return nothing
    length(HISTORY) >= HISTORY_LIMIT && popfirst!(HISTORY)
    push!(HISTORY, ex)
    return nothing
end

"Whether `ex` is the REPL's parsed input: `Expr(:toplevel, REPL[n] line, ...)`."
is_repl_input(ex) = ex isa Expr &&
    ex.head === :toplevel &&
    !isempty(ex.args) &&
    ex.args[1] isa LineNumberNode &&
    startswith(string(ex.args[1].file), "REPL[")

"""
The user's input inside `ex`, which other AST transforms (softscope, Revise,
…) may have wrapped; `ex` itself if it is not found.
"""
function user_input(ex)
    is_repl_input(ex) && return ex
    ex isa Expr || return nothing
    for arg in ex.args
        found = user_input(arg)
        found === nothing || return found
    end
    return nothing
end

"Drop line numbers and `softscope` markers; unwrap single-statement blocks."
function strip_markers(ex)
    ex isa Expr || return ex
    args = [
        strip_markers(a)
        for a in ex.args
        if !(a isa LineNumberNode) && !(a isa Expr && a.head === :softscope)
    ]
    ex.head in (:toplevel, :block) && length(args) == 1 && return args[1]
    return Expr(ex.head, args...)
end

"Source-like text of an input expression."
function input_text(ex)
    input = something(user_input(ex), ex)
    input isa Expr || return sprint(show, input)
    stripped = strip_markers(input)
    stripped isa Expr &&
        stripped.head === :toplevel &&
        return join(map(string, stripped.args), "; ")
    return string(stripped)
end

"`history`: the most recent inputs, oldest first."
function handle_request(::Service, ::Val{:history}, params)
    limit = param(params, "limit", HISTORY_LIMIT)
    limit isa Integer || throw(RpcError(INVALID_PARAMS, "`limit` must be an integer"))
    recent = HISTORY[max(1, end - limit + 1):end]
    return Dict{String, Any}(
        "entries" =>
            map(recent) do ex
                Dict{String, Any}("input" => ellipsize(input_text(ex), 2000))
            end,
    )
end

@testitem "history returns recent inputs" begin
    empty!(REPLConnect.HISTORY)
    service = REPLConnect.Service("c", Module(:Sandbox, false))
    REPLConnect.record_input!(:(x = 1 + 1))
    REPLConnect.record_input!(:(y = [1, 2]))

    reply = REPLConnect.respond(
        service,
        Dict("id" => 1, "method" => "history", "params" => Dict("limit" => 5)),
    )
    @test reply["result"]["entries"] ==
        [Dict("input" => "x = 1 + 1"), Dict("input" => "y = [1, 2]")]
    empty!(REPLConnect.HISTORY)
end

@testitem "input_text unwraps other REPL transforms" begin
    repl_input = Expr(
        :toplevel,
        LineNumberNode(1, Symbol("REPL[1]")),
        Expr(:block, Expr(:softscope, true), :(x = 100)),
    )
    revised = Expr(:toplevel, Expr(:block, :(Revise.revise())), repl_input)
    @test REPLConnect.input_text(revised) == "x = 100"

    loop = Expr(
        :toplevel,
        LineNumberNode(1, Symbol("REPL[2]")),
        :(
            for i in 1:2
                println(i)
            end
        ),
    )
    two = Expr(:toplevel, LineNumberNode(1, Symbol("REPL[3]")), :(a = 1), :(b = 2))
    @test REPLConnect.input_text(two) == "a = 1; b = 2"
    @test REPLConnect.input_text(:(x = 1 + 1)) == "x = 1 + 1"

    @test REPLConnect.input_text(loop) == "for i = 1:2\n    println(i)\nend"
end

@testitem "history recording can be turned off" begin
    empty!(REPLConnect.HISTORY)
    try
        REPLConnect.record_input!(:(a = 1))
        REPLConnect.record_history!(false)
        @test isempty(REPLConnect.HISTORY)
        before = REPLConnect.version()
        REPLConnect.record_input!(:(b = 2))
        @test isempty(REPLConnect.HISTORY)
        @test REPLConnect.version() == before + 1 # still marks the session dirty
        @test "history" ∉ REPLConnect.capabilities()
    finally
        REPLConnect.record_history!(true)
    end
    @test "history" in REPLConnect.capabilities()
end

@testitem "history keeps only the most recent evaluations" begin
    empty!(REPLConnect.HISTORY)
    for i in 1:(REPLConnect.HISTORY_LIMIT + 3)
        REPLConnect.record_input!(i)
    end
    @test length(REPLConnect.HISTORY) == REPLConnect.HISTORY_LIMIT
    @test REPLConnect.HISTORY[1] == 4
    empty!(REPLConnect.HISTORY)
end
