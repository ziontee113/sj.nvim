local cache = require("sj.cache")
local ui = require("sj.ui")
local utils = require("sj.utils")

local keymaps = {
	cancel = vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
	validate = vim.api.nvim_replace_termcodes("<CR>", true, false, true),
	prev_match = vim.api.nvim_replace_termcodes("<A-,>", true, false, true),
	next_match = vim.api.nvim_replace_termcodes("<A-;>", true, false, true),
	prev_pattern = vim.api.nvim_replace_termcodes("<C-p>", true, false, true),
	next_pattern = vim.api.nvim_replace_termcodes("<C-n>", true, false, true),

	delete_prev_char = vim.api.nvim_replace_termcodes("<BS>", true, false, true),
	delete_prev_word = vim.api.nvim_replace_termcodes("<C-W>", true, false, true),
	delete_pattern = vim.api.nvim_replace_termcodes("<C-U>", true, false, true),
	restore_pattern = vim.api.nvim_replace_termcodes("<A-BS>", true, false, true),

	send_to_qflist = vim.api.nvim_replace_termcodes("<A-q>", true, false, true),
}

local patterns = {}
local patterns_slider = utils.slider()

------------------------------------------------------------------------------------------------------------------------

local function update_search_register(pattern, pattern_type)
	if type(pattern) ~= "string" or #pattern == 0 then
		return
	end

	if pattern_type == "vim_very_magic" then
		pattern = "\\v" .. pattern
	end

	vim.fn.setreg("/", pattern)
end

local function send_to_qflist(matches)
	if type(matches) ~= "table" then
		return
	end

	local lnum, start_idx, end_idx, line
	local qf_list = {}
	for match_num, match_range in ipairs(matches) do
		lnum, start_idx, end_idx = unpack(match_range)
		line = vim.fn.getline(lnum + 1)
		qf_list[match_num] = {
			text = line,
			bufnr = vim.api.nvim_get_current_buf(),
			lnum = lnum + 1,
			col = start_idx,
			end_col = end_idx,
		}
	end
	vim.fn.setqflist(qf_list)
end

local function update_search_history(current_patterns, new_pattern)
	if type(new_pattern) ~= "string" or #new_pattern == 0 then
		return current_patterns
	end

	local new_patterns = {}

	for _, pattern in pairs(current_patterns) do
		if pattern ~= new_pattern then
			table.insert(new_patterns, pattern)
		end
	end
	table.insert(new_patterns, new_pattern)

	return new_patterns
end

local function pattern_ranges(text, pattern, search)
	local iters, text_len = 0, #text
	local start_idx, end_idx, init
	local ranges = {}

	if text_len == 0 then
		return ranges
	end

	while iters <= text_len do
		iters = iters + 1

		start_idx, end_idx, init = search(text, pattern, init)
		if start_idx == nil then
			break
		end

		table.insert(ranges, { start_idx, end_idx })
	end

	return ranges
end

local function get_search_function(pattern_type)
	if type(pattern_type) ~= "string" then
		pattern_type = "vim"
	end

	local plain = pattern_type:find("plain$") and true or false
	local function lua_search(text, pattern, init)
		if vim.o.ignorecase == true and not (vim.o.smartcase == true and pattern:find("%u") ~= nil) then
			text = text:lower()
			pattern = pattern:lower()
		end
		local start_idx, end_idx = text:find(pattern, init, plain)
		if start_idx ~= nil then
			return start_idx, end_idx, start_idx and start_idx == end_idx and end_idx + 1 or end_idx
		end
	end

	local prefix = pattern_type == "vim_very_magic" and "\\v" or ""
	local function vim_search(text, pattern, init)
		local _, start_idx, end_idx = unpack(vim.fn.matchstrpos(text, prefix .. pattern, init))
		if start_idx ~= -1 then
			return start_idx + 1, end_idx, end_idx
		end
	end

	if pattern_type:find("^lua") then
		return lua_search
	else
		return vim_search
	end
end

local function extract_pattern_and_label(user_input, separator)
	if separator == "" then
		return user_input, ""
	elseif type(separator) ~= "string" then
		separator = ":"
	end
	local separator_pos = user_input:match("^.*()" .. vim.pesc(separator))

	if separator_pos then
		return user_input:sub(1, separator_pos - 1), user_input:sub(separator_pos + separator:len())
	else
		return user_input, ""
	end
