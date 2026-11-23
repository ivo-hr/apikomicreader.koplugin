-- Chikari (chikari.moe), through the JSON API its web app uses.
-- Endpoints follow the Aidoku community source
-- (github.com/Aidoku-Community/sources, en.chikari).
-- The site also hosts novels, under /api/novels. /api/series leaves them out
-- unless type=novel is asked for; we ask for the comic types by name anyway.
local _ = require("gettext")
local logger = require("logger")
local T = require("ffi/util").template

local Http = require("apiko.http")

local Chikari = {
    id = "chikari",
    name = "Chikari",
    domain = "chikari.moe",
    base = "https://chikari.moe",
    order = 25,
    -- Mixed content: adult titles are flagged one by one.
    adult = false,
    search_hint = _("Title (empty = browse)"),
    sorts = {
        { id = "popular", text = _("Popular") },
        { id = "trending", text = _("Trending") },
        { id = "top_rated", text = _("Top rated") },
        { id = "updated", text = _("Latest chapters") },
        { id = "added", text = _("Newest titles") },
        { id = "most_bookmarked", text = _("Most bookmarked") },
        { id = "bingeable", text = _("Complete & bingeable") },
        { id = "random", text = _("Random") },
    },
}

local BASE = "https://chikari.moe"
local API = BASE .. "/api/series"
local PAGE_SIZE = 36
-- The server returns at most 200 chapters per request.
local CHAPTER_PAGE_SIZE = 200
local COMIC_TYPES = "type=manga&type=manhwa&type=manhua&type=oel"
local SAFE_RATINGS = "safe,suggestive"
local ALL_RATINGS = "safe,suggestive,erotica,pornographic"

-- Images are on two hosts with the same paths. Some networks can't reach
-- cdn.irakich.st (its certificate fails behind web filters), while
-- cdn.chikari.moe serves the same files.
local MIRROR_HOST = "cdn.chikari.moe"

local function str(v)
    return type(v) == "string" and v ~= "" and v or nil
end

local function list(v)
    return type(v) == "table" and v or {}
end

local function getJson(url)
    return Http.getJson(url, { referer = BASE .. "/" })
end

-- The same image on the mirror host, or nil if it's already there.
local function mirrorUrl(url)
    local host, path = url:match("^https?://([^/]+)(/.*)$")
    if not host or host == MIRROR_HOST then return nil end
    return "https://" .. MIRROR_HOST .. path
end

-- Covers get a single address, so use the host that works everywhere.
local function coverUrl(url)
    url = str(url)
    if not url then return nil end
    return mirrorUrl(url) or url
end

