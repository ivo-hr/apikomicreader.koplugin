-- MangaDex (mangadex.org), through its public API (api.mangadex.org).
-- Titles have chapters; each chapter is downloaded as its own CBZ.
local _ = require("gettext")
local logger = require("logger")
local T = require("ffi/util").template

local Http = require("apiko.http")

local MangaDex = {
    id = "mangadex",
    name = "MangaDex",
    domain = "mangadex.org",
    base = "https://mangadex.org",
    order = 10,
    -- Mixed content: adult titles are flagged one by one (content rating).
    adult = false,
    -- MangaDex asks clients to identify themselves instead of posing as a browser.
    user_agent = "APIKOmicReader/1.0 (KOReader plugin)",
    search_hint = _("Title, or a MangaDex link (empty = browse)"),
    sorts = {
        { id = "relevance", text = _("Relevance") },
        { id = "followedCount", text = _("Most followed") },
        { id = "latestUploadedChapter", text = _("Latest chapters") },
        { id = "createdAt", text = _("Newest titles") },
        { id = "rating", text = _("Top rated") },
    },
}

local API = "https://api.mangadex.org"
local COVERS = "https://uploads.mangadex.org/covers"
local PAGE_SIZE = 24
local SAFE_RATINGS = { "safe", "suggestive" }
local ALL_RATINGS = { "safe", "suggestive", "erotica", "pornographic" }
local ADULT_RATINGS = { erotica = true, pornographic = true }

local function str(v)
    return type(v) == "string" and v ~= "" and v or nil
end

-- "name[]=a&name[]=b", with the brackets encoded.
local function arrayParam(name, values)
    local parts = {}
    for __, v in ipairs(values) do
        table.insert(parts, name .. "%5B%5D=" .. Http.urlEncode(v))
    end
    return table.concat(parts, "&")
end

local function getJson(self, path)
    local data, err = Http.getJson(API .. path, { user_agent = self.user_agent })
    if not data then return nil, err end
    if data.result == "error" then
        local e = type(data.errors) == "table" and data.errors[1] or {}
        return nil, T(_("MangaDex error: %1"), tostring(e.detail or e.title or "?"))
    end
    return data
end

-- Text from a {lang = text} map: the wanted language, then English, then any.
-- The API sends an empty array instead of an empty map in some places.
local function localized(map, lang)
    if type(map) ~= "table" then return nil end
    local text = str(map[lang]) or str(map.en)
    if text then return text end
    for __, v in pairs(map) do
        if str(v) then return v end
    end
end

local function relationships(m, kind)
    local out = {}
    for __, r in ipairs(type(m.relationships) == "table" and m.relationships or {}) do
        if r.type == kind then table.insert(out, r) end
    end
    return out
end

local function titleOf(attr, lang)
    local t = type(attr.title) == "table" and attr.title or {}
    local own = str(t[lang])
    if own then return own end
    for __, alt in ipairs(type(attr.altTitles) == "table" and attr.altTitles or {}) do
        if type(alt) == "table" and str(alt[lang]) then return alt[lang] end
    end
    return localized(t, lang)
end

local function capitalize(s)
    return (s:gsub("^%l", string.upper))
end

local function toItem(m, lang)
    if type(m) ~= "table" or not str(m.id) then return nil end
    local attr = type(m.attributes) == "table" and m.attributes or {}
    local thumb
    local cover = relationships(m, "cover_art")[1]
    if cover and type(cover.attributes) == "table" and str(cover.attributes.fileName) then
        thumb = string.format("%s/%s/%s.256.jpg", COVERS, m.id, cover.attributes.fileName)
    end
    local info = {}
    if str(attr.status) then table.insert(info, capitalize(attr.status)) end
    if tonumber(attr.year) then table.insert(info, tostring(attr.year)) end
    return {
        id = m.id,
        title = titleOf(attr, lang) or m.id,
        subtitle = #info > 0 and table.concat(info, " · ") or nil,
        thumb = thumb,
        adult = ADULT_RATINGS[attr.contentRating] or false,
        detail = m,
    }
end

local INCLUDES = arrayParam("includes", { "cover_art", "author", "artist" })

function MangaDex:fetchManga(id, lang)
    local data, err = getJson(self, "/manga/" .. id .. "?" .. INCLUDES)
    if not data then return nil, err end
    local item = toItem(data.data, lang)
    if not item then return nil, _("Title not found.") end
    return item
end

function MangaDex:search(query, page, sort, opts)
    opts = opts or {}
    local lang = opts.language or "en"
    query = query:match("^%s*(.-)%s*$")

    -- A title id, or a link containing one: open it directly.
    local uuid = query:match("%x+%-%x+%-%x+%-%x+%-%x+")
    if uuid and #uuid == 36 then
        local item, err = self:fetchManga(uuid, lang)
        if not item then return nil, err end
        if item.adult and not opts.adult then return {}, false end
        return { item }, false
    end

    local order = sort
    if not order or order == "" or (order == "relevance" and query == "") then
        -- Relevance needs a query; browse by popularity instead.
        order = query ~= "" and "relevance" or "followedCount"
    end
    local params = {
        "limit=" .. PAGE_SIZE,
        "offset=" .. (page - 1) * PAGE_SIZE,
        INCLUDES,
        arrayParam("contentRating", opts.adult and ALL_RATINGS or SAFE_RATINGS),
        arrayParam("availableTranslatedLanguage", { lang }),
        "order%5B" .. order .. "%5D=desc",
    }
    if query ~= "" then table.insert(params, "title=" .. Http.urlEncode(query)) end
    local data, err = getJson(self, "/manga?" .. table.concat(params, "&"))
    if not data then return nil, err end
    local items = {}
    for __, m in ipairs(type(data.data) == "table" and data.data or {}) do
        local item = toItem(m, lang)
        if item then table.insert(items, item) end
    end
    local total = tonumber(data.total) or 0
    return items, page * PAGE_SIZE < total
