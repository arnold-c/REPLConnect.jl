# `definition`: where and how each method of a function is defined.
# Read-only: no evaluation and no package loading.

const CODETRACKING =
    Base.PkgId(Base.UUID("da1fd8a2-8d9e-5ec2-8556-3022fb5608a2"), "CodeTracking")

"Most methods returned for one function; methods from `Main` come first."
const DEFINITION_LIMIT = 200

"Inputs typed at the prompt that define methods, keyed by their `REPL[n]` file name."
const REPL_DEFINITIONS = Dict{String, Any}()

"Whether `ex` contains a method definition (`function`, `f(x) = …`, long or short form)."
defines_method(ex) = ex isa Expr && (
    ex.head === :function ||
        (ex.head === :(=) && is_signature(ex.args[1])) ||
        any(defines_method, ex.args)
)
is_signature(lhs) = lhs isa Expr &&
    (lhs.head === :call || (lhs.head in (:where, :(::)) && is_signature(lhs.args[1])))

"Remember a prompt input that defines methods, so `definition` can show its source."
function remember_definition!(ex)
    input = user_input(ex)
    (input === nothing || !defines_method(input)) && return nothing
    REPL_DEFINITIONS[string(input.args[1].file)] = input
    return nothing
end

"Text typed for `input`, found in the REPL history by parsing entries, or `nothing`."
function history_text(input)
    target = strip_markers(input)
    return try
        entries = Base.active_repl.interface.modes[1].hist.history
        for i in lastindex(entries):-1:max(firstindex(entries), lastindex(entries) - 1000)
            entry = entries[i]
            text = entry isa AbstractString ? entry : entry.content
            strip_markers(Meta.parseall(text)) == target && return String(text)
        end
        nothing
    catch
        nothing
    end
end

"The top-level statement of `input` that starts at `line`, printed, or `nothing`."
function statement_text(input, line::Integer)
    args = input.args
    for (i, arg) in enumerate(args)
        arg isa LineNumberNode && arg.line == line && i < length(args) &&
            return string(strip_markers(args[i + 1]))
    end
    return nothing
end

"Source of a method typed at the prompt as `REPL[n]`, or `nothing`."
function repl_source(file::AbstractString, line::Integer)
    input = get(REPL_DEFINITIONS, file, nothing)
    input === nothing && return nothing
    text = history_text(input)
    text === nothing || return expression_at(split(text, '\n'), line)
    return statement_text(input, line)
end

"The CodeTracking definition of `m` (present when Revise is loaded), or `nothing`."
function codetracking_source(m::Method)
    ct = get(Base.loaded_modules, CODETRACKING, nothing)
    ct === nothing && return nothing
    def = try
        Base.invokelatest(ct.definition, String, m)
    catch
        nothing
    end
    return def === nothing ? nothing : first(def)
end

"Text of the top-level expression starting at `line` of `path`, or `nothing`."
function file_source(path, line::Integer)
    path === nothing && return nothing
    return try
        expression_at(readlines(path), line)
    catch
        nothing
    end
end

"Text of the one top-level expression starting at `line` of `lines`, or `nothing`."
function expression_at(lines, line::Integer)
    1 <= line <= length(lines) || return nothing
    text = join(lines[line:end], "\n")
    _, stop = Meta.parse(text, 1; raise = false)
    return String(rstrip(text[1:prevind(text, stop)]))
end

# Prompt inputs are looked up first: CodeTracking indexes the REPL history in a
# way that is wrong on Julia 1.13, giving every method the same input.
function method_source(m::Method, path, file::AbstractString, line::Integer)
    if startswith(file, "REPL[")
        src = repl_source(file, line)
        src === nothing || return src
    end
    src = codetracking_source(m)
    src === nothing || return src
    return file_source(path, line)
end

"The `definition` entry for one method."
function method_location(m::Method)
    file, line = Base.updated_methodloc(m)
    file = string(file)
    path = Base.find_source_file(file)
    loc = Dict{String, Any}(
        "signature" => first(split(sprint(show, m), " @ ")),
        "file" => something(path, file),
        "line" => line,
    )
    src = method_source(m, path, file, line)
    src === nothing || (loc["source"] = src)
    return loc
end

