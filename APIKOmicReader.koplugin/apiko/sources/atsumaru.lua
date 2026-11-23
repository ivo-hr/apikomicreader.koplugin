-- Atsumaru (atsu.moe), through the JSON API its web app uses.
-- The website itself is behind a Cloudflare challenge, but /api/... and the
-- search endpoint (/collections/manga/documents/search, a Typesense proxy)
-- answer plain requests. Endpoints follow the Aidoku community source
-- (github.com/Aidoku-Community/sources, en.atsumaru).
local _ = require("gettext")
local logger = require("logger")
local T = require("ffi/util").template

local Http = require("apiko.http")

local Atsumaru = {
    id = "atsumaru",
    name = "Atsumaru",
    domain = "atsu.moe",
    base = "https://atsu.moe",
    order = 15,
    -- Mixed content: adult titles are flagged one by one.
    adult = false,
    search_hint = _("Title or author (empty = browse)"),
    -- Added to the warning about AVIF pages: older uploads are WebP, and a
    -- chapter often has uploads from several groups.
    unsupported_hint = _("Another group's upload of this chapter may use a supported format: look for the same chapter number in the list."),
    sorts = {
        { id = "relevance", text = _("Relevance") },
        { id = "views", text = _("Popular") },
        { id = "trending", text = _("Trending") },
        { id = "recentlyUpdated", text = _("Latest chapters") },
        { id = "dateAdded", text = _("Newest titles") },
        { id = "mbRating", text = _("Top rated") },
    },
}

local BASE = "https://atsu.moe"
local API = BASE .. "/api"
local CDN = "https://cdn.atsu.moe/static"
local PAGE_SIZE = 40
local FEED_PAGE_SIZE = 24
local CARD_FIELDS = "id,title,poster,posterMedium,isAdult,mbContentRating,genreIds,medium,status"

-- Genre ids that make an unrated title adult: Hentai, Adult, Smut.
local ADULT_GENRES = { ["10"] = true, ["46"] = true, ["41"] = true }
local ADULT_RATINGS = { Erotica = true, Pornographic = true }

local function str(v)
    return type(v) == "string" and v ~= "" and v or nil
end

local function list(v)
    return type(v) == "table" and v or {}
end

local function getJson(url)
    return Http.getJson(url, { referer = BASE .. "/" })
end

local function query(params)
    local parts = {}
    for __, p in ipairs(params) do
        table.insert(parts, p[1] .. "=" .. Http.urlEncode(p[2]))
    end
    return table.concat(parts, "&")
end

-- Paths come as "/static/posters/x.jpg" or "posters/x.jpg".
local function staticPath(path)
    path = path:gsub("^/+", "")
    return (path:gsub("^static/", ""))
end

-- Every cover size has a .webp copy next to the .avif one; KOReader can't
-- decode AVIF.
local function coverUrl(path)
    path = str(path)
    if not path then return nil end
    path = staticPath(path):gsub("%.avif$", ".webp")
    return CDN .. "/" .. path
end

local function isAdult(is_adult, rating, genre_ids)
    if is_adult == true or ADULT_RATINGS[rating] then return true end
    for __, g in ipairs(list(genre_ids)) do
        if ADULT_GENRES[tostring(g)] then return true end
    end
    return false
end

-- Typesense filter: comics only, visible, and safe unless adult is allowed.
local function filterBy(sort, adult)
    local clauses = { "hidden:!=true", "medium:!=[`Novel`]" }
    if not adult then
        table.insert(clauses, "isAdult:=false")
        table.insert(clauses, "mbContentRating:!=[`Erotica`,`Pornographic`]")
        table.insert(clauses, "genreIds:!=[`10`,`46`,`41`]")
    end
    if sort == "views" then table.insert(clauses, "views:>0") end
    if sort == "mbRating" then table.insert(clauses, "mbRating:>0") end
    return table.concat(clauses, " && ")
end

local function docItem(d)
    if type(d) ~= "table" or not str(d.id) then return nil end
    return {
        id = d.id,
        title = str(d.title) or d.id,
        subtitle = str(d.status),
        thumb = coverUrl(d.posterMedium or d.poster),
        adult = isAdult(d.isAdult, d.mbContentRating, d.genreIds),
    }
end

