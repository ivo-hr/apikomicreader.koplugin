-- nhentai.net, through its v2 JSON API (https://nhentai.net/api/v2/docs).
local _ = require("gettext")
local logger = require("logger")
local T = require("ffi/util").template

local Http = require("apiko.http")

local Nhentai = {
    id = "nhentai",
    name = "nhentai",
    domain = "nhentai.net",
    base = "https://nhentai.net",
    -- The whole source is adult content: hidden unless parental controls allow it.
    adult = true,
    -- A gallery is read directly; there is no chapter list.
    single_chapter = true,
    search_hint = _("Tags, title or gallery number (empty = latest)"),
    -- Values the v2 API accepts for `sort`.
    sorts = {
        { id = "date", text = _("Newest") },
        { id = "popular", text = _("Popular, all time") },
        { id = "popular-month", text = _("Popular, this month") },
        { id = "popular-week", text = _("Popular, this week") },
        { id = "popular-today", text = _("Popular, today") },
    },
}

local API = "/api/v2"

local function str(v)
    return type(v) == "string" and v ~= "" and v or nil
end

-- Image and thumbnail servers from /api/v2/cdn, fetched once per session.
-- The API says not to hardcode them. Paths are relative: server .. path.
local cdn  -- { images = {...}, thumbs = {...} }

local function joinUrl(server, path)
    if path:find("^%a+://") then return path end
    if not server:find("^%a+://") then server = "https://" .. server end
    return (server:gsub("/+$", "")) .. "/" .. (path:gsub("^/+", ""))
end

local function serverList(v)
    local servers = {}
    for __, s in ipairs(type(v) == "table" and v or {}) do
        if str(s) then table.insert(servers, s) end
    end
    return servers
end

function Nhentai:getCdn()
    if cdn then return cdn end
    local data, err = Http.getJson(self.base .. API .. "/cdn")
    if not data then return nil, err end
    local images = serverList(data.image_servers)
    if #images == 0 then
        logger.warn("APIKOmic: cdn reply without image_servers")
        return nil, _("The site returned no image servers.")
    end
    local thumbs = serverList(data.thumb_servers)
    if #thumbs == 0 then thumbs = images end
    cdn = { images = images, thumbs = thumbs }
    return cdn
end

-- Cover thumbnail URL. List entries have `thumbnail` as a path; full
-- galleries have it as { path, width, height }.
local function thumbUrl(g)
    local t = g.thumbnail
    if type(t) == "table" then t = t.path end
    t = str(t)
    if not t then return nil end
    if t:find("^%a+://") then return t end
    if not cdn then return nil end
    return joinUrl(cdn.thumbs[1], t)
end

-- List entries (search, latest, popular) are lightweight: no tag names.
local function listItem(g)
    if type(g) ~= "table" or not g.id then return nil end
    local pages = tonumber(g.num_pages)
    return {
        id = tostring(g.id),
        title = str(g.english_title) or str(g.japanese_title) or ("#" .. tostring(g.id)),
        pages = pages and pages > 0 and pages or nil,
        subtitle = pages and pages > 0 and T(_("%1 pages"), pages) or nil,
        thumb = thumbUrl(g),
        adult = true,
    }
end

local function prettyTitle(g)
    local t = type(g.title) == "table" and g.title or {}
    return str(t.pretty) or str(t.english) or str(t.japanese)
end

local function detailItem(g)
    return {
        id = tostring(g.id),
        title = prettyTitle(g) or ("#" .. tostring(g.id)),
        pages = tonumber(g.num_pages),
        subtitle = tonumber(g.num_pages) and T(_("%1 pages"), g.num_pages) or nil,
        thumb = thumbUrl(g),
        adult = true,
        detail = g,
    }
end

function Nhentai:fetchGallery(id)
    local g, err = Http.getJson(string.format("%s%s/galleries/%s", self.base, API, id))
    if not g then return nil, err end
    if not g.id then
        local keys = {}
        for k in pairs(g) do table.insert(keys, tostring(k)) end
        logger.warn("APIKOmic: gallery reply without id, keys:", table.concat(keys, ","),
                    "error:", tostring(g.error))
        return nil, type(g.error) == "string" and g.error or _("Gallery not found.")
    end
    return g
end

-- Full gallery (tags, page list). Cached on the item: the API is rate-limited.
function Nhentai:getDetail(item)
    if item.detail then return item.detail end
    local g, err = self:fetchGallery(item.id)
    if not g then return nil, err end
    item.detail = g
    item.title = prettyTitle(g) or item.title
    item.pages = tonumber(g.num_pages) or item.pages
    return g
end

-- data.result -> items, or nil and an error (never a silent empty list).
local function resultItems(data)
    if type(data.result) ~= "table" then
        local keys = {}
        for k in pairs(data) do table.insert(keys, tostring(k)) end
        logger.warn("APIKOmic: reply without result, keys:", table.concat(keys, ","),
                    "error:", tostring(data.error))
        local msg = type(data.error) == "string" and data.error or ("keys: " .. table.concat(keys, ","))
        return nil, T(_("Unexpected reply from the site: %1"), msg)
    end
    local items = {}
    for __, g in ipairs(data.result) do
        local item = listItem(g)
        if item then table.insert(items, item) end
    end
    logger.info("APIKOmic: parsed", #items, "of", #data.result, "results")
    return items
end

function Nhentai:search(query, page, sort)
    query = query:match("^%s*(.-)%s*$")
    -- Thumbnail paths need the server list; results still work without it.
    self:getCdn()

    -- Gallery number: open it directly.
    if query:match("^%d+$") then
        local g, err = self:fetchGallery(query)
        if not g then return nil, err end
        return { detailItem(g) }, false
    end

    local by_date = sort == nil or sort == "" or sort == "date"

    -- Empty query: the latest uploads, or a popularity ranking.
    if query == "" then
        if by_date then
            local data, err = Http.getJson(string.format("%s%s/galleries?page=%d", self.base, API, page))
            if not data then return nil, err end
            local items, ierr = resultItems(data)
            if not items then return nil, ierr end
            return items, page < (tonumber(data.num_pages) or 1)
        end
        if sort == "popular-today" and page == 1 then
            -- Dedicated endpoint: a plain array, no pages.
            local data, err = Http.getJson(self.base .. API .. "/galleries/popular")
            if not data then return nil, err end
            local items, ierr = resultItems({ result = data })
            if not items then return nil, ierr end
            return items, false
        end
        -- /search needs a non-empty query; this filter matches every gallery.
        query = "pages:>0"
    end

    local url = string.format("%s%s/search?query=%s&page=%d", self.base, API, Http.urlEncode(query), page)
    if not by_date then url = url .. "&sort=" .. sort end
    local data, err = Http.getJson(url)
    if not data then return nil, err end
    local items, ierr = resultItems(data)
    if not items then return nil, ierr end
    return items, page < (tonumber(data.num_pages) or 1)
end

function Nhentai:describe(item)
    local g, err = self:getDetail(item)
    local lines = { item.title, "" }
    table.insert(lines, T(_("#%1 · %2 pages"), item.id, item.pages or "?"))
    if not g then
        table.insert(lines, T(_("Could not load details: %1"), err))
        return table.concat(lines, "\n")
    end
    local groups = {}
    for __, tag in ipairs(type(g.tags) == "table" and g.tags or {}) do
        if type(tag.type) == "string" and type(tag.name) == "string" then
            groups[tag.type] = groups[tag.type] or {}
            table.insert(groups[tag.type], tag.name)
        end
    end
    for __, kind in ipairs{ "parody", "character", "artist", "group", "language", "category", "tag" } do
        if groups[kind] then
            table.insert(lines, kind .. ": " .. table.concat(groups[kind], ", "))
        end
    end
    return table.concat(lines, "\n")
end

-- A gallery is a single chapter.
function Nhentai:getChapters(item)
    return { { id = item.id, title = item.title, file_title = item.title, item = item } }
end

function Nhentai:getPages(chapter)
    local g, err = self:getDetail(chapter.item)
    if not g then return nil, err end
    if type(g.pages) ~= "table" or #g.pages == 0 then
        return nil, _("Gallery has no page list.")
    end
    local servers, serr = self:getCdn()
    if not servers then return nil, serr end
    servers = servers.images
    local pages = {}
    for __, p in ipairs(g.pages) do
        if type(p) == "table" and str(p.path) then
            local urls = {}
            for ___, server in ipairs(servers) do
                table.insert(urls, joinUrl(server, p.path))
            end
            table.insert(pages, { urls = urls, ext = p.path:match("%.(%w+)$") or "jpg" })
        end
    end
    if #pages == 0 then return nil, _("Gallery has no page list.") end
    logger.info("APIKOmic: first page url:", pages[1].urls[1])
    return pages
end

return Nhentai