end

------------------------------------------------------------------------------------------------------------------------

local M = {}

function M.manage_keymaps(new_keymaps)
	for action, _ in pairs(keymaps) do
		if type(new_keymaps[action]) == "string" and #new_keymaps[action] > 0 then
			keymaps[action] = vim.api.nvim_replace_termcodes(new_keymaps[action], true, false, true)
		end
	end
end

function M.jump_to(range)
	if type(range) ~= "table" then
		return
	end

	local lnum, col = unpack(range)
	if type(lnum) == "number" and type(col) == "number" then
		vim.api.nvim_win_set_cursor(0, { lnum + 1, col - 1 })
	end
end

function M.extract_range_and_jump_to(user_input, labels_map)
	if type(user_input) ~= "string" or type(labels_map) ~= "table" then
		return
	end

	local _, label = extract_pattern_and_label(user_input, cache.options.separator)

	if #user_input and label == "" then -- auto_jump
		label = cache.options.labels[1]
	end

	M.jump_to(labels_map[label])
end

function M.win_get_lines_range(win_id, scope)
	local cursor_line = vim.fn.line(".", win_id)
	local first_visible_line, last_visible_line = vim.fn.line("w0", win_id), vim.fn.line("w$", win_id)
	local first_buffer_line, last_buffer_line = 1, vim.fn.line("$", win_id)

	local cases = {
		current_line = { cursor_line, cursor_line },
		visible_lines_above = { first_visible_line, cursor_line - 1 },
		visible_lines_below = { cursor_line + 1, last_visible_line },
		visible_lines = { first_visible_line, last_visible_line },
		buffer = { first_buffer_line, last_buffer_line },
	}

	return unpack(cases[scope] or cases["visible_lines"])
end

