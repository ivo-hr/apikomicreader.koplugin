--[[
=============================================================================
  TEMPLATE FOR ADDING A NEW COMIC SITE
=============================================================================

  You don't need to know how to program to use this. You only fill in the
  blanks in PART 1 and PART 2 below. Everything after the line that says
  "YOU DON'T NEED TO CHANGE ANYTHING BELOW" works on its own.

  HOW TO USE IT
  -------------
    1. Make a copy of this file in the same folder and rename the copy,
       for example "mysite.lua". Use only lowercase letters, no spaces.
       (Files whose name starts with "_", like this one, are ignored.)
    2. Open the copy with any text editor (Notepad works) and fill in
       PART 1 and PART 2.
    3. Copy the plugin to your e-reader and restart KOReader. The site now
       shows up in the plugin's list of sites.
    4. If it does NOT show up, open the file koreader/crash.log on the
       e-reader and search for "skipping source". The line tells you what
       is wrong.

  WHAT KIND OF SITE WORKS?
  ------------------------
  The site needs an "API": special web addresses that return plain data
  instead of a web page. To check, open the address in your computer's
  browser. If you see text like this, it's an API and it will work:

      { "results": [ { "id": 123, "title": "My Comic", "cover": "https://..." } ] }

  If you see a normal web page with pictures and menus, it is not an API.
  Look for the site's "API documentation" (search the web for
  "<site name> API").

  A FEW RULES FOR WRITING THINGS IN THIS FILE
  -------------------------------------------
    * Lines starting with "--" are notes for humans. The plugin ignores them.
    * Text goes between double quotes:   name = "My Site",
    * Keep the comma at the end of each line inside { ... }.
    * true / false / nil are written without quotes. nil means "nothing".
    * If you break something, compare with this template or with
      mangadex.lua / nhentai.lua / archive.lua in the same folder.
=============================================================================
--]]

local _ = require("gettext")
local Http = require("apiko.http")

-----------------------------------------------------------------------------
-- PART 1: ABOUT THE SITE
-----------------------------------------------------------------------------
local Source = {
    -- A short code for the site. Lowercase letters, numbers and "-" only.
    -- No two sites can have the same one. Don't change it later: your
    -- downloads are stored in a folder with this name.
    id = "mysite",

    -- The name you'll see in the plugin.
    name = "My Site",

    -- The site's main address, without a "/" at the end.
    base = "https://mysite.example",

    -- The site's domain, shown when you use "Test connection".
    domain = "mysite.example",

    -- Is the WHOLE site for adults only (18+)? true or false.
    -- If true, the site is hidden while parental controls are on.
    adult = false,

    -- Does each comic have chapters (false), or is each comic just one
    -- set of pages with no chapters (true)?
    single_chapter = false,

    -- Grey hint text shown inside the search box.
    search_hint = _("Title"),

    -- Where the site goes in the list of sites. Lower numbers go first.
    order = 100,

    -- Some sites ask you to identify your program. Leave it as nil unless
    -- the site's API documentation asks for a "User-Agent".
    user_agent = nil,

    -- Sort options shown in the search box. "id" is the word the site
    -- expects in its address (see {sort} in PART 2); "text" is what you see.
    -- If the site has no sort options, you can leave these as they are.
    sorts = {
        { id = "popular", text = _("Popular") },
        { id = "latest", text = _("Latest") },
    },
}

