# Minimal JSON for the wire protocol; no dependencies.
#
# Encodes `nothing`, `Bool`, integers, floats, strings, symbols, vectors/tuples
# and string-keyed dictionaries/named tuples. Decodes into `Dict{String,Any}`,
# `Vector{Any}`, `String`, `Int64`, `Float64`, `Bool` and `nothing`.

module JSON

    export encode, decode

    #
    # Encoding
    #

    "Encode `value` as a single line of JSON."
encode(value) = sprint(write_json, value)

    write_json(io::IO, ::Nothing) = print(io, "null")
    write_json(io::IO, x::Bool) = print(io, x ? "true" : "false")
    write_json(io::IO, x::Integer) = print(io, x)
    function write_json(io::IO, x::AbstractFloat)
        isfinite(x) ? print(io, x) : print(io, "null")
    end
    write_json(io::IO, x::Symbol) = write_json(io, String(x))
    write_json(io::IO, x::AbstractString) = write_string(io, x)

    function write_string(io::IO, s::AbstractString)
        print(io, '"')
        for c in s
            if c == '"'
                print(io, "\\\"")
            elseif c == '\\'
                print(io, "\\\\")
            elseif c == '\n'
                print(io, "\\n")
            elseif c == '\r'
                print(io, "\\r")
            elseif c == '\t'
                print(io, "\\t")
            elseif c < ' ' || c == '\u7f'
                print(io, "\\u", lpad(string(UInt16(c); base = 16), 4, '0'))
            else
                print(io, c)
            end
        end
        print(io, '"')
    end

    function write_json(io::IO, xs::Union{AbstractVector, Tuple})
        print(io, '[')
        for (i, x) in enumerate(xs)
            i > 1 && print(io, ',')
            write_json(io, x)
        end
        print(io, ']')
    end

    function write_json(io::IO, d::Union{AbstractDict, NamedTuple})
        print(io, '{')
        first = true
        for (k, v) in pairs(d)
            first || print(io, ',')
            first = false
            write_string(io, string(k))
            print(io, ':')
            write_json(io, v)
        end
        print(io, '}')
    end

    #
    # Decoding
    #

    "Decode one JSON document; throw `ArgumentError` on malformed input."
