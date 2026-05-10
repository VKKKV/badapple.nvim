-- License: GPLv3
-- Author: vkkkv
-- Description: Play "Bad Apple" ASCII animation in a floating window with dynamic code masking.

local M = {}
local loop = vim.uv or vim.loop
local api = vim.api
local fn = vim.fn

---@class BadAppleConfig
---@field FRAME_WIDTH number Width of each frame in the source file
---@field FRAME_HEIGHT number Height of each frame in the source file
---@field SAMPLING_SCALE number Upscaling factor (1 = original size)
---@field PADDING number Space between code and animation mask
---@field FRAMES_PATH string Path to the frames file relative to rtp
---@field FPS number Frames per second

---@type BadAppleConfig
local CONF = {
    FRAME_WIDTH = 179,
    FRAME_HEIGHT = 73,
    SAMPLING_SCALE = 1,
    PADDING = 2,
    -- Braille file
    FRAMES_PATH = "lua/badapple/badapple.srt",
    AUDIO_PATH = "lua/badapple/badapple.m4a",
    -- Audio offset (ms)
    AUDIO_OFFSET = 3000,
    FPS = 30,
}

---@class BadAppleState
---@field timer uv_timer_t Animation timer
---@field buf integer Floating window buffer ID
---@field win integer Floating window ID
---@field target_win integer The window we are masking over
---@field cached_frames string[][] Pre-processed frames
---@field is_running boolean Status flag

---@type BadAppleState
local state = {
    timer = nil,
    buf = -1,
    win = -1,
    target_win = -1,
    cached_frames = {},
    is_running = false,
    audio_job = 0,
}


---Configures the plugin.
---@param opts? table Partial config override
function M.setup(opts)
    opts = opts or {}
    CONF = vim.tbl_deep_extend("force", CONF, opts)
end

---Splits SRT content into raw frame lines, filtering out metadata.
---@param content string Raw SRT content
---@return string[] Array of ASCII lines
local function split_lines(content)
    local lines = vim.split(content, "\n", { trimempty = false })
    local result = {}

    for _, line in ipairs(lines) do
        line = line:gsub("\r", "")

        -- Filter out SRT indices (digits) and timestamps (-->)
        if not line:match("^%d+$") and not line:match("%-%->") and #line > 0 then
            table.insert(result, line)
        end
    end
    return result
end

---Scales a frame's dimensions for better visibility on high-res displays.
---@param raw_lines string[] Original frame lines
---@param scale number Scaling factor
---@return string[] Scaled frame lines
local function pre_process_frame(raw_lines, scale)
    if scale <= 1 then
        return raw_lines
    end

    local new_frame = {}
    for _, line in ipairs(raw_lines) do
        local scaled_line_parts = {}
        -- Iterate by UTF-8 characters to handle Braille correctly
        for i = 1, fn.strchars(line) do
            local char = fn.strcharpart(line, i - 1, 1)
            table.insert(scaled_line_parts, string.rep(char, scale))
        end
        local scaled_row = table.concat(scaled_line_parts)

        for _ = 1, scale do
            table.insert(new_frame, scaled_row)
        end
    end
    return new_frame
end

