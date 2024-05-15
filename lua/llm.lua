local nio = require("nio")
local M = {}

local groq_url = "https://api.groq.com/openai/v1/chat/completions"
local openai_url = "https://api.openai.com/v1/chat/completions"
local timeout_ms = 10000

local function get_api_key(name)
	return os.getenv(name)
end

function M.get_lines_until_cursor()
	local current_buffer = vim.api.nvim_get_current_buf()
	local current_window = vim.api.nvim_get_current_win()
	local cursor_position = vim.api.nvim_win_get_cursor(current_window)
	local row = cursor_position[1]

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

local function process_sse_response(response)
	local buffer = ""
	local has_tokens = false
	local start_time = vim.uv.hrtime()

	nio.run(function()
		nio.sleep(timeout_ms)
		response.stdout.close()
		if not has_tokens then
			print("llm.nvim has timed out!")
		end
	end)
	while true do
		local current_time = vim.uv.hrtime()
		local elapsed = (current_time - start_time)
		if elapsed >= timeout_ms * 1000000 then
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

		for _, line in ipairs(lines) do
			if line == "data: [DONE]" then
				return
			else
				local data_start = line:find("data: ")
				if data_start then
					local json_str = line:sub(data_start + 6)
					nio.sleep(5)
					vim.schedule(function()
						vim.cmd("undojoin")
						local data = vim.fn.json_decode(json_str)
						local content = data.choices[1].delta.content
						if data.choices and content then
							has_tokens = true
							write_string_at_cursor(content)
						end
					end)
				end
			end
		end
	end
end

function M.prompt(opts)
	local replace = opts.replace
	local service = opts.service
	local prompt = ""
	local visual_lines = M.get_visual_selection()
	local system_prompt = [[
You are an AI programming assistant integrated into a code editor. Your purpose is to help the user with programming tasks as they write code.
Key capabilities:
- Thoroughly analyze the user's code and provide insightful suggestions for improvements related to best practices, performance, readability, and maintainability. Explain your reasoning.
- Answer coding questions in detail, using examples from the user's own code when relevant. Break down complex topics step-by-step.
- Spot potential bugs and logical errors. Alert the user and suggest fixes.
- Upon request, add helpful comments explaining complex or unclear code.
- Suggest relevant documentation, StackOverflow answers, and other resources related to the user's code and questions.
- Engage in back-and-forth conversations to understand the user's intent and provide the most helpful information.
- Keep concise and use markdown.
- When asked to create code, only generate the code. No bugs.
    ]]
	if visual_lines then
		prompt = table.concat(visual_lines, "\n")
		if replace then
			system_prompt =
				"Follow the instructions in the code comments. Generate code only. If you must speak, do so in comments. Generate valid code only."
			vim.api.nvim_command("normal! d")
			vim.api.nvim_command("normal! k")
		else
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", false, true, true), "nx", false)
		end
	else
		prompt = M.get_lines_until_cursor()
	end

	local url = ""
	local model = ""
	local api_key_name = ""
	if service == "groq" then
		url = groq_url
		api_key_name = "GROQ_API_KEY"
		model = "llama3-70b-8192"
	else
		url = openai_url
		api_key_name = "OPENAI_API_KEY"
		model = "gpt-4o"
	end

	local api_key = get_api_key(api_key_name)

	local data = {
		messages = {
			{
				role = "system",
				content = system_prompt,
			},
			{
				role = "user",
				content = prompt,
			},
		},
		model = model,
		temperature = 0.7,
		stream = true,
		max_tokens = 1024,
	}

	local response = nio.process.run({
		cmd = "curl",
		args = {
			"-N",
			"-X",
			"POST",
			"-H",
			"Content-Type: application/json",
			"-H",
			"Authorization: Bearer " .. api_key,
			"-d",
			vim.fn.json_encode(data),
			url,
		},
	})
	nio.run(function()
		nio.api.nvim_command("normal! o")
		process_sse_response(response)
	end)
end

function M.get_visual_selection()
	local _, srow, scol = unpack(vim.fn.getpos("v"))
	local _, erow, ecol = unpack(vim.fn.getpos("."))

	-- visual line mode
	if vim.fn.mode() == "V" then
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

return M
