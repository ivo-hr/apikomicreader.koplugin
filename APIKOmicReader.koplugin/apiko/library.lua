-- Groups the comics saved in a source's library by title (series), so the
-- chapters of one manga/comic appear together, and sorts them. The series of
-- a chapter is recorded when it is downloaded (Store.setChapterMeta); older
-- files, saved before that, are grouped by the part of their name before " - ".
local _ = require("gettext")

local Comics = require("apiko.comics")
local Store = require("apiko.store")

local Library = {}

-- Choices for the library (titles and collections) and for the chapters of a title.
Library.GROUP_SORTS = {
    { id = "recent", text = _("Recently added") },
    { id = "oldest", text = _("Oldest first") },
    { id = "name", text = _("Name A-Z") },
    { id = "name_desc", text = _("Name Z-A") },
    { id = "continue", text = _("Continue reading") },
    { id = "unread", text = _("Unread first") },
    { id = "read", text = _("Read first") },
}

Library.CHAPTER_SORTS = {
    { id = "order", text = _("Chapter order") },
    { id = "order_desc", text = _("Newest chapter first") },
    { id = "continue", text = _("Continue reading") },
    { id = "unread", text = _("Unread first") },
}

-- Sorts names so that "ch 2" comes before "ch 10".
local function naturalLess(a, b)
    a, b = a:lower(), b:lower()
    local i, j = 1, 1
    while i <= #a and j <= #b do
        local na, nb = a:match("^%d+", i), b:match("^%d+", j)
        if na and nb then
            local x, y = tonumber(na), tonumber(nb)
            if x ~= y then return x < y end
            i, j = i + #na, j + #nb
        else
            local ca, cb = a:sub(i, i), b:sub(j, j)
            if ca ~= cb then return ca < cb end
            i, j = i + 1, j + 1
        end
    end
    return (#a - i) < (#b - j)
end

-- Same characters the downloader strips from file names, so a recorded
-- series title and the one read back from a file name give the same key.
local function normalize(name)
    name = name:gsub("[%c/\\:%*%?\"<>|]", " "):gsub("%s+", " ")
    return (name:match("^%s*(.-)%s*$")):lower()
end

function Library.key(source_id, name)
    return source_id .. ":" .. normalize(name)
end

-- series name, chapter number (or nil), true if the name was recorded.
local function seriesOf(source_id, comic)
    local meta = Store.chapterMeta(source_id .. "_" .. comic.id)
    if meta and type(meta.series) == "string" and meta.series ~= "" then
        return meta.series, tonumber(meta.number), true
    end
    local head = comic.title:match("^(.-) %- ")
    if head and head ~= "" then return head end
    return comic.title
end

function Library.keyOf(source_id, comic)
    return Library.key(source_id, (seriesOf(source_id, comic)))
end

function Library.nameOf(source_id, comic)
    return (seriesOf(source_id, comic))
end

-- Reading order: by chapter number when every chapter has one, else by name.
local function sortChapterOrder(comics)
    local numbered = true
    for __, c in ipairs(comics) do
        if not c.number then numbered = false break end
    end
    table.sort(comics, function(a, b)
        if numbered and a.number ~= b.number then return a.number < b.number end
        if a.title ~= b.title then return naturalLess(a.title, b.title) end
        return a.path < b.path
    end)
end

-- comics: from Comics.list. Returns groups:
-- { key, name, comics = {...in reading order}, mtime, adult,
--   total, unread, reading, read, last_read }
-- Each comic gets status ("unread"/"reading"/"read"), percent and last_read.
function Library.groups(source_id, comics)
    local by_key, list = {}, {}
    for __, c in ipairs(comics) do
        local name, number, recorded = seriesOf(source_id, c)
        local key = Library.key(source_id, name)
        local g = by_key[key]
        if not g then
            g = {
                key = key, name = name, comics = {}, mtime = 0, adult = false,
                total = 0, unread = 0, reading = 0, read = 0, last_read = 0,
            }
            by_key[key] = g
            table.insert(list, g)
        end
        if recorded then g.name = name end  -- the recorded title is the exact one
        local p = Comics.progress(c.path)
        c.status, c.percent, c.last_read = p.status, p.percent, p.last_read
        c.number = number
        c.group_key = key
        table.insert(g.comics, c)
        g.total = g.total + 1
        g[c.status] = g[c.status] + 1
        if c.mtime > g.mtime then g.mtime = c.mtime end
        if c.last_read > g.last_read then g.last_read = c.last_read end
        if c.adult then g.adult = true end
    end
    for __, g in ipairs(list) do sortChapterOrder(g.comics) end
    return list
end

-- How a title (or collection) ranks in the progress-based orders; lower comes first.
local function rank(mode, g)
    local untouched = g.unread == g.total
    local finished = g.read == g.total
    if mode == "continue" then
        if g.reading > 0 then return 0 end              -- one is half-read
        if not untouched and not finished then return 1 end  -- between chapters
        if untouched then return 2 end
        return 3
    elseif mode == "unread" then
        if untouched then return 0 end
        if not finished then return 1 end
        return 2
    else  -- "read"
        if finished then return 0 end
        if not untouched then return 1 end
        return 2
    end
end

-- Sorts titles (or collections: any entries with name, key, mtime, total,
-- unread, reading, read and last_read) in place.
function Library.sortGroups(list, mode)
    local by_progress = mode == "continue" or mode == "unread" or mode == "read"
    table.sort(list, function(a, b)
        local x, y = (a.name or ""):lower(), (b.name or ""):lower()
        if mode == "name" or mode == "name_desc" then
            if x ~= y then
                local lt, gt = naturalLess(x, y), naturalLess(y, x)
                if lt ~= gt then
                    if mode == "name" then return lt end
                    return gt
                end
            end
        elseif mode == "oldest" then
            if a.mtime ~= b.mtime then return a.mtime < b.mtime end
        elseif by_progress then
            local ra, rb = rank(mode, a), rank(mode, b)
            if ra ~= rb then return ra < rb end
            -- Started titles: most recently read first; the rest: newest first.
            local by_read = (mode == "continue" and (ra == 0 or ra == 1 or ra == 3))
                or (mode == "read" and ra <= 1)
            local ta, tb = by_read and a.last_read or a.mtime, by_read and b.last_read or b.mtime
            if ta ~= tb then return ta > tb end
        else  -- "recent"
            if a.mtime ~= b.mtime then return a.mtime > b.mtime end
        end
        if x ~= y then return x < y end
        return (a.key or "") < (b.key or "")
    end)
end

-- Sorts the chapters of a title (already in reading order, with status) in place.
function Library.sortChapters(comics, mode)
    if mode == "order_desc" then
        local n = #comics
        for i = 1, math.floor(n / 2) do comics[i], comics[n - i + 1] = comics[n - i + 1], comics[i] end
    elseif mode == "continue" or mode == "unread" then
        local index = {}
        for i, c in ipairs(comics) do index[c] = i end
        local function r(c)
            if mode == "continue" then
                return c.status == "reading" and 0 or (c.status == "unread" and 1 or 2)
            end
            return c.status == "unread" and 0 or (c.status == "reading" and 1 or 2)
        end
        table.sort(comics, function(a, b)
            local ra, rb = r(a), r(b)
            if ra ~= rb then return ra < rb end
            if mode == "continue" and ra == 0 and a.last_read ~= b.last_read then
                return a.last_read > b.last_read
            end
            return index[a] < index[b]
        end)
    end
end

return Library