-----------------------------------------------------------------------------
-- PART 2: THE SITE'S API
-----------------------------------------------------------------------------
-- There are three steps: SEARCH for comics, get a comic's CHAPTERS, and get
-- a chapter's PAGES (the images). For each one you write:
--
--   * the web ADDRESS that gives the data, with a few {words in braces}
--     that the plugin fills in for you, and
--   * the NAMES of the fields in the answer where each piece of data is.
--
-- HOW TO FIND THE FIELD NAMES: open the address in your browser (put in a
-- real search word or id) and look at the answer. Example answer:
--
--     {
--       "total_pages": 5,
--       "results": [
--         { "id": 123, "title": "My Comic", "cover": "https://.../123.jpg" }
--       ]
--     }
--
-- Here the list of comics is in "results", each comic's id is "id", its
-- title is "title", its cover is "cover", and the number of pages of
-- results is "total_pages".
--
-- If a field is INSIDE another field, join the names with dots. For
--     { "data": { "attributes": { "title": "My Comic" } } }
-- you'd write "data.attributes.title".
--
-- If the site doesn't have a field, write nil (without quotes).

-- ----- SEARCH -------------------------------------------------------------
-- {query} = what you typed in the search box (empty when just browsing)
-- {page}  = 1 for the first page of results, 2 for the next one...
-- {sort}  = the "id" of the sort option you picked in PART 1
local SEARCH_ADDRESS = "https://mysite.example/api/search?q={query}&page={page}&sort={sort}"

local SEARCH_LIST     = "results"      -- where the list of comics is
local COMIC_ID        = "id"           -- each comic's id (number or code)
local COMIC_TITLE     = "title"        -- each comic's title
local COMIC_SUBTITLE  = "status"       -- small text under the title, or nil
local COMIC_COVER     = "cover"        -- address of the cover image, or nil
local COMIC_IS_ADULT  = nil            -- field that is true for 18+ comics, or nil
local TOTAL_PAGES     = "total_pages"  -- how many pages of results, or nil
-- (With TOTAL_PAGES = nil the plugin just keeps asking for the next page
-- until the site returns an empty list.)

-- ----- CHAPTERS -----------------------------------------------------------
-- Skipped if single_chapter = true in PART 1.
-- {id} = the comic's id (from COMIC_ID above)
local CHAPTERS_ADDRESS = "https://mysite.example/api/comic/{id}/chapters"

local CHAPTERS_LIST    = "chapters"    -- where the list of chapters is
local CHAPTER_ID       = "id"          -- each chapter's id
local CHAPTER_TITLE    = "name"        -- each chapter's title, or nil
local CHAPTER_NUMBER   = "number"      -- chapter number (like 12 or 12.5), or nil
local CHAPTER_GROUP    = nil           -- translator/group name, or nil

-- Does the site list the OLDEST chapter first? true or false.
local OLDEST_FIRST = false

-- ----- PAGES --------------------------------------------------------------
-- {id} = the chapter's id (from CHAPTER_ID above). For single_chapter
-- sites, it's the comic's id.
local PAGES_ADDRESS = "https://mysite.example/api/chapter/{id}/pages"

local PAGES_LIST  = "images"   -- where the list of page images is
-- If each entry of that list is just an image address, like
--     "images": [ "https://.../1.jpg", "https://.../2.jpg" ]
-- leave PAGE_IMAGE = nil. If each entry has more stuff in it, like
--     "images": [ { "url": "https://.../1.jpg", "width": 800 } ]
-- write the name of the field with the address, here "url".
local PAGE_IMAGE  = nil

-- If the image addresses are incomplete, like "/img/1.jpg" instead of
-- "https://mysite.example/img/1.jpg", write the missing beginning here,
-- e.g. "https://mysite.example". Otherwise leave it as "".
local PAGE_IMAGE_START = ""


--[[
=============================================================================
  YOU DON'T NEED TO CHANGE ANYTHING BELOW THIS LINE.

  (For programmers: the plugin calls Source:search, Source:getChapters,
  Source:getPages and, optionally, Source:describe. You can replace any of
  them with your own code for sites that don't fit the simple settings
  above. Each receives `opts` with opts.adult, opts.language and
  opts.data_saver. See mangadex.lua for a full hand-written example.)
=============================================================================
--]]

