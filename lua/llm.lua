local nio = require("nio")
local M = {}
local vim = vim or {}

local timeout_ms = 10000

local service_lookup = {
	groq = {
		url = "https://api.groq.com/openai/v1/chat/completions",
		model = "llama3-70b-8192",
		api_key_name = "GROQ_API_KEY",
	},
	openai = {
		url = "https://api.openai.com/v1/chat/completions",
		model = "gpt-4o",
		api_key_name = "OPENAI_API_KEY",
	},
	anthropic = {
		url = "https://api.anthropic.com/v1/messages",
		model = "claude-3-5-sonnet-20240620",
		api_key_name = "ANTHROPIC_API_KEY",
	},
}

local system_prompt = [[
You are an AI programming assistant integrated into a code editor. Your purpose is to help the user with programming tasks as they write code.
Key capabilities:
- Thoroughly analyze the user's code and provide insightful suggestions for improvements related to best practices, performance, readability, and maintainability. Explain your reasoning.
- Answer coding questions in detail, using examples from the user's own code when relevant. Break down complex topics step- Spot potential bugs and logical errors. Alert the user and suggest fixes.
- Upon request, add helpful comments explaining complex or unclear code.
- Suggest relevant documentation, StackOverflow answers, and other resources related to the user's code and questions.
- Engage in back-and-forth conversations to understand the user's intent and provide the most helpful information.
- Keep concise and use markdown.
- When asked to create code, only generate the code. No bugs.
- Think step by step
]]

local system_prompt_replace =
	"Follow the instructions in the code comments. Generate code only. Think step by step. If you must speak, do so in comments. Generate valid code only."

local print_prompt = false

local function get_api_key(name)
	return os.getenv(name)
end

function M.setup(opts)
	timeout_ms = opts.timeout_ms or timeout_ms
	if opts.services then
		for key, service in pairs(opts.services) do
			service_lookup[key] = service
		end
	end
	if opts.system_prompt then
		system_prompt = opts.system_prompt
	end
	if opts.system_prompt_replace then
		system_prompt_replace = opts.system_prompt_replace
	end

	if opts.print_prompt then
		print_prompt = opts.print_prompt
	end
end

local function get_lines(opts)
	local current_buffer = vim.api.nvim_get_current_buf()
	local current_window = vim.api.nvim_get_current_win()
	local cursor_position = vim.api.nvim_win_get_cursor(current_window)
	local row
	if opts.all then
		row = -1
	else
		row = cursor_position[1]
	end

	local lines = vim.api.nvim_buf_get_lines(current_buffer, 0, row, true)

	return table.concat(lines, "\n")
end

local function write_string_at_cursor(str)
	local current_window = vim.api.nvim_get_current_win()
	local cursor_position = vim.api.nvim_win_get_cursor(current_window)
	local row, col = cursor_position[1], cursor_position[2]

	local lines = vim.split(str, "\n")
	vim.api.nvim_put(lines, "c", true, true)

	local num_lines = #lines
	local last_line_length = #lines[num_lines]
	vim.api.nvim_win_set_cursor(current_window, { row + num_lines - 1, col + last_line_length })
end

local function process_data_lines(lines, service, process_data)
	for _, line in ipairs(lines) do
		local data_start = line:find("data: ")
		if data_start then
			local json_str = line:sub(data_start + 6)
			local stop = false
			if line == "data: [DONE]" then
				return true
			end
			local data = vim.json.decode(json_str)
			if service == "anthropic" then
				stop = data.type == "message_stop"
			end
			if stop then
				return true
			else
				nio.sleep(5)
				vim.schedule(function()
					vim.cmd("undojoin")
					process_data(data)
				end)
			end
		end
	end
	return false
end

