local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local Event = require("ui/event")

-- Plugin-local modules must be required at load time, while the plugin
-- directory is on package.path.
local Browser = require("apiko.browser")
local Home = require("apiko.home")
local Comics = require("apiko.comics")
local Http = require("apiko.http")
local Library = require("apiko.library")
local Paths = require("apiko.paths")
local Settings = require("apiko.settings")
local Sources = require("apiko.sources")
local Store = require("apiko.store")
local ZipWriter = require("apiko.zipwriter")

local ApiKomic = WidgetContainer:extend{
    name = "apikomicreader",
    is_doc_only = false,
}

-- Shared by the file manager's and the reader's instances of the plugin.
local adult_unlocked = false -- PIN entered since the plugin was last left or the device slept
local return_nav = nil       -- screens to restore after closing a comic opened from the plugin
local return_ready = false   -- that comic was closed: restore return_nav in the file manager
local queue_running = false   -- the download queue is being processed

local VIEW_MODES = {
    { id = "grid", text = _("Grid with covers") },
    { id = "list_icons", text = _("List with covers") },
    { id = "list", text = _("Simple list") },
}

local PANELS_MODES = {
    { id = "manga", text = _("Manga (right to left)") },
    { id = "comic", text = _("Comic (left to right)") },
    { id = "off", text = _("Leave Panels+ as it is") },
}

local function choiceText(choices, id)
    for __, c in ipairs(choices) do
        if c.id == id then return c.text end
    end
    return choices[1].text
end

local function imageExt(data)
    if data:sub(1, 3) == "\255\216\255" then return "jpg" end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
    if data:sub(1, 4) == "GIF8" then return "gif" end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return "webp" end
end

