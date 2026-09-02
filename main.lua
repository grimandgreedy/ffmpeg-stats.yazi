--- FFmpeg Stats Linemode Plugin for Yazi
--- Displays multiple media file stats using ffprobe

local DEBUG = os.getenv("YAZI_FFMPEG_STATS_DEBUG") == "1"
local PLUGIN_ID = "ffmpeg-stats"

local function log_debug(...)
	if not DEBUG then
		return
	end
	local parts = { "[ffmpeg-stats]" }
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring(select(i, ...))
	end
	ya.err(table.concat(parts, " "))
end

local MEDIA_EXTENSIONS = {
	mp4 = true,
	mkv = true,
	avi = true,
	mov = true,
	webm = true,
	flv = true,
	wmv = true,
	m4v = true,
	mpg = true,
	mpeg = true,
	["3gp"] = true,
	ogv = true,
	ts = true,
	mts = true,
	m2ts = true,
	mp3 = true,
	flac = true,
	wav = true,
	m4a = true,
	ogg = true,
	aac = true,
	wma = true,
	opus = true,
	ape = true,
	alac = true,
	aiff = true,
	dsf = true,
	dff = true,
}

local function is_media_file(file)
	if file.cha and file.cha.is_dir then
		return false
	end
	local name = tostring(file.url):match("[^/\\]+$")
	if not name then
		return false
	end
	local ext = name:match("%.([^.]+)$")
	return ext ~= nil and MEDIA_EXTENSIONS[ext:lower()] == true
end

--- Format Functions ---

local function format_duration(seconds)
	if not seconds or seconds <= 0 then
		return ""
	end
	local total = math.floor(seconds + 0.5)
	local h = math.floor(total / 3600)
	local m = math.floor((total % 3600) / 60)
	local s = total % 60
	return string.format("%02d:%02d:%02d", h, m, s)
end

local function format_resolution(width, height)
	if not width or not height or width == 0 or height == 0 then
		return ""
	end
	return string.format("%dx%d", width, height)
end

local function format_codec(codec)
	if not codec or codec == "" then
		return ""
	end
	return codec:upper()
end

local function format_fps(fps_str)
	if not fps_str or fps_str == "" then
		return ""
	end
	local num, denom = fps_str:match("(%d+)/(%d+)")
	if num and denom then
		local fps = tonumber(num) / tonumber(denom)
		if fps > 0 then
			-- Format to 2 decimals, remove trailing zeros
			local formatted = string.format("%.2f", fps):gsub("%.?0+$", "")
			return formatted .. "fps"
		end
	end
	return ""
end

local function format_bitrate(bitrate_num)
	if not bitrate_num or bitrate_num <= 0 then
		return ""
	end
	local kbps = math.floor(bitrate_num / 1000)
	if kbps >= 1000 then
		return string.format("%.1fMbps", kbps / 1000)
	end
	return string.format("%dkbps", kbps)
end

local function format_bitrate_kbps(bitrate_num)
	if not bitrate_num or bitrate_num <= 0 then
		return ""
	end
	local kbps = math.floor(bitrate_num / 1000)
	return string.format("%dkbps", kbps)
end

local function format_audio_codec(codec)
	if not codec or codec == "" then
		return ""
	end
	return codec:upper()
end

local function format_audio_channels(channels)
	if not channels or channels <= 0 then
		return ""
	end
	if channels == 1 then
		return "mono"
	elseif channels == 2 then
		return "stereo"
	elseif channels == 6 then
		return "5.1ch"
	elseif channels == 8 then
		return "7.1ch"
	else
		return string.format("%dch", channels)
	end
end

local function format_format(format_str)
	if not format_str or format_str == "" then
		return ""
	end
	-- Take first format from comma-separated list
	local first = format_str:match("([^,]+)")
	return first and first:upper() or ""
end

local function format_aspect(aspect_str)
	if not aspect_str or aspect_str == "" then
		return ""
	end
	return aspect_str
end

--- JSON Parsing ---