local function process_sse_response(response, service)
	local buffer = ""
	local has_tokens = false
	local start_time = vim.uv.hrtime()

	nio.run(function()
		nio.sleep(timeout_ms)
		if not has_tokens then
			response.stdout.close()
			print("llm.nvim has timed out!")
		end
	end)
	local done = false
	while not done do
		local current_time = vim.uv.hrtime()
		local elapsed = (current_time - start_time)
		if elapsed >= timeout_ms * 1000000 and not has_tokens then
			return
		end
		local chunk = response.stdout.read(1024)
		if chunk == nil then
			break
		end
		buffer = buffer .. chunk

		local lines = {}
		for line in buffer:gmatch("(.-)\r?\n") do
			table.insert(lines, line)
		end

		buffer = buffer:sub(#table.concat(lines, "\n") + 1)

		done = process_data_lines(lines, service, function(data)
			local content
			if service == "anthropic" then
				if data.delta and data.delta.text then
					content = data.delta.text
				end
			else
				if data.choices and data.choices[1] and data.choices[1].delta then
					content = data.choices[1].delta.content
				end
			end
			if content and content ~= vim.NIL then
				has_tokens = true
				write_string_at_cursor(content)
			end
		end)
	end
end

function M.prompt(opts)
	local replace = opts.replace
	local service = opts.service
	local all_text = get_lines({ all = true })
	local prompt = ""
	local visual_lines = M.get_selection()
	if visual_lines then
		prompt = table.concat(visual_lines, "\n")
		if replace then
			local selection = prompt
			prompt = all_text .. "\n============ code to replace ============\n" .. selection
			vim.api.nvim_command("normal! d")
			vim.api.nvim_command("normal! k")
		else
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", false, true, true), "nx", false)
		end
	else
		prompt = get_lines({ all = false })
	end

	if print_prompt then
		print(prompt)
	end

	local url = ""
	local model = ""
	local api_key_name = ""

	local found_service = service_lookup[service]
	if found_service then
		url = found_service.url
		api_key_name = found_service.api_key_name
		model = found_service.model
	else
		print("Invalid service: " .. service)
		return
	end

	local api_key = api_key_name and get_api_key(api_key_name)

	local data
	if service == "anthropic" then
		data = {
			system = replace and system_prompt_replace or system_prompt,
			messages = {
				{
					role = "user",
					content = prompt,
				},
			},
			model = model,
			stream = true,
			max_tokens = 1024,
		}
	else
		data = {
			messages = {
				{
					role = "system",
					content = replace and system_prompt_replace or system_prompt,
				},
				{
					role = "user",
					content = prompt,
				},
			},
			model = model,
			temperature = 0.7,
			stream = true,
		}
	end

	local args = {
		"-N",
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-d",
		vim.json.encode(data),
	}

	if api_key then
		if service == "anthropic" then
			table.insert(args, "-H")
			table.insert(args, "x-api-key: " .. api_key)
			table.insert(args, "-H")
			table.insert(args, "anthropic-version: 2023-06-01")
		else
			table.insert(args, "-H")
			table.insert(args, "Authorization: Bearer " .. api_key)
		end
	end

	table.insert(args, url)

	local response = nio.process.run({
		cmd = "curl",
		args = args,
	})
	nio.run(function()
		nio.api.nvim_command("normal! o")
		process_sse_response(response, service)
	end)
end

function M.get_selection()
	local is_motion = _G.op_func_llm_prompt ~= nil
	local start_mark, end_mark
	if is_motion then
		start_mark = "'["
		end_mark = "']"
	else
		start_mark = "v"
		end_mark = "."
	end
	local _, srow, scol = unpack(vim.fn.getpos(start_mark))
	local _, erow, ecol = unpack(vim.fn.getpos(end_mark))

	-- visual line mode
	if vim.fn.mode() == "V" or is_motion then
		if srow > erow then
			return vim.api.nvim_buf_get_lines(0, erow - 1, srow, true)
		else
			return vim.api.nvim_buf_get_lines(0, srow - 1, erow, true)
		end
	end

	-- regular visual mode
	if vim.fn.mode() == "v" then
		if srow < erow or (srow == erow and scol <= ecol) then
			return vim.api.nvim_buf_get_text(0, srow - 1, scol - 1, erow - 1, ecol, {})
		else
			return vim.api.nvim_buf_get_text(0, erow - 1, ecol - 1, srow - 1, scol, {})
		end
	end

	-- visual block mode
	if vim.fn.mode() == "\22" then
		local lines = {}
		if srow > erow then
			srow, erow = erow, srow
		end
		if scol > ecol then
			scol, ecol = ecol, scol
		end
		for i = srow, erow do
			table.insert(
				lines,
				vim.api.nvim_buf_get_text(0, i - 1, math.min(scol - 1, ecol), i - 1, math.max(scol - 1, ecol), {})[1]
			)
		end
		return lines
	end
end

function M.create_llm_md()
	local cwd = vim.fn.getcwd()
	local cur_buf = vim.api.nvim_get_current_buf()
	local cur_buf_name = vim.api.nvim_buf_get_name(cur_buf)
	local llm_md_path = cwd .. "/llm.md"
	if cur_buf_name ~= llm_md_path then
		vim.api.nvim_command("edit " .. llm_md_path)
		local buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
		vim.api.nvim_win_set_buf(0, buf)
	end
end

-- For running prompt on a range of text via vim motions.
function M.prompt_operatorfunc(opts)
	local old_func = vim.go.operatorfunc -- backup previous reference
	-- set a globally callable object/function
	_G.op_func_llm_prompt = function()
		require("llm").prompt(opts)
		vim.go.operatorfunc = old_func -- restore previous opfunc
		_G.op_func_llm_prompt = nil -- deletes itself from global namespace
	end
	vim.go.operatorfunc = "v:lua.op_func_llm_prompt"
	vim.api.nvim_feedkeys("g@", "n", false)
end

return M
