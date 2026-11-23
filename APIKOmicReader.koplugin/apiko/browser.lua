-- Full-screen, paged view of comics with covers: a grid, or a list with
-- covers. Covers are fetched one by one after the page is shown.
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local RenderImage = require("ui/renderimage")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

local function freeWidget(w)
    if w and w.free then w:free() end
end

-- One comic: cover plus title, tappable.
local Cell = InputContainer:extend{
    browser = nil,
    item = nil,
    width = 0,
    height = 0,
}

function Cell:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    self[1] = self:build()
end

-- A plain w×h box with a border, for placeholders and the pile behind a
-- collection's cover.
local function box(w, h, color, background, child)
    local border = Size.border.thin
    return FrameContainer:new{
        padding = 0,
        bordersize = border,
        color = color,
        background = background,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * border, h = h - 2 * border },
            child or HorizontalSpan:new{ width = 0 },
        },
    }
end

-- A small rounded label, white on black, that stands out on any cover.
local function badge(text, small)
    local h = Screen:scaleBySize(small and 20 or 26)
    local border = Size.border.thin
    local label = TextWidget:new{
        text = text,
        face = Font:getFace("cfont", small and 11 or 14),
        bold = true,
        fgcolor = Blitbuffer.COLOR_WHITE,
    }
    local w = math.max(h, label:getSize().w + h / 2)
    return FrameContainer:new{
        padding = 0,
        bordersize = border,
        color = Blitbuffer.COLOR_WHITE,
        background = Blitbuffer.COLOR_BLACK,
        radius = math.floor(h / 2),
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * border, h = h - 2 * border },
            label,
        },
    }
end

-- The cover image fitted into w×h, keeping its shape, and its size. Without
-- an image: "…" while loading, "×" when there is none.
function Cell:image(w, h)
    local data = self.browser.thumbs[self.item]
    if data then
        local ok, bb = pcall(RenderImage.renderImageData, RenderImage, data, #data, false)
        if ok and bb then
            local scale = math.min(w / bb:getWidth(), h / bb:getHeight())
            local iw = math.max(1, math.floor(bb:getWidth() * scale))
            local ih = math.max(1, math.floor(bb:getHeight() * scale))
            return ImageWidget:new{ image = bb, image_disposable = true, width = iw, height = ih, scale_factor = 0 },
                iw, ih
        end
        logger.info("APIKOmic: could not decode cover for", self.item.title)
    end
    return box(w, h, Blitbuffer.COLOR_LIGHT_GRAY, nil, TextWidget:new{
        text = data == false and "×" or "…",
        face = Font:getFace("cfont", 22),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }), w, h
end

-- The cover with its marks (see Browser.badges): a ✓ badge top right, a
-- number top left, a progress bar along the bottom and, for collections, a
-- pile of covers behind it.
function Cell:cover(w, h)
    local b = self.browser.badges and self.browser.badges(self.item) or {}
    local small = self.browser.mode ~= "grid"
    local pile = b.stack and Screen:scaleBySize(small and 4 or 7) or 0
    local border = pile > 0 and Size.border.thin or 0
    local img, iw, ih = self:image(w - 2 * pile - 2 * border, h - 2 * pile - 2 * border)
    if pile > 0 then
        img = FrameContainer:new{ padding = 0, bordersize = border, img }
        iw, ih = iw + 2 * border, ih + 2 * border
    end
    local group = OverlapGroup:new{ dimen = Geom:new{ w = iw + 2 * pile, h = ih + 2 * pile } }
    local function place(widget, x, y)
        widget.overlap_offset = { x, y }
        table.insert(group, widget)
    end
    if pile > 0 then
        place(box(iw, ih, Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_LIGHT_GRAY), 2 * pile, 0)
        place(box(iw, ih, Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE), pile, pile)
        place(img, 0, 2 * pile)
    else
        place(img, 0, 0)
    end
    local top = 2 * pile
    local margin = Screen:scaleBySize(small and 3 or 5)
    if b.count then
        place(badge(tostring(b.count), small), margin, top + margin)
    end
    if b.done then
        local check = badge("✓", small)
        place(check, iw - check:getSize().w - margin, top + margin)
    end
    if b.progress then
        local bar_h = Screen:scaleBySize(small and 5 or 8)
        place(ProgressWidget:new{
            width = iw - 2 * margin,
            height = bar_h,
            percentage = math.min(math.max(b.progress, 0), 1),
            margin_h = 0,
            margin_v = 0,
            radius = math.floor(bar_h / 2),
            bordersize = Size.border.thin,
            bordercolor = Blitbuffer.COLOR_BLACK,
            bgcolor = Blitbuffer.COLOR_WHITE,
            fillcolor = Blitbuffer.COLOR_BLACK,
        }, margin, top + ih - bar_h - margin)
    end
    return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, group }
