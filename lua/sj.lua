local config = {
	auto_jump = false, -- automatically jump if there is only one match
	use_overlay = true, -- apply an overlay to better identify labels and matches
	separator = ":", -- separator used to extract pattern and label from the user input

	-- stylua: ignore
	labels = {
		"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
		"n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
		"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
		"N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
		"0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ",", ";", "!",
	},
}

local highlights = {
	SjLabel = "Label",
	SjOverlay = "Comment",
	SjSearch = "IncSearch",
	SjWarning = "WarningMsg",
}

local sj_ns = vim.api.nvim_create_namespace("SJ")

--- Highlights ---------------------------------------------------------------------------------------------------------

local function init_highlights()
	for hl_group, hl_target in pairs(highlights) do
		vim.cmd(string.format("highlight link %s %s", hl_group, hl_target))
	end
end
pcall(init_highlights) -- user might have a reload mechanism and highlights might already be linked

local function update_highlights(user_highlights)
	local old_hl_conf, new_hl_conf

	for hl_group in pairs(highlights) do
		old_hl_conf = vim.api.nvim_get_hl_by_name(hl_group, true)
		new_hl_conf = vim.tbl_extend("force", {}, old_hl_conf, user_highlights[hl_group] or {})
		vim.api.nvim_set_hl(0, hl_group, new_hl_conf)
	end
end

local function clear_highlights()
	vim.api.nvim_buf_clear_namespace(0, sj_ns, 0, -1)
end

--- Core ---------------------------------------------------------------------------------------------------------------

local function create_labels_map(matches)
	local label, lnum, start_idx, end_idx
	local labels_map = {}

	for match_num, match_pos in ipairs(matches) do
		label = config.labels[match_num]
		if label then
			lnum, start_idx, end_idx = unpack(match_pos)
			labels_map[label] = { lnum, start_idx, end_idx }
		end
	end

	return labels_map
end

local function extract_pattern_and_label(user_input)
	local separator_pos = string.find(string.reverse(user_input), config.separator, 1, true)
	if not separator_pos then
		return { user_input, "" }
	else
		separator_pos = #user_input - separator_pos
		return { string.sub(user_input, 1, separator_pos), string.sub(user_input, separator_pos + 2) }
	end
end

--- Feedbacks -----------------------------------------

local function apply_overlay(redraw)
	if config.use_overlay ~= true then
		return
	end

	for lnum = 0, vim.fn.line("$") - 1 do
		vim.api.nvim_buf_add_highlight(0, sj_ns, "SjOverlay", lnum, 0, -1)
	end

	if redraw ~= false then
		vim.cmd.redraw()
	end
end

local function highlight_matches(labels_map)
	local lnum, start_idx, end_idx

	clear_highlights()
	apply_overlay(false) -- redrawing here will cause flickering

	for label, match_pos in pairs(labels_map) do
		lnum, start_idx, end_idx = unpack(match_pos)

		vim.api.nvim_buf_add_highlight(0, sj_ns, "SjSearch", lnum, start_idx - 1, end_idx)

		vim.api.nvim_buf_set_extmark(0, sj_ns, lnum, math.max(start_idx - 1 - string.len(label), 0), {
			virt_text = { { label, "SjLabel" } },
			virt_text_pos = "overlay",
		})
	end

	vim.cmd.redraw()
end

local function echo_pattern(pattern, matches)
	vim.api.nvim_echo({ { pattern, #matches > 0 and "" or "SjWarning" } }, false, {})
end

local function clear_everything()
	clear_highlights()
	echo_pattern("", {})
end

--- Search --------------------------------------------

local function gfind(text, pattern)
	local init = 1
	local start_idx, end_idx
	local ranges = {}

	if vim.opt.smartcase and not string.find(pattern, "%u") then
		text = string.lower(text)
	end

	start_idx, end_idx = string.find(text, pattern, init, true)
	while start_idx do
		table.insert(ranges, { start_idx, end_idx })
		start_idx, end_idx = string.find(text, pattern, init + end_idx, true)
	end

	return ranges
end

local function find_matches(pattern, first_line, last_line)
	if type(pattern) ~= "string" or #pattern < 1 then
		return {}
	end

	local lines = vim.api.nvim_buf_get_lines(0, first_line - 1, last_line, false)
	local matches = {}

	if vim.opt.smartcase and not string.find(pattern, "%u") then
		pattern = string.lower(pattern)
	end

	for i, line in ipairs(lines) do
		for _, match_range in ipairs(gfind(line, pattern)) do
			table.insert(matches, { first_line + i - 2, unpack(match_range) })
		end
	end

	return matches
end

local function search_pattern()
	local first_line, last_line = vim.fn.line("w0"), vim.fn.line("w$")
	local pattern, matches
	local labels_map = {}

	-- Don't wait for the user input to apply overlay
	apply_overlay()

	while true do
		pattern = coroutine.yield()
		if pattern == nil then
			break
		end

		matches = find_matches(pattern, first_line, last_line)
		if config.auto_jump and #matches == 1 then
			labels_map = { [config.labels[1]] = matches[1] }
			break
		end

		labels_map = create_labels_map(matches)
		highlight_matches(labels_map)
		echo_pattern(pattern, matches)
	end

	clear_everything()
	return labels_map
end

--- Input ---------------------------------------------

local function get_user_input(coro)
	local keynum, ok, char
	local user_input = ""
	local pattern, label
	local labels_map

	coroutine.resume(coro)

	while true do
		keynum = vim.fn.getchar()
		ok, char = pcall(string.char, keynum)

		if ok then
			if char == "\r" or char == "" then
				break
			end

			if char == "" and #user_input > 0 then
				user_input = string.sub(user_input, 1, #user_input - 1)
			elseif char == "" then
				user_input = ""
			else
				user_input = user_input .. char
			end

			pattern, label = unpack(extract_pattern_and_label(user_input))
			if #label > 0 then
				break
			end

			_, labels_map = coroutine.resume(coro, pattern)
			if labels_map then -- #autojump
				break
			end
		end
	end
	clear_everything()

	if char == "" then
		return
	end

	if labels_map then -- #autojump
		return user_input, labels_map
	else
		_, labels_map = coroutine.resume(coro)
		return user_input, labels_map
	end
end

--- Jump ----------------------------------------------

local function jump_to_match(user_input, labels_map)
	if type(user_input) ~= "string" or type(labels_map) ~= "table" then
		return
	end

	local _, label = unpack(extract_pattern_and_label(user_input))

	if #user_input and label == "" then
		label = config.labels[1]
	end

	local match_range = labels_map[label]
	if not match_range then
		return
	end

	local lnum, col = unpack(match_range)
	vim.api.nvim_win_set_cursor(0, { lnum + 1, col - 1 })
end

--- Exported -----------------------------------------------------------------------------------------------------------

local M = {}

function M.run()
	local coro = coroutine.create(search_pattern)
	local user_input, labels_map = get_user_input(coro)
	jump_to_match(user_input, labels_map)
end

function M.setup(user_config)
	config = vim.tbl_deep_extend("force", {}, config, user_config)
	if config.highlights then
		update_highlights(config.highlights)
	end
end

return M
