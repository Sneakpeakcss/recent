local o = {
    auto_save = true,                      -- Automatically save to log, otherwise only saves when requested
                                           -- you need to bind a save key if you disable it
    save_bind = "",
    auto_save_skip_past = 100,             -- When automatically saving, skip entries with playback positions
                                           -- past this value, in percent. 100 saves all, around 95 is
                                           -- good for skipping videos that have reached final credits.
    hide_same_dir = false,                 -- Display only the latest file from each directory
    auto_run_idle = true,                  -- Runs automatically when --idle
    write_watch_later = true,              -- Write watch later for current file when switching
    display_bind = "`",                    -- Display menu bind

    mouse_controls = true,                 -- Middle click: Select; Right click: Exit; Scroll wheel: Up/Down

    log_path = "history.log",              -- Reads from config directory or an absolute path
    date_format = "%d/%m/%y %X",           -- Date format in the log (see lua date formatting)

    show_paths = false,                    -- Show file paths instead of media-title
    slice_longfilenames = false,           -- Slice long filenames, and how many chars to show
    slice_longfilenames_amount = 100,
    slice_longfilenames_amount_uosc = 100,
    split_paths = true,                    -- Split paths to only show the file or show the full path

    font_scale = 50,
    border_size = 0.7,
    hi_color = "FFCF46",                   -- Highlight color in RRGGBB

    ellipsis = false,                      -- Draw ellipsis at start/end denoting omitted entries
    list_show_amount = 20,                 -- Change maximum number to show items on integrated submenus in uosc or mpv-menu-plugin
    use_uosc_menu = false,                 -- Use uosc menu as default
    double_menu_key = true,                -- Open default menu by keypress, open uosc menu when holding it (second hold switches to path menu)
    custom_colors = "",                    -- User defined Prefix/Colors (more details in config)
}

(require "mp.options").read_options(o, _, function() end)
local utils = require("mp.utils")
o.log_path = utils.join_path(mp.find_config_file("."), o.log_path)

local cur_title, cur_path
local list_drawn = false
local uosc_available = false
local is_windows = package.config:sub(1,1) == "\\"

function parse_custom_colors(custom_colors)
    local parsed_tags = {}

    for entry in custom_colors:gmatch("[^,]+") do
        local pattern, prefix, prefixColor, highlightColor = entry:match("([^|]+)|([^|]+)|([^|]+)|([^|]+)")
        table.insert(parsed_tags, {
            pattern = pattern,
            prefix = (prefix == '""') and "" or prefix,
            prefixColor = (prefixColor == '""') and "" or prefixColor,
            highlightColor = (highlightColor == '""') and "" or highlightColor
        })
    end

    return parsed_tags
end
custom_colors = parse_custom_colors(o.custom_colors)

function esc_string(str)
    return str:gsub("([%p])", "%%%1")
end

function is_protocol(path)
    return type(path) == 'string' and path:match('^%a[%a%d-_]+://') ~= nil
end

function normalize(path)
    if normalize_path ~= nil then
        if normalize_path then
            path = mp.command_native({"normalize-path", path})
        else
            local directory = mp.get_property("working-directory", "")
            path = mp.utils.join_path(directory, path:gusb('^%.[\\/]',''))
            if is_windows then path = path:gsub("\\", "/") end
        end
        return path
    end

    normalize_path = false

    local commands = mp.get_property_native("command-list", {})
    for _, command in ipairs(commands) do
        if command.name == "normalize-path" then
            normalize_path = true
            break
        end
    end
    return normalize(path)
end

-- from http://lua-users.org/wiki/LuaUnicode
local UTF8_PATTERN = '[%z\1-\127\194-\244][\128-\191]*'