function M.discard_labels(labels, matches)
	if type(matches) ~= "table" or #matches == 0 then
		return labels
	end

	local next_chars
	local discardable = {}

	for _, match_range in pairs(matches) do
		next_chars = match_range[#match_range]
		if #next_chars > 0 and not discardable[next_chars] then
			discardable[next_chars] = true
		end
	end

	if next(discardable) == nil then
		return labels
	end

	discardable = vim.tbl_keys(discardable)
	table.sort(discardable)
	local discardable_rx = "[" .. vim.pesc(table.concat(discardable)) .. "]"
	local filtered_labels = {}

	for _, label in ipairs(labels) do
		if vim.fn.match(label, "\\C" .. discardable_rx) == -1 then
			table.insert(filtered_labels, label)
		end
	end

	return filtered_labels
end

function M.create_labels_map(labels, matches, reverse)
	local label
	local labels_map = {}

	for match_num, _ in pairs(matches) do
		label = labels[match_num]
		if not label then
			break
		end

		if reverse == true then
			labels_map[label] = matches[#matches + 1 - match_num]
		else
			labels_map[label] = matches[match_num]
		end
	end

	return labels_map
end

function M.win_find_pattern(win_id, pattern, opts)
	if type(win_id) ~= "number" or not vim.api.nvim_win_is_valid(win_id) then
		return {}
	end

	if type(pattern) ~= "string" or #pattern == 0 then
		return {}
	end

	local default_opts = {
		cursor_pos = vim.api.nvim_win_get_cursor(win_id),
		forward = true,
		pattern_type = "vim",
		relative = false,
		scope = "visible_lines",
	}
	opts = vim.tbl_extend("force", default_opts, type(opts) == "table" and opts or {})

	local buf_nr = vim.api.nvim_win_get_buf(win_id)
	local first_line, last_line = M.win_get_lines_range(win_id, opts.scope)
	local lines = vim.api.nvim_buf_get_lines(buf_nr, first_line - 1, last_line, false)

	if vim.o.smartcase and opts.pattern_type:find("vim") and pattern:find("%u") then
		pattern = "\\C" .. pattern
	end
	local search = get_search_function(opts.pattern_type)

	local cursor_lnum, cursor_col = opts.cursor_pos[1], opts.cursor_pos[2] + 1

	local forward = opts.forward == true
	local relative = opts.relative == true

	local match_lnum, match_col, match_end_col, match_next_chars
	local prev_matches, next_matches = {}, {}

	for i, line in ipairs(lines) do
		--- skip errors due to % at the end (lua), unbalanced (), ...
		local ok, ranges = pcall(pattern_ranges, line, pattern, search)

		if ok then
			for _, match_range in ipairs(ranges) do
				match_lnum, match_col, match_end_col = first_line - 1 + i, unpack(match_range)
				match_next_chars = line:sub(match_end_col + 1, match_end_col + 1)
				match_range = { match_lnum - 1, match_col, match_end_col, match_next_chars }

				--- prev matches
				if match_lnum < cursor_lnum then
					table.insert(prev_matches, match_range)
				elseif match_lnum == cursor_lnum and forward == false and match_col < cursor_col then
					table.insert(prev_matches, match_range)
				elseif match_lnum == cursor_lnum and forward == true and match_col <= cursor_col then
					table.insert(prev_matches, match_range)

				--- next matches
				elseif match_lnum == cursor_lnum and forward == false and match_col >= cursor_col then
					table.insert(next_matches, match_range)
				elseif match_lnum == cursor_lnum and forward == true and match_col > cursor_col then
					table.insert(next_matches, match_range)
				elseif match_lnum > cursor_lnum then
					table.insert(next_matches, match_range)
				end
			end
		end
	end

	local matches = {}

	if relative == false and forward == false then
		matches = utils.list_reverse(utils.list_extend(prev_matches, next_matches))
	elseif relative == false and forward == true then
		matches = utils.list_extend(prev_matches, next_matches)
	elseif relative == true and forward == false then
		matches = utils.list_extend(utils.list_reverse(prev_matches), utils.list_reverse(next_matches))
	elseif relative == true and forward == true then
		matches = utils.list_extend(next_matches, prev_matches)
	end

	return matches
end

function M.get_user_input(user_prefix)
	local keynum, ok, char
	local separator = cache.options.separator
	local user_input = user_prefix or ""
	local pattern, label, last_matching_pattern = "", "", ""
	local matches, labels_map, prev_labels_map = {}, {}, {}
	local labels = cache.options.labels
	local need_looping = true
	local loop_count = 0
	local delete_prev_word_rx = [=[\v[[:keyword:]]\zs[^[:keyword:]]+$|[[:keyword:]]+$]=]

	local win_id = vim.api.nvim_get_current_win()
	local buf_nr = vim.api.nvim_win_get_buf(win_id)
	local cursor_pos = vim.api.nvim_win_get_cursor(win_id)
	local view = utils.win_view(win_id)

	local search_opts = {
		cursor_pos = cursor_pos, -- needed here to avoid "sliding matches" while typing the pattern
		forward = cache.options.forward_search,
		pattern_type = cache.options.pattern_type,
		relative = cache.options.relative_labels,
		scope = cache.options.search_scope,
	}

	local labels_slider = utils.slider(nil, true)
	labels_slider.move(1)

	patterns_slider.move(#patterns + 1)

	if cache.options.use_last_pattern == true and type(cache.state.last_used_pattern) == "string" then
		user_input = cache.state.last_used_pattern
		pattern = cache.state.last_used_pattern
		matches = M.win_find_pattern(win_id, user_input, search_opts)
		labels_slider.set_max(#matches)
		if cache.options.search_scope == "buffer" then
			M.jump_to(matches[1])
		end
	end

	if cache.options.auto_jump and #matches == 1 then
		need_looping = false
	end

	if need_looping == true then
		if separator == "" then
			labels = M.discard_labels(cache.options.labels, matches)
		end
		labels_map = M.create_labels_map(labels, matches, false)
		prev_labels_map = labels_map
		ui.show_feedbacks(buf_nr, pattern, matches, labels_map, labels[labels_slider.pos])
	end

	while need_looping == true do
		--- user input

		if not (loop_count == 0 and user_input ~= "") then
			ok, keynum = pcall(vim.fn.getchar)
			if ok then
				char = type(keynum) == "number" and vim.fn.nr2char(keynum) or ""
				if char == keymaps.cancel or keynum == keymaps.cancel then
					user_input, labels_map = "", {}
					break
				elseif char == keymaps.validate or keynum == keymaps.validate then
					break
				elseif char == keymaps.delete_prev_char or keynum == keymaps.delete_prev_char then
					user_input = #user_input > 0 and user_input:sub(1, #user_input - 1) or user_input
				elseif char == keymaps.delete_prev_word or keynum == keymaps.delete_prev_word then
					user_input = vim.fn.substitute(user_input, delete_prev_word_rx, "", "")
				elseif char == keymaps.restore_pattern or keynum == keymaps.restore_pattern then
					user_input = last_matching_pattern
				elseif char == keymaps.delete_pattern or keynum == keymaps.delete_pattern then
					user_input = ""
				elseif char == keymaps.prev_pattern or keynum == keymaps.prev_pattern then
					user_input = patterns[patterns_slider.prev()]
				elseif char == keymaps.next_pattern or keynum == keymaps.next_pattern then
					user_input = patterns[patterns_slider.next()]
				elseif char == keymaps.prev_match or keynum == keymaps.prev_match then
					cache.state.label_index = labels_slider.prev()
				elseif char == keymaps.next_match or keynum == keymaps.next_match then
					cache.state.label_index = labels_slider.next()
				elseif char == keymaps.send_to_qflist or keynum == keymaps.send_to_qflist then
					send_to_qflist(matches)
					break
				elseif cache.options.max_pattern_length > 0 and #pattern >= cache.options.max_pattern_length then
					user_input = user_input .. separator .. char
				else
					user_input = user_input .. char
				end
			end
		end

		--- matches

		pattern, label = extract_pattern_and_label(user_input, separator)
		matches = M.win_find_pattern(win_id, pattern, search_opts)
		if separator == "" then
			labels = M.discard_labels(cache.options.labels, matches)
		end
		labels_map = M.create_labels_map(labels, matches, false)
		labels_slider.set_max(#matches)

		if cache.options.search_scope == "buffer" then
			M.jump_to(matches[labels_slider.pos])
		end
		ui.show_feedbacks(buf_nr, pattern, matches, labels_map, labels[labels_slider.pos])

		if #matches > 0 then
			last_matching_pattern = pattern
		end

		local last_char = user_input:sub(#user_input, #user_input)
		if separator == "" and #matches == 0 and vim.tbl_contains(labels, last_char) then
			pattern, label = user_input:sub(1, #user_input - 1), last_char
			labels_map = prev_labels_map
		end
		prev_labels_map = labels_map

		if #pattern > 0 and #label > 0 then
			break
		end

		if cache.options.auto_jump and #matches == 1 then
			label = labels[1]
			break
		end

		---

		loop_count = loop_count + 1
	end
	ui.clear_feedbacks(buf_nr)

	cache.state.last_used_pattern = pattern
	patterns = update_search_history(patterns, pattern)
	patterns_slider.set_max(#patterns)

	if cache.options.update_search_register == true then
		update_search_register(cache.state.last_used_pattern, cache.options.pattern_type)
	end

	if separator == "" and #label > 0 and labels_map[label] then
		M.jump_to(labels_map[label])
		return
	end

	if char == keymaps.validate or keynum == keymaps.validate then
		M.jump_to(labels_map[labels[labels_slider.pos]])
		return
	end

	if char == keymaps.cancel or not labels_map[label] then
		view.restore()
		return
	end

	if char == keymaps.send_to_qflist or keynum == keymaps.send_to_qflist then
		return
	end

	return user_input, labels_map
end

function M.select_window()
	local wins_list = utils.tab_list_wins(0)
	local wins_ctxt = {}
	local wins_labels = {}

	for win_nr, win_id in ipairs(wins_list) do
		local first_line, last_line = M.win_get_lines_range(win_id, "visible_lines")
		local label = cache.options.labels[win_nr]
		wins_labels[label] = win_id
		wins_ctxt[win_id] = {
			win_id = win_id,
			buf_nr = vim.api.nvim_win_get_buf(win_id),
			first_line = first_line,
			last_line = last_line,
			label = label,
		}
	end

	ui.multi_win_show_indicators(wins_list, wins_ctxt)
	local ok, keynum = pcall(vim.fn.getchar)
	ui.multi_win_hide_indicators(wins_list, wins_ctxt)

	if not ok then
		return
	end

	local label = type(keynum) == "number" and vim.fn.nr2char(keynum) or ""
	local win_id = wins_labels[label]

	if win_id then
		vim.api.nvim_set_current_win(win_id)
		return win_id
	end
end

return M