function Atsumaru:searchIndex(text, page, sort, adult)
    local sort_by
    if sort == "relevance" then
        sort_by = "_text_match:desc,views:desc"
    else
        sort_by = sort .. ":desc"
    end
    local params = {
        { "q", text ~= "" and text or "*" },
        { "query_by", "title,englishTitle,otherNames,authors,acronyms" },
        { "query_by_weights", "4,3,2,2,1" },
        { "num_typos", "4,3,2,1,0" },
        { "prefix", "true,true,true,true,false" },
        { "include_fields", CARD_FIELDS },
        { "filter_by", filterBy(sort, adult) },
        { "page", tostring(page) },
        { "per_page", tostring(PAGE_SIZE) },
        { "sort_by", sort_by },
    }
    if text ~= "" then table.insert(params, { "infix", "off,off,fallback,off,off" }) end
    local data, err = getJson(BASE .. "/collections/manga/documents/search?" .. query(params))
    if not data then return nil, err end
    if type(data.hits) ~= "table" then
        logger.warn("APIKOmic: atsumaru search reply without hits:", tostring(data.message))
        return nil, T(_("Unexpected reply from the site: %1"), tostring(data.message or "no results list"))
    end
    local items = {}
    for __, hit in ipairs(data.hits) do
        local item = docItem(hit.document)
        if item then table.insert(items, item) end
    end
    local found, per_page = tonumber(data.found) or 0, tonumber(data.request_params and data.request_params.per_page) or PAGE_SIZE
    return items, page * per_page < found
end

-- Home feed of recently updated titles (no text query).
function Atsumaru:latest(page, adult)
    local params = {
        { "offset", tostring((page - 1) * FEED_PAGE_SIZE) },
        { "limit", tostring(FEED_PAGE_SIZE) },
        { "mediums", "Comic" },
    }
    if adult then
        table.insert(params, { "contentRatings", "Safe,Suggestive,Erotica,Pornographic" })
    else
        -- Omitting contentRatings would also mean safe mode; be explicit.
        table.insert(params, { "contentRatings", "Safe,Suggestive" })
        table.insert(params, { "excludedTags", "10,46,41" })
    end
    local data, err = getJson(API .. "/home2/recentlyUpdated?" .. query(params))
    if not data then return nil, err end
    if type(data.items) ~= "table" then
        return nil, T(_("Unexpected reply from the site: %1"), "no items")
    end
    local items = {}
    for __, f in ipairs(data.items) do
        if str(f.id) and f.medium ~= "Novel" then
            table.insert(items, {
                id = f.id,
                title = str(f.title) or f.id,
                subtitle = str(f.type),
                thumb = coverUrl(f.mediumImage or f.image),
                adult = f.isAdult == true,
            })
        end
    end
    return items, #data.items == FEED_PAGE_SIZE
end

function Atsumaru:search(text, page, sort, opts)
    opts = opts or {}
    text = text:match("^%s*(.-)%s*$")

    -- A link to a title: atsu.moe/manga/<id> or atsu.moe/read/<id>/<chapter>.
    local link_id = text:match("atsu%.moe/manga/([%w_%-]+)") or text:match("atsu%.moe/read/([%w_%-]+)")
    if link_id then
        local page_data, err = self:fetchPage(link_id)
        if not page_data then return nil, err end
        local item = {
            id = link_id,
            title = str(page_data.title) or link_id,
            subtitle = str(page_data.status),
            thumb = coverUrl(type(page_data.poster) == "table" and (page_data.poster.mediumImage or page_data.poster.image)),
            adult = isAdult(page_data.isAdult, nil, self:genreIds(page_data)),
            page = page_data,
        }
        if item.adult and not opts.adult then return {}, false end
        return { item }, false
    end

    if not sort or sort == "" then sort = "relevance" end
    if text == "" then
        if sort == "recentlyUpdated" then return self:latest(page, opts.adult) end
        -- Relevance needs a query; browse by popularity instead.
        if sort == "relevance" then sort = "views" end
    elseif sort == "recentlyUpdated" then
        -- The update feed can't be searched.
        sort = "relevance"
    end
    return self:searchIndex(text, page, sort, opts.adult)
end

function Atsumaru:fetchPage(id)
    local data, err = getJson(API .. "/manga/page?id=" .. Http.urlEncode(id))
    if not data then return nil, err end
    if type(data.mangaPage) ~= "table" then
        return nil, _("This title is no longer on Atsumaru.")
    end
    return data.mangaPage
end

function Atsumaru:genreIds(p)
    local ids = {}
    for __, g in ipairs(list(p.genres)) do table.insert(ids, g.id) end
    return ids
end

-- Full title page (details and first chapters). Cached on the item.
function Atsumaru:getPage(item)
    if item.page then return item.page end
    local p, err = self:fetchPage(item.id)
    if not p then return nil, err end
    item.page = p
    item.title = str(p.title) or item.title
    item.adult = item.adult or isAdult(p.isAdult, nil, self:genreIds(p))
    return p
