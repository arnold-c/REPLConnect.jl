# Completion pipeline portions adapted from JuliaLang/IJulia.jl v1.34.4,
# src/handlers.jl (complete_request):
# https://github.com/JuliaLang/IJulia.jl/blob/v1.34.4/src/handlers.jl
# Copyright © 2013 Steven G. Johnson, Fernando Perez, Jeff Bezanson,
# Stefan Karpinski, Keno Fischer, and other contributors.
# MIT License; see ../../../LICENSES/IJulia-MIT.txt.
# Modified: transport-free table-column matches.
#
# Column-name completion for tables, inside indexing brackets:
#
#     df[!, <cursor>     df[:, :<cursor>     df[!, "<cursor>     df["<cursor>
#
# Used by `complete.jl`: if the text before the cursor ends in such an index of
# a table (anything Tables.jl recognises, e.g. a DataFrame), the columns are
# the completions.

const IDENT = raw"[\p{L}_][\p{L}\p{N}_!]*"

# `name` or `a.b.c`, `[`, an optional row selector (`!,` or `:,`), an optional
# opening `:` or `"`, and the partial column name. The lookbehind rejects
# `f(x).df[` and `v[1].df[`, whose receiver is not a plain name.
const COLUMN_CONTEXT = Regex(
    "(?<![\\p{L}\\p{N}_.!)\\]])($IDENT(?:\\.$IDENT)*)" *
        "\\[[ \\t]*(?:([!:])[ \\t]*,[ \\t]*)?(:|\")?([\\p{L}\\p{N}_]*)\$",
)

"""
Look up a dotted property path in `mod` without evaluating expressions.
Return `Some(value)` (including `Some(nothing)`) or `nothing` for an undefined
root. Property access uses the latest world age and may throw.
"""
function lookup(mod::Module, path::AbstractString)
    head, rest = Iterators.peel(split(path, '.'))
    isdefined(mod, Symbol(head)) || return nothing
    value = getglobal(mod, Symbol(head))
    for field in rest
        value = Base.invokelatest(getproperty, value, Symbol(field))
    end
    return Some(value)
end

"Whether `value` is indexed by column names (and not by position or key)."
is_column_indexed(value) = istable(value) &&
    !(value isa AbstractArray) &&
    !(value isa AbstractDict)

"""
    column_completion(prefix, mod) -> Union{Nothing, NamedTuple}

Column completions for the code `prefix` before the cursor, or `nothing` if the
cursor is not in a supported column position of a table in `mod`. Receivers
must be plain or dotted names; arrays/dictionaries are excluded. Supported
forms are `df[!, ...`, `df[:, ...` and `df[\"...`. Lookup failures are ignored;
Tables.jl interface errors may propagate to the caller. The result has
`matches` (text to insert), `types` (element types) and `partial`, the text
before the cursor that the matches replace.
"""
function column_completion(prefix::AbstractString, mod::Module = Main)
    m = match(COLUMN_CONTEXT, prefix)
    m === nothing && return nothing
    receiver, selector, quote_char, partial = m.captures
    # Without a row selector only `df["col"]` is column indexing; and a bare
    # partial name is a variable, not a column.
    (selector === nothing && quote_char != "\"") && return nothing
    (quote_char === nothing && !isempty(partial)) && return nothing

    found = try
        lookup(mod, receiver)
    catch
        nothing
    end
    found === nothing && return nothing
    table = something(found)
    is_column_indexed(table) || return nothing

    cols, names = table_columns(table)
    matches, types = String[], String[]
    for name in names
        key = string(name)
        startswith(key, partial) || continue
        text = column_text(key, quote_char)
        text === nothing && continue
        push!(matches, text)
        push!(types, string(eltype(table_column(cols, name))))
    end
    return (; matches, types, partial = String(partial))
end

"How column `key` is written after `quote_char`, or `nothing` if it cannot be."
function column_text(key::AbstractString, quote_char)
    if quote_char == "\""
        return escape_string(key, ('"', '$'))
    elseif quote_char == ":"
        return Base.isidentifier(key) ? key : nothing
    else
        return Base.isidentifier(key) ?
            ":" * key :
            "\"" * escape_string(key, ('"', '$')) * "\""
    end
end

@testitem "column completion in bracket positions" begin
    using Tables

    sandbox = Module(:Sandbox)
    Core.eval(
        sandbox,
        :(df = (alpha = [1, 2], beta = ["a", "b"], var"gamma delta" = [1.5, 2.5])),
    )
    Core.eval(sandbox, :(nested = (inner = df,)))
    Core.eval(sandbox, :(xs = [1, 2, 3]))
    Core.eval(sandbox, :(d = Dict(:a => 1)))

    # Complete against only the sandbox bindings created for this test.
    complete(prefix) = REPLConnect.column_completion(prefix, sandbox)
    # Extract match text while preserving the no-column-context sentinel.
    matches(prefix) = (r = complete(prefix); r === nothing ? nothing : r.matches)

    # No prefix: symbols where possible, strings otherwise
    @test matches("df[!, ") == [":alpha", ":beta", "\"gamma delta\""]
    @test matches("df[:, ") == [":alpha", ":beta", "\"gamma delta\""]
    @test matches("df[! , ") == [":alpha", ":beta", "\"gamma delta\""]
    # After `:`, bare names (only those that are valid identifiers)
    @test matches("df[!, :") == ["alpha", "beta"]
    @test matches("df[!, :b") == ["beta"]
    # After `"`, any name
    @test matches("df[!, \"") == ["alpha", "beta", "gamma delta"]
    @test matches("df[!, \"ga") == ["gamma delta"]
    @test matches("df[\"") == ["alpha", "beta", "gamma delta"]

    # What is replaced, and the element types
    r = complete("x = df[!, :al")
    @test r.partial == "al"
    @test r.matches == ["alpha"]
    @test r.types == ["Int64"]
    @test complete("df[!, ").partial == ""

    # Dotted receivers
    @test matches("nested.inner[!, :") == ["alpha", "beta"]

    # Not column positions
    @test complete("df[") === nothing # could be a row index
    @test complete("df[1") === nothing
    @test complete("df[!, al") === nothing # a variable, not a column
    @test complete("xs[!, :") === nothing  # not a table
    @test complete("d[:") === nothing      # dict keys are REPLCompletions' job
    @test complete("missing[!, :") === nothing
    @test complete("f(x).df[!, :") === nothing
    @test complete("nested.nope[!, :") === nothing
    @test complete("df[!, :alpha] + df[!, :") !== nothing
end
