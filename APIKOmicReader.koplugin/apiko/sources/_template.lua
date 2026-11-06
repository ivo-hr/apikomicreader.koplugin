-- Template for a new source. Files starting with "_" are not loaded.
--
-- To add a source: copy this file to apiko/sources/<name>.lua (e.g. mysite.lua),
-- fill it in, copy the plugin to the device and restart KOReader. The source
-- then appears in the plugin's source picker. If it fails to load, the reason
-- is in koreader/crash.log (search for "APIKOmic: skipping source").
--
-- Everything the plugin does with the source goes through the functions
-- below; downloads, history, library, bookmarks, saved searches, covers and
-- parental controls all work automatically.
local _ = require("gettext")
local logger = require("logger")

local Http = require("apiko.http")
-- Http.getJson(url, { user_agent = ..., referer = ... }) -> table | nil, error text
-- Http.get(url, opts)                                     -> body string | nil, error text
-- Http.urlEncode(text)                                    -> text for a URL query

local Source = {
    -- Required -------------------------------------------------------------
    id = "mysite",                  -- unique; letters, digits, "-". Used in file names.
    name = "My Site",               -- shown in the plugin.

    -- Optional -------------------------------------------------------------
    domain = "mysite.example",      -- shown in "Test connection".
    base = "https://mysite.example",-- sent as Referer for covers and pages.
    adult = false,                  -- true: the whole source is 18+ (hidden by parental controls).
    single_chapter = false,         -- true: items are read directly (no chapter list), like nhentai.
    user_agent = nil,               -- custom User-Agent for this site's requests.
    search_hint = _("Title"),       -- placeholder in the search box.
    order = 100,                    -- position in the source list (lower first).
    sorts = {                       -- offered in the search box; ids are passed to search().
        { id = "popular", text = _("Popular") },
        { id = "latest", text = _("Latest") },
    },
}

-- opts, passed to every function:
--   opts.adult       true if adult content may be returned (parental controls)
--   opts.language    chapter language chosen in Settings, e.g. "en"
--   opts.data_saver  true if smaller page images are preferred

-- Returns items, has_more  (or nil, error text).
-- query may be "" (browse); page starts at 1; sort is one of `sorts` ids or nil.
-- Item fields: id (required, no spaces), title (required), subtitle, thumb
-- (cover image URL), adult (true for an 18+ title in a mixed source). Any
-- other fields are kept on the item for your own use (e.g. raw API data).
function Source:search(query, page, sort, opts)
    local data, err = Http.getJson(string.format("%s/api/search?q=%s&page=%d",
        self.base, Http.urlEncode(query), page), { user_agent = self.user_agent })
    if not data then return nil, err end
    local items = {}
    for __, r in ipairs(data.results or {}) do
        table.insert(items, {
            id = tostring(r.id),
            title = r.title,
            subtitle = r.status,
            thumb = r.cover_url,
            adult = r.nsfw == true and true or false,
        })
    end
    return items, page < (data.total_pages or 1)
end

-- Optional. Text for the details screen (title, authors, tags, description...).
-- Fetch more data here if search results don't have it.
function Source:describe(item, opts)
    return item.title .. "\n\n" .. (item.subtitle or "")
end

-- Returns the chapters of an item, newest first (or nil, error).
-- Chapter fields: id (required, unique within the source, no spaces), title
-- (required), number (chapter number, e.g. 12 or 12.5: used by "Download a
-- range" and to skip duplicate translations in bulk downloads), group (shown
-- on the right), file_title (name for the downloaded file; default title),
-- item (the item it belongs to).
-- For single_chapter sources, return one chapter with the item's id.
function Source:getChapters(item, opts)
    local data, err = Http.getJson(self.base .. "/api/comic/" .. item.id .. "/chapters")
    if not data then return nil, err end
    local chapters = {}
    for __, c in ipairs(data.chapters or {}) do
        table.insert(chapters, {
            id = tostring(c.id),
            number = tonumber(c.number),
            title = c.name,
            file_title = item.title .. " - " .. c.name,
            item = item,
        })
    end
    return chapters
end

-- Returns the pages of a chapter, in reading order (or nil, error).
-- Each page lists one or more image URLs, tried in order until one works.
function Source:getPages(chapter, opts)
    local data, err = Http.getJson(self.base .. "/api/chapter/" .. chapter.id .. "/pages")
    if not data then return nil, err end
    local pages = {}
    for __, url in ipairs(data.images or {}) do
        table.insert(pages, { urls = { url } })
    end
    logger.info("APIKOmic: mysite pages:", #pages)
    return pages
end

return Source