---Loads frames from the filesystem and caches them in memory.
---@return boolean Success status
local function load_resources()
    if #state.cached_frames > 0 then
        return true
    end

    local path = api.nvim_get_runtime_file(CONF.FRAMES_PATH, true)[1]
    if not path then
        vim.notify("BadApple: Frames file missing at " .. CONF.FRAMES_PATH, vim.log.levels.ERROR)
        return false
    end

    local fd = io.open(path, "r")
    if not fd then
        return false
    end
    local content = fd:read("*all")
    fd:close()

    local raw_lines = split_lines(content)
    local frame_h = CONF.FRAME_HEIGHT

    local current_batch = {}
    for _, line in ipairs(raw_lines) do
        -- Pad short lines to ensure uniform frame width
        local char_count = fn.strchars(line)
        if char_count < CONF.FRAME_WIDTH then
            line = line .. string.rep(" ", CONF.FRAME_WIDTH - char_count)
        end
        table.insert(current_batch, line)

        if #current_batch == frame_h then
            table.insert(state.cached_frames, pre_process_frame(current_batch, CONF.SAMPLING_SCALE))
            current_batch = {}
        end
    end

    vim.notify(string.format("BadApple: Loaded %d frames.", #state.cached_frames), vim.log.levels.INFO)
    return true
end

---Creates a "masked" version of the frame by overlaying it with code from the target window.
---@param frame_lines string[] The ASCII frame to mask
---@param target_win integer The window containing code to mask against
---@return string[] Masked lines
local function get_masked_frame(frame_lines, target_win)
    if not api.nvim_win_is_valid(target_win) then
        return frame_lines
    end

    local target_buf = api.nvim_win_get_buf(target_win)
    local start_line = fn.line("w0", target_win)
    local buf_line_count = api.nvim_buf_line_count(target_buf)

    -- Bulk fetch visible lines from the buffer for performance
    local range_end = math.min(start_line + #frame_lines - 1, buf_line_count)
    local buffer_lines = api.nvim_buf_get_lines(target_buf, start_line - 1, range_end, false)

    local masked_lines = {}
    local frame_width_chars = fn.strchars(frame_lines[1])

    for i, ascii_line in ipairs(frame_lines) do
        local mask_len = 0
        local buffer_line = buffer_lines[i]

        if buffer_line and #buffer_line > 0 then
            mask_len = fn.strdisplaywidth(buffer_line) + CONF.PADDING
        end

        if mask_len == 0 then
            table.insert(masked_lines, ascii_line)
        elseif mask_len >= frame_width_chars then
            table.insert(masked_lines, string.rep(" ", frame_width_chars))
        else
            -- Slice the ASCII line and prepend transparency (spaces)
            local remainder = fn.strcharpart(ascii_line, mask_len)
            table.insert(masked_lines, string.rep(" ", mask_len) .. remainder)
        end
    end

    return masked_lines
end

---Starts the Bad Apple animation.
function M.start()
    if state.is_running then
        M.stop()
    end

    if not load_resources() then
        return
    end

    state.target_win = api.nvim_get_current_win()
    local win_conf = {
        relative = "win",
        win = state.target_win,
        width = api.nvim_win_get_width(state.target_win),
        height = api.nvim_win_get_height(state.target_win),
        col = 0,
        row = 0,
        style = "minimal",
        focusable = false,
        zindex = 40,
    }

    state.buf = api.nvim_create_buf(false, true)
    state.win = api.nvim_open_win(state.buf, false, win_conf)

    -- Configure window options for a transparent, non-obtrusive overlay
    local wo = vim.wo[state.win]
    wo.winblend = 100 -- Fully transparent background
    wo.wrap = false
    wo.number = false
    wo.relativenumber = false
    wo.signcolumn = "no"
    wo.foldcolumn = "0"

    -- --- AUDIO SECTION ---
    local audio_file = api.nvim_get_runtime_file(CONF.AUDIO_PATH, true)[1]

    if audio_file then
        state.audio_job = vim.fn.jobstart({
            "mpv",
            "--no-config",
            "--no-video",
            "--no-terminal",
            audio_file,
        }, {
            on_exit = function()
                -- Cleanup if audio finishes first (unlikely for loop, but good practice)
                state.audio_job = 0
            end,
        })

        if state.audio_job <= 0 then
            vim.notify("Warning: Failed to start mpv. Is it installed?", vim.log.levels.WARN)
        end
    else
        vim.notify("Warning: Audio file not found. Silence is golden anyway.", vim.log.levels.WARN)
    end

    state.is_running = true
    local idx = 1
    local total_frames = #state.cached_frames

    -- Delay the Animation Start (The fast part)
    vim.defer_fn(function()
        if not state.is_running then
            return
        end

        state.timer = loop.new_timer()
        state.timer:start(
            0,
            math.floor(1000 / CONF.FPS),
            vim.schedule_wrap(function()
                if not state.is_running or not api.nvim_win_is_valid(state.win) then
                    M.stop()
                    return
                end

                local frame = state.cached_frames[idx]
                local final_render = get_masked_frame(frame, state.target_win)
                api.nvim_buf_set_lines(state.buf, 0, -1, false, final_render)

                idx = idx + 1
                if idx > total_frames then
                    M.stop()
                    return
                end
            end)
        )
    end, CONF.AUDIO_OFFSET) -- Wait for X ms
end

---Stops the animation and cleans up resources.
function M.stop()
    state.is_running = false

    -- --- AUDIO CLEANUP ---
    if state.audio_job > 0 then
        vim.fn.jobstop(state.audio_job)
        state.audio_job = 0
    end

    if state.timer then
        state.timer:stop()
        if not state.timer:is_closing() then
            state.timer:close()
        end
        state.timer = nil
    end

    if state.win and api.nvim_win_is_valid(state.win) then
        api.nvim_win_close(state.win, true)
    end
    if state.buf and api.nvim_buf_is_valid(state.buf) then
        api.nvim_buf_delete(state.buf, { force = true })
    end
    state.win = -1
    state.buf = -1
end


return M
