-- Julia: how to launch a REPL running REPLConnect, and editor details.
-- Part of replconnect-julia; registered by `plugin/replconnect-julia.lua`.

local M = {
	name = "julia",
	label = "Julia",
	filetypes = { "julia" },
	---Prompt shown before inputs in session previews.
	prompt = "julia> ",
	---Characters that trigger runtime completion.
	trigger_characters = { ".", "[", '"', ":" },
	---Default launch command (override with `setup({ command = ... })`).
	command = { "julia" },
	plot_capture = true,
	plots_hint = "run REPLConnect.capture_plots!(true) in the REPL",
	stop_hint = "run REPLConnect.stop() in the REPL",
	startup_hint = "check Julia startup errors and the loaded REPLConnect version",
}

---Root of this plugin checkout (contains `julia/`).
---@return string
function M.root()
	local source = debug.getinfo(1, "S").source:sub(2)
	return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

---A Julia string literal for `s` (escapes `\`, `"` and `$`).
---@param s string
---@return string
function M.julia_string(s)
	return '"' .. s:gsub('[\\"$]', "\\%0") .. '"'
end

---Julia code run in the new REPL. It registers a hook that runs after any
---`startup.jl` hooks: if REPLConnect is already loaded (for example by
---`startup.jl`) it is only started, which is idempotent; otherwise an installed
---REPLConnect package is loaded (precompiled, and compatible with a later
---`using REPLConnect`), falling back to including this plugin checkout's source.
---`invokelatest` because the module is newer than the hook's world (Julia 1.12+).
---`atreplinit` prepends, so hooks registered by `-e` would run *before*
---`startup.jl` hooks, which could then re-include REPLConnect and replace the
---plot-enabled module. Appending to `Base.repl_hooks` makes this hook run last.
---@param root string plugin checkout (contains `julia/`)
---@param opts? replconnect.ReplConfig
---@return string
function M.startup_code(root, opts)
	root = root or M.root()
	local capture, limit = require("replconnect.languages").plot_options(opts or {})
	-- start() only serves; behaviour is set separately (and never undone by it).
	local start = capture
			and ("(Main.REPLConnect.start(); Main.REPLConnect.capture_plots!(true; limit = "
				.. string.format("%.0f", limit) .. "))")
		or "Main.REPLConnect.start()"
	local source = vim.fs.joinpath(root, "julia", "REPLConnect", "src", "REPLConnect.jl")
	return table.concat({
		"let hook = function (_)",
		"if !isdefined(Main, :REPLConnect) if Base.find_package(\"REPLConnect\") === nothing include("
			.. M.julia_string(source) .. ") else Core.eval(Main, :(using REPLConnect)) end end",
		"Base.invokelatest(() -> " .. start .. ")",
		"end",
		"isdefined(Base, :repl_hooks) ? push!(Base.repl_hooks, hook) : atreplinit(hook)",
		"end",
	}, "; ")
end

---The command line: `command`, extra switches, then the startup code run before the prompt.
---@param opts replconnect.ReplConfig
---@param extra? string[] extra Julia switches, e.g. `--project=.`
---@param root? string plugin checkout (default: this plugin)
---@return string[] cmd
---@return table<string, string>? env extra environment for the job
function M.build_cmd(opts, extra, root)
	local cmd = vim.list_extend({}, opts.command)
	vim.list_extend(cmd, extra or {})
	vim.list_extend(cmd, { "-i", "-e", M.startup_code(root or M.root(), opts) })
	return cmd, nil
end

---Plugin options (lazy.nvim `opts`): the core's `repl` fields for Julia only,
---e.g. `{ command = { ... }, capture_plots = true }`. Optional: the plugin
---registers itself when loaded.
---@param opts? replconnect.ReplConfig
function M.setup(opts)
	require("replconnect.languages").configure(M, opts)
end

return M