-- return a substring based on utf8 characters
-- like string.sub, but negative index is not supported
local function utf8_sub(s, i, j)
    local t = {}
    local idx = 1
    for match in s:gmatch(UTF8_PATTERN) do
        if j and idx > j then break end
        if idx >= i then t[#t + 1] = match end
        idx = idx + 1
    end
    return table.concat(t)
end

function utf8_len(s)
    local _, count = string.gsub(s, UTF8_PATTERN, "")
    return count
end

function split_ext(filename)
    local idx = filename:match(".+()%.%w+$")
    if idx then
        filename = filename:sub(1, idx - 1)
    end
    return filename
end

function strip_title(str, uoscopen, prefix_length)
    if uoscopen then
        if o.slice_longfilenames and utf8_len(str) > (o.slice_longfilenames_amount_uosc + 5) then
            str = utf8_sub(str, 1, o.slice_longfilenames_amount_uosc) .. "..."
        end
    elseif o.slice_longfilenames and utf8_len(str..(prefix_length or "")) > (o.slice_longfilenames_amount + 5) then
        str = utf8_sub(str, 1, o.slice_longfilenames_amount - utf8_len(prefix_length or "")) .. "..."
    end
    return str
end

function get_ext(path)
    if is_protocol(path) then
        return path:match("^(%a[%w.+-]-)://"):upper()
    else
        return path:match(".+%.(%w+)$"):upper()
    end
end

function get_dir(path)
    if is_protocol(path) then
        return path
    end
    local dir, filename = utils.split_path(path)
    return dir
end

function get_filename(item)
    if is_protocol(item.path) then
        return item.title
    end
    local dir, filename = utils.split_path(item.path)
    return filename
end

function get_path()
    local path = mp.get_property("path")
    local title = mp.get_property("media-title"):gsub("\"", "")
    if not path then return end
    if is_protocol(path) then
        return title, path
    else
        local path = normalize(path)
        return title, path
    end
end

function unbind()
    if o.mouse_controls then
        for _, key in ipairs({"WUP", "WDOWN", "MMID", "SHIFT_MMID", "MRIGHT"}) do
            mp.remove_key_binding("recent-" .. key)
        end
    end
    -- List of keys to unbind
    for _, key in ipairs({
        "UP", "PGUP", "DOWN", "PGDWN", "HOME", "END",
        "ENTER", "KP_ENTER", "SHIFT_ENTER", "SHIFT_KP_ENTER", "Space", "DEL", "BS", "ESC",
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "0"
    }) do
        mp.remove_key_binding("recent-" .. key)
    end
    mp.set_osd_ass(0, 0, "")
    list_drawn = false
end

function read_log(func)
    local f = io.open(o.log_path, "r")
    if not f then return end
    local list = {}
    for line in f:lines() do
        if not line:match("^%s*$") then
            table.insert(list, (func(line)))
        end
    end
    f:close()
    return list
end

function read_log_table()
    return read_log(function(line)
        local t, p
        t, p = line:match("^.-\"(.-)\" | (.*)$")
        return {title = t, path = p}
    end)
end

function table_reverse(table)
    local reversed_table = {}
    for i = 1, #table do
        reversed_table[#table - i + 1] = table[i]
    end
    return reversed_table
end

function hide_same_dir(content)
    local lists = {}
    local dir_cache = {}
    for i = 1, #content do
        local dirname = get_dir(content[#content-i+1].path)
        if not dir_cache[dirname] then
            table.insert(lists, content[#content-i+1])
        end
        if dirname ~= "." then
            dir_cache[dirname] = true
        end
    end
    return table_reverse(lists)
end

local dyn_menu = {
    ready = false,
    type = 'submenu',
    submenu = {}
}

function update_dyn_menu_items()
    local menu = {}
    local lists = read_log_table()
    if not lists or not lists[1] then
        return
    end
    if o.hide_same_dir then
        lists = hide_same_dir(lists)
    end
    if #lists > o.list_show_amount then
        length = o.list_show_amount
    else
        length = #lists
    end
    for i = 1, length do
        menu[#menu + 1] = {
            title = string.format('%s\t%s', o.show_paths and strip_title(split_ext(get_filename(lists[#lists-i+1])))
            or strip_title(split_ext(lists[#lists-i+1].title)), get_ext(lists[#lists-i+1].path)),
            cmd = string.format("loadfile '%s'", lists[#lists-i+1].path),
        }
    end
    dyn_menu.submenu = menu
    mp.commandv('script-message-to', 'dyn_menu', 'update', 'recent', utils.format_json(dyn_menu))
end

-- Write path to log on file end
-- removing duplicates along the way
function write_log(delete)
    if not cur_path or (cur_path:match("bd://") or cur_path:match("dvd://")
    or cur_path:match("dvb://") or cur_path:match("cdda://")) then
        return
    end
    local content = read_log(function(line)
        if line:find(esc_string(cur_path)) then
            return nil
        else
            return line
        end
    end)
    local lines = {}
    if content then
        for i=1, #content do
            table.insert(lines, content[i])
        end
    end
    if not delete then
        table.insert(lines, string.format("[%s] \"%s\" | %s", os.date(o.date_format), cur_title, cur_path))
    end
    -- Write all accumulated lines to the file in one operation
    local f = io.open(o.log_path, "w+")
    if f then
        f:write(table.concat(lines, "\n") .. "\n")
        f:close()
    end
    if dyn_menu.ready then
        update_dyn_menu_items()
    end
end

-- Display list on OSD and terminal
function draw_list(list, start, choice)
    local font_scale = o.font_scale * (display_scale or 1)
    local msg = string.format("{\\fscx%f}{\\fscy%f}{\\bord%f}",
                font_scale, font_scale, o.border_size)
    local hi_start = string.format("{\\1c&H%s}", o.hi_color:gsub("(%x%x)(%x%x)(%x%x)","%3%2%1"))
    local hi_end = "{\\1c&HFFFFFF}"
    local hi_end = hi_end:gsub("{\\1c&H(%x%x)(%x%x)(%x%x)}","{\\1c&H%3%2%1}")
    local size = #list

    local current_line = start + choice + 1
    local total_lines  = size
    local current_page = math.ceil(current_line / 10)
    local total_pages  = math.ceil(total_lines / 10)

    local ss = "{\\fscx0}"
    local se = string.format("{\\fscx%f}", font_scale)
    local hs = ss .. string.char(0xE2, 0x80, 0x8A) .. se

    -- Pad numbers with leading zeros and add hairspace before each digit to avoid width shifting in certain cases: "11" "111" "1111"
    local function format_number(n, width) return (string.format("%0" .. width .. "d", n)):gsub("%d", hs .. "%0") end

    local current_line = format_number(current_line, #tostring(total_lines))
    local current_page = format_number(current_page, #tostring(total_pages))

    -- Display additional information above the list
    msg = msg .. string.format("%sLine:%s %s/%s %sPage:%s %s/%s\\N",
                        hi_start, hi_end, current_line, total_lines,
                        hi_start, hi_end, current_page, total_pages) .. (not o.ellipsis and "\\h\\N\\N" or "")
    if o.ellipsis then
        if start ~= 0 then
            msg = msg.."..."
        end
        msg = msg.."\\h\\N\\N"
    end
    for i=1, math.min(10, size-start), 1 do
        local key = i % 10
        local p
        if o.show_paths then
            if o.split_paths or is_protocol(list[size-start-i+1].path) then
                p = get_filename(list[size-start-i+1])
            else
                p = list[size-start-i+1].path or ""
            end
        else
            p = list[size-start-i+1].title or list[size-start-i+1].path or ""
        end
        p = p:gsub("\\", "\\\239\187\191"):gsub("{", "\\{"):gsub("^ ", "\\h")

        -- Check if the path contains any custom tags
        local prefix = ""
        local prefix_length = ""
        local highlightColor = ""
        if o.custom_colors then
            for _, tag in ipairs(custom_colors) do
                if list[size-start-i+1].path:lower():match(tag.pattern) then
                    if tag.prefix and tag.prefix ~= "" then
                        prefix = string.format("{\\q2}{\\1c&H%s}%s ", tag.prefixColor ~= "" and tag.prefixColor:gsub("(%x%x)(%x%x)(%x%x)", "%3%2%1") or "00FF00", tag.prefix) .. hi_end
                        prefix_length = tag.prefix
                    end
                    highlightColor = tag.highlightColor:gsub("(%x%x)(%x%x)(%x%x)", "%3%2%1")
                    break
                end
            end
        end

        -- Apply the highlightColor (if specified)
        local hi_start = highlightColor ~= "" and string.format("{\\1c&H%s}", highlightColor) or hi_start

        if i == choice+1 then
            msg = msg..hi_start.."("..key..")  "..(prefix ~= "" and prefix..hi_start or "") ..strip_title(p, nil, prefix_length).."\\N\\N"..hi_end
        else
            msg = msg.."("..key..")  "          ..(prefix ~= "" and prefix or "")           ..strip_title(p, nil, prefix_length).."\\N\\N"
        end
        if not list_drawn then
            print("("..key..") "..p)
        end
    end
    if o.ellipsis then
        msg = msg .. (start+10 < size and "..." or "\\h")
    end
    mp.set_osd_ass(0, 0, msg)
end

function page_move(list, start, choice, direction)
    local max_start = math.max(#list - 10, 0)

    -- Handle PGUP (moving up)
    if direction < 0 then
        if start == 0 and choice == 0 then
            return start, choice  -- Already at the very top, no change
        elseif start == 0 and choice > 0 then
            choice = 0  -- Move selection to the very top
        else
            start = math.max(0, start + direction)  -- Normal move up
        end
    -- Handle PGDWN (moving down)
    elseif direction > 0 then
        if start == max_start and choice == math.min(#list - start, 10) - 1 then
            return start, choice  -- Already at the very bottom, no change
        elseif start == max_start and choice < math.min(#list - start, 10) - 1 then
            choice = math.min(#list - start, 10) - 1  -- Move selection to the very bottom
        else
            start = math.min(max_start, start + direction)  -- Normal move down
        end
    end

    draw_list(list, start, choice)
    return start, choice
end

-- Handle up/down keys
function select(list, start, choice, inc)
    if inc == "start" then
        start, choice = 0, 0
    elseif inc == "end" then
        start = math.max(#list - 10, 0)
        choice = math.min(#list, 10) - 1
    else
        choice = choice + inc
        if choice < 0 then
            choice = 0
            start = start + inc
        elseif choice >= math.min(#list, 10) then
            choice = math.min(#list, 10) - 1
            start = start + inc
        end
        start = math.max(math.min(start, #list - 10), 0)
    end
    draw_list(list, start, choice)
    return start, choice
end

-- Delete selected entry from the log
function delete(list, start, choice)
    local playing_path = cur_path
    cur_path = list[#list-start-choice].path
    if not cur_path then
        print("Failed to delete")
        return
    end
    write_log(true)
    print("Deleted \""..cur_path.."\"")
    cur_path = playing_path
end

-- Load file and remove binds
function load(list, start, choice, action)
    unbind()
    if start+choice >= #list then return end
    if o.write_watch_later then
        mp.command("write-watch-later-config")
    end
    local path = list[#list-start-choice].path
    action = action or "replace"
    mp.commandv("loadfile", path, action)
    if action == "append-play" then
        mp.osd_message("Appending: " .. (is_protocol(path) and path or split_ext(get_filename({path = path}))))
    end
end

-- play last played file
function play_last()
    local lists = read_log_table()
    if not lists or not lists[1] then
        return
    end
    mp.commandv("loadfile", lists[#lists].path, "replace")
end

-- Open the recent submenu for uosc
function open_menu(lists)
    local script_name = mp.get_script_name()
    local menu = {
        type = 'recent_menu',
        title = 'Recent',
        on_close = {"script-message-to", script_name, "recent-uosc-closed"},
        items = { { title = 'Nothing here', value = 'ignore' } },
    }
    if #lists > o.list_show_amount then
        length = o.list_show_amount
    else
        length = #lists
    end
    for i = 1, length do
        menu.items[i] = {
            title = (o.show_paths or uosc_opened) and strip_title(lists[#lists-i+1].path, true)
            or strip_title(lists[#lists-i+1].title, true),
            hint = get_ext(lists[#lists-i+1].path),
            value = { "loadfile", lists[#lists-i+1].path, "replace" },
        }
    end
    local json = utils.format_json(menu)
    mp.commandv("script-message-to", "uosc", not uosc_menu_opened and "open-menu" or "update-menu", json)
    uosc_menu_opened = true
end

-- Display list and add keybinds
function display_list()
    if list_drawn then
        unbind()
        return
    end
    local list = read_log_table()
    if not list or not list[1] then
        mp.osd_message("Log empty")
        return
    end
    if o.hide_same_dir then
        list = hide_same_dir(list)
    end
    if not o.use_uosc_menu and uosc_menu_opened then
        mp.commandv("script-message-to", mp.get_script_name(), "recent-uosc-closed")
    end
    if o.use_uosc_menu and uosc_available then
        if uosc_menu_opened then mp.commandv('script-message-to', 'uosc', 'close-menu')
            mp.commandv("script-message-to", mp.get_script_name(), "recent-uosc-closed") 
            return
        end
        open_menu(list) 
        if o.double_menu_key then uosc_opened = true end 
        return
    end
    local choice = 0
    local start = 0
    draw_list(list, start, choice)
    list_drawn = true

    -- Navigation keys
    mp.add_forced_key_binding("UP",                 "recent-UP",             function() start, choice = select(list, start, choice, -1)      end, {repeatable=true})
    mp.add_forced_key_binding("DOWN",               "recent-DOWN",           function() start, choice = select(list, start, choice, 1)       end, {repeatable=true})
    mp.add_forced_key_binding("PGUP",               "recent-PGUP",           function() start, choice = page_move(list, start, choice, -10)  end, {repeatable=true})
    mp.add_forced_key_binding("PGDWN",              "recent-PGDWN",          function() start, choice = page_move(list, start, choice, 10)   end, {repeatable=true})
    mp.add_forced_key_binding("HOME",               "recent-HOME",           function() start, choice = select(list, start, choice, "start") end)
    mp.add_forced_key_binding("END",                "recent-END",            function() start, choice = select(list, start, choice, "end")   end)
    -- Selection keys
    mp.add_forced_key_binding("ENTER",              "recent-ENTER",          function() load(list, start, choice)                            end)
    mp.add_forced_key_binding("KP_ENTER",           "recent-KP_ENTER",       function() load(list, start, choice)                            end)
    mp.add_forced_key_binding("SHIFT+ENTER",        "recent-SHIFT_ENTER",    function() load(list, start, choice, "append-play")             end)
    mp.add_forced_key_binding("SHIFT+KP_ENTER",     "recent-SHIFT_KP_ENTER", function() load(list, start, choice, "append-play")             end)
    mp.add_forced_key_binding("Space",              "recent-Space",          function() load(list, start, choice)                            end)
    -- Exit keys
    mp.add_forced_key_binding("BS",  "recent-BS",  unbind)
    mp.add_forced_key_binding("ESC", "recent-ESC", unbind)
    -- Mouse controls
    if o.mouse_controls then
        mp.add_forced_key_binding("WHEEL_UP",       "recent-WUP",            function() start, choice = select(list, start, choice, -1) end)
        mp.add_forced_key_binding("WHEEL_DOWN",     "recent-WDOWN",          function() start, choice = select(list, start, choice, 1)  end)
        mp.add_forced_key_binding("MBTN_MID",       "recent-MMID",           function() load(list, start, choice)                       end)
        mp.add_forced_key_binding("SHIFT+MBTN_MID", "recent-SHIFT_MMID",     function() load(list, start, choice, "append-play")        end)
        mp.add_forced_key_binding("MBTN_RIGHT",     "recent-MRIGHT",         unbind)
    end
    -- Deletion key
    mp.add_forced_key_binding("DEL", "recent-DEL", function()
        delete(list, start, choice)
        list = read_log_table()
        if not list or not list[1] then
            unbind()
            return
        end
        start, choice = select(list, start, choice, 0)
    end)
    -- Number keys (1 to 0) 
    for i = 1, 10 do
        local key = tostring(i == 10 and 0 or i)
        mp.add_forced_key_binding(key, "recent-" .. key, function() load(list, start, i - 1) end)
    end
end

if o.double_menu_key then
    -- Press %o.display_bind% to open normal menu, hold to open uosc menu
    mp.add_key_binding(o.display_bind, "display-recent", function(keypress)
        if keypress.event == "down" and uosc_available then
            long_press = false
            key_timer = mp.add_timeout(.2, function()
                if list_drawn then unbind() end
                local list = read_log_table()
                open_menu(list)
                long_press = true
                uosc_opened = not uosc_opened
            end)
        elseif keypress.event == "up" then
            if key_timer and key_timer:is_enabled() then key_timer:kill() end
            if not long_press then
                mp.commandv('script-message-to', 'uosc', 'close-menu')
                display_list()
            end
        end
    end, {complex=true})
else
    mp.add_key_binding(o.display_bind, "display-recent", display_list)
end

local function run_idle()
    mp.observe_property("idle-active", "bool", function(_, v)
        if o.auto_run_idle and v and not use_uosc_menu then
            display_list()
        end
    end)
end

-- mpv-menu-plugin integration
mp.register_script_message('menu-ready', function()
    dyn_menu.ready = true
    update_dyn_menu_items()
end)

-- check if uosc is running
mp.register_script_message('uosc-version', function(version)
    uosc_available = true
    uosc_menu_opened = false
end)

mp.register_script_message("recent-uosc-closed", function()
    uosc_menu_opened = false
    uosc_opened = false
end)

mp.observe_property("display-hidpi-scale", "native", function(_, scale)
    if scale then
        display_scale = scale
        run_idle()
    end
end)

mp.register_event("file-loaded", function()
    unbind()
    cur_title, cur_path = get_path()

    -- Use the original hook method if the skip past value is changed
    if o.auto_save_skip_past == 100 then
        file_load(false)
    elseif not hook_added then
        mp.add_hook("on_unload", 9, function ()
            file_load(true)
        end)
        hook_added = true
    end
end)

function file_load(from_hook)
    if not o.auto_save then return end

    local save = function()
        local pos = mp.get_property("percent-pos")
        if not pos then return end
        if tonumber(pos) <= o.auto_save_skip_past then
            write_log(false)
        else
            write_log(true)
        end
    end

    if from_hook then
        save()
    else
        local timeout = is_protocol(mp.get_property("path")) and .03 or .001
        mp.add_timeout(timeout, save)
    end
end

mp.add_key_binding(o.save_bind, "recent-save", function()
    write_log(false)
    mp.osd_message("Saved entry to log")
end)
mp.add_key_binding(nil, "play-last", play_last)
