-- Copyright (c) 2023-2024 tsl0922. All rights reserved.
-- SPDX-License-Identifier: GPL-2.0-only

local opts = require('mp.options')
local utils = require('mp.utils')
local msg = require('mp.msg')

-- user options
local o = {
    uosc_syntax = false,     -- toggle uosc menu syntax support
    max_title_length = 80,   -- limit the title length, set to 0 to disable.
    max_playlist_items = 20, -- limit the playlist items in submenu, set to 0 to disable.
}
opts.read_options(o)

local menu_native = 'menu'               -- dll client name
local menu_prop = 'user-data/menu/items' -- menu data property
local menu_items = {}                    -- raw menu data
local menu_items_dirty = false           -- menu data dirty flag
local dyn_menus = {}                     -- dynamic menu list
local keyword_to_menu = {}               -- keyword -> menu
local has_uosc = false                   -- uosc installed flag

-- lua expression compiler (copied from mpv auto_profiles.lua)
------------------------------------------------------------------------
local watched_properties = {}  -- indexed by property name (used as a set)
local cached_properties = {}   -- property name -> last known raw value
local properties_to_menus = {} -- property name -> set of menus using it
local have_dirty_menus = false -- at least one menu is marked dirty

-- Used during evaluation of the menu update
local current_menu = nil

-- Cached set of all top-level mpv properities. Only used for extra validation.
local property_set = {}
for _, property in pairs(mp.get_property_native("property-list")) do
    property_set[property] = true
end

local function on_property_change(name, val)
    cached_properties[name] = val
    -- Mark all menus reading this property as dirty, so they get re-evaluated
    -- the next time the script goes back to sleep.
    local dependent_menus = properties_to_menus[name]
    if dependent_menus then
        for menu, _ in pairs(dependent_menus) do
            menu.dirty = true
            have_dirty_menus = true
        end
    end
end

function get(name, default)
    -- Normally, we use the cached value only
    if not watched_properties[name] then
        watched_properties[name] = true
        local res, err = mp.get_property_native(name)
        -- Property has to not exist and the toplevel of property in the name must also
        -- not have an existing match in the property set for this to be considered an error.
        -- This allows things like user-data/test to still work.
        if err == "property not found" and property_set[name:match("^([^/]+)")] == nil then
            msg.error("Property '" .. name .. "' was not found.")
            return default
        end
        cached_properties[name] = res
        mp.observe_property(name, "native", on_property_change)
    end
    -- The first time the property is read we need add it to the
    -- properties_to_menus table, which will be used to mark the menu
    -- dirty if a property referenced by it changes.
    if current_menu then
        local map = properties_to_menus[name]
        if not map then
            map = {}
            properties_to_menus[name] = map
        end
        map[current_menu] = true
    end
    local val = cached_properties[name]
    if val == nil then
        val = default
    end
    return val
end

local function magic_get(name)
    -- Lua identifiers can't contain "-", so in order to match with mpv
    -- property conventions, replace "_" to "-"
    name = string.gsub(name, "_", "-")
    return get(name, nil)
end

local evil_magic = {}
setmetatable(evil_magic, {
    __index = function(table, key)
        -- interpret everything as property, unless it already exists as
        -- a non-nil global value
        local v = _G[key]
        if type(v) ~= "nil" then
            return v
        end
        return magic_get(key)
    end,
})

p = {}
setmetatable(p, {
    __index = function(table, key)
        return magic_get(key)
    end,
})

local function compile_expr(name, s)
    local code, chunkname = "return " .. s, "expr " .. name
    local chunk, err
    if setfenv then -- lua 5.1
        chunk, err = loadstring(code, chunkname)
        if chunk then
            setfenv(chunk, evil_magic)
        end
    else -- lua 5.2
        chunk, err = load(code, chunkname, "t", evil_magic)
    end
    if not chunk then
        msg.error("expr '" .. name .. "' : " .. err)
        chunk = function() return false end
    end
    return chunk
end
------------------------------------------------------------------------

-- escape codec name to make it more readable
local function escape_codec(str)
    if not str or str == '' then return '' end
    if str:find("mpeg2") then return "mpeg2"
    elseif str:find("dvvideo") then return "dv"
    elseif str:find("pcm") then return "pcm"
    elseif str:find("pgs") then return "pgs"
    elseif str:find("subrip") then return "srt"
    elseif str:find("vtt") then return "vtt"
    elseif str:find("dvd_sub") then return "vob"
    elseif str:find("dvb_sub") then return "dvb"
    elseif str:find("dvb_tele") then return "teletext"
    elseif str:find("arib") then return "arib"
    else return str end
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

