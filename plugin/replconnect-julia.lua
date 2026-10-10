-- Register Julia with the replconnect.nvim core (a separate plugin).
local ok, languages = pcall(require, "replconnect.languages")
if not ok then
	vim.notify("replconnect-julia: replconnect.nvim is not installed or not on the runtimepath", vim.log.levels.ERROR)
	return
end
languages.register(require("replconnect.julia"))
