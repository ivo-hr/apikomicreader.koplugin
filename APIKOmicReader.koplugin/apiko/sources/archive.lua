-- Internet Archive (archive.org): items that contain comic book files
-- (CBZ or CBR). Each comic file in an item is a chapter; its pages are read
-- one by one from inside the archive, which archive.org can list and serve.
local bit = require("bit")
local _ = require("gettext")
local logger = require("logger")
local T = require("ffi/util").template

local Http = require("apiko.http")

local Archive = {
    id = "archive",
    name = "Internet Archive",
    domain = "archive.org",
    base = "https://archive.org",
    order = 20,
    -- archive.org asks automated clients to identify themselves.
    user_agent = "APIKOmicReader/1.0 (KOReader plugin)",
    search_hint = _("Title, series or publisher, or an archive.org link"),
    sorts = {
        { id = "downloads desc", text = _("Most downloaded") },
        { id = "addeddate desc", text = _("Recently added") },
        { id = "titleSorter asc", text = _("Title A-Z") },
    },
}

local PAGE_SIZE = 24
local COMIC_FORMATS = { ["Comic Book ZIP"] = true, ["Comic Book RAR"] = true }
local FORMAT_QUERY = 'format:("Comic Book ZIP" OR "Comic Book RAR")'
local IMAGE_EXT = { jpg = true, jpeg = true, png = true, gif = true, webp = true }

local function str(v)
    if type(v) == "table" then v = v[1] end
    return type(v) == "string" and v ~= "" and v or nil
end

local function num(v)
    if type(v) == "table" then v = v[1] end
    return tonumber(v)
end

local function getJson(self, url)
    return Http.getJson(url, { user_agent = self.user_agent })
end

local function thumbUrl(id)
    return "https://archive.org/services/img/" .. id
end

local function subtitleOf(creator, year)
    local parts = {}
    if creator then table.insert(parts, creator) end
    if year then table.insert(parts, tostring(year)) end
    return #parts > 0 and table.concat(parts, " · ") or nil
end

local function toItem(doc)
    local id = str(doc.identifier)
    if not id then return nil end
    return {
        id = id,
        title = str(doc.title) or id,
        subtitle = subtitleOf(str(doc.creator), num(doc.year)),
        thumb = thumbUrl(id),
        adult = false,
    }
end

-- Item metadata (title, description, file list); cached on the item.
function Archive:metadata(item)
    if item.meta then return item.meta end
    local data, err = getJson(self, "https://archive.org/metadata/" .. item.id)
    if not data then return nil, err end
    if type(data.metadata) ~= "table" or type(data.files) ~= "table" then
        return nil, _("This archive.org item doesn't exist or isn't available.")
    end
    item.meta = data
    return data
end

function Archive:search(query, page, sort)
    query = query:match("^%s*(.-)%s*$")

    -- An archive.org link: open that item directly.
    local linked = query:match("archive%.org/details/([%w%._%-]+)")
    if linked then
        local item = { id = linked }
        local meta, err = self:metadata(item)
        if not meta then return nil, err end
        local m = meta.metadata
        item.title = str(m.title) or linked
        item.subtitle = subtitleOf(str(m.creator), num(m.year))
        item.thumb = thumbUrl(linked)
        item.adult = false
        return { item }, false
    end

    local q = query ~= "" and ("(" .. query .. ") AND " .. FORMAT_QUERY) or FORMAT_QUERY
    local params = {
        "q=" .. Http.urlEncode(q),
        "fl%5B%5D=identifier", "fl%5B%5D=title", "fl%5B%5D=creator", "fl%5B%5D=year",
        "rows=" .. PAGE_SIZE,
        "page=" .. page,
        "output=json",
        "sort%5B%5D=" .. Http.urlEncode(sort or self.sorts[1].id),
    }
    local data, err = getJson(self, "https://archive.org/advancedsearch.php?" .. table.concat(params, "&"))
    if not data then return nil, err end
    local response = type(data.response) == "table" and data.response or {}
    local items = {}
    for __, doc in ipairs(type(response.docs) == "table" and response.docs or {}) do
        local item = toItem(doc)
        if item then table.insert(items, item) end
    end
    return items, page * PAGE_SIZE < (tonumber(response.numFound) or 0)