end

-- Markdown in descriptions, reduced to plain text.
local function plainText(s)
    s = s:gsub("\r", ""):gsub("\n%-%-%-.*$", "")
    s = s:gsub("%[([^%]]-)%]%b()", "%1")
    s = s:gsub("[%*_~]+", "")
    return (s:match("^%s*(.-)%s*$"))
end

function MangaDex:describe(item, opts)
    local lang = (opts and opts.language) or "en"
    if not item.detail then
        local full, err = self:fetchManga(item.id, lang)
        if not full then return item.title .. "\n\n" .. err end
        item.detail = full.detail
        item.thumb = item.thumb or full.thumb
        item.adult = full.adult
        item.subtitle = item.subtitle or full.subtitle
    end
    local m = item.detail
    local attr = type(m.attributes) == "table" and m.attributes or {}
    local lines = { item.title, "" }

    local names = {}
    for __, kind in ipairs{ "author", "artist" } do
        for __, r in ipairs(relationships(m, kind)) do
            local name = type(r.attributes) == "table" and str(r.attributes.name)
            if name and not names[name] then
                names[name] = true
                table.insert(names, name)
            end
        end
    end
    if #names > 0 then table.insert(lines, T(_("By %1"), table.concat(names, ", "))) end
    if item.subtitle then table.insert(lines, item.subtitle) end
    if str(attr.contentRating) then
        table.insert(lines, T(_("Rating: %1"), attr.contentRating))
    end
    local tags = {}
    for __, tag in ipairs(type(attr.tags) == "table" and attr.tags or {}) do
        local name = type(tag.attributes) == "table" and localized(tag.attributes.name, "en")
        if name then table.insert(tags, name) end
    end
    if #tags > 0 then table.insert(lines, T(_("Tags: %1"), table.concat(tags, ", "))) end
    local description = localized(attr.description, lang)
    if description then
        table.insert(lines, "")
        table.insert(lines, plainText(description))
    end
    return table.concat(lines, "\n")
end

local function chapterName(attr)
    local parts = {}
    if str(attr.volume) then table.insert(parts, "Vol. " .. attr.volume) end
    if str(attr.chapter) then table.insert(parts, "Ch. " .. attr.chapter) end
    local title = str(attr.title)
    if title then
        if #parts > 0 then table.insert(parts, "- " .. title) else table.insert(parts, title) end
    end
    return #parts > 0 and table.concat(parts, " ") or _("Oneshot")
end

-- Chapters in the configured language, newest first.
function MangaDex:getChapters(item, opts)
    local lang = (opts and opts.language) or "en"
    local chapters = {}
    local offset = 0
    while true do
        local params = {
            "limit=500",
            "offset=" .. offset,
            arrayParam("translatedLanguage", { lang }),
            arrayParam("includes", { "scanlation_group" }),
            arrayParam("contentRating", ALL_RATINGS),
            "order%5Bvolume%5D=desc",
            "order%5Bchapter%5D=desc",
            "includeFuturePublishAt=0",
            "includeEmptyPages=0",
        }
        local data, err = getJson(self, "/manga/" .. item.id .. "/feed?" .. table.concat(params, "&"))
        if not data then return nil, err end
        local list = type(data.data) == "table" and data.data or {}
        for __, c in ipairs(list) do
            local attr = type(c.attributes) == "table" and c.attributes or {}
            -- Chapters hosted elsewhere (e.g. official sites) have no pages here.
            if str(c.id) and (tonumber(attr.pages) or 0) > 0 and not str(attr.externalUrl) then
                local groups = {}
                for __, r in ipairs(relationships(c, "scanlation_group")) do
                    local name = type(r.attributes) == "table" and str(r.attributes.name)
                    if name then table.insert(groups, name) end
                end
                local name = chapterName(attr)
                table.insert(chapters, {
                    id = c.id,
                    number = tonumber(attr.chapter),
                    title = name,
                    group = #groups > 0 and table.concat(groups, " & ") or nil,
                    file_title = item.title .. " - " .. name,
                    item = item,
                })
            end
        end
        offset = offset + (tonumber(data.limit) or 500)
        if #list == 0 or offset >= (tonumber(data.total) or 0) then break end
    end
    logger.info("APIKOmic: MangaDex chapters for", item.id, #chapters)
    return chapters
end

-- Page images come from a MangaDex@Home server picked per request.
function MangaDex:getPages(chapter, opts)
    local data, err = getJson(self, "/at-home/server/" .. chapter.id)
    if not data then return nil, err end
    local ch = type(data.chapter) == "table" and data.chapter or {}
    local base_url = str(data.baseUrl)
    local hash = str(ch.hash)
    local full = type(ch.data) == "table" and ch.data or {}
    local saver = type(ch.dataSaver) == "table" and ch.dataSaver or {}
    if not base_url or not hash or #full == 0 then
        return nil, _("MangaDex returned no pages for this chapter.")
    end
    local prefer_saver = not opts or opts.data_saver ~= false
    local pages = {}
    for i, file in ipairs(full) do
        local original = string.format("%s/data/%s/%s", base_url, hash, file)
        local small = saver[i] and string.format("%s/data-saver/%s/%s", base_url, hash, saver[i])
        local urls = {}
        if small and prefer_saver then table.insert(urls, small) end
        table.insert(urls, original)
        if small and not prefer_saver then table.insert(urls, small) end
        pages[i] = { urls = urls, ext = file:match("%.(%w+)$") or "jpg" }
    end
    return pages
end

return MangaDex