end

-- Collections get a bold name as well as the pile.
function Cell:isPile()
    local b = self.browser.badges and self.browser.badges(self.item)
    return b and b.stack or false
end

function Cell:build()
    local pad = Size.padding.default
    if self.browser.mode == "grid" then
        local text_h = Screen:scaleBySize(44)
        local img_w = self.width - 2 * pad
        local img_h = self.height - text_h - 3 * pad
        return CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            VerticalGroup:new{
                align = "center",
                self:cover(img_w, img_h),
                VerticalSpan:new{ width = pad },
                TextBoxWidget:new{
                    text = self.item.title,
                    face = Font:getFace("cfont", 15),
                    bold = self:isPile(),
                    width = img_w,
                    height = text_h,
                    alignment = "center",
                    height_overflow_show_ellipsis = true,
                },
            },
        }
    end

    -- List with covers.
    local subtitle = self.browser.subtitle and self.browser.subtitle(self.item)
    local subtitle_h = subtitle and Screen:scaleBySize(28) or 0
    local line_h = Size.line.thin
    local thumb_h = self.height - line_h - 2 * pad
    local thumb_w = math.floor(thumb_h * 0.7)
    local text_w = self.width - thumb_w - 3 * pad
    local info = VerticalGroup:new{
        align = "left",
        TextBoxWidget:new{
            text = self.item.title,
            face = Font:getFace("cfont", 18),
            bold = self:isPile(),
            width = text_w,
            height = thumb_h - subtitle_h,
            height_overflow_show_ellipsis = true,
        },
    }
    if subtitle then
        table.insert(info, TextWidget:new{
            text = subtitle,
            face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = text_w,
        })
    end
    return VerticalGroup:new{
        align = "left",
        LeftContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height - line_h },
            HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = pad },
                self:cover(thumb_w, thumb_h),
                HorizontalSpan:new{ width = pad },
                info,
            },
        },
        LineWidget:new{
            dimen = Geom:new{ w = self.width, h = line_h },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        },
    }
end

function Cell:refresh()
    freeWidget(self[1])
    self[1] = self:build()
end

function Cell:onTap()
    if self.browser.on_tap then self.browser.on_tap(self.item) end
    return true
end

function Cell:onHold()
    if self.browser.on_hold then self.browser.on_hold(self.item) end
    return true
end

-- A slim, tappable strip under the title bar.
local Banner = InputContainer:extend{
    width = 0,
    text = "",
    callback = nil,
}

function Banner:init()
    local h = Screen:scaleBySize(38)
    self.dimen = Geom:new{ w = self.width, h = h }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    self[1] = FrameContainer:new{
        width = self.width,
        height = h,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = h },
            TextWidget:new{
                text = self.text,
                face = Font:getFace("cfont", 17),
                max_width = self.width - 2 * Size.padding.large,
            },
        },
    }
end

function Banner:onTap()
    if self.callback then self.callback() end
    return true
end

local Browser = InputContainer:extend{
    title = "",
    mode = "grid",      -- "grid" or "list_icons"
    items = nil,        -- { {title = ...}, ... }; may grow through load_more
    has_more = nil,     -- function() -> bool
    load_more = nil,    -- function() -> bool, true if items were appended
    fetch_thumb = nil,  -- function(item) -> image data or nil
    subtitle = nil,     -- function(item) -> string or nil
    badges = nil,       -- function(item) -> { done, progress = 0..1, count, stack } or nil
    on_tap = nil,       -- function(item)
    on_hold = nil,      -- function(item)
    on_back = nil,      -- function(); shows a back arrow when set
    banner = nil,       -- { text = ..., callback = function() }: strip under the title bar
    footer_buttons = nil, -- { { text = ..., callback = function() }, ... } left of the page arrows
    start_page = nil,
    close_callback = nil,
    covers_fullscreen = true,
}

function Browser:init()
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    local landscape = self.width > self.height
    if self.mode == "grid" then
        self.cols, self.rows = landscape and 4 or 3, landscape and 2 or 3
    else
        self.cols, self.rows = 1, landscape and 4 or 6
    end
    self.per_page = self.cols * self.rows
    self.page = math.min(math.max(self.start_page or 1, 1), self:pageCount())
    self.thumbs = {}  -- item -> image data, or false when unavailable
    self.generation = 0
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { "Back" } } }
    end
    self:update()
end