"Methods of `f`, those defined in `Main` first, capped at `DEFINITION_LIMIT`."
function definition_methods(f)
    ms = collect(methods(f))
    sort!(ms; by = m -> m.module !== Main, alg = MergeSort)
    return first(ms, DEFINITION_LIMIT)
end

definition_locations(f) = Dict{String, Any}[method_location(m) for m in definition_methods(f)]

function handle_request(service::Service, ::Val{:definition}, params)
    f = resolve(path_param(params), service.mod)
    f isa Union{Function, Type} ||
        throw(RpcError(INVALID_PARAMS, "Not a function"))
    return Dict{String, Any}("locations" => definition_locations(f))
end

@testitem "definition locates a method defined in a file" begin
    dir = mktempdir()
    file = joinpath(dir, "defs.jl")
    write(file, "# header\nf(x) = x + 1\n\nfunction f(x, y)\n    x + y\nend\n")
    sandbox = Module(:Sandbox, false)
    Base.include(sandbox, file)
    service = REPLConnect.Service("c", sandbox)

    reply = REPLConnect.respond(
        service,
        Dict("id" => 1, "method" => "definition", "params" => Dict("path" => ["f"])),
    )
    locs = reply["result"]["locations"]
    @test length(locs) == 2
    @test all(l -> l["file"] == file, locs)
    byline = Dict(l["line"] => l for l in locs)
    @test byline[2]["source"] == "f(x) = x + 1"
    @test byline[4]["source"] == "function f(x, y)\n    x + y\nend"
end

@testitem "definition of a Base function resolves to a readable file" begin
    service = REPLConnect.Service("c", Module(:Sandbox, false))
    Core.eval(service.mod, :(g = $(Base.sum)))
    reply = REPLConnect.respond(
        service,
        Dict("id" => 1, "method" => "definition", "params" => Dict("path" => ["g"])),
    )
    locs = reply["result"]["locations"]
    @test !isempty(locs)
    @test any(l -> isfile(l["file"]), locs)
end

@testitem "definition of a non-function or unknown path is invalid params" begin
    sandbox = Module(:Sandbox, false)
    Core.eval(sandbox, :(x = 1))
    service = REPLConnect.Service("c", sandbox)
    for path in (["x"], ["nope"])
        reply = REPLConnect.respond(
            service,
            Dict("id" => 1, "method" => "definition", "params" => Dict("path" => path)),
        )
        @test reply["error"]["code"] == REPLConnect.INVALID_PARAMS
    end
end

@testitem "definition shows the source of a method typed at the prompt" begin
    sandbox = Module(:Sandbox, false)
    input = Meta.parseall("answer(x, y) = x + y"; filename = "REPL[7]")
    REPLConnect.remember_definition!(REPLConnect.mark_transform(input))
    Core.eval(sandbox, input)
    service = REPLConnect.Service("c", sandbox)

    reply = REPLConnect.respond(
        service,
        Dict("id" => 1, "method" => "definition", "params" => Dict("path" => ["answer"])),
    )
    loc = only(reply["result"]["locations"])
    @test loc["file"] == "REPL[7]"
    @test !isfile(loc["file"])
    @test loc["source"] == "answer(x, y) = x + y"
end

@testitem "each method sent in one prompt input gets its own source" begin
    sandbox = Module(:Sandbox, false)
    input = Meta.parseall("#%%\nduo(x, y) = x + y\n\nduo(x) = 20x"; filename = "REPL[8]")
    REPLConnect.remember_definition!(input)
    Core.eval(sandbox, input)
    service = REPLConnect.Service("c", sandbox)

    reply = REPLConnect.respond(
        service,
        Dict("id" => 1, "method" => "definition", "params" => Dict("path" => ["duo"])),
    )
    sources = Dict(l["line"] => l["source"] for l in reply["result"]["locations"])
    @test sources[2] == "duo(x, y) = x + y"
    @test occursin("duo(x) =", sources[4])
end

@testitem "expression_at cuts one statement out of multi-statement text" begin
    lines = ["#%%", "function f(x)", "    x", "end", "", "g(x) = 1"]
    @test REPLConnect.expression_at(lines, 2) == "function f(x)\n    x\nend"
    @test REPLConnect.expression_at(lines, 6) == "g(x) = 1"
    @test REPLConnect.expression_at(lines, 7) === nothing
end

@testitem "definition is a capability" begin
    @test "definition" in REPLConnect.capabilities()
end
