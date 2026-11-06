-- Recent searches, saved searches and bookmarked comics, kept in the hidden
-- folder rather than in KOReader's settings file. Every entry has a `source`
-- id; the functions here work on one source at a time.
local LuaSettings = require("luasettings")

local Paths = require("apiko.paths")

local Store = {}

local MAX_SEARCHES = 50  -- per source

local db

local function open()
    if not db then db = LuaSettings:open(Paths.root() .. "/data.lua") end
    return db
end

local function get(key)
    return open():readSetting(key) or {}
end

local function put(key, list)
    open():saveSetting(key, list)
    open():flush()
end

local function ofSource(list, source_id)
    local out = {}
    for __, e in ipairs(list) do
        if e.source == source_id then table.insert(out, e) end
    end
    return out
end

local function sameSearch(a, b)
    return a.source == b.source and a.query == b.query and a.sort == b.sort
end

local function removeSearchFrom(key, entry)
    local list = get(key)
    for i = #list, 1, -1 do
        if sameSearch(list[i], entry) then table.remove(list, i) end
    end
    return list
end

-- Recent searches ---------------------------------------------------------------
-- Entries: { source = id, query = "...", sort = "...", time = os.time() }, newest first.

function Store.searches(source_id)
    return ofSource(get("searches"), source_id)
end

function Store.addSearch(source_id, query, sort)
    local entry = { source = source_id, query = query, sort = sort, time = os.time() }
    local list = removeSearchFrom("searches", entry)
    table.insert(list, 1, entry)
    local count = 0
    for i = 1, #list do
        if list[i] and list[i].source == source_id then
            count = count + 1
        end
    end
    for i = #list, 1, -1 do
        if count <= MAX_SEARCHES then break end
        if list[i].source == source_id then
            table.remove(list, i)
            count = count - 1
        end
    end
    put("searches", list)
end

function Store.removeSearch(entry)
    put("searches", removeSearchFrom("searches", entry))
end

function Store.clearSearches(source_id)
    local list = get("searches")
    for i = #list, 1, -1 do
        if list[i].source == source_id then table.remove(list, i) end
    end
    put("searches", list)
end

-- Saved searches ----------------------------------------------------------------
-- Same entries as recent searches, kept until removed; newest first.

function Store.savedSearches(source_id)
    return ofSource(get("saved_searches"), source_id)
end

function Store.isSearchSaved(source_id, query, sort)
    local entry = { source = source_id, query = query, sort = sort }
    for __, e in ipairs(get("saved_searches")) do
        if sameSearch(e, entry) then return true end
    end
    return false
end

-- Returns false if that search was already saved.
function Store.saveSearch(source_id, query, sort)
    if Store.isSearchSaved(source_id, query, sort) then return false end
    local list = get("saved_searches")
    table.insert(list, 1, { source = source_id, query = query, sort = sort, time = os.time() })
    put("saved_searches", list)
    return true
end

function Store.unsaveSearch(entry)
    put("saved_searches", removeSearchFrom("saved_searches", entry))
end

-- Bookmarks ---------------------------------------------------------------------
-- Comics marked for later, without downloading them. Entries:
-- { source = id, id = "...", title = "...", subtitle = "...", thumb = url, adult = bool, time = os.time() }

function Store.bookmarks(source_id)
    return ofSource(get("bookmarks"), source_id)
end

function Store.isBookmarked(source_id, id)
    for __, b in ipairs(get("bookmarks")) do
        if b.source == source_id and b.id == id then return true end
    end
    return false
end

function Store.addBookmark(source_id, item, subtitle)
    if Store.isBookmarked(source_id, item.id) then return end
    local list = get("bookmarks")
    table.insert(list, 1, {
        source = source_id,
        id = item.id,
        title = item.title,
        subtitle = subtitle,
        thumb = item.thumb,
        adult = item.adult or false,
        time = os.time(),
    })
    put("bookmarks", list)
end

function Store.removeBookmark(source_id, id)
    local list = get("bookmarks")
    for i = #list, 1, -1 do
        if list[i].source == source_id and list[i].id == id then table.remove(list, i) end
    end
    put("bookmarks", list)
end

return Store