function Browser:pageCount()
    return math.max(1, math.ceil(#self.items / self.per_page))
end

function Browser:buildFooter()
    local pages = self:pageCount()
    local more = self.has_more and self.has_more() or false
    local prev = Button:new{
        icon = "chevron.left",
        bordersize = 0,
        enabled = self.page > 1,
        callback = function() self:prevPage() end,
        show_parent = self,
    }
    local next_page = Button:new{
        icon = "chevron.right",
        bordersize = 0,
        enabled = self.page < pages or more,
        callback = function() self:nextPage() end,
        show_parent = self,
    }
    local label = TextWidget:new{
        text = T(_("Page %1 of %2"), self.page, pages) .. (more and "+" or ""),
        face = Font:getFace("cfont", 18),
    }
    local gap = HorizontalSpan:new{ width = Screen:scaleBySize(32) }
    local h = math.max(prev:getSize().h, label:getSize().h)
    local group = HorizontalGroup:new{ align = "center" }
    for __, b in ipairs(self.footer_buttons or {}) do
        local button = Button:new{
            text = b.text,
            bordersize = 0,
            callback = b.callback,
            show_parent = self,
        }
        table.insert(group, button)
        table.insert(group, gap)
        h = math.max(h, button:getSize().h)
    end
    for __, w in ipairs{ prev, gap, label, gap, next_page } do table.insert(group, w) end
    return CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = h },
        group,
    }
end

function Browser:update()
    freeWidget(self[1])
    self.generation = self.generation + 1

    local title_bar = TitleBar:new{
        width = self.width,
        fullscreen = true,
        title = self.title,
        with_bottom_line = true,
        left_icon = self.on_back and "chevron.left" or nil,
        left_icon_tap_callback = self.on_back,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local footer = self:buildFooter()
    local banner = self.banner and Banner:new{
        width = self.width,
        text = self.banner.text,
        callback = self.banner.callback,
    }
    local grid_h = self.height - title_bar:getSize().h - footer:getSize().h
        - (banner and banner:getSize().h or 0)
    local cell_w = math.floor(self.width / self.cols)
    local cell_h = math.floor(grid_h / self.rows)

    self.cells = {}
    local grid = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * self.per_page
    for r = 1, self.rows do
        local row = HorizontalGroup:new{ align = "top" }
        for c = 1, self.cols do
            local item = self.items[first + (r - 1) * self.cols + c]
            if item then
                local cell = Cell:new{ browser = self, item = item, width = cell_w, height = cell_h }
                table.insert(self.cells, cell)
                table.insert(row, cell)
            end
        end
        if #row > 0 then table.insert(grid, row) end
    end
    -- Keep the footer at the bottom on a partly filled last page.
    local filler = VerticalSpan:new{ width = math.max(0, grid_h - grid:getSize().h) }

    local content = VerticalGroup:new{ align = "left", title_bar }
    if banner then table.insert(content, banner) end
    table.insert(content, grid)
    table.insert(content, filler)
    table.insert(content, footer)
    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        content,
    }
    UIManager:setDirty(self, "ui")
    self:loadThumbs()
end

-- Shows, changes or (nil) removes the strip under the title bar.
function Browser:setBanner(banner)
    self.banner = banner
    self:update()
end

function Browser:loadThumbs()
    if not self.fetch_thumb then return end
    local generation = self.generation
    local queue = {}
    for __, cell in ipairs(self.cells) do
        if self.thumbs[cell.item] == nil then table.insert(queue, cell) end
    end
    local function step()
        -- Stop when the page changed or the view was closed.
        if generation ~= self.generation then return end
        local cell = table.remove(queue, 1)
        if not cell then return end
        local ok, data = pcall(self.fetch_thumb, cell.item)
        if not ok then logger.warn("APIKOmic: cover failed:", data) end
        self.thumbs[cell.item] = ok and data or false
        cell:refresh()
        UIManager:setDirty(self, function() return "ui", cell.dimen end)
        UIManager:scheduleIn(0.05, step)
    end
    if #queue > 0 then UIManager:scheduleIn(0.3, step) end
end

function Browser:nextPage()
    if self.page < self:pageCount() then
        self.page = self.page + 1
        return self:update()
    end
    if self.has_more and self.has_more() and self.load_more and self.load_more() then
        if self.page < self:pageCount() then self.page = self.page + 1 end
        self:update()
    end
end

function Browser:prevPage()
    if self.page > 1 then
        self.page = self.page - 1
        self:update()
    end
end

function Browser:onSwipe(arg, ges)
    if ges.direction == "west" then
        self:nextPage()
        return true
    elseif ges.direction == "east" then
        self:prevPage()
        return true
    end
end

function Browser:onClose()
    -- Full refresh, or e-ink keeps showing the list after it closed.
    UIManager:close(self, "flashui")
    if self.close_callback then self.close_callback() end
    return true
end

function Browser:onCloseWidget()
    self.generation = self.generation + 1
    freeWidget(self[1])
end

return Browser
