-- Run from this plugin's root: nvim --headless -u NONE -l tests/launch.lua
-- Needs replconnect.nvim: set REPLCONNECT_CORE to its checkout (default: a sibling REPLConnect.nvim).
local core = vim.env.REPLCONNECT_CORE or vim.fs.joinpath(vim.fs.dirname(vim.fn.getcwd()), "REPLConnect.nvim")
assert(vim.uv.fs_stat(core), "replconnect.nvim not found at " .. core .. "; set REPLCONNECT_CORE")
vim.opt.runtimepath:prepend(core)
vim.opt.runtimepath:prepend(vim.fn.getcwd())
-- Load this plugin as Neovim would.
vim.cmd.runtime({ args = { "plugin/*.lua" }, bang = true })
local config = require("replconnect.config")
local repl = require("replconnect.repl")
local languages = require("replconnect.languages")

local function eq(a, b) assert(vim.deep_equal(a, b), vim.inspect(a) .. " ~= " .. vim.inspect(b)) end

local julia = require("replconnect.julia")

-- the plugin registers itself with the core, and is found by filetype
assert(languages.get("julia") == julia)
assert(languages.for_filetype("julia") == julia)
eq(julia.command, { "julia" })
eq(julia.prompt, "julia> ")
config.set()
eq(config.repl_options(julia).command, { "julia" })

-- the plugin root contains the Julia source
local root = julia.root()
assert(vim.uv.fs_stat(vim.fs.joinpath(root, "julia", "REPLConnect", "src", "REPLConnect.jl")), root)

-- Julia string literals escape the characters that would end or interpolate them
eq(julia.julia_string("a/b"), '"a/b"')
eq(julia.julia_string('a"b\\c$d'), '"a\\"b\\\\c\\$d"')

-- startup code: a REPL hook, run after startup.jl hooks, that only includes
-- when not loaded, then starts
local code = julia.startup_code("/x/y")
assert(code:find("push!(Base.repl_hooks, hook)", 1, true))
assert(code:find('Base.find_package("REPLConnect") === nothing', 1, true))
assert(code:find("Core.eval(Main, :(using REPLConnect))", 1, true))
assert(code:find("!isdefined(Main, :REPLConnect)", 1, true))
assert(code:find('include("/x/y/julia/REPLConnect/src/REPLConnect.jl")', 1, true))
assert(code:find("Base.invokelatest(() -> Main.REPLConnect.start())", 1, true))
assert(not code:find("\n"), "must be a single line for -e")
eq(julia.startup_code(nil), julia.startup_code(root)) -- defaults to this plugin

-- command line: executable, switches, then the startup code; no extra environment
local cmd = repl.build_cmd(julia, { command = { "julia", "+1.12" } }, { "--project=." })
eq(cmd[1], "julia")
eq(cmd[2], "+1.12")
eq(cmd[3], "--project=.")
eq(cmd[4], "-i")
eq(cmd[5], "-e")
eq(cmd[6], julia.startup_code(root))
eq(#cmd, 6)
eq(select(2, repl.build_cmd(julia, { command = { "julia" } })), nil)
eq(#repl.build_cmd(julia, { command = { "julia" } }), 4)

-- Plot capture options are forwarded to Julia, not just stored in Lua.
config.set({ repl = { capture_plots = true, plot_limit = 12 } })
local plot_cmd = repl.build_cmd(julia, config.repl_options(julia))
assert(plot_cmd[#plot_cmd]:find("(Main.REPLConnect.start(); Main.REPLConnect.capture_plots!(true; limit = 12))", 1, true))
assert(julia.startup_code("/x/y", { capture_plots = true }):find("limit = 50", 1, true))
eq(julia.startup_code("/x/y", { capture_plots = false, plot_limit = 12 }), code)
for _, limit in ipairs({ 0, -1, 1.5, math.huge, "50); error()" }) do
	local ok, err = pcall(julia.startup_code, "/x/y", { capture_plots = true, plot_limit = limit })
	assert(not ok and tostring(err):find("repl.plot_limit", 1, true))
end
assert(not pcall(julia.startup_code, "/x/y", { capture_plots = "true" }))
eq(julia.plot_capture, true)
eq(repl.launch_options(julia).capture_plots, true)
config.set()

-- a missing executable is reported against repl.julia.command
local notified
local original = vim.notify
vim.notify = function(msg, level) notified = { msg = msg, level = level } end
config.set({ repl = { julia = { command = { "definitely-not-a-julia-binary" } } } })
assert(repl.start("julia") == nil)
assert(notified and notified.level == vim.log.levels.ERROR and notified.msg:find("repl.julia.command", 1, true))
vim.notify = original
config.set()

-- setup() (lazy.nvim `opts`) sets this plugin's launch options and keeps it registered
julia.setup({ command = { "julia", "--project=." }, capture_plots = true })
assert(languages.get("julia") == julia)
config.set({ repl = { split = "horizontal" } })
eq(config.repl_options(julia).command, { "julia", "--project=." })
eq(config.repl_options(julia).split, "horizontal")
eq(repl.launch_options(julia).capture_plots, true)
julia.setup()
eq(config.repl_options(julia).command, { "julia" })
config.set()

print("replconnect-julia launch tests passed")
