---@alias SplitModifier "aboveleft"|"belowright"|"topleft"|"botright"|""
---@alias SMods { vertical: boolean?, silent: boolean?, split: SplitModifier? }
---@alias CommandParam { args: string?, smods: SMods? }
---@alias Config { no_baleia_support: boolean?, default_command: string?, time_format: string?, baleia_opts: table?, buffer_name: string? }
---@alias IntByInt { [1]: integer, [2]: integer }

local a = require("plenary.async")
local errors = require("compile-mode.errors")
---@diagnostic disable-next-line: undefined-field
local buf_set_opt = vim.api.nvim_buf_set_option

local M = {}

---@type string|nil
M.prev_dir = nil
---@type Config
M.config = {}

---@param bufnr integer
---@param start integer
---@param end_ integer
---@param flag boolean
---@param lines string[]
local function set_lines(bufnr, start, end_, flag, lines)
	vim.api.nvim_buf_set_lines(bufnr, start, end_, flag, lines)

	errors.highlight(bufnr)
end

---@type fun(opts: table): string
local input = a.wrap(vim.ui.input, 2)

---@type fun()
local wait = a.wrap(vim.schedule, 1)

---@type fun(cmd: string, bufnr: integer): integer, integer
local runjob = a.wrap(function(cmd, bufnr, callback)
	local count = 0

	local function on_either(_, data)
		if data and (#data > 1 or data[1] ~= "") then
			count = count + #data

			local linecount = vim.api.nvim_buf_line_count(bufnr)
			for i, line in ipairs(data) do
				local error = errors.parse(line)
				if error then
					errors.error_list[linecount + i - 1] = error
				elseif not M.config.no_baleia_support then
					local normal = "\x1b[0m"
					local blue = "\x1b[34m"

					data[i] = vim.fn.substitute(line, "^\\([^: \\t]\\+\\):", blue .. "\\1" .. normal .. ":", "") --[[@as string]]
				end
			end

			set_lines(bufnr, -2, -1, false, data)
		end
	end

	vim.fn.jobstart(cmd, {
		cwd = M.prev_dir,
		on_stdout = on_either,
		on_stderr = on_either,
		on_exit = function(_, code)
			callback(count, code)
		end,
	})
end, 3)

---If `fname` has a window open, do nothing.
---Otherwise, split a new window (and possibly buffer) open for that file, respecting `config.split_vertically`.
---
---@param fname string
---@param smods SMods
---@return integer bufnr the identifier of the buffer for `fname`
local function split_unless_open(fname, smods)
	local bufnum = vim.fn.bufnr(vim.fn.expand(fname) --[[@as any]]) --[[@as integer]]
	local winnum = vim.fn.bufwinnr(bufnum)

	if winnum == -1 then
		local cmd = fname
		if smods.vertical then
			cmd = "vsplit " .. cmd
		else
			cmd = "split " .. cmd
		end

		if smods.split and smods.split ~= "" then
			cmd = smods.split .. " " .. cmd
		end

		vim.cmd(cmd)
	end

	return vim.fn.bufnr(vim.fn.expand(fname) --[[@as any]]) --[[@as integer]]
end

---Get the current time, formatted.
local function time()
	local format = "%a %b %e %H:%M:%S"
	if M.config.time_format then
		format = M.config.time_format
	end

	return vim.fn.strftime(format)
end

---Get the default directory, formatted.
local function default_dir()
	local cwd = vim.fn.getcwd() --[[@as string]]
	return cwd:gsub("^" .. vim.env.HOME, "~")
end

---@param filename string
---@param error Error
local function goto_file(filename, error)
	local row = error.row and error.row.value or 1
	local end_row = error.end_row and error.end_row.value

	local col = (error.col and error.col.value or 1) - 1
	if col < 0 then
		col = 0
	end
	local end_col = error.end_col and error.end_col.value - 1
	if end_col and end_col < 0 then
		end_col = 0
	end

	vim.cmd.e(filename)
	vim.api.nvim_win_set_cursor(0, { row, col })

	if end_row or end_col then
		local cmd = ""
		if not error.col then
			cmd = cmd .. "V"
		else
			cmd = cmd .. "v"
		end

		if end_row then
			cmd = cmd .. tostring(end_row - row) .. "j"
		end

		if end_col then
			cmd = cmd .. tostring(end_col - col) .. "l"
		end

		-- TODO: maybe use select mode by doing:
		-- cmd = cmd .. "gh"

		vim.cmd.normal(cmd)
	end
end

---@type fun(error: Error)
local goto_error = a.void(
	---@param error Error
	function(error)
		local file_exists = vim.fn.filereadable(error.filename.value) ~= 0

		if file_exists then
			goto_file(error.filename.value, error)
		else
			local dir = input({
				prompt = "Find this error in: ",
				completion = "file",
			})
			if not dir then
				return
			end
			dir = dir:gsub("/$", "")

			wait()

			if not vim.fn.isdirectory(dir) then
				vim.notify(dir .. " is not a directory", vim.log.levels.ERROR)
				return
			end

			local nested_filename = dir .. "/" .. error.filename.value
			if vim.fn.filereadable(nested_filename) == 0 then
				vim.notify(error.filename.value .. " does not exist in " .. dir, vim.log.levels.ERROR)
				return
			end

			goto_file(nested_filename, error)
		end
	end
)

---Go to the error on the current line
---@type fun()
local error_on_line = a.void(function()
	local linenum = unpack(vim.api.nvim_win_get_cursor(0))
	local error = errors.error_list[linenum]

	if not error then
		vim.notify("No error here")
		return
	end

	goto_error(error)
end)

---Run `command` and place the results in the "Compilation" buffer.
---
---@type fun(command: string, smods: SMods)
local runcommand = a.void(function(command, smods)
	local bufnr = split_unless_open(M.config.buffer_name or "Compilation", smods)
	buf_set_opt(bufnr, "modifiable", true)
	buf_set_opt(bufnr, "filetype", "compile")
	vim.keymap.set("n", "q", "<CMD>q<CR>", { silent = true, buffer = bufnr })
	vim.keymap.set("n", "<CR>", error_on_line, { silent = true, buffer = bufnr })

	vim.api.nvim_create_autocmd("ExitPre", {
		group = vim.api.nvim_create_augroup("compile-mode", { clear = true }),
		callback = function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				vim.api.nvim_buf_delete(bufnr, { force = true })
			end
		end,
	})

	if not M.config.no_baleia_support then
		require("baleia").setup(M.config.baleia_opts or {}).automatically(bufnr)
	end

	-- reset compilation buffer
	set_lines(bufnr, 0, -1, false, {})

	set_lines(bufnr, 0, 0, false, {
		'-*- mode: compilation; default-directory: "' .. default_dir() .. '" -*-',
		"Compilation started at " .. time(),
		"",
		-- TODO: parse error for command itself
		command,
	})

	local count, code = runjob(command, bufnr)
	if count == 0 then
		set_lines(bufnr, -1, -1, false, { "" })
	end

	local simple_message
	local finish_message
	if code == 0 then
		simple_message = "Compilation finished"
		finish_message = "Compilation \x1b[32mfinished\x1b[0m"
	else
		simple_message = "Compilation exited abnormally with code " .. tostring(code)
		finish_message = "Compilation \x1b[31mexited abnormally\x1b[0m with code \x1b[31m"
			.. tostring(code)
			.. "\x1b[0m"
	end

	local compliation_message = M.config.no_baleia_support and simple_message or finish_message
	set_lines(bufnr, -1, -1, false, {
		compliation_message .. " at " .. time(),
		"",
	})

	if not smods.silent then
		vim.notify(simple_message)
	end

	vim.schedule(function()
		buf_set_opt(bufnr, "modifiable", false)
		buf_set_opt(bufnr, "modified", false)
	end)
end)

---Prompt for (or get by parameter) a command and run it.
---
---@param param CommandParam
M.compile = a.void(function(param)
	param = param or {}

	local command = param.args ~= "" and param.args
		or input({
			prompt = "Compile command: ",
			default = vim.g.compile_command or M.config.default_command or "make -k ",
			completion = "shellcmd",
		})

	if command == nil then
		return
	end

	vim.g.compile_command = command
	M.prev_dir = vim.fn.getcwd()

	runcommand(command, param.smods or {})
end)

---Rerun the last command.
---@param param CommandParam
M.recompile = a.void(function(param)
	if vim.g.compile_command then
		runcommand(vim.g.compile_command, param.smods or {})
	else
		vim.notify("Cannot recompile without previous command; compile first", vim.log.levels.ERROR)
	end
end)

---Configure `compile-mode.nvim`.
---
---@param config Config
function M.setup(config)
	M.config = config

	vim.cmd("highlight default CompileModeError gui=underline")
	vim.cmd("highlight default CompileModeErrorRow guifg=green gui=underline")
	vim.cmd("highlight default CompileModeErrorCol guifg=gray gui=underline")

	vim.cmd("highlight default CompileModeErrorFilename guifg=red gui=bold,underline")
	vim.cmd("highlight default CompileModeWarningFilename guifg=yellow gui=underline")
	vim.cmd("highlight default CompileModeInfoFilename guifg=cyan gui=underline")
end

return M
