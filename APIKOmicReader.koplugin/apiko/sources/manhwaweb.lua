-- ManhwaWeb (manhwaweb.com), Spanish manhwa/manga/manhua, through the JSON
-- API its web app uses (api.manhwaweb.com). Endpoints follow the Aidoku
-- community source (github.com/Aidoku-Community/sources, es.manhwaweb).
-- Images need a Referer, which the plugin always sends.
local _ = require("gettext")
local logger = require("logger")
local T = require("ffi/util").template

local Http = require("apiko.http")

local ManhwaWeb = {
    id = "manhwaweb",
    name = "ManhwaWeb",
    domain = "manhwaweb.com",
    base = "https://manhwaweb.com",
    order = 30,
    -- Mixed content: adult titles are flagged one by one.
    adult = false,
    search_hint = _("Title (empty = browse)"),
    -- "<order_item>_<order_dir>". There's no popularity sort: the site's
    -- top list has no adult flag, so it would leak adult titles.
    sorts = {
        { id = "creacion_desc", text = _("Newest titles") },
        { id = "num_chapter_desc", text = _("Most chapters") },
        { id = "alfabetico_asc", text = _("A–Z") },
    },
}

local API = "https://api.manhwaweb.com"

local STATUS = {
    publicandose = _("Ongoing"),
    finalizado = _("Completed"),
    pausado = _("Hiatus"),
}

local function str(v)
    return type(v) == "string" and v ~= "" and v or nil
end

local function list(v)
    return type(v) == "table" and v or {}
end

local function trim(s)
    return (s:match("^%s*(.-)%s*$"))
end

local function getJson(url)
    return Http.getJson(url, { referer = ManhwaWeb.base .. "/" })
end

local function capitalize(s)
    s = str(s)
    return s and (s:sub(1, 1):upper() .. s:sub(2)) or nil
end

-- 5 -> "5", 5.5 -> "5.5", like the site's chapter links.
local function numberText(n)
    if n == math.floor(n) then return string.format("%d", n) end
    return string.format("%g", n)
end

local function lastSegment(url)
    return (url:gsub("[?#].*$", ""):gsub("/+$", ""):match("([^/]+)$"))
end

local function names(people)
    local out, seen = {}, {}
    for __, p in ipairs(list(people)) do
        local name = type(p) == "table" and str(p.name) and trim(p.name)
        if name and name ~= "" and not seen[name] then
            seen[name] = true
            table.insert(out, name)
        end
    end
    return out
end

local function titleOf(r)
    local title = str(r.name_esp) or str(r.the_real_name)
    return title and trim(title) or nil
end

local function subtitleOf(r)
    local info = {}
    if str(r._tipo) then table.insert(info, capitalize(r._tipo)) end
    if str(r._status) then table.insert(info, STATUS[r._status] or capitalize(r._status)) end
    local caps = tonumber(r._numero_cap)
    if caps then table.insert(info, T(_("%1 ch."), numberText(caps))) end
    return #info > 0 and table.concat(info, " · ") or nil
end

local function libraryItem(r)
    if type(r) ~= "table" or not str(r.real_id) then return nil end
    return {
        id = r.real_id,
        title = titleOf(r) or r.real_id,
        subtitle = subtitleOf(r),
        thumb = str(r._imagen),
        adult = r._erotico == "si",
    }
end

function ManhwaWeb:fetchDetail(id)
    local data, err = getJson(API .. "/manhwa/see/" .. Http.urlEncode(id))
    if not data then
        if err == T(_("HTTP error %1"), 404) then
            return nil, _("This title is no longer on ManhwaWeb (or the link uses an old address: search for it by name).")
        end
        return nil, err
    end
    if not str(data.real_id) then
        return nil, T(_("Unexpected reply from the site: %1"), "no real_id")
    end
    return data
end

function ManhwaWeb:search(text, page, sort, opts)
    opts = opts or {}
    text = trim(text)

    -- A link: manhwaweb.com/manhwa/<id>, /manga/<id> or /leer/<id>-<n>_<v>.
    local path = text:match("manhwaweb%.com(/[^%s]*)")
    if path then
        local id
        if path:match("^/manhwa/") or path:match("^/manga/") then
            id = lastSegment(path)
        elseif path:match("^/leer/") then
            id = lastSegment(path):match("^(.+)%-[^%-]+$")
        end
        if not id then return nil, _("This link isn't a title or a chapter.") end
        local d, err = self:fetchDetail(id)
        if not d then return nil, err end
        local item = libraryItem(d)
        item.subtitle = subtitleOf(d)
        item.detail = d
        if item.adult and not opts.adult then return {}, false end
        return { item }, false
    end

    if not sort or sort == "" then sort = self.sorts[1].id end
    local order_item, order_dir = sort:match("^(.+)_(%a+)$")
    if not order_item then order_item, order_dir = "creacion", "desc" end
    local url = string.format("%s/manhwa/library?buscar=%s&order_item=%s&order_dir=%s&page=%d",
        API, Http.urlEncode(text), order_item, order_dir, page - 1)
    if not opts.adult then url = url .. "&erotico=no" end
    local data, err = getJson(url)
    if not data then return nil, err end
    if type(data.data) ~= "table" then
        return nil, T(_("Unexpected reply from the site: %1"), "no data")
    end
    local items = {}
    for __, r in ipairs(data.data) do
        local item = libraryItem(r)
        if item and (opts.adult or not item.adult) then table.insert(items, item) end
    end
    return items, data.next == true