-- abbreviate title if it's too long
local function abbr_title(str)
    if not str or str == '' then return '' end
    if o.max_title_length > 0 and str:len() > o.max_title_length then
        return utf8_sub(str, 1, o.max_title_length) .. '...'
    end
    return str
end

-- build track title from track metadata
--
-- example:
--        V: Video 1 [h264, 1920x1080, 23.976 fps] (*)        JPN
--        |     |               |                   |          |
--       type  title          hints               default     lang
local function build_track_title(track, prefix, filename)
    local type = track.type
    local title = track.title or ''
    local lang = track.lang or ''
    local codec = escape_codec(track.codec)

    -- remove filename from title if it's external track
    if track.external and title ~= '' then
        if filename ~= '' then title = title:gsub(filename .. '%.?', '') end
        if title:lower() == codec:lower() then title = '' end
    end
    -- set a default title if it's empty
    if title == '' then
        local name = type:sub(1, 1):upper() .. type:sub(2, #type)
        title = string.format('%s %d', name, track.id)
    else
        title = abbr_title(title)
    end

    -- build hints from track metadata
    local hints = {}
    local function h(value) hints[#hints + 1] = value end
    if codec ~= '' then h(codec) end
    if track['demux-h'] then
        h(track['demux-w'] and (track['demux-w'] .. 'x' .. track['demux-h'] or track['demux-h'] .. 'p'))
    end
    if track['demux-fps'] then h(string.format('%.3g fps', track['demux-fps'])) end
    if track['audio-channels'] then h(track['audio-channels'] .. ' ch') end
    if track['demux-samplerate'] then h(string.format('%.3g kHz', track['demux-samplerate'] / 1000)) end
    if track['demux-bitrate'] then h(string.format('%.3g kbps', track['demux-bitrate'] / 1000)) end
    if #hints > 0 then title = string.format('%s [%s]', title, table.concat(hints, ', ')) end

    -- put some important info at the end
    if track.forced then title = title .. ' (forced)' end
    if track.external then title = title .. ' (external)' end
    if track.default then title = title .. ' (*)' end

    -- show language at right side (\t is used to right align the text)
    if lang ~= '' then title = string.format('%s\t%s', title, lang:upper()) end
    -- prepend a 1-letter type prefix, used when displaying multiple track types
    if prefix then title = string.format('%s: %s', type:sub(1, 1):upper(), title) end
    return title
end

-- build track menu items from track list for given type
local function build_track_items(list, type, prop, prefix)
    local items = {}

    -- filename without extension, escaped for pattern matching
    local filename = get('filename/no-ext', ''):gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0")
    local pos = tonumber(get(prop)) or -1
    for _, track in ipairs(list) do
        if track.type == type then
            local state = {}
            -- there may be 2 tracks selected at the same time, for example: subtitle
            if track.selected then
                table.insert(state, 'checked')
                if track.id ~= pos then table.insert(state, 'disabled') end
            end

            items[#items + 1] = {
                title = build_track_title(track, prefix, filename),
                cmd = string.format('set %s %d', prop, track.id),
                state = state,
            }
        end
    end

    -- add an extra item to disable or re-enable the track
    if #items > 0 then
        local title = pos > 0 and 'Off' or 'Auto'
        local value = pos > 0 and 'no' or 'auto'
        if prefix then title = string.format('%s: %s', type:sub(1, 1):upper(), title) end

        items[#items + 1] = {
            title = title,
            cmd = string.format('set %s %s', prop, value),
        }
    end

    return items
end

-- update menu item to a submenu
local function to_submenu(item)
    item.type = 'submenu'
    item.submenu = {}
    item.cmd = nil

    menu_items_dirty = true

    return item.submenu
end

-- handle #@tracks menu update
local function update_tracks_menu(menu)
    local submenu = to_submenu(menu.item)
    local track_list = get('track-list', {})
    if #track_list == 0 then return end

    local items_v = build_track_items(track_list, 'video', 'vid', true)
    local items_a = build_track_items(track_list, 'audio', 'aid', true)
    local items_s = build_track_items(track_list, 'sub', 'sid', true)

    -- append video/audio/sub tracks into one submenu, separated by a separator
    for _, item in ipairs(items_v) do table.insert(submenu, item) end
    if #submenu > 0 and #items_a > 0 then table.insert(submenu, { type = 'separator' }) end
    for _, item in ipairs(items_a) do table.insert(submenu, item) end
    if #submenu > 0 and #items_s > 0 then table.insert(submenu, { type = 'separator' }) end
    for _, item in ipairs(items_s) do table.insert(submenu, item) end
end

-- handle #@tracks/<type> menu update for given type
local function update_track_menu(menu, type, prop)
    local submenu = to_submenu(menu.item)
    local track_list = get('track-list', {})
    if #track_list == 0 then return end

    local items = build_track_items(track_list, type, prop, false)
    for _, item in ipairs(items) do table.insert(submenu, item) end
end

-- handle #@chapters menu update
local function update_chapters_menu(menu)
    local submenu = to_submenu(menu.item)
    local chapter_list = get('chapter-list', {})
    if #chapter_list == 0 then return end

    local pos = get('chapter', -1)
    for id, chapter in ipairs(chapter_list) do
        local title = abbr_title(chapter.title)
        if title == '' then title = 'Chapter ' .. id end
        local time = string.format('%02d:%02d:%02d', chapter.time / 3600, chapter.time / 60 % 60, chapter.time % 60)

        submenu[#submenu + 1] = {
            title = string.format('%s\t[%s]', title, time),
            cmd = string.format('seek %f absolute', chapter.time),
            state = id == pos + 1 and { 'checked' } or {},
        }
    end
end

-- handle #@edition menu update
local function update_editions_menu(menu)
    local submenu = to_submenu(menu.item)
    local edition_list = get('edition-list', {})
    if #edition_list == 0 then return end

    local current = get('current-edition', -1)
    for id, edition in ipairs(edition_list) do
        local title = abbr_title(edition.title)
        if title == '' then title = 'Edition ' .. id end
        if edition.default then title = title .. ' [default]' end
        submenu[#submenu + 1] = {
            title = title,
            cmd = string.format('set edition %d', id - 1),
            state = id == current + 1 and { 'checked' } or {},
        }
    end
end

-- handle #@audio-devices menu update
local function update_audio_devices_menu(menu)
    local submenu = to_submenu(menu.item)
    local device_list = get('audio-device-list', {})
    if #device_list == 0 then return end

    local current = get('audio-device', '')
    for _, device in ipairs(device_list) do
        submenu[#submenu + 1] = {
            title = device.description or device.name,
            cmd = string.format('set audio-device %s', device.name),
            state = device.name == current and { 'checked' } or {},
        }
    end
end

-- build playlist item title
local function build_playlist_title(item, id)
    local title = item.title or ''
    local ext = ''
    if item.filename and item.filename ~= '' then
        local _, filename = utils.split_path(item.filename)
        local n, e = filename:match('^(.+)%.([%w-_]+)$')
        if title == '' then title = n and n or filename end
        if e then ext = e end
    end
    title = title ~= '' and abbr_title(title) or 'Item ' .. id
    return ext ~= '' and title .. "\t" .. ext:upper() or title
end

-- handle #@playlist menu update
local function update_playlist_menu(menu)
    local submenu = to_submenu(menu.item)
    local playlist = get('playlist', {})
    if #playlist == 0 then return end

    for id, item in ipairs(playlist) do
        if o.max_playlist_items > 0 and id > o.max_playlist_items then break end
        submenu[#submenu + 1] = {
            title = build_playlist_title(item, id - 1),
            cmd = string.format('playlist-play-index %d', id - 1),
            state = item.current and { 'checked' } or {},
        }
    end

    if o.max_playlist_items > 0 and #playlist > o.max_playlist_items then
        submenu[#submenu + 1] = {
            title = string.format('...\t[%d]', #playlist - o.max_playlist_items),
            cmd = has_uosc and 'script-message-to uosc playlist' or 'ignore',
        }
    end
end

-- handle #@profiles menu update
local function update_profiles_menu(menu)
    local submenu = to_submenu(menu.item)
    local profile_list = get('profile-list', {})
    if #profile_list == 0 then return end

    for _, profile in ipairs(profile_list) do
        if not (profile.name == 'default' or profile.name:find('gui') or
                profile.name == 'encoding' or profile.name == 'libmpv') then
            submenu[#submenu + 1] = {
                title = profile.name,
                cmd = string.format('show-text %s; apply-profile %s', profile.name, profile.name),
            }
        end
    end
end

-- handle menu state update
local function update_menu_state(menu)
    if not menu.state then return end
    local status, res = pcall(menu.state)
    if not status then
        msg.verbose("state expr error on evaluating: " .. res)
        return
    end

    local state = {}
    if type(res) == 'string' then
        for s in res:gmatch('[^,%s]+') do table.insert(state, s) end
    end
    menu.item.state = state
    menu_items_dirty = true
end

-- dynamic menu updaters
local dyn_updaters = {
    ['tracks'] = update_tracks_menu,
    ['tracks/video'] = function(menu) update_track_menu(menu, 'video', 'vid') end,
    ['tracks/audio'] = function(menu) update_track_menu(menu, 'audio', 'aid') end,
    ['tracks/sub'] = function(menu) update_track_menu(menu, 'sub', 'sid') end,
    ['tracks/sub-secondary'] = function(menu) update_track_menu(menu, 'sub', 'secondary-sid') end,
    ['chapters'] = update_chapters_menu,
    ['editions'] = update_editions_menu,
    ['audio-devices'] = update_audio_devices_menu,
    ['playlist'] = update_playlist_menu,
    ['profiles'] = update_profiles_menu,
}

-- handle dynamic menu update
local function update_menu(menu)
    if menu.updater then
        msg.debug('update menu: ' .. menu.item.title)
        current_menu = menu
        menu.updater(menu)
        current_menu = nil
    end
end

-- load dynamic menu item
local function dyn_menu_load(item, keyword)
    local menu = {
        item = item,
        updater = nil,
        state = nil,
        dirty = false,
    }
    table.insert(dyn_menus, menu)
    local list = keyword_to_menu[keyword] or {}
    list[#list+1] = menu
    keyword_to_menu[keyword] = list
    list = nil

    local expr = keyword:match('^state=(.-)%s*$')
    if expr then
        menu.updater = update_menu_state
        menu.state = compile_expr(string.format('[%s]:%s', item.title, keyword), expr)
    else
        keyword = keyword:match('^([%S]+).*$')
        menu.updater = dyn_updaters[keyword]
    end

    -- update menu immediately
    if menu.updater then update_menu(menu) end
end

-- find #@keyword for dynamic menu and handle updates
--
-- cplugin will keep the trailing comments in the cmd field, so we can
-- parse the keyword from it.
--
-- example: ignore        #menu: Chapters #@chapters    # extra comment
local function dyn_menu_check(items)
    if not items then return end
    for _, item in ipairs(items) do
        if item.type == 'submenu' then
            dyn_menu_check(item.submenu)
        else
            if item.type ~= 'separator' and item.cmd then
                local keyword = item.cmd:match('%s*#@(.-)%s*$') or ''
                if keyword ~= '' then
                    msg.debug('load menu: ' .. item.title, ', keyword: ' .. keyword)
                    dyn_menu_load(item, keyword)
                end
            end
        end
    end
end

-- load dynamic menus
local function load_dyn_menus()
    dyn_menu_check(menu_items)

    -- broadcast menu ready message
    mp.commandv('script-message', 'menu-ready', mp.get_script_name())
end

-- script message: list <src>
mp.register_script_message('list', function(src)
    local list = {}
    for name, _ in pairs(keyword_to_menu) do
        list[#list + 1] = name
    end

    mp.commandv('script-message-to', src, 'menu-list-reply', utils.format_json(list))
end)

-- script message: get <keyword> <src>
mp.register_script_message('get', function(keyword, src)
    if not src or src == '' then
        msg.debug('get: ignored message with empty src')
        return
    end

    local list = keyword_to_menu[keyword] or nil
    local reply = { keyword = keyword }

    if not list then
        reply.error = 'keyword not found'
        return
    end

    for id, menu in ipairs(list) do
        reply.item = menu.item
        reply.id = id
        mp.commandv('script-message-to', src, 'menu-get-reply', utils.format_json(reply))
    end
end)

-- script message: update <keyword> <json> <opt:id>
mp.register_script_message('update', function(keyword, json, id)
    local list = keyword_to_menu[keyword] or nil
    if not list then
        msg.debug('update: ignored message with invalid keyword:', keyword)
        return
    end

    local data, err = utils.parse_json(json)
    if err then msg.error('update: failed to parse json:', err) end
    if not data or next(data) == nil then
        msg.debug('update: ignored message with invalid json:', json)
        return
    end

    local function update(menu)
        local item = menu.item
        if not data.title or data.title == '' then data.title = item.title end
        if not data.type or data.type == '' then data.type = item.type end

        for k, _ in pairs(item) do item[k] = nil end
        for k, v in pairs(data) do item[k] = v end
    end
    if not id then
        for _, menu in ipairs(list) do
            update(menu)
        end
    else
        local pos = tonumber(id)
        if not pos then msg.error('update: ignored message with invalid json:', json) return end
        local menu = list[pos]
        update(menu)
    end

    menu_items_dirty = true
end)

-- script binding: show
mp.add_key_binding('MBTN_RIGHT', 'show', function()
    mp.commandv('script-message-to', menu_native, 'show')
end)

-- detect dll client name
mp.register_script_message('menu-init', function(name) menu_native = name end)

-- detect uosc installation
mp.register_script_message('uosc-version', function() has_uosc = true end)

-- update menu on idle, this reduces the update frequency
mp.register_idle(function()
    if have_dirty_menus then
        for _, menu in ipairs(dyn_menus) do
            if menu.dirty then
                update_menu(menu)
                menu.dirty = false
            end
        end
        have_dirty_menus = false
    end

    if menu_items_dirty then
        msg.debug('commit menu items: ' .. menu_prop)
        mp.set_property_native(menu_prop, menu_items)
        menu_items_dirty = false
    end
end)

-- read input.conf content
local function get_input_conf()
    local prop = mp.get_property_native('input-conf')
    if prop:sub(1, 9) == 'memory://' then return prop:sub(10) end

    prop = prop == '' and '~~/input.conf' or prop
    local conf_path = mp.command_native({ 'expand-path', prop })

    local f, err = io.open(conf_path, 'rb')
    if not f then
        msg.error('failed to open file: ' .. conf_path)
        return nil
    end

    local conf = f:read('*all')
    f:close()
    return conf
end

-- parse input.conf, return menu items
local function parse_input_conf(conf)
    local items = {}
    local by_id = {}

    local function extract_title(cmd)
        if not cmd or cmd == '' then return '' end
        local title = cmd:match('#menu:%s*(.*)%s*')
        if not title and o.uosc_syntax then title = cmd:match('#!%s*(.*)%s*') end
        if title then title = title:match('(.-)%s*#.*$') or title end
        return title or ''
    end

    local function split_title(title)
        local list = {}
        if not title or title == '' then return list end

        local pattern = '(.-)%s*>%s*'
        local last_ends = 1
        local starts, ends, match = title:find(pattern)
        while starts do
            list[#list + 1] = match
            last_ends = ends + 1
            starts, ends, match = title:find(pattern, last_ends)
        end
        if last_ends < (#title + 1) then list[#list + 1] = title:sub(last_ends) end

        return list
    end

    for line in conf:gmatch('[^\r\n]+') do
        if line:sub(1, 1) ~= '#' or o.uosc_syntax then
            local key, cmd = line:match('%s*([%S]+)%s+(.-)%s*$')
            local title = extract_title(cmd)
            local list = split_title(title)

            local submenu_id = ''
            local target_menu = items

            for id, name in ipairs(list) do
                if id < #list then
                    submenu_id = submenu_id .. name
                    if not by_id[submenu_id] then
                        local submenu = {}
                        by_id[submenu_id] = submenu
                        target_menu[#target_menu + 1] = {
                            title = name,
                            type = 'submenu',
                            submenu = submenu,
                        }
                    end
                    target_menu = by_id[submenu_id]
                else
                    if name == '-' or (o.uosc_syntax and name:sub(1, 3) == '---') then
                        target_menu[#target_menu + 1] = {
                            type = 'separator',
                        }
                    else
                        target_menu[#target_menu + 1] = {
                            title = (key ~= '' and key ~= '_') and (name .. "\t" .. key) or name,
                            cmd = cmd,
                        }
                    end
                end
            end
        end
    end

    return items
end

-- load menu data from input.conf
--
-- NOTE: to simplify the code, we don't watch for the menu data change event, this
--       make it conflict with other scripts that also update the menu data property.
local conf = get_input_conf()
if conf then
    menu_items = parse_input_conf(conf)
    menu_items_dirty = true
    load_dyn_menus()
end
