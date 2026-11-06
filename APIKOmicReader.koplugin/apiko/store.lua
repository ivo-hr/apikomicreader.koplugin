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

-- Chapter metadata --------------------------------------------------------------
-- Which title a downloaded chapter belongs to, so the library can group them.
-- Key: "<source>_<chapter id>". Value: { series = "title", number = 12 }.

function Store.setChapterMeta(key, series, number)
    local map = get("chapter_meta")
    map[key] = { series = series, number = number }
    put("chapter_meta", map)
end

function Store.chapterMeta(key)
    return get("chapter_meta")[key]
end

function Store.removeChapterMeta(key)
    local map = get("chapter_meta")
    if map[key] == nil then return end
    map[key] = nil
    put("chapter_meta", map)
end

-- Collections -------------------------------------------------------------------
-- Named groups of library titles, made by the user. Entries:
-- { source = id, id = "...", name = "...", members = { "<title key>", ... } }

local function newId()
    return string.format("%d%04d", os.time(), math.random(0, 9999))
end

function Store.collections(source_id)
    return ofSource(get("collections"), source_id)
end

function Store.collection(source_id, id)
    for __, c in ipairs(get("collections")) do
        if c.source == source_id and c.id == id then return c end
    end
end

function Store.addCollection(source_id, name)
    local list = get("collections")
    local entry = { source = source_id, id = newId(), name = name, members = {} }
    table.insert(list, entry)
    put("collections", list)
    return entry
end

function Store.renameCollection(id, name)
    local list = get("collections")
    for __, c in ipairs(list) do
        if c.id == id then c.name = name end
    end
    put("collections", list)
end

function Store.deleteCollection(id)
    local list = get("collections")
    for i = #list, 1, -1 do
        if list[i].id == id then table.remove(list, i) end
    end
    put("collections", list)
end

function Store.inCollection(collection, key)
    for __, k in ipairs(collection.members) do
        if k == key then return true end
    end
    return false
end

function Store.collectionAdd(id, key)
    local list = get("collections")
    for __, c in ipairs(list) do
        if c.id == id and not Store.inCollection(c, key) then table.insert(c.members, key) end
    end
    put("collections", list)
end

function Store.collectionRemove(id, key)
    local list = get("collections")
    for __, c in ipairs(list) do
        if c.id == id then
            for i = #c.members, 1, -1 do
                if c.members[i] == key then table.remove(c.members, i) end
            end
        end
    end
    put("collections", list)
end

-- Download queue ----------------------------------------------------------------
-- Titles, or single chapters, waiting to be downloaded to the library, oldest
-- first. Entries: { id, source, item = { id, title, subtitle, thumb, adult },
-- chapter_id (nil = every chapter), chapter_title, error, time }.

function Store.queue()
    return get("queue")
end

-- True if the whole title is queued, or (when chapter_id is given) that chapter.
function Store.isQueued(source_id, item_id, chapter_id)
    for __, e in ipairs(get("queue")) do
        if e.source == source_id and e.item.id == item_id then
            if e.chapter_id == nil then return true end
            if chapter_id ~= nil and e.chapter_id == chapter_id then return true end
        end
    end
    return false
end

-- chapter: nil for the whole title, or { id, title }. Returns the new entry,
-- or nil if it is already queued.
function Store.addToQueue(source_id, item, chapter)
    if Store.isQueued(source_id, item.id, chapter and chapter.id) then return nil end
    local list = get("queue")
    if not chapter then
        -- The whole title covers any of its chapters queued before.
        for i = #list, 1, -1 do
            if list[i].source == source_id and list[i].item.id == item.id then table.remove(list, i) end
        end
    end
    local entry = {
        id = newId(),
        source = source_id,
        item = {
            id = item.id,
            title = item.title,
            subtitle = item.subtitle,
            thumb = item.thumb,
            adult = item.adult or false,
        },
        chapter_id = chapter and chapter.id or nil,
        chapter_title = chapter and chapter.title or nil,
        time = os.time(),
    }
    table.insert(list, entry)
    put("queue", list)
    return entry
end

function Store.removeFromQueue(id)
    local list = get("queue")
    for i = #list, 1, -1 do
        if list[i].id == id then table.remove(list, i) end
    end
    put("queue", list)
end

function Store.setQueueError(id, err)
    local list = get("queue")
    for __, e in ipairs(list) do
        if e.id == id then e.error = err end
    end
    put("queue", list)
end

function Store.queueToTop(id)
    local list = get("queue")
    for i, e in ipairs(list) do
        if e.id == id then
            table.remove(list, i)
            table.insert(list, 1, e)
            break
        end
    end
    put("queue", list)
end

return Store