local function extract_json_value(json, key, numeric)
	-- Match both quoted strings and unquoted numbers
	local pattern_quoted = '"' .. key .. '"%s*:%s*"([^"]*)"'
	local pattern_unquoted = '"' .. key .. '"%s*:%s*([%d%.]+)'

	local value = json:match(pattern_quoted)
	if not value then
		value = json:match(pattern_unquoted)
	end

	if numeric and value then
		return tonumber(value)
	end
	return value
end

local function parse_ffprobe_json(json_str)
	if not json_str or json_str == "" then
		return nil
	end

	-- Extract streams array
	local streams = json_str:match('"streams"%s*:%s*%[(.-)%]')
	if not streams then
		if DEBUG then
			log_debug("No streams found in JSON")
		end
		return nil
	end

	local info = {}

	-- Find video stream (one that has width and height)
	local video_stream = nil
	local pos = 1
	while true do
		local stream = streams:match("(%b{})", pos)
		if not stream then
			break
		end
		-- Check if this stream has width and height (indicates video)
		local width = extract_json_value(stream, "width", true)
		local height = extract_json_value(stream, "height", true)
		if width and height and width > 0 and height > 0 then
			-- Prefer larger resolution (skip thumbnails)
			if not video_stream then
				video_stream = stream
				info.width = width
				info.height = height
			else
				-- If we found a larger stream, use that instead
				if width * height > (info.width or 0) * (info.height or 0) then
					video_stream = stream
					info.width = width
					info.height = height
				end
			end
		end
		pos = pos + #stream
	end

	-- Extract video stats if video stream exists
	if video_stream then
		-- width and height already extracted above
		info.codec = extract_json_value(video_stream, "codec_name")
		info.fps_str = extract_json_value(video_stream, "r_frame_rate")
		info.bitrate = extract_json_value(video_stream, "bit_rate", true)
		info.aspect = extract_json_value(video_stream, "display_aspect_ratio")

		-- Compute resolution pixels for sorting
		if info.width and info.height then
			info.resolution_pixels = info.width * info.height
		end
	end

	-- Extract audio stats (look for channels field which indicates audio stream)
	local audio_channels = extract_json_value(streams, "channels", true)
	if audio_channels then
		info.audio_channels = audio_channels
		-- Try to find audio codec near the channels field
		local audio_part = streams:match('"channels"%s*:%s*' .. audio_channels .. '.-"codec_name"%s*:%s*"([^"]+)"')
		if not audio_part then
			-- Try reverse order
			audio_part = streams:match('"codec_name"%s*:%s*"([^"]+)".-"channels"%s*:%s*' .. audio_channels)
		end
		if audio_part then
			info.audio_codec = audio_part
		end
	end

	-- Extract format section
	local format_section = json_str:match('"format"%s*:%s*(%b{})')
	if format_section then
		info.format = extract_json_value(format_section, "format_name")
		info.duration = extract_json_value(format_section, "duration", true)

		-- Compute duration_ms for sorting
		if info.duration then
			info.duration_ms = math.floor(info.duration * 1000 + 0.5)
		end
	end

	-- Compute bitrate_kbps for sorting
	if info.bitrate then
		info.bitrate_kbps = math.floor(info.bitrate / 1000)
	end

	-- Compute fps numeric for sorting
	if info.fps_str then
		local num, denom = info.fps_str:match("(%d+)/(%d+)")
		if num and denom then
			info.fps_numeric = tonumber(num) / tonumber(denom)
		end
	end

	return info
end

--- Thread-safe State Functions ---

local claim_path = ya.sync(function(st, path)
	if st.cache[path] ~= nil then
		return false
	end
	if st.pending[path] then
		return false
	end
	st.pending[path] = true
	return true
end)

local update_cache = ya.sync(function(st, path, entry)
	st.pending[path] = nil
	if entry then
		st.cache[path] = entry
	else
		st.cache[path] = false
	end
	ui.render()
end)

--- FFProbe Execution ---

local function fetch_info(path)
	local output, err = Command("ffprobe")
		:arg({
			"-v",
			"error",
			"-show_entries",
			"stream=width,height,codec_name,r_frame_rate,bit_rate,channels,display_aspect_ratio",
			"-show_entries",
			"format=format_name,duration",
			"-of",
			"json",
			path,
		})
		:stdout(Command.PIPED)
		:stderr(Command.NULL)
		:output()

	if not output or not output.status or not output.status.success then
		if DEBUG then
			log_debug("ffprobe failed", path, err or "unknown error")
		end
		return nil
	end

	return parse_ffprobe_json(output.stdout)