end

-- HTML from item descriptions, reduced to plain text.
local function plainText(s)
    s = s:gsub("<[Bb][Rr]%s*/?>", "\n"):gsub("</[Pp]>", "\n"):gsub("<[^>]+>", "")
    s = s:gsub("&nbsp;", " "):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&amp;", "&")
    s = s:gsub("\n%s*\n%s*\n+", "\n\n")
    return (s:match("^%s*(.-)%s*$"))
end

local function comicFiles(meta)
    local files = {}
    for __, f in ipairs(meta.files) do
        if type(f) == "table" and str(f.name)
            and (COMIC_FORMATS[f.format] or f.name:lower():match("%.cb[zr]$")) then
            table.insert(files, f.name)
        end
    end
    return files
end

function Archive:describe(item)
    local meta, err = self:metadata(item)
    if not meta then return item.title .. "\n\n" .. err end
    local m = meta.metadata
    local lines = { str(m.title) or item.title, "" }
    if str(m.creator) then table.insert(lines, T(_("By %1"), str(m.creator))) end
    local date = str(m.date) or (num(m.year) and tostring(num(m.year)))
    if date then table.insert(lines, T(_("Date: %1"), date)) end
    local count = #comicFiles(meta)
    table.insert(lines, count == 1 and _("1 comic file") or T(_("%1 comic files"), count))
    local description = str(m.description)
    if description then
        table.insert(lines, "")
        table.insert(lines, plainText(description))
    end
    return table.concat(lines, "\n")
end

-- Sorts names so that "issue 2" comes before "issue 10".
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

-- Short, stable id for a file name (used in downloaded file names).
local function shortHash(s)
    local h = 5381
    for i = 1, #s do
        h = bit.band(h * 33 + s:byte(i), 0xFFFFFFFF)
    end
    return bit.tohex(h, 8)
end

local function fileTitle(name)
    local base = name:match("([^/]+)$"):gsub("%.[^%.]+$", ""):gsub("_", " ")
    return (base:match("^%s*(.-)%s*$"))
end

-- One chapter per comic file, newest (last by name) first.
function Archive:getChapters(item)
    local meta, err = self:metadata(item)
    if not meta then return nil, err end
    local files = comicFiles(meta)
    table.sort(files, naturalLess)
    local chapters = {}
    for i = #files, 1, -1 do
        local name = files[i]
        local title = fileTitle(name)
        table.insert(chapters, {
            id = item.id .. "." .. shortHash(name),
            title = title,
            file = name,
            file_title = #files > 1 and (item.title .. " - " .. title) or item.title,
            item = item,
        })
    end
    return chapters
end

-- archive.org lists the files inside a CBZ/CBR at download/<item>/<file>/.
local function encodePath(path)
    local parts = {}
    for segment in path:gmatch("[^/]+") do table.insert(parts, Http.urlEncode(segment)) end
    return table.concat(parts, "/")
end

function Archive:getPages(chapter)
    local url = string.format("https://archive.org/download/%s/%s/", chapter.item.id, encodePath(chapter.file))
    local html, err = Http.get(url, { user_agent = self.user_agent })
    if not html then return nil, err end
    local entries = {}
    for href, name in html:gmatch('<a href="([^"]+)">([^<]+)</a>') do
        href = href:gsub("&amp;", "&")
        local ext = href:match("%.(%w+)$")
        if href:find("/download/", 1, true) and ext and IMAGE_EXT[ext:lower()] then
            if href:sub(1, 2) == "//" then href = "https:" .. href end
            table.insert(entries, { name = name, url = href, ext = ext:lower() })
        end
    end
    if #entries == 0 then
        logger.warn("APIKOmic: no images listed in", url)
        return nil, _("Couldn't open this comic file on archive.org.")
    end
    table.sort(entries, function(a, b) return naturalLess(a.name, b.name) end)
    local pages = {}
    for i, e in ipairs(entries) do
        pages[i] = { urls = { e.url }, ext = e.ext }
    end
    return pages
end

return Archive