local function safeName(s)
    s = s:gsub("[%c/\\:%*%?\"<>|]", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
    if #s > 80 then s = s:sub(1, 80) end
    return s
end

local function showMessage(msg)
    UIManager:show(InfoMessage:new{ text = msg })
end

-- Shows a message, repaints, and runs a blocking function. Returns its
-- results, or nil and the error text if it raised one.
local function busy(text, fn)
    local msg = InfoMessage:new{ text = text }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local ok, a, b = pcall(fn)
    UIManager:close(msg)
    if not ok then
        logger.err("APIKOmic:", a)
        return nil, tostring(a)
    end
    return a, b
end

-- Keeping the device awake while downloads run ---------------------------------------
local awake_count = 0
local last_pulse = 0

local function awakeStart()
    awake_count = awake_count + 1
    if awake_count == 1 then pcall(UIManager.preventStandby, UIManager) end
end

local function awakeStop()
    awake_count = math.max(0, awake_count - 1)
    if awake_count == 0 then pcall(UIManager.allowStandby, UIManager) end
end

-- Call often while downloading: restarts the auto-suspend countdown (at most every 5 s).
local function awakePulse()
    local now = os.time()
    if now - last_pulse < 5 then return end
    last_pulse = now
    pcall(function() UIManager:broadcastEvent(Event:new("InputEvent")) end)
end

-- Runs fn with standby and auto-suspend held off; returns its results.
local function whileAwake(fn)
    awakeStart()
    local ok, a, b = pcall(fn)
    awakeStop()
    if not ok then error(a, 0) end
    return a, b
end

local PARALLEL_CHOICES = {
    { id = 1, text = _("1 (one at a time)") },
    { id = 2, text = "2" },
    { id = 3, text = "3" },
    { id = 4, text = "4" },
    { id = 6, text = "6" },
}

local function hashPin(pin)
    local sha2 = require("ffi/sha2")
    return (sha2.sha256 or sha2.md5)("apikomicreader:" .. pin)
end

-- Parental controls ------------------------------------------------------------------
-- Adult sources (nhentai) and adult titles (e.g. MangaDex erotica) are hidden
-- unless allowed: with a PIN, after entering it; without one, by the toggle.

local function adultAllowed()
    local s = Settings.get()
    if s.pin_hash then return adult_unlocked end
    return s.show_adult == true
end

local function isVisible(thing)
    return not thing.adult or adultAllowed()
end

-- Entries of list that may be shown now.
local function visible(list)
    if adultAllowed() then return list end
    local out = {}
    for __, e in ipairs(list) do
        if not e.adult then table.insert(out, e) end
    end
    return out
end

local function visibleSources()
    return visible(Sources.list)
end

local function activeSource()
    local source = Sources.get(Settings.get().active_source)
    if source and isVisible(source) then return source end
    return visibleSources()[1]
end

local function isAdultFile(file)
    local source_id, __, adult = Comics.parseName(file:match("([^/]+)$") or "")
    if adult then return true end
    local source = source_id and Sources.get(source_id)
    return source ~= nil and source.adult == true
end

local function sourceOpts()
    local s = Settings.get()
    return { adult = adultAllowed(), language = s.language, data_saver = s.data_saver }
end

-- Init -------------------------------------------------------------------------------

function ApiKomic:init()
    self.nav = {}
    self.last_queries = {}
    self.last_sorts = {}
    -- Offer the app icon to launchers such as ZenOS (KOReader's user icons).
    pcall(Paths.installIcon)
    self.ui.menu:registerToMainMenu(self)
    -- Back in the file manager after reading one of our comics: return to
    -- the screen it was opened from.
    if not self.ui.document and return_ready and return_nav then
        local nav = return_nav
        return_nav, return_ready = nil, false
        UIManager:nextTick(function()
            self.nav = nav
            self:navShow()
        end)
    end
end

function ApiKomic:addToMainMenu(menu_items)
    menu_items.apikomicreader = {
        text = _("APIKOmicReader"),
        sorting_hint = "tools",
        callback = function() self:open() end,
    }
end

function ApiKomic:open()
    self.nav = {}
    self:navPush{ screen = "home" }
end

-- PIN ----------------------------------------------------------------------------------

function ApiKomic:askPin(title, callback)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = "",
        text_type = "password",
        input_type = "number",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("OK"), is_enter_default = true, callback = function()
                local pin = dialog:getInputText()
                UIManager:close(dialog)
                callback(pin)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ApiKomic:checkPin(title, fn)
    self:askPin(title, function(pin)
        if hashPin(pin) == Settings.get().pin_hash then fn() else showMessage(_("Wrong PIN.")) end
    end)
end

-- Shows or hides adult content.
function ApiKomic:toggleAdult()
    local s = Settings.get()
    if adultAllowed() then
        if s.pin_hash then
            adult_unlocked = false
        else
            s.show_adult = false
            Settings.save()
        end
        return self:navRefresh()
    end
    if s.pin_hash then
        self:checkPin(_("Enter PIN to show adult content"), function()
            adult_unlocked = true
            self:navRefresh()
        end)
    else
        s.show_adult = true
        Settings.save()
        self:navRefresh()
    end
end

function ApiKomic:pinSettings()
    local s = Settings.get()
    local function setNew()
        self:askPin(_("New PIN (at least 4 digits)"), function(pin1)
            if #pin1 < 4 then return showMessage(_("Use at least 4 digits.")) end
            self:askPin(_("Repeat the new PIN"), function(pin2)
                if pin1 ~= pin2 then return showMessage(_("The PINs don't match.")) end
                s.pin_hash = hashPin(pin1)
                s.show_adult = false
                Settings.save()
                adult_unlocked = false
                showMessage(_("PIN set. Adult content is now hidden until the PIN is entered."))
                self:navRefresh()
            end)
        end)
    end
    if not s.pin_hash then return setNew() end
    local dialog
    dialog = ButtonDialog:new{
        title = _("Parental controls PIN"),
        buttons = {
            {{ text = _("Change PIN"), callback = function()
                UIManager:close(dialog)
                self:checkPin(_("Current PIN"), setNew)
            end }},
            {{ text = _("Remove PIN"), callback = function()
                UIManager:close(dialog)
                self:checkPin(_("Current PIN"), function()
                    s.pin_hash = nil
                    s.show_adult = adult_unlocked
                    Settings.save()
                    showMessage(_("PIN removed."))
                    self:navRefresh()
                end)
            end }},
        },
    }
    UIManager:show(dialog)
end

-- Navigation ---------------------------------------------------------------------
-- self.nav is a stack of screen entries ({screen = "home"}, {screen = "results",
-- source = ..., state = ...}, ...). The top one is shown; back pops it. Entries
-- also keep the page their view was on, so going back returns to the same place.

-- refresh: also redraw the whole screen, needed when nothing of ours replaces
-- the view (leaving the plugin); otherwise e-ink keeps showing it.
function ApiKomic:closeView(refresh)
    if self.view then
        local view = self.view
        self.view = nil
        if refresh then
            UIManager:close(view, "flashui")
        else
            UIManager:close(view)
        end
    end
end

function ApiKomic:rememberPage()
    local entry = self.nav[#self.nav]
    if entry and self.view and self.view.page then entry.page = self.view.page end
end

function ApiKomic:navShow()
    self:closeView()
    local entry = self.nav[#self.nav]
    if not entry then return end
    -- A screen of a source that is now hidden (adult content locked): go home.
    if entry.source and not isVisible(entry.source) then
        self.nav = { { screen = "home" } }
        entry = self.nav[1]
    end
    self.screens[entry.screen](self, entry)
end

function ApiKomic:navPush(entry)
    self:rememberPage()
    table.insert(self.nav, entry)
    self:navShow()
end

function ApiKomic:navBack()
    table.remove(self.nav)
    if #self.nav == 0 then return self:exit() end
    self:navShow()
end

-- Rebuilds the current screen, e.g. after a change.
function ApiKomic:navRefresh()
    if #self.nav == 0 then return end
    self:rememberPage()
    self:navShow()
end

-- Drops an empty screen that was just opened and says why.
function ApiKomic:navEmpty(message)
    table.remove(self.nav)
    self:navShow()
    showMessage(message)
end

function ApiKomic:topScreen()
    local entry = self.nav[#self.nav]
    return entry and entry.screen
end

function ApiKomic:exit()
    self:closeView(true)
    self.nav = {}
    adult_unlocked = false
end

-- KOReader's Menu may call close_callback after an item is selected, which
-- would close the list under us. Item callbacks call this first so that one
-- close is ignored; the flag is dropped on the next tick in case the Menu
-- does not call close_callback at all.
function ApiKomic:keepViewOpen()
    self.keep_view_open = true
    UIManager:nextTick(function() self.keep_view_open = nil end)
end

function ApiKomic:wrapItems(item_table)
    for __, it in ipairs(item_table) do
        local cb = it.callback
        if cb and not it.wrapped then
            it.callback = function()
                self:keepViewOpen()
                cb()
            end
            it.wrapped = true
        end
    end
    return item_table
end

-- Simple list screen with back and close buttons. Items take text,
-- mandatory, callback and hold_callback.
function ApiKomic:showMenu(entry, title, item_table)
    local queue_item = self:queueMenuItem(entry)
    if queue_item then table.insert(item_table, 1, queue_item) end
    local view
    view = Menu:new{
        title = title,
        item_table = self:wrapItems(item_table),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        title_bar_left_icon = #self.nav > 1 and "chevron.left" or nil,
        onLeftButtonTap = function() self:navBack() end,
        close_callback = function()
            if self.keep_view_open then
                self.keep_view_open = nil
                return
            end
            self:exit()
        end,
    }
    view.onMenuHold = function(menu_self, menu_item)
        if menu_item and menu_item.hold_callback then menu_item.hold_callback() end
        return true
    end
    self.view = view
    UIManager:show(view)
    if entry.page and entry.page > 1 then pcall(view.onGotoPage, view, entry.page) end
    return view
end

-- Shows comics as a grid, a list with covers or a simple list, per the
-- "view_mode" setting. opts:
--   title, items
--   has_more() -> bool, load_more() -> bool (appends to items)  [optional]
--   fetch_thumb(item) -> image data | nil                        [optional]
--   subtitle(item) -> string | nil                               [optional]
--   on_tap(item), on_hold(item)                                  [on_hold optional]
function ApiKomic:showItems(entry, opts)
    local mode = Settings.get().view_mode
    local actions = opts.actions or {}
    if mode == "grid" or mode == "list_icons" then
        local view = Browser:new{
            title = opts.title,
            mode = mode,
            items = opts.items,
            start_page = entry.page,
            has_more = opts.has_more,
            load_more = opts.load_more,
            fetch_thumb = opts.fetch_thumb,
            subtitle = opts.subtitle,
            on_tap = opts.on_tap,
            on_hold = opts.on_hold,
            on_back = #self.nav > 1 and function() self:navBack() end or nil,
            banner = self:queueBanner(entry),
            footer_buttons = actions,
            close_callback = function() self:exit() end,
        }
        self.view = view
        UIManager:show(view)
        return
    end

    local view
    local function buildTable()
        local menu_items = {}
        -- Actions (e.g. sorting) come first, as rows.
        for __, a in ipairs(actions) do
            table.insert(menu_items, { text = a.long_text or a.text, callback = a.callback })
        end
        for __, item in ipairs(opts.items) do
            table.insert(menu_items, {
                text = item.title,
                mandatory = opts.subtitle and opts.subtitle(item) or nil,
                callback = function() opts.on_tap(item) end,
                hold_callback = opts.on_hold and function() opts.on_hold(item) end or nil,
            })
        end
        if opts.has_more and opts.has_more() then
            table.insert(menu_items, {
                text = _("Load more…"),
                callback = function()
                    local queue_item = self:queueMenuItem(entry)
                    local first_new = #opts.items + 1 + #actions + (queue_item and 1 or 0)
                    if not opts.load_more() then return end
                    if self.view == view then
                        local rows = buildTable()
                        if queue_item then table.insert(rows, 1, queue_item) end
                        view:switchItemTable(nil, self:wrapItems(rows), first_new)
                    else
                        self:navRefresh()
                    end
                end,
            })
        end
        return menu_items
    end
    view = self:showMenu(entry, opts.title, buildTable())
end

-- Home -----------------------------------------------------------------------------

function ApiKomic:pickSource()
    local dialog
    local rows = {}
    local current = activeSource()
    for __, source in ipairs(visibleSources()) do
        table.insert(rows, {{
            text = (source == current and "✓ " or "") .. source.name .. (source.adult and "  (18+)" or ""),
            callback = function()
                UIManager:close(dialog)
                Settings.get().active_source = source.id
                Settings.save()
                self:navRefresh()
            end,
        }})
    end
    dialog = ButtonDialog:new{ title = _("Source"), buttons = rows }
    UIManager:show(dialog)
end

function ApiKomic:showHome(entry)
    -- No source when every installed one is adult content and that is hidden.
    local source = activeSource()
    local tiles = {}
    if source then
        local function count(list) return tostring(#list) end
        tiles = {
            { id = "saved", label = _("Saved searches"), icon = "saved", count = count(Store.savedSearches(source.id)) },
            { id = "searches", label = _("Recent"), icon = "recent", count = count(Store.searches(source.id)) },
            { id = "bookmarks", label = _("Bookmarks"), icon = "bookmark", count = count(visible(Store.bookmarks(source.id))) },
            { id = "library", label = _("Library"), icon = "library", count = count(visible(Comics.list(Paths.library(source.id)))) },
            { id = "history", label = _("History"), icon = "history", count = count(visible(Comics.list(Paths.history(source.id)))) },
        }
    end
    table.insert(tiles, { id = "settings", label = _("Settings"), icon = "settings" })

    local view = Home:new{
        source_name = source and source.name,
        adult_shown = adultAllowed(),
        queue_count = self:queueCount(),
        on_queue = function() self:navPush{ screen = "queue" } end,
        tiles = tiles,
        on_search = function()
            if source then self:showSearch(source) end
        end,
        on_source = function() self:pickSource() end,
        on_tile = function(id)
            if id == "settings" then
                self:navPush{ screen = "settings" }
            else
                self:navPush{ screen = id, source = source }
            end
        end,
        on_logo_hold = function() self:toggleAdult() end,
        close_callback = function() self:exit() end,
    }
    self.view = view
    -- Full refresh: the logo and icons would otherwise leave e-ink ghosting.
    UIManager:show(view, "flashui")
end

-- Search -------------------------------------------------------------------------

local function sortText(source, sort)
    for __, s in ipairs(source.sorts or {}) do
        if s.id == sort then return s.text end
    end
end

local function queryText(s)
    return s.query ~= "" and s.query or _("(everything)")
end

function ApiKomic:showSearch(source)
    local sorts = source.sorts or {}
    if not self.last_sorts[source.id] and sorts[1] then self.last_sorts[source.id] = sorts[1].id end

    local dialog
    local function currentQuery()
        return dialog:getInputText():match("^%s*(.-)%s*$")
    end

    local function go()
        local query = currentQuery()
        UIManager:close(dialog)
        self.last_queries[source.id] = query
        NetworkMgr:runWhenOnline(function() self:runSearch(source, query, self.last_sorts[source.id]) end)
    end

    local function pickSort()
        self.last_queries[source.id] = currentQuery()
        UIManager:close(dialog)
        local picker
        local rows = {}
        for __, s in ipairs(sorts) do
            table.insert(rows, {{
                text = (s.id == self.last_sorts[source.id] and "✓ " or "") .. s.text,
                callback = function()
                    self.last_sorts[source.id] = s.id
                    UIManager:close(picker)
                    self:showSearch(source)
                end,
            }})
        end
        picker = ButtonDialog:new{
            title = _("Sort by"),
            buttons = rows,
            -- Tapping outside brings the search box back.
            tap_close_callback = function() self:showSearch(source) end,
        }
        UIManager:show(picker)
    end

    local buttons = {
        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
    }
    if #sorts > 0 then
        table.insert(buttons, {
            text = T(_("Sort: %1"), sortText(source, self.last_sorts[source.id]) or _("Default")),
            callback = pickSort,
        })
    end
    table.insert(buttons, { text = _("Search"), is_enter_default = true, callback = go })

    local save_row = {{
        text = _("Save this search"),
        callback = function()
            if Store.saveSearch(source.id, currentQuery(), self.last_sorts[source.id]) then
                showMessage(_("Search saved."))
            else
                showMessage(_("This search is already saved."))
            end
        end,
    }}

    dialog = InputDialog:new{
        title = T(_("Search %1"), source.name),
        input = self.last_queries[source.id] or "",
        input_hint = source.search_hint,
        buttons = { save_row, buttons },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ApiKomic:runSearch(source, query, sort)
    local items, more = busy(_("Searching…"), function()
        return source:search(query, 1, sort, sourceOpts())
    end)
    if not items then return showMessage(more) end
    Store.addSearch(source.id, query, sort)
    if #items == 0 then return showMessage(_("No results.")) end
    self:navPush{
        screen = "results",
        source = source,
        state = { source = source, query = query, sort = sort, page = 1, items = items, has_more = more },
    }
end

-- Fetches the next page of results into state.items. Returns true on success.
function ApiKomic:fetchMore(state)
    local items, more = busy(_("Loading…"), function()
        return state.source:search(state.query, state.page + 1, state.sort, sourceOpts())
    end)
    if not items then
        showMessage(more)
        return false
    end
    state.page = state.page + 1
    for __, item in ipairs(items) do table.insert(state.items, item) end
    state.has_more = more
    return true
end

function ApiKomic:fetchThumb(source, item)
    if not item.thumb then return nil end
    local data = Http.get(item.thumb, { referer = source.base .. "/", user_agent = source.user_agent })
    if data and imageExt(data) then return data end
    return nil
end

local function subtitleOf(item)
    return item.subtitle
end

function ApiKomic:showResults(entry)
    local state = entry.state
    local source = state.source
    -- Results fetched while adult content was shown may need filtering now.
    local items = visible(state.items)
    local function load_more()
        local ok = self:fetchMore(state)
        if ok and items ~= state.items then
            for i = #items, 1, -1 do items[i] = nil end
            for __, item in ipairs(visible(state.items)) do table.insert(items, item) end
        end
        return ok
    end
    self:showItems(entry, {
        title = state.query ~= "" and T(_("%1: %2"), source.name, state.query) or source.name,
        items = items,
        has_more = function() return state.has_more end,
        load_more = load_more,
        fetch_thumb = function(item) return self:fetchThumb(source, item) end,
        subtitle = subtitleOf,
        on_tap = function(item) self:showDetails(source, item) end,
        on_hold = function(item) self:resultActions(source, item) end,
    })
end

function ApiKomic:resultActions(source, item)
    local queued = Store.isQueued(source.id, item.id)
    local dialog
    dialog = ButtonDialog:new{
        title = item.title,
        buttons = {
            {{ text = _("Details"), callback = function()
                UIManager:close(dialog)
                self:showDetails(source, item)
            end }},
            {{
                text = queued and _("In the download queue") or _("Add to download queue"),
                enabled = not queued,
                callback = function()
                    UIManager:close(dialog)
                    self:enqueue(source, item)
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

-- Recent and saved searches: tap runs the search again.
function ApiKomic:searchItems(source, list, on_hold)
    local items = {}
    for __, s in ipairs(list) do
        table.insert(items, {
            text = queryText(s),
            mandatory = sortText(source, s.sort),
            callback = function()
                NetworkMgr:runWhenOnline(function() self:runSearch(source, s.query, s.sort) end)
            end,
            hold_callback = function() on_hold(s) end,
        })
    end
    return items
end

function ApiKomic:showSearches(entry)
    local source = entry.source
    local items = self:searchItems(source, Store.searches(source.id), function(s)
        local dialog
        local saved = Store.isSearchSaved(s.source, s.query, s.sort)
        dialog = ButtonDialog:new{
            title = queryText(s),
            buttons = {
                {{
                    text = saved and _("Already saved") or _("Save this search"),
                    enabled = not saved,
                    callback = function()
                        UIManager:close(dialog)
                        Store.saveSearch(s.source, s.query, s.sort)
                        showMessage(_("Search saved."))
                    end,
                }},
                {{
                    text = _("Remove from recent searches"),
                    callback = function()
                        UIManager:close(dialog)
                        Store.removeSearch(s)
                        self:navRefresh()
                    end,
                }},
            },
        }
        UIManager:show(dialog)
    end)
    if #items == 0 then return self:navEmpty(_("No recent searches.")) end
    table.insert(items, {
        text = _("Clear recent searches"),
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = T(_("Clear all recent searches for %1?"), source.name),
                ok_text = _("Clear"),
                ok_callback = function()
                    Store.clearSearches(source.id)
                    self:navBack()
                end,
            })
        end,
    })
    self:showMenu(entry, T(_("Recent searches: %1"), source.name), items)
end

function ApiKomic:showSaved(entry)
    local source = entry.source
    local items = self:searchItems(source, Store.savedSearches(source.id), function(s)
        UIManager:show(ConfirmBox:new{
            text = T(_("Remove saved search \"%1\"?"), queryText(s)),
            ok_text = _("Remove"),
            ok_callback = function()
                Store.unsaveSearch(s)
                self:navRefresh()
            end,
        })
    end)
    if #items == 0 then
        return self:navEmpty(_("No saved searches yet. Use \"Save this search\" in the search box, or long-press a recent search."))
    end
    self:showMenu(entry, T(_("Saved searches: %1"), source.name), items)
end

-- Details and bookmarks -------------------------------------------------------------

function ApiKomic:showDetails(source, item)
    NetworkMgr:runWhenOnline(function()
        -- describe() may fetch the full title (tags, description), so show a busy message.
        local text, err = busy(_("Loading…"), function() return source:describe(item, sourceOpts()) end)
        local bookmarked = Store.isBookmarked(source.id, item.id)
        local viewer
        local function closeThen(fn)
            return function()
                UIManager:close(viewer)
                fn()
            end
        end
        local row1 = {{
            text = bookmarked and _("Remove bookmark") or _("Bookmark"),
            callback = closeThen(function()
                if bookmarked then
                    Store.removeBookmark(source.id, item.id)
                    showMessage(_("Bookmark removed."))
                else
                    Store.addBookmark(source.id, item, item.subtitle)
                    showMessage(_("Bookmarked."))
                end
                if self:topScreen() == "bookmarks" then self:navRefresh() end
            end),
        }}
        if source.single_chapter then
            table.insert(row1, {
                text = _("Save to library"),
                callback = closeThen(function() self:openItem(source, item, true) end),
            })
        end
        local queued = Store.isQueued(source.id, item.id)
        local row_queue = {{
            text = queued and _("In the download queue") or _("Add to download queue"),
            enabled = not queued,
            callback = closeThen(function() self:enqueue(source, item) end),
        }}
        local row2 = {
            { text = _("Close"), callback = function() UIManager:close(viewer) end },
            {
                text = source.single_chapter and _("Read") or _("Chapters"),
                callback = closeThen(function() self:openItem(source, item) end),
            },
        }
        viewer = TextViewer:new{
            title = item.title,
            text = text or err or item.title,
            buttons_table = { row1, row_queue, row2 },
        }
        UIManager:show(viewer)
    end)
end

function ApiKomic:showBookmarks(entry)
    local source = entry.source
    local items = {}
    for __, b in ipairs(visible(Store.bookmarks(source.id))) do
        table.insert(items, { id = b.id, title = b.title, subtitle = b.subtitle, thumb = b.thumb, adult = b.adult })
    end
    if #items == 0 then
        return self:navEmpty(_("No bookmarks yet. Open a title's details and tap Bookmark."))
    end
    self:showItems(entry, {
        title = T(_("Bookmarks: %1"), source.name),
        items = items,
        fetch_thumb = function(item) return self:fetchThumb(source, item) end,
        subtitle = subtitleOf,
        on_tap = function(item) self:showDetails(source, item) end,
        on_hold = function(item)
            UIManager:show(ConfirmBox:new{
                text = T(_("Remove bookmark \"%1\"?"), item.title),
                ok_text = _("Remove"),
                ok_callback = function()
                    Store.removeBookmark(source.id, item.id)
                    self:navRefresh()
                end,
            })
        end,
    })
end

-- Chapters --------------------------------------------------------------------------

-- One chapter per number, oldest first. Sites like MangaDex list the same
-- chapter once per translation group; the first one listed is kept.
local function readingOrder(chapters)
    local picked, seen = {}, {}
    for __, c in ipairs(chapters) do
        if c.number == nil or not seen[c.number] then
            if c.number ~= nil then seen[c.number] = true end
            table.insert(picked, c)
        end
    end
    local out = {}
    for i = #picked, 1, -1 do table.insert(out, picked[i]) end
    return out
end

-- Chapters whose number (or, when a site has no numbers, position from the
-- first chapter) is between from and to.
local function chapterRange(ordered, from, to)
    local use_numbers = false
    for __, c in ipairs(ordered) do
        if c.number then use_numbers = true break end
    end
    local selected = {}
    for i, c in ipairs(ordered) do
        local n = use_numbers and c.number or i
        if n and n >= from and n <= to then table.insert(selected, c) end
    end
    return selected, use_numbers
end

function ApiKomic:showChapters(entry)
    local source, item = entry.source, entry.item
    if not entry.chapters then
        local chapters, err = busy(_("Loading chapters…"), function()
            return source:getChapters(item, sourceOpts())
        end)
        if not chapters then return self:navEmpty(err) end
        if #chapters == 0 then
            return self:navEmpty(T(_("No chapters available in your language (%1). You can change it in Settings."),
                Settings.get().language))
        end
        entry.chapters = chapters
    end
    local downloaded, saved = {}, {}
    for __, c in ipairs(Comics.list(Paths.history(source.id))) do downloaded[c.id] = true end
    for __, c in ipairs(Comics.list(Paths.library(source.id))) do saved[c.id] = true end
    local items = {
        {
            text = _("Download all chapters"),
            mandatory = T(_("%1 chapters"), #readingOrder(entry.chapters)),
            callback = function() self:confirmBulk(source, item, readingOrder(entry.chapters)) end,
        },
        {
            text = _("Download a range…"),
            callback = function() self:askRange(source, item, entry.chapters) end,
        },
        {
            text = Store.isQueued(source.id, item.id) and _("All chapters are in the download queue")
                or _("Add all chapters to the download queue"),
            callback = function() self:enqueue(source, item) end,
        },
    }
    for __, chapter in ipairs(entry.chapters) do
        table.insert(items, {
            text = chapter.title,
            mandatory = (saved[chapter.id] and _("in library")) or (downloaded[chapter.id] and "✓") or chapter.group,
            callback = function() self:download(source, item, chapter) end,
            hold_callback = function()
                local dialog
                local queued_chapter = Store.isQueued(source.id, item.id, chapter.id)
                dialog = ButtonDialog:new{
                    title = chapter.title,
                    buttons = {
                        {{ text = _("Read"), callback = function()
                            UIManager:close(dialog)
                            self:download(source, item, chapter)
                        end }},
                        {{ text = _("Save to library"), enabled = not saved[chapter.id], callback = function()
                            UIManager:close(dialog)
                            self:download(source, item, chapter, true)
                        end }},
                        {{
                            text = queued_chapter and _("In the download queue") or _("Add to download queue"),
                            enabled = not queued_chapter,
                            callback = function()
                                UIManager:close(dialog)
                                self:enqueue(source, item, chapter)
                            end,
                        }},
                    },
                }
                UIManager:show(dialog)
            end,
        })
    end
    self:showMenu(entry, item.title, items)
end

-- History and library ------------------------------------------------------------

function ApiKomic:showComics(entry)
    local source = entry.source
    local library = entry.screen == "library"
    local items = visible(Comics.list(library and Paths.library(source.id) or Paths.history(source.id)))
    if #items == 0 then
        return self:navEmpty(library
            and _("The library is empty. Use \"Save to library\", or long-press a comic in History.")
            or _("No downloaded comics yet."))
    end
    self:showItems(entry, {
        title = T(library and _("Library: %1") or _("History: %1"), source.name),
        items = items,
        -- The cover is the CBZ's first page: works offline.
        fetch_thumb = function(item) return ZipWriter.readFirstEntry(item.path) end,
        subtitle = function(item) return os.date("%Y-%m-%d %H:%M", item.mtime) end,
        on_tap = function(item) self:openComic(item.path) end,
        on_hold = function(item) self:comicActions(source, item, library) end,
    })
end

-- Library ------------------------------------------------------------------------
-- The library groups chapters of the same title. Top level: the user's
-- collections, then titles that are in no collection (a title with a single
-- saved chapter is shown as that comic). A title opens to its chapters; a
-- collection opens to its titles.

function ApiKomic:askName(title, initial, callback)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = initial or "",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("OK"), is_enter_default = true, callback = function()
                local name = dialog:getInputText():match("^%s*(.-)%s*$")
                UIManager:close(dialog)
                if name ~= "" then callback(name) end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Tap a collection to add the title to it, or remove it (✓ = it is in it).
function ApiKomic:pickCollection(source, key, name)
    local dialog
    local rows = {}
    for __, c in ipairs(Store.collections(source.id)) do
        local has = Store.inCollection(c, key)
        table.insert(rows, {{
            text = (has and "✓ " or "") .. c.name,
            callback = function()
                UIManager:close(dialog)
                if has then Store.collectionRemove(c.id, key) else Store.collectionAdd(c.id, key) end
                showMessage(has and T(_("Removed from \"%1\"."), c.name) or T(_("Added to \"%1\"."), c.name))
                self:navRefresh()
            end,
        }})
    end
    table.insert(rows, {{
        text = _("New collection…"),
        callback = function()
            UIManager:close(dialog)
            self:askName(_("New collection"), "", function(new_name)
                local c = Store.addCollection(source.id, new_name)
                Store.collectionAdd(c.id, key)
                self:navRefresh()
            end)
        end,
    }})
    dialog = ButtonDialog:new{ title = T(_("Collections for \"%1\""), name), buttons = rows }
    UIManager:show(dialog)
end

local function statusText(c)
    if c.status == "read" then return _("Read") end
    if c.status == "reading" then return string.format("%d%%", math.floor((c.percent or 0) * 100)) end
    return _("Unread")
end

-- A group as shown in the library: a lone chapter is that comic itself.
local function groupItem(g)
    if #g.comics == 1 then
        local c = g.comics[1]
        c.series_name = g.name
        if c.status == "read" then
            local copy = {}
            for k, v in pairs(c) do copy[k] = v end
            copy.title = "✓ " .. c.title
            return copy
        end
        return c
    end
    return {
        kind = "series",
        key = g.key,
        name = g.name,
        group = g,
        title = (g.read == g.total and "✓ " or "") .. T(_("%1 (%2)"), g.name, g.total),
        path = g.comics[1].path,  -- the cover is the first chapter's first page
        adult = g.adult,
        mtime = g.mtime,
    }
end

local function libraryGroups(source)
    return Library.groups(source.id, visible(Comics.list(Paths.library(source.id))))
end

-- Sort button (a footer button in the grid/cover views, the first row in the simple list).
function ApiKomic:sortAction(kind)
    local s = Settings.get()
    local chapters = kind == "chapters"
    local choices = chapters and Library.CHAPTER_SORTS or Library.GROUP_SORTS
    local current = chapters and s.chapter_sort or s.library_sort
    return {
        text = _("Sort"),
        long_text = T(_("Sort: %1"), choiceText(choices, current)),
        callback = function() self:pickSort(kind) end,
    }
end

function ApiKomic:pickSort(kind)
    local s = Settings.get()
    local chapters = kind == "chapters"
    local key = chapters and "chapter_sort" or "library_sort"
    self:pickChoice(chapters and _("Sort chapters") or _("Sort library"),
        chapters and Library.CHAPTER_SORTS or Library.GROUP_SORTS, s[key], function(id)
            s[key] = id
            Settings.save()
            if self.view then self.view.page = 1 end  -- start from the top of the new order
            self:navRefresh()
        end)
end

function ApiKomic:showLibrary(entry)
    local source = entry.source
    local sort = Settings.get().library_sort
    local groups = libraryGroups(source)
    Library.sortGroups(groups, sort)
    local collection
    if entry.collection_id then
        collection = Store.collection(source.id, entry.collection_id)
        if not collection then return self:navEmpty(_("That collection no longer exists.")) end
    end

    local items = {}
    if collection then
        local members = {}
        for __, k in ipairs(collection.members) do members[k] = true end
        for __, g in ipairs(groups) do
            if members[g.key] then table.insert(items, groupItem(g)) end
        end
        if #items == 0 then
            return self:navEmpty(_("This collection is empty. Long-press a title in the library to add it."))
        end
    else
        local in_collection = {}
        local cols = {}
        for __, c in ipairs(Store.collections(source.id)) do
            local members = {}
            for __, k in ipairs(c.members) do
                members[k] = true
                in_collection[k] = true
            end
            local col = {
                kind = "collection", collection = c, key = c.id, name = c.name,
                title = "[" .. c.name .. "]", count = 0,
                total = 0, unread = 0, reading = 0, read = 0, last_read = 0, mtime = 0,
            }
            for __, g in ipairs(groups) do
                if members[g.key] then
                    col.count = col.count + 1
                    col.path = col.path or g.comics[1].path
                    col.total = col.total + g.total
                    col.unread = col.unread + g.unread
                    col.reading = col.reading + g.reading
                    col.read = col.read + g.read
                    col.last_read = math.max(col.last_read, g.last_read)
                    col.mtime = math.max(col.mtime, g.mtime)
                end
            end
            -- A collection holding only hidden (adult) titles stays out of sight.
            if col.count > 0 or #c.members == 0 then table.insert(cols, col) end
        end
        Library.sortGroups(cols, sort)
        for __, col in ipairs(cols) do table.insert(items, col) end
        for __, g in ipairs(groups) do
            if not in_collection[g.key] then table.insert(items, groupItem(g)) end
        end
        if #items == 0 then
            return self:navEmpty(_("The library is empty. Use \"Save to library\", or long-press a comic in History."))
        end
    end

    self:showItems(entry, {
        title = collection and T(_("Collection: %1"), collection.name) or T(_("Library: %1"), source.name),
        items = items,
        actions = { self:sortAction("library") },
        fetch_thumb = function(item) return item.path and ZipWriter.readFirstEntry(item.path) or nil end,
        subtitle = function(item)
            if item.kind == "collection" then return T(_("%1 titles"), item.count) end
            if item.kind == "series" then
                local g = item.group
                local text = T(_("%1 chapters"), g.total)
                if g.read == g.total then
                    text = text .. " · " .. _("read")
                elseif g.unread < g.total then
                    text = text .. " · " .. T(_("%1 unread"), g.unread)
                    if g.reading > 0 then text = text .. " · " .. _("reading") end
                end
                return text
            end
            return statusText(item) .. " · " .. os.date("%Y-%m-%d %H:%M", item.mtime)
        end,
        on_tap = function(item)
            if item.kind == "collection" then
                self:navPush{ screen = "collection", source = source, collection_id = item.collection.id }
            elseif item.kind == "series" then
                self:navPush{ screen = "series", source = source, group_key = item.key,
                              collection_id = entry.collection_id }
            else
                self:openComic(item.path)
            end
        end,
        on_hold = function(item)
            if item.kind == "collection" then
                self:collectionActions(source, item.collection)
            elseif item.kind == "series" then
                self:seriesActions(source, item.key, item.name, item.group.comics, entry.collection_id)
            else
                self:comicActions(source, item, true, entry.collection_id)
            end
        end,
    })
end

-- The chapters of one title.
function ApiKomic:showSeries(entry)
    local source = entry.source
    local group
    for __, g in ipairs(libraryGroups(source)) do
        if g.key == entry.group_key then group = g break end
    end
    if not group then return self:navEmpty(_("No chapters left in this title.")) end
    Library.sortChapters(group.comics, Settings.get().chapter_sort)
    -- Chapter names without the repeated title: "Title - Ch. 5" -> "Ch. 5",
    -- with a ✓ when read and the percentage when half-read.
    local prefix = safeName(group.name) .. " - "
    local items = {}
    for __, c in ipairs(group.comics) do
        local copy = {}
        for k, v in pairs(c) do copy[k] = v end
        if c.title:sub(1, #prefix) == prefix and #c.title > #prefix then
            copy.title = c.title:sub(#prefix + 1)
        end
        if c.status == "read" then
            copy.title = "✓ " .. copy.title
        elseif c.status == "reading" then
            copy.title = copy.title .. string.format(" (%d%%)", math.floor((c.percent or 0) * 100))
        end
        table.insert(items, copy)
    end
    self:showItems(entry, {
        title = group.name,
        items = items,
        actions = { self:sortAction("chapters") },
        fetch_thumb = function(item) return ZipWriter.readFirstEntry(item.path) end,
        subtitle = function(item) return statusText(item) .. " · " .. os.date("%Y-%m-%d %H:%M", item.mtime) end,
        on_tap = function(item) self:openComic(item.path) end,
        on_hold = function(item) self:comicActions(source, item, true) end,
    })
end

function ApiKomic:seriesActions(source, key, name, comics, collection_id)
    local dialog
    local rows = {
        {{ text = _("Collections…"), callback = function()
            UIManager:close(dialog)
            self:pickCollection(source, key, name)
        end }},
    }
    if collection_id then
        table.insert(rows, {{ text = _("Remove from this collection"), callback = function()
            UIManager:close(dialog)
            Store.collectionRemove(collection_id, key)
            self:navRefresh()
        end }})
    end
    table.insert(rows, {{ text = _("Delete all chapters"), callback = function()
        UIManager:close(dialog)
        UIManager:show(ConfirmBox:new{
            text = T(_("Delete all %1 chapters of \"%2\" from the library?"), #comics, name),
            ok_text = _("Delete"),
            ok_callback = function()
                for __, c in ipairs(comics) do Comics.delete(c.path) end
                self:navRefresh()
            end,
        })
    end }})
    dialog = ButtonDialog:new{ title = name, buttons = rows }
    UIManager:show(dialog)
end

function ApiKomic:collectionActions(source, collection)
    local dialog
    dialog = ButtonDialog:new{
        title = collection.name,
        buttons = {
            {{ text = _("Rename"), callback = function()
                UIManager:close(dialog)
                self:askName(_("Rename collection"), collection.name, function(name)
                    Store.renameCollection(collection.id, name)
                    self:navRefresh()
                end)
            end }},
            {{ text = _("Delete collection"), callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = T(_("Delete the collection \"%1\"? Its comics stay in the library."), collection.name),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        Store.deleteCollection(collection.id)
                        self:navRefresh()
                    end,
                })
            end }},
        },
    }
    UIManager:show(dialog)
end

-- collection_id: set when shown inside that collection.
function ApiKomic:comicActions(source, item, in_library, collection_id)
    local dialog
    local rows = {}
    if not in_library then
        table.insert(rows, {{
            text = _("Save to library"),
            callback = function()
                UIManager:close(dialog)
                local ok, err = Comics.move(item.path, Paths.library(source.id))
                showMessage(ok and _("Saved to library.") or T(_("Could not move it: %1"), err))
                self:navRefresh()
            end,
        }})
    else
        local key = item.group_key or Library.keyOf(source.id, item)
        local name = item.series_name or Library.nameOf(source.id, item)
        table.insert(rows, {{
            text = _("Collections…"),
            callback = function()
                UIManager:close(dialog)
                self:pickCollection(source, key, name)
            end,
        }})
        if collection_id then
            table.insert(rows, {{
                text = _("Remove from this collection"),
                callback = function()
                    UIManager:close(dialog)
                    Store.collectionRemove(collection_id, key)
                    self:navRefresh()
                end,
            }})
        end
    end
    table.insert(rows, {{
        text = _("Delete"),
        callback = function()
            UIManager:close(dialog)
            UIManager:show(ConfirmBox:new{
                text = T(_("Delete \"%1\"?"), item.title),
                ok_text = _("Delete"),
                ok_callback = function()
                    Comics.delete(item.path)
                    self:navRefresh()
                end,
            })
        end,
    }})
    dialog = ButtonDialog:new{ title = item.title, buttons = rows }
    UIManager:show(dialog)
end

-- Download & open ------------------------------------------------------------------

-- Single-chapter sources download right away; others open the chapter list.
-- to_library: save into the library (and don't open it) instead of reading now.
function ApiKomic:openItem(source, item, to_library)
    NetworkMgr:runWhenOnline(function()
        if not source.single_chapter then
            return self:navPush{ screen = "chapters", source = source, item = item }
        end
        local chapters, err = busy(_("Loading…"), function() return source:getChapters(item, sourceOpts()) end)
        if not chapters then return showMessage(err) end
        if #chapters == 0 then return showMessage(_("No chapters found.")) end
        self:download(source, item, chapters[1], to_library)
    end)
end

function ApiKomic:fetchImage(source, page)
    local urls = page.urls
    local start = (self.mirror_source == source.id and self.mirror_index) or 1
    local last_err
    for n = 0, #urls - 1 do
        local idx = (start - 1 + n) % #urls + 1
        local data, err = Http.get(urls[idx], { referer = source.base .. "/", user_agent = source.user_agent })
        if data and imageExt(data) then
            self.mirror_source, self.mirror_index = source.id, idx
            return data
        end
        last_err = err or _("The server did not return an image.")
        logger.info("APIKOmic: image failed", urls[idx], last_err)
    end
    return nil, last_err
end

function ApiKomic:download(source, item, chapter, to_library)
    local key = source.id .. "_" .. chapter.id
    local library_dir, history_dir = Paths.library(source.id), Paths.history(source.id)
    local in_library = Comics.find(library_dir, key)
    local in_history = Comics.find(history_dir, key)
    if to_library then
        if in_library then return showMessage(_("Already in the library.")) end
        if in_history then
            local ok, err = Comics.move(in_history, library_dir)
            showMessage(ok and _("Saved to library.") or T(_("Could not move it: %1"), err))
            if self:topScreen() == "chapters" then self:navRefresh() end
            return
        end
    else
        local existing = in_library or in_history
        if existing then return self:openComic(existing) end
    end

    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local dir = library_dir
            if not to_library then
                Comics.prune(source.id, math.max(1, tonumber(Settings.get().cache_keep) or 20))
                dir = history_dir
            end
            local path, err = self:fetchChapter(source, item, chapter, dir, "")
            Trapper:clear()
            if not path then
                if err then showMessage(err) end
                return
            end
            if to_library then
                showMessage(_("Saved to library."))
                if self:topScreen() == "chapters" then self:navRefresh() end
            else
                self:openComic(path)
            end
        end)
    end)
end

-- Downloads all pages into zip, in order. Several pages are fetched at once,
-- each by its own subprocess (a blocking socket call would freeze the screen
-- otherwise). Returns true, or nil and an error (no error when cancelled).
function ApiKomic:fetchPages(source, pages, zip, status)
    local total = #pages
    local parallel = math.min(8, math.max(1, tonumber(Settings.get().parallel_downloads) or 3))

    local function progress(n)
        return Trapper:info(status .. T(_("Downloading page %1 of %2…\n\nTap to cancel."), math.min(n, total), total))
    end

    -- One page at a time, in this process.
    local function sequential(from)
        for i = from, total do
            if not progress(i) then return nil end
            awakePulse()
            local data, err = self:fetchImage(source, pages[i])
            if not data then return nil, T(_("Page %1 failed: %2"), i, err) end
            zip:add(string.format("%04d.%s", i, imageExt(data) or "jpg"), data)
        end
        return true
    end
    if parallel <= 1 or total <= 1 then return sequential(1) end

    local dir = Paths.tmp()
    local function cleanTmp()
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then os.remove(dir .. "/" .. name) end
        end
    end
    cleanTmp()

    local workers, count = {}, 0   -- pid -> { i, tmp, tries }
    local ready = {}               -- page number -> true once its file is complete
    local next_start, next_write = 1, 1
    local window = parallel * 3    -- how far ahead of the page being written to fetch
    local last_info = os.time()

    local function tmpName(i) return string.format("%s/%d.img", dir, i) end

    local function startWorker(i, tries)
        local tmp = tmpName(i)
        os.remove(tmp)
        os.remove(tmp .. ".err")
        local ok, pid = pcall(ffiUtil.runInSubProcess, function()
            local data, err = self:fetchImage(source, pages[i])
            if data then
                local f = io.open(tmp .. ".part", "wb")
                if f then
                    f:write(data)
                    f:close()
                    os.rename(tmp .. ".part", tmp)
                    return
                end
                err = "cannot write a temporary file"
            end
            local f = io.open(tmp .. ".err", "wb")
            if f then
                f:write(tostring(err or "?"))
                f:close()
            end
        end)
        if not ok or not pid then return false end
        workers[pid] = { i = i, tmp = tmp, tries = tries }
        count = count + 1
        return true
    end

    local function stopAll()
        if next(workers) then
            for pid in pairs(workers) do pcall(ffiUtil.terminateSubProcess, pid) end
            ffiUtil.usleep(50000)
            for pid in pairs(workers) do pcall(ffiUtil.isSubProcessDone, pid) end
        end
        workers, count = {}, 0
        cleanTmp()
    end

    local function failed(i, err)
        stopAll()
        return nil, T(_("Page %1 failed: %2"), i, err or "?")
    end

    if not progress(1) then return nil end
    while next_write <= total do
        -- Collect finished workers; a page that failed is tried once more.
        local retry = {}
        for pid, w in pairs(workers) do
            if ffiUtil.isSubProcessDone(pid) then
                workers[pid] = nil
                count = count - 1
                if lfs.attributes(w.tmp, "mode") == "file" then
                    ready[w.i] = true
                else
                    local err
                    local f = io.open(w.tmp .. ".err", "rb")
                    if f then
                        err = f:read("*a")
                        f:close()
                    end
                    os.remove(w.tmp .. ".err")
                    if w.tries >= 2 then return failed(w.i, err) end
                    table.insert(retry, w)
                end
            end
        end
        for __, w in ipairs(retry) do
            if not startWorker(w.i, w.tries + 1) then return failed(w.i, _("could not start a download")) end
        end

        -- Write the pages that are ready, in order.
        local wrote = false
        while ready[next_write] do
            local tmp = tmpName(next_write)
            local f = io.open(tmp, "rb")
            local data = f and f:read("*a")
            if f then f:close() end
            os.remove(tmp)
            ready[next_write] = nil
            if not data or #data == 0 then return failed(next_write, _("empty file")) end
            zip:add(string.format("%04d.%s", next_write, imageExt(data) or "jpg"), data)
            next_write = next_write + 1
            wrote = true
        end
        if next_write > total then break end

        -- Keep the workers busy.
        while count < parallel and next_start <= total and next_start < next_write + window do
            if not startWorker(next_start, 1) then
                if count == 0 then
                    -- Cannot start subprocesses here: carry on one page at a time.
                    stopAll()
                    return sequential(next_write)
                end
                break
            end
            next_start = next_start + 1
        end

        if wrote then
            if not progress(next_write) then
                stopAll()
                return nil
            end
            last_info = os.time()
        else
            ffiUtil.usleep(40000)
            -- Now and then let a tap through, to cancel.
            if os.time() - last_info >= 2 then
                last_info = os.time()
                if not progress(next_write) then
                    stopAll()
                    return nil
                end
            end
        end
        awakePulse()
    end
    stopAll()
    return true
end

-- Downloads one chapter into dir as a CBZ; must run inside Trapper:wrap.
-- `status` is shown above the progress. Returns the file's path, or nil and
-- an error message (no message when the user cancelled). Keeps the device awake.
function ApiKomic:fetchChapter(source, item, chapter, dir, status)
    return whileAwake(function() return self:fetchChapterNow(source, item, chapter, dir, status) end)
end

function ApiKomic:fetchChapterNow(source, item, chapter, dir, status)
    if not Trapper:info(status .. _("Fetching page list…")) then return nil end
    local ok, pages, err = pcall(source.getPages, source, chapter, sourceOpts())
    if not ok then pages, err = nil, tostring(pages) end
    if not pages or #pages == 0 then return nil, err or _("No pages found.") end

    local title = safeName(chapter.file_title or chapter.title or item.title)
    local final = dir .. "/" .. Comics.fileName(source.id, chapter.id, item.adult or source.adult, title)
    local part = final .. ".part"
    local zip, zerr = ZipWriter.open(part)
    if not zip then return nil, T(_("Cannot write file: %1"), zerr) end

    local complete, derr = self:fetchPages(source, pages, zip, status)
    if not complete then
        zip:abort()
        os.remove(part)
        return nil, derr
    end
    zip:close()
    os.rename(part, final)
    -- Remember which title this chapter belongs to (the library groups by it).
    pcall(Store.setChapterMeta, source.id .. "_" .. chapter.id, item.title, chapter.number)
    return final
end

-- Saves one chapter to the library: "skipped" (already there), "saved", or
-- nil and an error (no error when the user cancelled). Moves it out of
-- History if it is there. Must run inside Trapper:wrap.
function ApiKomic:saveChapter(source, item, chapter, status)
    local key = source.id .. "_" .. chapter.id
    local library_dir, history_dir = Paths.library(source.id), Paths.history(source.id)
    if Comics.find(library_dir, key) then return "skipped" end
    local in_history = Comics.find(history_dir, key)
    if in_history and Comics.move(in_history, library_dir) then return "saved" end
    local path, err = self:fetchChapter(source, item, chapter, library_dir, status)
    if path then return "saved" end
    return nil, err
end

-- Bulk downloads ---------------------------------------------------------------------

function ApiKomic:askRange(source, item, chapters)
    local ordered = readingOrder(chapters)
    local low, high
    for __, c in ipairs(ordered) do
        if c.number then
            low = math.min(low or c.number, c.number)
            high = math.max(high or c.number, c.number)
        end
    end
    local description = low
        and T(_("Chapter numbers to save to the library, e.g. %1-%2."), low, high)
        or T(_("Chapters to save to the library, counted from the first (1-%1)."), #ordered)
    local dialog
    dialog = InputDialog:new{
        title = _("Download a range"),
        description = description,
        input = "",
        input_hint = low and (low .. "-" .. high) or ("1-" .. #ordered),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Download"), is_enter_default = true, callback = function()
                local text = dialog:getInputText()
                local from, to = text:match("^%s*([%d%.]+)%s*%-%s*([%d%.]+)%s*$")
                if not from then
                    from = text:match("^%s*([%d%.]+)%s*$")
                    to = from
                end
                from, to = tonumber(from), tonumber(to)
                if not from or not to then return showMessage(_("Type a range like 1-20.")) end
                if from > to then from, to = to, from end
                UIManager:close(dialog)
                local selected = chapterRange(ordered, from, to)
                if #selected == 0 then return showMessage(_("No chapters in that range.")) end
                self:confirmBulk(source, item, selected)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ApiKomic:confirmBulk(source, item, chapters)
    local library_dir = Paths.library(source.id)
    local todo = 0
    for __, c in ipairs(chapters) do
        if not Comics.find(library_dir, source.id .. "_" .. c.id) then todo = todo + 1 end
    end
    if todo == 0 then return showMessage(_("Those chapters are already in the library.")) end
    UIManager:show(ConfirmBox:new{
        text = T(_("Save %1 chapters of %2 to the library?\n\nThis can take a while and use a lot of space. Keep the device awake and on Wi-Fi; you can cancel at any time."),
            todo, item.title),
        ok_text = _("Download"),
        ok_callback = function() self:downloadChapters(source, item, chapters) end,
    })
end

-- Saves chapters to the library one after another, skipping those already
-- there and moving those already in History.
function ApiKomic:downloadChapters(source, item, chapters)
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local saved, skipped, failed, cancelled = 0, 0, {}, false
            awakeStart()
            local run_ok, run_err = pcall(function()
                for n, chapter in ipairs(chapters) do
                    local status = T(_("Chapter %1 of %2: %3\n"), n, #chapters, chapter.title)
                    local result, err = self:saveChapter(source, item, chapter, status)
                    if result == "saved" then
                        saved = saved + 1
                    elseif result == "skipped" then
                        skipped = skipped + 1
                    elseif err then
                        logger.warn("APIKOmic: chapter failed", chapter.id, err)
                        table.insert(failed, chapter.title .. ": " .. err)
                    else
                        cancelled = true
                        break
                    end
                end
            end)
            awakeStop()
            if not run_ok then
                logger.err("APIKOmic:", run_err)
                table.insert(failed, tostring(run_err))
            end
            Trapper:clear()
            local lines = { cancelled and _("Download cancelled.") or _("Download finished.") }
            table.insert(lines, T(_("Saved to library: %1"), saved))
            if skipped > 0 then table.insert(lines, T(_("Already there: %1"), skipped)) end
            if #failed > 0 then
                table.insert(lines, T(_("Failed: %1"), #failed))
                for i = 1, math.min(3, #failed) do table.insert(lines, "• " .. failed[i]) end
            end
            showMessage(table.concat(lines, "\n"))
            if self:topScreen() == "chapters" then self:navRefresh() end
        end)
    end)
end

-- Download queue --------------------------------------------------------------------
-- Titles (every chapter) or single chapters waiting to be saved to the library.
-- They are kept across restarts and downloaded one after another on request.

function ApiKomic:queueCount()
    return #visible(Store.queue())
end

-- Button for the top of a grid/cover view, or nil when there is no queue.
function ApiKomic:queueBanner(entry)
    if entry.screen == "queue" then return nil end
    local n = self:queueCount()
    if n == 0 then return nil end
    return {
        text = T(_("Download queue: %1 — tap to open"), n),
        callback = function() self:navPush{ screen = "queue" } end,
    }
end

-- First row for a list view, or nil when there is no queue.
function ApiKomic:queueMenuItem(entry)
    if entry.screen == "queue" then return nil end
    local n = self:queueCount()
    if n == 0 then return nil end
    return {
        text = T(_("Download queue (%1)"), n),
        mandatory = _("open"),
        callback = function() self:navPush{ screen = "queue" } end,
    }
end

-- The queue changed: update what is on screen.
function ApiKomic:queueChanged()
    local top = self:topScreen()
    if not top then return end
    local view = self.view
    if top ~= "queue" and view and view.setBanner then
        view:setBanner(self:queueBanner({ screen = top }))
    else
        self:navRefresh()
    end
end

-- chapter: nil for the whole title, or a chapter.
function ApiKomic:enqueue(source, item, chapter)
    local entry = Store.addToQueue(source.id, item, chapter and { id = chapter.id, title = chapter.title })
    if not entry then
        showMessage(_("Already in the download queue."))
        return
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Added to the download queue (%1)."), self:queueCount()),
        timeout = 2,
    })
    self:queueChanged()
end

function ApiKomic:showQueue(entry)
    local entries = visible(Store.queue())
    if #entries == 0 then return self:navEmpty(_("The download queue is empty.")) end
    local items = {
        {
            text = _("Start downloading"),
            mandatory = tostring(#entries),
            callback = function() self:runQueue() end,
        },
        {
            text = _("Clear the queue"),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Remove everything from the download queue?"),
                    ok_text = _("Clear"),
                    ok_callback = function()
                        for __, e in ipairs(entries) do Store.removeFromQueue(e.id) end
                        self:navRefresh()
                    end,
                })
            end,
        },
    }
    for __, e in ipairs(entries) do
        local source = Sources.get(e.source)
        local name = e.chapter_title and (e.item.title .. " – " .. e.chapter_title) or e.item.title
        local function actions() self:queueEntryActions(e, name) end
        table.insert(items, {
            text = name,
            mandatory = e.error and _("failed") or (source and source.name or e.source),
            callback = actions,
            hold_callback = actions,
        })
    end
    self:showMenu(entry, T(_("Download queue (%1)"), #entries), items)
end

function ApiKomic:queueEntryActions(e, name)
    local dialog
    dialog = ButtonDialog:new{
        title = e.error and (name .. "\n" .. e.error) or name,
        buttons = {
            {{ text = _("Move to the top"), callback = function()
                UIManager:close(dialog)
                Store.queueToTop(e.id)
                self:navRefresh()
            end }},
            {{ text = _("Remove from the queue"), callback = function()
                UIManager:close(dialog)
                Store.removeFromQueue(e.id)
                self:navRefresh()
            end }},
        },
    }
    UIManager:show(dialog)
end

function ApiKomic:runQueue()
    if queue_running then return showMessage(_("The queue is already downloading.")) end
    if self:queueCount() == 0 then return end
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            queue_running = true
            local ok, result = pcall(whileAwake, function() return self:processQueue() end)
            queue_running = false
            Trapper:clear()
            if not ok then
                logger.err("APIKOmic: queue failed:", result)
                result = tostring(result)
            end
            showMessage(result)
            self:queueChanged()
        end)
    end)
end

-- Downloads the queued titles one after another into the library. A title
-- that finishes leaves the queue; one with failures stays, marked "failed",
-- and is tried again next time. Returns a summary. Inside Trapper:wrap.
function ApiKomic:processQueue()
    local entries = visible(Store.queue())
    local saved, skipped, failed, cancelled = 0, 0, {}, false
    for n, entry in ipairs(entries) do
        local source = Sources.get(entry.source)
        local item = entry.item
        local status = T(_("Queue %1 of %2: %3\n"), n, #entries, item.title)
        Store.setQueueError(entry.id, nil)
        local problem
        if not source then
            problem = _("This source is not installed any more.")
        elseif not Trapper:info(status .. _("Loading chapters…")) then
            cancelled = true
            break
        else
            local ok, chapters, err = pcall(source.getChapters, source, item, sourceOpts())
            if not ok then chapters, err = nil, tostring(chapters) end
            if not chapters then
                problem = err or _("No chapters found.")
            else
                local list = {}
                if entry.chapter_id then
                    for __, c in ipairs(chapters) do
                        if c.id == entry.chapter_id then
                            list = { c }
                            break
                        end
                    end
                else
                    list = readingOrder(chapters)
                end
                if #list == 0 then problem = _("No chapters found.") end
                for i, chapter in ipairs(list) do
                    local label = status .. T(_("Chapter %1 of %2: %3\n"), i, #list, chapter.title)
                    local result, cerr = self:saveChapter(source, item, chapter, label)
                    if result == "saved" then
                        saved = saved + 1
                    elseif result == "skipped" then
                        skipped = skipped + 1
                    elseif cerr then
                        logger.warn("APIKOmic: queued chapter failed", chapter.id, cerr)
                        problem = problem or (chapter.title .. ": " .. cerr)
                    else
                        cancelled = true
                        break
                    end
                end
            end
        end
        if cancelled then break end
        if problem then
            Store.setQueueError(entry.id, problem)
            table.insert(failed, item.title .. ": " .. problem)
        else
            Store.removeFromQueue(entry.id)
        end
    end
    local lines = { cancelled and _("Queue stopped.") or _("Queue finished.") }
    table.insert(lines, T(_("Saved to library: %1"), saved))
    if skipped > 0 then table.insert(lines, T(_("Already there: %1"), skipped)) end
    if #failed > 0 then
        table.insert(lines, T(_("Failed: %1"), #failed))
        for i = 1, math.min(3, #failed) do table.insert(lines, "• " .. failed[i]) end
    end
    return table.concat(lines, "\n")
end

function ApiKomic:openComic(path)
    -- Come back to this screen when the comic is closed.
    self:rememberPage()
    return_nav, return_ready = self.nav, false
    self:closeView()
    self.nav = {}
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(path)
end

-- Reader hooks ---------------------------------------------------------------------

-- An adult comic of ours opened while adult content is hidden (e.g. through the
-- file browser with hidden files shown): close it, and reopen it after the PIN.
function ApiKomic:guardDocument(file)
    if adultAllowed() or not isAdultFile(file) then return false end
    UIManager:nextTick(function()
        self.ui:onClose()
        if Settings.get().pin_hash then
            self:checkPin(_("Enter PIN to open adult content"), function()
                adult_unlocked = true
                require("apps/reader/readerui"):showReader(file)
            end)
        else
            showMessage(_("This comic is hidden by APIKOmicReader's parental controls."))
        end
    end)
    return true
end

function ApiKomic:onReaderReady()
    local file = self.ui.document and self.ui.document.file
    if not Paths.isOurs(file) then
        -- Reading something else now: don't jump back into the plugin later.
        return_nav, return_ready = nil, false
        return
    end
    if self:guardDocument(file) then return end
    UIManager:nextTick(function() Comics.forget(file) end)
    self:setupPanelsPlus()
end

function ApiKomic:onCloseDocument()
    local file = self.ui.document and self.ui.document.file
    if Paths.isOurs(file) then
        Comics.forget(file)
        if return_nav then return_ready = true end
    end
end

function ApiKomic:onSuspend()
    if Settings.get().pin_hash and adult_unlocked then
        adult_unlocked = false
        -- Don't leave adult content on screen.
        self:closeView()
        self.nav = {}
        return_nav, return_ready = nil, false
    end
end

-- Panels+ (github.com/KristanLaimon/PanelsPlus): switch it on in the
-- configured mode when one of our comics opens.
function ApiKomic:setupPanelsPlus()
    local mode = Settings.get().panels_mode
    if mode ~= "manga" and mode ~= "comic" then return end
    -- Panels+ loads its per-document settings in its own onReaderReady; act
    -- after that so they don't override ours.
    UIManager:nextTick(function()
        local panels = self.ui.panelsplus
        if not panels then
            logger.info("APIKOmic: Panels+ not installed")
            return
        end
        if panels.isEnabled and panels.setEnabled and not panels:isEnabled() then
            panels:setEnabled(true)
        end
        if panels.setMode then panels:setMode(mode) end
        logger.info("APIKOmic: Panels+ set to", mode)
    end)
end

-- Settings -----------------------------------------------------------------------

function ApiKomic:pickChoice(title, choices, current, on_pick)
    local dialog
    local rows = {}
    for __, c in ipairs(choices) do
        table.insert(rows, {{
            text = (c.id == current and "✓ " or "") .. c.text,
            callback = function()
                UIManager:close(dialog)
                on_pick(c.id)
            end,
        }})
    end
    dialog = ButtonDialog:new{ title = title, buttons = rows }
    UIManager:show(dialog)
end

function ApiKomic:editText(title, description, value, on_save)
    local dialog
    dialog = InputDialog:new{
        title = title,
        description = description,
        input = value or "",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local v = dialog:getInputText():match("^%s*(.-)%s*$")
                UIManager:close(dialog)
                on_save(v)
                Settings.save()
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ApiKomic:testConnection(source)
    NetworkMgr:runWhenOnline(function()
        local items, err = busy(T(_("Contacting %1…"), source.domain), function()
            return source:search("", 1, nil, sourceOpts())
        end)
        if items then
            showMessage(T(_("%1: OK, received %2 results."), source.name, #items))
        else
            showMessage(err)
        end
    end)
end

function ApiKomic:showSettings(entry)
    local s = Settings.get()
    local source = activeSource()
    local items = {
        {
            text = T(_("View: %1"), choiceText(VIEW_MODES, s.view_mode)),
            callback = function()
                self:pickChoice(_("View"), VIEW_MODES, s.view_mode, function(id)
                    s.view_mode = id
                    Settings.save()
                    self:navRefresh()
                end)
            end,
        },
        {
            text = T(_("Chapter language: %1"), s.language),
            callback = function()
                self:editText(_("Chapter language"),
                    _("Language code for chapters and search results on sources with translations (MangaDex), e.g. en, es, fr, pt-br, ja."),
                    s.language, function(v)
                        if v ~= "" then s.language = v:lower() end
                        self:navRefresh()
                    end)
            end,
        },
        {
            text = s.data_saver and _("Page images: data saver (smaller)") or _("Page images: original quality"),
            callback = function()
                s.data_saver = not s.data_saver
                Settings.save()
                self:navRefresh()
            end,
        },
        {
            text = T(_("Parallel page downloads: %1"), tostring(s.parallel_downloads)),
            callback = function()
                self:pickChoice(_("Pages downloaded at the same time"), PARALLEL_CHOICES,
                    s.parallel_downloads, function(id)
                        s.parallel_downloads = id
                        Settings.save()
                        self:navRefresh()
                    end)
            end,
        },
        {
            text = T(_("Panels+: %1"), choiceText(PANELS_MODES, s.panels_mode)),
            callback = function()
                self:pickChoice(_("When a comic opens, set Panels+ to"), PANELS_MODES, s.panels_mode, function(id)
                    s.panels_mode = id
                    Settings.save()
                    self:navRefresh()
                end)
            end,
        },
        {
            text = T(_("Comics kept in history: %1"), s.cache_keep),
            callback = function()
                self:editText(_("Comics kept in history"),
                    _("For each source, older comics in History are deleted automatically. The library is never cleaned up."),
                    tostring(s.cache_keep), function(v)
                        s.cache_keep = math.max(1, tonumber(v) or 20)
                        self:navRefresh()
                    end)
            end,
        },
        {
            text = s.pin_hash and _("Parental controls PIN: on") or _("Parental controls PIN: off"),
            callback = function() self:pinSettings() end,
        },
    }
    if source then
        table.insert(items, {
            text = T(_("Test connection to %1"), source.name),
            callback = function() self:testConnection(source) end,
        })
        table.insert(items, {
            text = T(_("Clear history of %1"), source.name),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Delete all comics in %1's History? The library is not affected."), source.name),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        for __, c in ipairs(Comics.list(Paths.history(source.id))) do Comics.delete(c.path) end
                        showMessage(_("History cleared."))
                    end,
                })
            end,
        })
    end
    self:showMenu(entry, _("Settings"), items)
end

ApiKomic.screens = {
    home = ApiKomic.showHome,
    results = ApiKomic.showResults,
    searches = ApiKomic.showSearches,
    saved = ApiKomic.showSaved,
    bookmarks = ApiKomic.showBookmarks,
    chapters = ApiKomic.showChapters,
    library = ApiKomic.showLibrary,
    collection = ApiKomic.showLibrary,
    series = ApiKomic.showSeries,
    queue = ApiKomic.showQueue,
    history = ApiKomic.showComics,
    settings = ApiKomic.showSettings,
}

return ApiKomic