-- Reads a field like "data.attributes.title" from the site's answer.
local function field(data, path)
    if path == nil or path == "" then return data end
    for key in tostring(path):gmatch("[^%.]+") do
        if type(data) ~= "table" then return nil end
        local value = data[key]
        if value == nil and tonumber(key) then value = data[tonumber(key)] end
        data = value
    end
    return data
end

local function text(value)
    if type(value) == "number" then return tostring(value) end
    if type(value) == "string" and value ~= "" then return value end
    return nil
end

local function list(data, path)
    local value = field(data, path)
    return type(value) == "table" and value or {}
end

-- Fills the {words} in an address.
local function address(pattern, values)
    return (pattern:gsub("{(%w+)}", function(key)
        local value = values[key]
        return value ~= nil and Http.urlEncode(tostring(value)) or ""
    end))
end

local function getJson(self, url)
    return Http.getJson(url, { user_agent = self.user_agent, referer = self.base })
end

-- Returns items, has_more (or nil, error text).
function Source:search(query, page, sort, opts)
    local data, err = getJson(self, address(SEARCH_ADDRESS, {
        query = query, page = page, sort = sort or (self.sorts and self.sorts[1] and self.sorts[1].id),
    }))
    if not data then return nil, err end
    local items = {}
    for __, r in ipairs(list(data, SEARCH_LIST)) do
        local id = text(field(r, COMIC_ID))
        if id then
            table.insert(items, {
                id = id,
                title = text(field(r, COMIC_TITLE)) or id,
                subtitle = COMIC_SUBTITLE and text(field(r, COMIC_SUBTITLE)) or nil,
                thumb = COMIC_COVER and text(field(r, COMIC_COVER)) or nil,
                adult = self.adult or (COMIC_IS_ADULT ~= nil and field(r, COMIC_IS_ADULT) == true),
            })
        end
    end
    local has_more
    if TOTAL_PAGES then
        has_more = page < (tonumber(field(data, TOTAL_PAGES)) or 1)
    else
        has_more = #items > 0
    end
    return items, has_more
end

-- Text for the details screen.
function Source:describe(item, opts)
    return item.title .. (item.subtitle and ("\n\n" .. item.subtitle) or "")
end

-- Returns the chapters of an item, newest first (or nil, error text).
function Source:getChapters(item, opts)
    if self.single_chapter then
        return { { id = item.id, title = item.title, file_title = item.title, item = item } }
    end
    local data, err = getJson(self, address(CHAPTERS_ADDRESS, { id = item.id }))
    if not data then return nil, err end
    local chapters = {}
    for __, c in ipairs(list(data, CHAPTERS_LIST)) do
        local id = text(field(c, CHAPTER_ID))
        if id then
            local number = CHAPTER_NUMBER and tonumber(field(c, CHAPTER_NUMBER)) or nil
            local title = CHAPTER_TITLE and text(field(c, CHAPTER_TITLE))
                or (number and (_("Chapter") .. " " .. number)) or id
            table.insert(chapters, {
                id = id,
                number = number,
                title = title,
                group = CHAPTER_GROUP and text(field(c, CHAPTER_GROUP)) or nil,
                file_title = item.title .. " - " .. title,
                item = item,
            })
        end
    end
    if OLDEST_FIRST then
        for i = 1, math.floor(#chapters / 2) do
            chapters[i], chapters[#chapters - i + 1] = chapters[#chapters - i + 1], chapters[i]
        end
    end
    return chapters
end

-- Returns the pages of a chapter, in reading order (or nil, error text).
function Source:getPages(chapter, opts)
    local data, err = getJson(self, address(PAGES_ADDRESS, { id = chapter.id }))
    if not data then return nil, err end
    local pages = {}
    for __, p in ipairs(list(data, PAGES_LIST)) do
        local url = text(field(p, PAGE_IMAGE))
        if url then
            table.insert(pages, { urls = { PAGE_IMAGE_START .. url } })
        end
    end
    if #pages == 0 then return nil, _("This chapter has no pages.") end
    return pages
end

return Source
