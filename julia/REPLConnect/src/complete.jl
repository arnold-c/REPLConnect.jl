# Runtime completion for the `complete` request.
#
# Column names of tables come first (`columns.jl`); everything else is
# `REPL.REPLCompletions` run against the live session. Cursors and ranges on
# the wire are 0-based UTF-8 byte offsets, `start` inclusive and `stop`
# exclusive, so `code[start+1:stop]` (by bytes) is the text a completion replaces.

const MAX_COMPLETIONS = 1000

# LSP `CompletionItemKind` values, so clients can pass them straight through.
const KIND_TEXT = 1
const KIND_METHOD = 2
const KIND_FUNCTION = 3
const KIND_FIELD = 5
const KIND_VARIABLE = 6
const KIND_CLASS = 7
const KIND_MODULE = 9
const KIND_PROPERTY = 10
const KIND_VALUE = 12
const KIND_KEYWORD = 14
const KIND_FILE = 17

"The LSP kind and a short type description of a bound name, or `nothing` if it cannot be read."
function binding_kind(parent::Module, name::AbstractString)
    sym = Symbol(name)
    isdefined(parent, sym) || return (KIND_VARIABLE, nothing)
    value = try
        getglobal(parent, sym)
    catch
        return (KIND_VARIABLE, nothing)
    end
    value isa Module && return (KIND_MODULE, nothing)
    value isa Function && return (KIND_FUNCTION, nothing)
    value isa Type && return (KIND_CLASS, nothing)
    return (KIND_VARIABLE, string(typeof(value)))
end

"Text a REPL completion inserts. Backslash completions have no `completion_text` method."
function completion_text(c)
    try
        return String(REPL.REPLCompletions.completion_text(c))
    catch
        return String(getfield(c, 1))
    end
end

"`(kind, detail)` of a REPL completion, keyed by its type name so Julia versions may add types."
function completion_kind(c)
    name = nameof(typeof(c))
    name === :ModuleCompletion && return binding_kind(c.parent, c.mod)
    name === :KeywordCompletion && return (KIND_KEYWORD, nothing)
    name === :PathCompletion && return (KIND_FILE, nothing)
    name === :PackageCompletion && return (KIND_MODULE, nothing)
    name === :PropertyCompletion && return (KIND_PROPERTY, nothing)
    name === :FieldCompletion && return (KIND_FIELD, nothing)
    name === :KeywordArgumentCompletion && return (KIND_PROPERTY, nothing)
    name === :MethodCompletion && return (KIND_METHOD, nothing)
    name === :DictCompletion && return (KIND_VALUE, nothing)
    return (KIND_TEXT, nothing)
end

function completion_item(c)
    kind, detail = completion_kind(c)
    item = Dict{String, Any}("label" => completion_text(c), "kind" => kind)
    detail === nothing || (item["detail"] = detail)
    return item
end

empty_completion(cursor) = (items = Dict{String, Any}[], start = cursor, stop = cursor)

"Table-column completion at the cursor, or `nothing`."
function column_items(code::AbstractString, cursor::Int, mod::Module)
    result = column_completion(code[1:cursor], mod)
    result === nothing && return nothing
    items = [
        Dict{String, Any}("label" => m, "kind" => KIND_FIELD, "detail" => t)
        for (m, t) in zip(result.matches, result.types)
    ]
    return (; items, start = cursor - ncodeunits(result.partial), stop = cursor)
end

"REPL completions at the cursor, as `(items, start, stop)`."
function repl_items(code::AbstractString, cursor::Int, mod::Module)
    completions, range, should_complete = REPL.REPLCompletions.completions(
        code,
        thisind(code, cursor),
        mod,
    )
    # Without `should_complete` the REPL only offers method signatures as hints.
    should_complete || return empty_completion(cursor)
    items = [completion_item(c) for c in Iterators.take(completions, MAX_COMPLETIONS)]
    return (; items, start = first(range) - 1, stop = last(range))
end

"""
    complete(code, cursor; mod = Main) -> (items, start, stop)

Completions for `code` with the cursor `cursor` bytes into it. Never throws:
failures in user code (`getproperty`, Tables.jl, ...) yield no completions.
"""
function complete(code::AbstractString, cursor::Integer; mod::Module = Main)
    cursor = clamp(Int(cursor), 0, ncodeunits(code))
    # A cursor inside a multi-byte character moves back to the character's start.
    cursor < ncodeunits(code) && (cursor = thisind(code, cursor + 1) - 1)
    cursor == 0 && return empty_completion(0)
    try
        columns = column_items(code, cursor, mod)
        columns === nothing || return columns
        return repl_items(code, cursor, mod)
    catch
        return empty_completion(cursor)
    end
end