end

-- Full title details, chapters included. Cached on the item.
function ManhwaWeb:getDetail(item)
    if item.detail then return item.detail end
    local d, err = self:fetchDetail(item.id)
    if not d then return nil, err end
    item.detail = d
    item.title = titleOf(d) or item.title
    item.adult = item.adult or d._erotico == "si"
    return d
end

function ManhwaWeb:describe(item, opts)
    local d, err = self:getDetail(item)
    if not d then return item.title .. "\n\n" .. err end
    local lines = { item.title, "" }

    local authors = names(d.autor)
    local artists = names(d.artista)
    if #authors > 0 then table.insert(lines, T(_("By %1"), table.concat(authors, ", "))) end
    if #artists > 0 and table.concat(artists, ", ") ~= table.concat(authors, ", ") then
        table.insert(lines, T(_("Art: %1"), table.concat(artists, ", ")))
    end

    local info = {}
    if str(d._tipo) then table.insert(info, capitalize(d._tipo)) end
    if str(d._demografi) then table.insert(info, capitalize(d._demografi)) end
    if str(d._status) then table.insert(info, STATUS[d._status] or capitalize(d._status)) end
    local count = #list(d.chapters)
    if count > 0 then table.insert(info, T(_("%1 chapters"), count)) end
    if #info > 0 then table.insert(lines, table.concat(info, " · ")) end

    -- Each genre is a single-entry map like {"3": "Accion"}.
    local genres = {}
    for __, g in ipairs(list(d._categoris)) do
        if type(g) == "table" then
            for __, name in pairs(g) do
                if str(name) then table.insert(genres, trim(name)) end
            end
        end
    end
    if #genres > 0 then table.insert(lines, T(_("Tags: %1"), table.concat(genres, ", "))) end

    local alt = {}
    for __, n in ipairs(list(d.others_name)) do
        if str(n) and trim(n) ~= "" then table.insert(alt, trim(n)) end
    end
    if #alt > 0 then table.insert(lines, T(_("Also known as: %1"), table.concat(alt, ", "))) end

    if str(d._sinopsis) then
        table.insert(lines, "")
        table.insert(lines, trim(d._sinopsis:gsub("\r", "")))
    end
    return table.concat(lines, "\n")
end

-- Plain (non-pattern) replace of every occurrence.
local function replacePlain(s, old, new)
    if old == new or old == "" then return s end
    local out, pos = {}, 1
    while true do
        local i, j = s:find(old, pos, true)
        if not i then break end
        table.insert(out, s:sub(pos, i - 1))
        table.insert(out, new)
        pos = j + 1
    end
    table.insert(out, s:sub(pos))
    return table.concat(out)
end

-- Every upload ("version") of every released chapter is one row. chapter.id
-- is the site's chapter key, "<real_id>-<number>_<version>".
function ManhwaWeb:getChapters(item, opts)
    local d, err = self:getDetail(item)
    if not d then return nil, err end
    local old_id, real_id = str(d._id) or d.real_id, d.real_id
    local chapters = {}
    for __, c in ipairs(list(d.chapters)) do
        local number = tonumber(c.chapter)
        for __, v in ipairs(list(c.versions)) do
            -- No date means the chapter isn't released yet.
            if number and str(v.link) and tonumber(v.create) then
                -- Links still use the old id, which the API rejects.
                local key = lastSegment(replacePlain(v.link, old_id, real_id))
                local title = T(_("Chapter %1"), numberText(number))
                local groups = names(v.joint)
                table.insert(chapters, {
                    id = key,
                    number = number,
                    title = title,
                    group = #groups > 0 and table.concat(groups, ", ") or nil,
                    file_title = item.title .. " - " .. title,
                    item = item,
                })
            end
        end
    end
    -- The site lists chapters oldest first; show newest first.
    table.sort(chapters, function(a, b)
        if a.number ~= b.number then return a.number > b.number end
        return a.id < b.id
    end)
    logger.info("APIKOmic: manhwaweb chapters for", item.id, #chapters)
    return chapters
end

function ManhwaWeb:getPages(chapter, opts)
    local data, err = getJson(API .. "/chapters/see/" .. Http.urlEncode(chapter.id))
    if not data then
        -- A missing chapter answers 404, or sometimes plain text, not JSON.
        if err == T(_("HTTP error %1"), 404)
            or err == _("The site returned something that is not valid JSON.") then
            return nil, _("This chapter is no longer on ManhwaWeb.")
        end
        return nil, err
    end
    local ch = type(data.chapter) == "table" and data.chapter or {}
    local pages = {}
    for __, url in ipairs(list(ch.img)) do
        url = str(url)
        if url and url:match("^https?://") then
            table.insert(pages, { urls = { url }, ext = url:match("^[^?#]*%.(%w+)$") or "webp" })
        end
    end
    if #pages == 0 then return nil, _("This chapter has no pages.") end
    logger.info("APIKOmic: manhwaweb pages:", #pages, pages[1].urls[1])
    return pages
end

return ManhwaWeb