end

-- Synopses are Markdown; keep the text.
local function plainText(s)
    s = s:gsub("\r", ""):gsub("\\(%p)", "%1")
    s = s:gsub("%[([^%]]-)%]%b()", "%1"):gsub("%*+", "")
    return (s:match("^%s*(.-)%s*$"))
end

function Atsumaru:describe(item, opts)
    local p, err = self:getPage(item)
    if not p then return item.title .. "\n\n" .. err end
    local lines = { item.title, "" }

    local authors, seen = {}, {}
    for __, a in ipairs(list(p.authors)) do
        local name = str(a.name)
        if name and not seen[name] then
            seen[name] = true
            table.insert(authors, name)
        end
    end
    if #authors > 0 then table.insert(lines, T(_("By %1"), table.concat(authors, ", "))) end

    local info = {}
    if str(p.type) then table.insert(info, p.type) end
    if str(p.status) then table.insert(info, p.status) end
    if tonumber(p.released) then table.insert(info, os.date("!%Y", math.floor(p.released / 1000))) end
    if tonumber(p.totalChapterCount) then table.insert(info, T(_("%1 chapters"), p.totalChapterCount)) end
    if #info > 0 then table.insert(lines, table.concat(info, " · ")) end
    if tonumber(p.avgRating) then
        table.insert(lines, T(_("Rating: %1/10"), string.format("%.1f", p.avgRating)))
    end

    local tags = {}
    for __, g in ipairs(list(p.genres)) do
        if str(g.name) then table.insert(tags, g.name) end
    end
    for __, t in ipairs(list(p.tags)) do
        if str(t.name) and (t.weight == "Core" or t.weight == "Defining") and not t.isSpoiler then
            table.insert(tags, t.name)
        end
    end
    if #tags > 0 then table.insert(lines, T(_("Tags: %1"), table.concat(tags, ", "))) end

    if str(p.synopsis) then
        table.insert(lines, "")
        table.insert(lines, plainText(p.synopsis))
    end
    return table.concat(lines, "\n")
end

-- Reading a chapter needs the title id too, so chapter.id is
-- "<title id>.<chapter id>" (both ids are letters, digits, "_" and "-").
function Atsumaru:getChapters(item, opts)
    local p, err = self:getPage(item)
    if not p then return nil, err end
    local raw = list(p.chapters)
    if p.hasMoreChapters then
        -- The title page only has the first chapters.
        local data, cerr = getJson(API .. "/manga/allChapters?mangaId=" .. Http.urlEncode(item.id))
        if not data then return nil, cerr end
        raw = list(data.chapters)
    end
    local groups = {}
    for __, s in ipairs(list(p.scanlators)) do
        if str(s.id) and str(s.name) then groups[s.id] = s.name end
    end
    local chapters = {}
    -- The site lists chapters newest first.
    for __, c in ipairs(raw) do
        if str(c.id) then
            local number = tonumber(c.number)
            local title = str(c.title) and c.title:match("^%s*(.-)%s*$")
            if not title or title == "" then
                title = number and T(_("Chapter %1"), c.number) or c.id
            end
            table.insert(chapters, {
                id = item.id .. "." .. c.id,
                chapter_id = c.id,
                number = number,
                title = title,
                group = groups[c.scanlationMangaId],
                file_title = item.title .. " - " .. title,
                item = item,
            })
        end
    end
    logger.info("APIKOmic: atsumaru chapters for", item.id, #chapters)
    return chapters
end

function Atsumaru:getPages(chapter, opts)
    local manga_id, chapter_id = chapter.id:match("^(.-)%.([^%.]+)$")
    if not manga_id then
        manga_id, chapter_id = chapter.item and chapter.item.id, chapter.id
    end
    local data, err = getJson(string.format("%s/read/chapter?mangaId=%s&chapterId=%s",
        API, Http.urlEncode(manga_id), Http.urlEncode(chapter_id)))
    if not data then return nil, err end
    local ch = type(data.readChapter) == "table" and data.readChapter or {}
    local pages = {}
    for __, pg in ipairs(list(ch.pages)) do
        local image = str(pg.image)
        if image then
            -- Uploads since mid-2026 are mostly AVIF, with no other format on
            -- the CDN; the plugin warns before downloading those.
            local path = staticPath(image)
            table.insert(pages, { urls = { CDN .. "/" .. path }, ext = path:match("%.(%w+)$") or "jpg" })
        end
    end
    if #pages == 0 then return nil, _("This chapter has no pages.") end
    logger.info("APIKOmic: atsumaru pages:", #pages, pages[1].urls[1])
    return pages
end

return Atsumaru
