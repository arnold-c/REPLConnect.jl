tests: nvim_tests julia_tests

nvim_tests:
        nvim --headless -u NONE -l tests/launch.lua

julia_tests:
	juliati julia/

julia_format:
	fatou format julia/
