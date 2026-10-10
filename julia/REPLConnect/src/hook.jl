# REPL session state: a cheap "something may have changed" counter and a busy flag.
#
# The only work done per evaluation is `mark_dirty!`, an atomic increment.
# Inspection happens on request, never as part of an evaluation.

const DIRTY = Threads.Atomic{Int}(0)

"""
Record that the session may have changed. O(1); called from the REPL's AST
transform before each evaluation and by mutating requests.
"""
function mark_dirty!()
    Threads.atomic_add!(DIRTY, 1)
    return nothing
end

"The session version: increments when an evaluation starts and on `delete`/`clear`."
version() = DIRTY[]

"Whether the REPL is evaluating user code right now (false if there is no REPL backend)."
busy() = (backend = Base.active_repl_backend; backend !== nothing && backend.in_eval)

"""
Wrap `ex` so that `record_input!` (which calls `mark_dirty!`) runs first,
even if `ex` throws; the value of `ex` is kept.
"""
mark_transform(ex) = Expr(
    :toplevel,
    Expr(:call, GlobalRef(@__MODULE__, :install_plot_display!)),
    Expr(:call, GlobalRef(@__MODULE__, :record_input!), QuoteNode(ex)),
    ex,
)

# Where `mark_transform` should be registered: the defaults used for new REPL
# backends, and the active backend if one is already running.
function transform_lists()
    lists = Vector{Any}[REPL.repl_ast_transforms]
    backend = Base.active_repl_backend
    backend === nothing || push!(lists, backend.ast_transforms)
    return lists
end

"Register the dirty-marking AST transform with the REPL. Idempotent."
function install_hook!()
    for list in transform_lists()
        mark_transform in list || push!(list, mark_transform)
    end
    return nothing
end

"Remove the AST transform again (used by tests)."
function uninstall_hook!()
    for list in transform_lists()
        filter!(!=(mark_transform), list)
    end
    return nothing
end

@testitem "mark_dirty! counts and the transform keeps the value" begin
    before = REPLConnect.version()
    REPLConnect.mark_dirty!()
    @test REPLConnect.version() == before + 1

    wrapped = REPLConnect.mark_transform(:(1 + 1))
    @test Core.eval(Main, wrapped) == 2
    @test REPLConnect.version() == before + 2

    throwing = REPLConnect.mark_transform(:(error("boom")))
    @test_throws ErrorException Core.eval(Main, throwing)
    @test REPLConnect.version() == before + 3
end

@testitem "install_hook! is idempotent and reversible" begin
    using REPL
    REPLConnect.uninstall_hook!()
    REPLConnect.install_hook!()
    REPLConnect.install_hook!()
    @test count(==(REPLConnect.mark_transform), REPL.repl_ast_transforms) == 1
    REPLConnect.uninstall_hook!()
    @test REPLConnect.mark_transform ∉ REPL.repl_ast_transforms
    @test REPLConnect.busy() == false
end