end

--- Fetcher Function ---

local function fetch(_, job)
	local targets = {}
	for _, file in ipairs(job.files) do
		if is_media_file(file) then
			local path = tostring(file.url)
			if claim_path(path) then
				targets[#targets + 1] = path
			end
		end
	end

	if #targets == 0 then
		return require("noop"):fetch(job)
	end

	for _, path in ipairs(targets) do
		local info = fetch_info(path)
		if info then
			update_cache(path, info)
		else
			update_cache(path, false)
		end
	end

	return require("noop"):fetch(job)
end

--- Toggle Functions ---

local toggle_stat = ya.sync(function(st, stat_name)
	if st.enabled[stat_name] ~= nil then
		st.enabled[stat_name] = not st.enabled[stat_name]
	end
	ui.render()
	return st.enabled[stat_name]
end)

local toggle_all = ya.sync(function(st)
	-- Check if any are enabled
	local any_enabled = false
	for _, v in pairs(st.enabled) do
		if v then
			any_enabled = true
			break
		end
	end

	-- If any enabled, disable all; otherwise enable all
	local new_state = not any_enabled
	for k in pairs(st.enabled) do
		st.enabled[k] = new_state
	end

	ui.render()
	return new_state
end)

local disable_all = ya.sync(function(st)
	for k in pairs(st.enabled) do
		st.enabled[k] = false
	end
	ui.render()
end)

--- Sort Functions ---

local current_linemode = ya.sync(function()
	local ok, result = pcall(function()
		local tab = cx and cx.active
		if not tab then
			return nil
		end
		local current = tab.current and tab.current.linemode
		local pref = tab.pref and tab.pref.linemode
		if current and current ~= "" then
			return current
		end
		if pref and pref ~= "" then
			return pref
		end
		return nil
	end)
	if ok then
		return result
	else
		if DEBUG then
			log_debug("current_linemode error:", result)
		end
		return nil
	end
end)

local function safe_current_linemode()
	local ok, mode = pcall(current_linemode)
	if not ok then
		if DEBUG then
			log_debug("current_linemode failed", mode)
		end
		return nil
	end
	if mode == "" then
		return nil
	end
	return mode
end

local function set_linemode(mode)
	if not mode or mode == "" or #mode > 20 then
		if DEBUG then
			log_debug("Invalid linemode:", mode, "length:", mode and #mode or 0)
		end
		return
	end
	ya.emit("linemode", { mode })
end

local restore_linemode_direct = ya.sync(function(_, mode)
	if not mode or mode == "" then
		return
	end
	set_linemode(mode)
end)

local function schedule_restore(mode)
	if not mode or mode == "" then
		return
	end
	if DEBUG then
		log_debug("schedule restore", mode)
	end
	ya.emit("plugin", { PLUGIN_ID, "restore", mode })
end

local function sort_with(mode, reverse)
	local prev = safe_current_linemode()
	if DEBUG then
		log_debug("sort", mode, "reverse", tostring(reverse), "prev", tostring(prev))
	end
	set_linemode(mode)
	ya.emit("sort", {
		"linemode",
		reverse = reverse,
	})
	if prev and prev ~= mode then
		schedule_restore(prev)
	end
end

--- Setup Function ---

local function setup(st, opts)
	opts = opts or {}
	st.cache = {}
	st.pending = {}
	st.enabled = {
		duration = opts.duration == true,
		resolution = opts.resolution == true,
		codec = opts.codec == true,
		fps = opts.fps == true,
		bitrate = opts.bitrate == true,
		audio_codec = opts.audio_codec == true,
		audio_channels = opts.audio_channels == true,
		format = opts.format == true,
		aspect = opts.aspect == true,
	}

	st.style = opts.style
	st.order = opts.order or 1600

	-- Register display callback using children_add
	Linemode:children_add(function(self)
		local entry = st.cache[tostring(self._file.url)]
		if not entry or entry == false then
			return ""
		end

		local parts = {}

		if st.enabled.audio_channels and entry.audio_channels then
			local ach = format_audio_channels(entry.audio_channels)
			if ach ~= "" then
				parts[#parts + 1] = ach
			end
		end

		if st.enabled.audio_codec and entry.audio_codec then
			local ac = format_audio_codec(entry.audio_codec)
			if ac ~= "" then
				parts[#parts + 1] = ac
			end
		end

		if st.enabled.bitrate and entry.bitrate then
			local br = format_bitrate(entry.bitrate)
			if br ~= "" then
				parts[#parts + 1] = br
			end
		end

		if st.enabled.fps and entry.fps_str then
			local fps = format_fps(entry.fps_str)
			if fps ~= "" then
				parts[#parts + 1] = fps
			end
		end

		if st.enabled.codec and entry.codec then
			local codec = format_codec(entry.codec)
			if codec ~= "" then
				parts[#parts + 1] = codec
			end
		end

		if st.enabled.format and entry.format then
			local fmt = format_format(entry.format)
			if fmt ~= "" then
				parts[#parts + 1] = fmt
			end
		end

		if st.enabled.aspect and entry.aspect then
			local asp = format_aspect(entry.aspect)
			if asp ~= "" then
				parts[#parts + 1] = asp
			end
		end

		if st.enabled.resolution and entry.width and entry.height then
			local res = format_resolution(entry.width, entry.height)
			if res ~= "" then
				parts[#parts + 1] = res
			end
		end

		if st.enabled.duration and entry.duration then
			local dur = format_duration(entry.duration)
			if dur ~= "" then
				parts[#parts + 1] = dur
			end
		end

		if #parts == 0 then
			return ""
		end

		local display = table.concat(parts, " ")
		local span = st.style and ui.Span(display):style(st.style) or display
		return ui.Line({ " ", span })
	end, st.order)

	-- Individual linemode functions for direct usage
	function Linemode:ffmpeg_duration()
		local entry = st.cache[tostring(self._file.url)]
		return entry and entry.duration and format_duration(entry.duration) or ""
	end

	function Linemode:ffmpeg_resolution()
		local entry = st.cache[tostring(self._file.url)]
		return entry and format_resolution(entry.width, entry.height) or ""
	end

	function Linemode:ffmpeg_codec()
		local entry = st.cache[tostring(self._file.url)]
		return entry and format_codec(entry.codec) or ""
	end

	function Linemode:ffmpeg_fps()
		local entry = st.cache[tostring(self._file.url)]
		return entry and format_fps(entry.fps_str) or ""
	end

	function Linemode:ffmpeg_bitrate()
		local entry = st.cache[tostring(self._file.url)]
		return entry and format_bitrate(entry.bitrate) or ""
	end

	function Linemode:ffmpeg_audio_codec()
		local entry = st.cache[tostring(self._file.url)]
		return entry and format_audio_codec(entry.audio_codec) or ""
	end

	function Linemode:ffmpeg_audio_channels()
		local entry = st.cache[tostring(self._file.url)]
		return entry and format_audio_channels(entry.audio_channels) or ""
	end

	function Linemode:ffmpeg_format()
		local entry = st.cache[tostring(self._file.url)]
		return entry and format_format(entry.format) or ""
	end

	function Linemode:ffmpeg_aspect()
		local entry = st.cache[tostring(self._file.url)]
		return entry and format_aspect(entry.aspect) or ""
	end

	-- Sort linemode functions (using same formatting as display for readability)
	function Linemode:ffmpeg_duration_sort()
		local entry = st.cache[tostring(self._file.url)]
		return entry and entry.duration and format_duration(entry.duration) or ""
	end

	function Linemode:ffmpeg_res_sort()
		local entry = st.cache[tostring(self._file.url)]
		if not entry or entry == false then
			return ""
		end
		return format_resolution(entry.width, entry.height)
	end

	function Linemode:ffmpeg_codec_sort()
		local entry = st.cache[tostring(self._file.url)]
		return entry and format_codec(entry.codec) or ""
	end

	function Linemode:ffmpeg_fps_sort()
		local entry = st.cache[tostring(self._file.url)]
		return entry and format_fps(entry.fps_str) or ""
	end

	function Linemode:ffmpeg_bitrate_sort()
		local entry = st.cache[tostring(self._file.url)]
		return entry and format_bitrate_kbps(entry.bitrate) or ""
	end

	function Linemode:ffmpeg_acodec_sort()
		local entry = st.cache[tostring(self._file.url)]
		return entry and format_audio_codec(entry.audio_codec) or ""
	end

	function Linemode:ffmpeg_channels_sort()
		local entry = st.cache[tostring(self._file.url)]
		return entry and format_audio_channels(entry.audio_channels) or ""
	end

	function Linemode:ffmpeg_format_sort()
		local entry = st.cache[tostring(self._file.url)]
		return entry and format_format(entry.format) or ""
	end

	function Linemode:ffmpeg_aspect_sort()
		local entry = st.cache[tostring(self._file.url)]
		return entry and format_aspect(entry.aspect) or ""
	end
end

--- Entry Point ---

local function entry(_, job)
	local cmd = job.args and job.args[1]
	if DEBUG then
		log_debug("entry", cmd)
	end

	if cmd == "toggle-duration" then
		toggle_stat("duration")
	elseif cmd == "toggle-resolution" then
		toggle_stat("resolution")
	elseif cmd == "toggle-codec" then
		toggle_stat("codec")
	elseif cmd == "toggle-fps" then
		toggle_stat("fps")
	elseif cmd == "toggle-bitrate" then
		toggle_stat("bitrate")
	elseif cmd == "toggle-audio-codec" then
		toggle_stat("audio_codec")
	elseif cmd == "toggle-audio-channels" then
		toggle_stat("audio_channels")
	elseif cmd == "toggle-format" then
		toggle_stat("format")
	elseif cmd == "toggle-aspect" then
		toggle_stat("aspect")
	elseif cmd == "toggle-all" then
		toggle_all()
	elseif cmd == "disable-all" then
		disable_all()
	elseif cmd == "sort-duration" then
		sort_with("ffmpeg_duration_sort", false)
	elseif cmd == "sort-duration-reverse" then
		sort_with("ffmpeg_duration_sort", true)
	elseif cmd == "sort-resolution" then
		sort_with("ffmpeg_res_sort", false)
	elseif cmd == "sort-resolution-reverse" then
		sort_with("ffmpeg_res_sort", true)
	elseif cmd == "sort-codec" then
		sort_with("ffmpeg_codec_sort", false)
	elseif cmd == "sort-codec-reverse" then
		sort_with("ffmpeg_codec_sort", true)
	elseif cmd == "sort-fps" then
		sort_with("ffmpeg_fps_sort", false)
	elseif cmd == "sort-fps-reverse" then
		sort_with("ffmpeg_fps_sort", true)
	elseif cmd == "sort-bitrate" then
		sort_with("ffmpeg_bitrate_sort", false)
	elseif cmd == "sort-bitrate-reverse" then
		sort_with("ffmpeg_bitrate_sort", true)
	elseif cmd == "sort-audio-codec" then
		sort_with("ffmpeg_acodec_sort", false)
	elseif cmd == "sort-audio-codec-reverse" then
		sort_with("ffmpeg_acodec_sort", true)
	elseif cmd == "sort-audio-channels" then
		sort_with("ffmpeg_channels_sort", false)
	elseif cmd == "sort-audio-channels-reverse" then
		sort_with("ffmpeg_channels_sort", true)
	elseif cmd == "sort-format" then
		sort_with("ffmpeg_format_sort", false)
	elseif cmd == "sort-format-reverse" then
		sort_with("ffmpeg_format_sort", true)
	elseif cmd == "sort-aspect" then
		sort_with("ffmpeg_aspect_sort", false)
	elseif cmd == "sort-aspect-reverse" then
		sort_with("ffmpeg_aspect_sort", true)
	elseif cmd == "restore" then
		local target = job.args and job.args[2]
		restore_linemode_direct(target)
	else
		ya.err(string.format("ffmpeg-stats: unknown command '%s'", tostring(cmd)))
	end
end

return { setup = setup, fetch = fetch, entry = entry }