-- 349.0 -> "349", 12.5 -> "12.5" (the API takes either, but this is what
-- the site's own links use).
local function numberText(n)
    if n == math.floor(n) then return string.format("%d", n) end
    return string.format("%g", n)
end

local function capitalize(s)
    s = str(s)
    return s and (s:sub(1, 1):upper() .. s:sub(2)) or nil
end

local function listItem(r)
    if type(r) ~= "table" or not str(r.slug) then return nil end
    -- Belt and braces: never show a novel.
    if r.medium == "novel" or r.type == "novel" then return nil end
    local info = {}
    if str(r.type) then table.insert(info, capitalize(r.type)) end
    if str(r.status) then table.insert(info, capitalize(r.status)) end
    return {
        id = r.slug,
        title = str(r.title) or r.slug,
        subtitle = #info > 0 and table.concat(info, " · ") or nil,
        thumb = coverUrl(r.cover_url),
        adult = r.is_nsfw == true,
    }
end

function Chikari:fetchDetail(slug)
    local data, err = getJson(API .. "/" .. Http.urlEncode(slug))
    if not data then
        if err == T(_("HTTP error %1"), 404) then
            return nil, _("This title is no longer on Chikari.")
        end
        return nil, err
    end
    if not str(data.slug) then
        return nil, T(_("Unexpected reply from the site: %1"), "no slug")
    end
    if data.medium == "novel" or data.type == "novel" then
        return nil, _("This is a novel. Only comics can be read here.")
    end
    return data
end

function Chikari:search(text, page, sort, opts)
    opts = opts or {}
    text = text:match("^%s*(.-)%s*$")

    -- A link to a title or chapter: chikari.moe/series/<slug>[/...].
    local link_slug = text:match("chikari%.moe/series/([%w_%-]+)")
    if link_slug then
        local d, err = self:fetchDetail(link_slug)
        if not d then return nil, err end
        local item = listItem(d)
        if not item then return {}, false end
        item.detail = d
        if item.adult and not opts.adult then return {}, false end
        return { item }, false
    end
    if text:match("chikari%.moe/novels/") then
        return nil, _("This is a novel. Only comics can be read here.")
    end

    if not sort or sort == "" then sort = self.sorts[1].id end
    local url = string.format("%s?sort=%s&limit=%d&offset=%d&%s&content_rating=%s",
        API, Http.urlEncode(sort), PAGE_SIZE, (page - 1) * PAGE_SIZE, COMIC_TYPES,
        opts.adult and ALL_RATINGS or SAFE_RATINGS)
    if text ~= "" then url = url .. "&q=" .. Http.urlEncode(text) end
    local data, err = getJson(url)
    if not data then return nil, err end
    if type(data.items) ~= "table" then
        return nil, T(_("Unexpected reply from the site: %1"), "no items")
    end
    local items = {}
    for __, r in ipairs(data.items) do
        local item = listItem(r)
        if item and (opts.adult or not item.adult) then table.insert(items, item) end
    end
    local total = tonumber(data.total)
    local has_more
    if total and total > 0 then
        has_more = (page - 1) * PAGE_SIZE + #data.items < total
    else
        has_more = #data.items >= PAGE_SIZE
    end
    return items, has_more
end

-- Full title details. Cached on the item.
function Chikari:getDetail(item)
    if item.detail then return item.detail end
    local d, err = self:fetchDetail(item.id)
    if not d then return nil, err end
    item.detail = d
    item.title = str(d.title) or item.title
    item.adult = item.adult or d.is_nsfw == true
    return d
end

function Chikari:describe(item, opts)
    local d, err = self:getDetail(item)
    if not d then return item.title .. "\n\n" .. err end
    local lines = { item.title, "" }

    local authors, seen = {}, {}
    for __, a in ipairs(list(d.authors)) do
        local name = str(a.name)
        if name and not seen[name] then
            seen[name] = true
            table.insert(authors, name)
        end
    end
    if #authors > 0 then table.insert(lines, T(_("By %1"), table.concat(authors, ", "))) end

    local info = {}
    if str(d.type) then table.insert(info, capitalize(d.type)) end
    if str(d.status) then table.insert(info, capitalize(d.status)) end
    if tonumber(d.year) then table.insert(info, tostring(d.year)) end
    if tonumber(d.chapter_count) then table.insert(info, T(_("%1 chapters"), d.chapter_count)) end
    if #info > 0 then table.insert(lines, table.concat(info, " · ")) end
    if tonumber(d.rating) and tonumber(d.rating) > 0 then
        table.insert(lines, T(_("Rating: %1/10"), string.format("%.1f", d.rating)))
    end

    -- Genres first, then tags; some titles have 50+ tags, so cap the list.
    local MAX_TAGS = 15
    local tags, seen_tags = {}, {}
    local function addTag(name)
        name = str(name)
        if name and not seen_tags[name] and #tags < MAX_TAGS then
            seen_tags[name] = true
            table.insert(tags, name)
        end
    end
    for __, g in ipairs(list(d.genres)) do addTag(g.name) end
    for __, t in ipairs(list(d.tags)) do
        if not t.is_spoiler then addTag(t.name) end
    end
    if #tags > 0 then table.insert(lines, T(_("Tags: %1"), table.concat(tags, ", "))) end

    if str(d.description) then
        table.insert(lines, "")
        table.insert(lines, (d.description:gsub("\r", ""):match("^%s*(.-)%s*$")))
    end
    return table.concat(lines, "\n")
end

-- Reading a chapter needs the title slug too, so chapter.id is
-- "<slug>~<number>" (slugs are letters, digits, "-" and "_"; the id ends
-- up in file names, so no "/").
function Chikari:getChapters(item, opts)
    local chapters = {}
    local offset = 0
    while true do
        local data, err = getJson(string.format("%s/%s/chapters?order=desc&limit=%d&offset=%d",
            API, Http.urlEncode(item.id), CHAPTER_PAGE_SIZE, offset))
        if not data then
            if err == T(_("HTTP error %1"), 404) then
                return nil, _("This title is no longer on Chikari.")
            end
            return nil, err
        end
        local raw = list(data.items)
        -- The site lists chapters newest first (order=desc).
        for __, c in ipairs(raw) do
            local number = tonumber(c.number)
            if number then
                local num = numberText(number)
                local title = str(c.title) and c.title:gsub("%s+", " "):match("^%s*(.-)%s*$")
                if not title or title == "" then
                    title = T(_("Chapter %1"), num)
                elseif not title:lower():find("^ch") then
                    title = T(_("Chapter %1"), num) .. ": " .. title
                end
                local scan = list(c.scans)[1]
                table.insert(chapters, {
                    id = item.id .. "~" .. num,
                    number = number,
                    title = title,
                    group = type(scan) == "table" and str(scan.name) or nil,
                    file_title = item.title .. " - " .. title,
                    item = item,
                })
            end
        end
        local total = tonumber(data.total) or 0
        local server_offset = tonumber(data.offset) or offset
        local next_offset = server_offset + #raw
        if #raw == 0 or next_offset >= total or next_offset <= offset then break end
        offset = next_offset
    end
    logger.info("APIKOmic: chikari chapters for", item.id, #chapters)
    return chapters
end

function Chikari:getPages(chapter, opts)
    local slug, num = chapter.id:match("^(.-)~([^~]+)$")
    if not slug then
        slug, num = chapter.item and chapter.item.id, chapter.id
    end
    local data, err = getJson(string.format("%s/%s/chapters/%s",
        API, Http.urlEncode(slug), Http.urlEncode(num)))
    if not data then
        if err == T(_("HTTP error %1"), 404) then
            return nil, _("This chapter is no longer on Chikari.")
        end
        return nil, err
    end
    local pages = {}
    for __, url in ipairs(list(data.pages)) do
        url = str(url)
        if url then
            local urls = { url }
            local mirror = mirrorUrl(url)
            if mirror then table.insert(urls, mirror) end
            table.insert(pages, { urls = urls, ext = url:match("^[^?#]*%.(%w+)$") or "webp" })
        end
    end
    if #pages == 0 then return nil, _("This chapter has no pages.") end
    logger.info("APIKOmic: chikari pages:", #pages, pages[1].urls[1])
    return pages
end

return Chikari