function decode(text::AbstractString)
        s = String(text)
        value, i = parse_value(s, skip_ws(s, 1))
        i = skip_ws(s, i)
        i > ncodeunits(s) || fail(s, i, "trailing characters")
        return value
    end

    fail(s, i, msg) = throw(ArgumentError("Invalid JSON at byte $i: $msg"))

    function skip_ws(s, i)
        while i <= ncodeunits(s) && codeunit(s, i) in (0x20, 0x09, 0x0a, 0x0d)
            i += 1
        end
        return i
    end

    peek_byte(s, i) = i <= ncodeunits(s) ? codeunit(s, i) : fail(s, i, "unexpected end")

    function parse_value(s, i)
        b = peek_byte(s, i)
        b == UInt8('{') && return parse_object(s, i + 1)
        b == UInt8('[') && return parse_array(s, i + 1)
        b == UInt8('"') && return parse_string(s, i + 1)
        for (word, value) in (("true", true), ("false", false), ("null", nothing))
            startswith(SubString(s, i), word) && return value, i + length(word)
        end
        return parse_number(s, i)
    end

    function parse_number(s, i)
        j = i
        while j <= ncodeunits(s) && codeunit(s, j) in b"+-0123456789.eE"
            j += 1
        end
        j > i || fail(s, i, "unexpected character")
        text = SubString(s, i, j - 1)
        value = tryparse(Int64, text)
        value === nothing && (value = tryparse(Float64, text))
        value === nothing && fail(s, i, "bad number")
        return value, j
    end

    function parse_array(s, i)
        out = Any[]
        i = skip_ws(s, i)
        peek_byte(s, i) == UInt8(']') && return out, i + 1
        while true
            value, i = parse_value(s, skip_ws(s, i))
            push!(out, value)
            i = skip_ws(s, i)
            b = peek_byte(s, i)
            i += 1
            b == UInt8(',') && continue
            b == UInt8(']') && return out, i
            fail(s, i - 1, "expected , or ]")
        end
    end

    function parse_object(s, i)
        out = Dict{String, Any}()
        i = skip_ws(s, i)
        peek_byte(s, i) == UInt8('}') && return out, i + 1
        while true
            i = skip_ws(s, i)
            peek_byte(s, i) == UInt8('"') || fail(s, i, "expected string key")
            key, i = parse_string(s, i + 1)
            i = skip_ws(s, i)
            peek_byte(s, i) == UInt8(':') || fail(s, i, "expected :")
            value, i = parse_value(s, skip_ws(s, i + 1))
            out[key] = value
            i = skip_ws(s, i)
            b = peek_byte(s, i)
            i += 1
            b == UInt8(',') && continue
            b == UInt8('}') && return out, i
            fail(s, i - 1, "expected , or }")
        end
    end

    function parse_hex4(s, i)
        i + 3 <= ncodeunits(s) || fail(s, i, "bad \\u escape")
        n = tryparse(UInt16, SubString(s, i, i + 3); base = 16)
        n === nothing && fail(s, i, "bad \\u escape")
        return n
    end

    const ESCAPES = Dict(
        UInt8('"') => '"',
        UInt8('\\') => '\\',
        UInt8('/') => '/',
        UInt8('b') => '\b',
        UInt8('f') => '\f',
        UInt8('n') => '\n',
        UInt8('r') => '\r',
        UInt8('t') => '\t',
    )

    # `i` is just after the opening quote; returns the string and the index after the closing quote.
    function parse_string(s, i)
        io = IOBuffer()
        while true
            b = peek_byte(s, i)
            if b == UInt8('"')
                return String(take!(io)), i + 1
            elseif b == UInt8('\\')
                e = peek_byte(s, i + 1)
                if e == UInt8('u')
                    unit = parse_hex4(s, i + 2)
                    i += 6
                    if 0xd800 <= unit <= 0xdbff
                        # High surrogate: must be followed by `\uDC00`-`\uDFFF`.
                        (
                            peek_byte(s, i) == UInt8('\\') &&
                                peek_byte(s, i + 1) == UInt8('u')
                        ) ||
                            fail(s, i, "unpaired surrogate")
                        low = parse_hex4(s, i + 2)
                        0xdc00 <= low <= 0xdfff || fail(s, i, "unpaired surrogate")
                        i += 6
                        print(
                            io,
                            Char(
                                0x00010000 +
                                    ((UInt32(unit) - 0xd800) << 10) +
                                    (low - 0xdc00),
                            ),
                        )
                    elseif 0xdc00 <= unit <= 0xdfff
                        fail(s, i, "unpaired surrogate")
                    else
                        print(io, Char(unit))
                    end
                else
                    haskey(ESCAPES, e) || fail(s, i, "bad escape")
                    print(io, ESCAPES[e])
                    i += 2
                end
            else
                b < 0x20 && fail(s, i, "control character in string")
                write(io, b)
                i += 1
            end
        end
    end

end # module

@testitem "JSON round-trips protocol values" begin
    using REPLConnect.JSON
    value = Dict{String, Any}(
        "a" => [1, 2.5, true, nothing, "x"],
        "s" => "quote\" back\\ nl\n tab\t ctl\u01 uni é 😀",
        "n" => Dict{String, Any}("deep" => Any[]),
    )
    @test decode(encode(value)) == value
    @test !occursin('\n', encode(value))
end

@testitem "JSON decodes escapes, surrogates and rejects malformed input" begin
    using REPLConnect.JSON
    @test decode(raw"\"\u00e9\ud83d\ude00\"") == "é😀"
    @test decode(" [1, -2, 3.5e2, {\"k\": null}] ") ==
        Any[1, -2, 350.0, Dict("k" => nothing)]
    @test decode("\"é\"") == "é"
    for bad in (
            "",
            "{",
            "[1,]",
            "{\"a\" 1}",
            "\"abc",
            raw"\"\ud83d\"",
            "1 2",
            "nul",
            "{\"a\":1,}",
        )
        @test_throws ArgumentError decode(bad)
    end
    @test encode((a = 1, b = :s)) == "{\"a\":1,\"b\":\"s\"}"
    @test encode(NaN) == "null"
end