function handle_request(service::Service, ::Val{:complete}, params)
    code = param(params, "code")
    cursor = param(params, "cursor")
    (code isa AbstractString && cursor isa Integer) ||
        throw(RpcError(INVALID_PARAMS, "`code` and `cursor` are required"))
    items, start, stop = complete(code, cursor; mod = service.mod)
    return Dict{String, Any}("items" => items, "start" => start, "stop" => stop)
end

@testitem "complete finds names, properties and keywords" begin
    sandbox = Module(:Sandbox)
    Core.eval(sandbox, :(alpha_value = 1))
    Core.eval(sandbox, :(function alpha_func() end))
    Core.eval(sandbox, :(point = (xcoord = 1, ycoord = 2)))

    result = REPLConnect.complete("alpha_", 6; mod = sandbox)
    labels = [i["label"] for i in result.items]
    @test sort(labels) == ["alpha_func", "alpha_value"]
    @test (result.start, result.stop) == (0, 6)
    kinds = Dict(i["label"] => i["kind"] for i in result.items)
    @test kinds["alpha_func"] == REPLConnect.KIND_FUNCTION
    @test kinds["alpha_value"] == REPLConnect.KIND_VARIABLE
    detail = Dict(i["label"] => get(i, "detail", nothing) for i in result.items)
    @test detail["alpha_value"] == "Int64"

    code = "y = point.x"
    result = REPLConnect.complete(code, ncodeunits(code); mod = sandbox)
    @test [i["label"] for i in result.items] == ["xcoord"]
    @test (result.start, result.stop) == (ncodeunits("y = point."), ncodeunits(code))
    @test result.items[1]["kind"] == REPLConnect.KIND_PROPERTY

    result = REPLConnect.complete("whi", 3; mod = sandbox)
    @test any(
        i -> i["label"] == "while" && i["kind"] == REPLConnect.KIND_KEYWORD,
        result.items,
    )
end

@testitem "complete uses byte offsets and only text before the cursor" begin
    sandbox = Module(:Sandbox)
    Core.eval(sandbox, :(α_long = 1))

    code = "αβ = 1; α_lo"
    result = REPLConnect.complete(code, ncodeunits(code); mod = sandbox)
    @test [i["label"] for i in result.items] == ["α_long"]
    @test result.start == ncodeunits("αβ = 1; ")
    @test result.stop == ncodeunits(code)
    @test code[(result.start + 1):result.stop] == "α_lo"

    # text after the cursor is not part of the completed word
    code = "α_lo + 1"
    result = REPLConnect.complete(code, ncodeunits("α_lo"); mod = sandbox)
    @test [i["label"] for i in result.items] == ["α_long"]
    @test (result.start, result.stop) == (0, ncodeunits("α_lo"))

    # a cursor inside a multi-byte character is moved back to its start
    result = REPLConnect.complete("α_lo", 1; mod = sandbox)
    @test result.start <= result.stop <= 1

    # backslash (LaTeX) completions
    result = REPLConnect.complete("\\alph", 5; mod = sandbox)
    @test "\\alpha" in [i["label"] for i in result.items]

    # out-of-range cursors are clamped, empty input has no completions
    @test REPLConnect.complete("", 0; mod = sandbox).items == []
    @test REPLConnect.complete("x", 99; mod = sandbox).stop <= 1
end

@testitem "complete offers table columns first and survives failures" begin
    using Tables
    sandbox = Module(:Sandbox)
    Core.eval(sandbox, :(df = (alpha = [1, 2], beta = ["a", "b"])))

    code = "df[!, :a"
    result = REPLConnect.complete(code, ncodeunits(code); mod = sandbox)
    @test [i["label"] for i in result.items] == ["alpha"]
    @test result.items[1]["detail"] == "Int64"
    @test code[(result.start + 1):result.stop] == "a"

    Core.eval(sandbox, :(struct Bomb end))
    Core.eval(sandbox, :(Base.getproperty(::Bomb, ::Symbol) = error("boom")))
    Core.eval(sandbox, :(bomb = Bomb()))
    result = REPLConnect.complete("bomb.", 5; mod = sandbox)
    @test result.items isa Vector
end

@testitem "the complete request validates params and answers with items" begin
    sandbox = Module(:Sandbox, false)
    Core.eval(sandbox, :(some_value = 1))
    service = REPLConnect.Service("c", sandbox)

    reply = REPLConnect.respond(
        service,
        Dict(
            "id" => 1,
            "method" => "complete",
            "params" => Dict("code" => "some_v", "cursor" => 6),
        ),
    )
    @test [i["label"] for i in reply["result"]["items"]] == ["some_value"]
    @test (reply["result"]["start"], reply["result"]["stop"]) == (0, 6)

    reply = REPLConnect.respond(
        service,
        Dict("id" => 2, "method" => "complete", "params" => Dict("code" => "x")),
    )
    @test reply["error"]["code"] == REPLConnect.INVALID_PARAMS
end
