-- The plugin's home screen: logo, source picker, search bar and a grid of
-- tiles (saved searches, bookmarks, library...). Long-pressing the logo shows
-- or hides adult content; while it is shown the logo blushes and a warning
-- sits at the bottom.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Paths = require("apiko.paths")

local Screen = Device.screen

-- Wraps a widget so tapping it calls on_tap, and holding it calls on_hold.
local Tappable = InputContainer:extend{
    on_tap = nil,
    on_hold = nil,
}

function Tappable:init()
    local size = self[1]:getSize()
    self.dimen = Geom:new{ w = size.w, h = size.h }
    self.ges_events = {}
    if self.on_tap then
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }
    end
    if self.on_hold then
        self.ges_events.Hold = { GestureRange:new{ ges = "hold", range = self.dimen } }
    end
end

function Tappable:onTap()
    if self.on_tap then self.on_tap() end
    return true
end

function Tappable:onHold()
    if self.on_hold then self.on_hold() end
    return true
end

local Home = InputContainer:extend{
    title = "APIKOmicReader",
    source_name = nil,   -- nil when no source is available
    adult_shown = false,
    tiles = nil,         -- { {id, label, icon, count?}, ... }
    on_search = nil,     -- function()
    on_source = nil,     -- function()
    on_tile = nil,       -- function(id)
    on_logo_hold = nil,  -- function(); shows or hides adult content
    queue_count = 0,     -- downloads waiting; a button shows at the top left when > 0
    on_queue = nil,      -- function()
    close_callback = nil,
    covers_fullscreen = true,
}

function Home:init()
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    if Device:hasKeys() then
        self.key_events = { Close = { { "Back" } } }
    end
    self[1] = self:build()
end

-- One of the plugin's SVG icons, or a dot if it is missing.
function Home:icon(name, size)
    local file = Paths.asset("icons/" .. name .. ".svg")
    if lfs.attributes(file, "mode") == "file" then
        local ok, widget = pcall(ImageWidget.new, ImageWidget, {
            file = file, width = size, height = size, alpha = true,
        })
        if ok then return widget end
        logger.warn("APIKOmic: cannot load icon", file, widget)
    end
    return CenterContainer:new{
        dimen = Geom:new{ w = size, h = size },
        TextWidget:new{ text = "•", face = Font:getFace("cfont", 24) },
    }
end

-- The logo, blushing while adult content is shown. Holding it calls on_logo_hold.
function Home:logo(size)
    local file = Paths.asset(self.adult_shown and "logo_blush.png" or "logo.png")
    local image
    if lfs.attributes(file, "mode") == "file" then
        image = ImageWidget:new{ file = file, width = size, height = size, scale_factor = 0 }
    else
        image = VerticalSpan:new{ width = size }
    end
    return Tappable:new{ on_hold = self.on_logo_hold, image }
end

function Home:build()
    local w, h = self.width, self.height
    local landscape = w > h
    local pad = Size.padding.large
    local gap = Screen:scaleBySize(12)
    local border = Screen:scaleBySize(2)
    local content_w = w - 4 * pad

    -- Close button, top right.
    local close = IconButton:new{
        icon = "close",
        width = Screen:scaleBySize(32),
        height = Screen:scaleBySize(32),
        padding = Size.padding.default,
        callback = function() self:onClose() end,
        show_parent = self,
    }
    local top
    if (self.queue_count or 0) > 0 and self.on_queue then
        local queue_text = TextWidget:new{
            text = T(_("Queue: %1"), self.queue_count),
            face = Font:getFace("cfont", 18),
        }
        local queue_h = queue_text:getSize().h + 2 * Size.padding.default
        local queue_button = Tappable:new{
            on_tap = self.on_queue,
            FrameContainer:new{
                radius = math.floor(queue_h / 2),
                bordersize = border,
                padding = Size.padding.default,
                padding_left = pad,
                padding_right = pad,
                queue_text,
            },
        }
        local spacer = math.max(0, w - 2 * pad - queue_button:getSize().w - close:getSize().w)
        top = HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = pad },
            queue_button,
            HorizontalSpan:new{ width = spacer },
            close,
            HorizontalSpan:new{ width = pad },
        }
    else
        top = RightContainer:new{
            dimen = Geom:new{ w = w, h = close:getSize().h },
            HorizontalGroup:new{ close, HorizontalSpan:new{ width = pad } },
        }
    end

    -- Logo and name.
    local logo_h = math.floor(h * (landscape and 0.17 or 0.15))
    local logo = self:logo(logo_h)
    local title = TextWidget:new{
        text = self.title,
        face = Font:getFace("tfont", 28),
        bold = true,
    }

    -- Source chip: "MangaDex ⌄".
    local chip
    if self.source_name then
        local chip_text = TextWidget:new{ text = self.source_name, face = Font:getFace("cfont", 18) }
        local chip_h = chip_text:getSize().h + 2 * Size.padding.default
        chip = Tappable:new{
            on_tap = self.on_source,
            FrameContainer:new{
                radius = math.floor(chip_h / 2),
                bordersize = border,
                padding = Size.padding.default,
                padding_left = pad,
                padding_right = pad,
                HorizontalGroup:new{
                    align = "center",
                    chip_text,
                    HorizontalSpan:new{ width = Size.padding.default },
                    self:icon("chevron_down", Screen:scaleBySize(16)),
                },
            },
        }
    else
        chip = TextWidget:new{
            text = _("No sources available"),
            face = Font:getFace("cfont", 18),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
    end

    -- Search bar.
    local bar_h = Screen:scaleBySize(54)
    local search_icon_size = Screen:scaleBySize(26)
    local bar_inner_w = content_w - 2 * border - pad
    local bar = Tappable:new{
        on_tap = self.on_search,
        FrameContainer:new{
            width = content_w,
            height = bar_h,
            radius = math.floor(bar_h / 2),
            bordersize = border,
            padding = 0,
            padding_left = pad,
            LeftContainer:new{
                dimen = Geom:new{ w = bar_inner_w, h = bar_h - 2 * border },
                HorizontalGroup:new{
                    align = "center",
                    self:icon("search", search_icon_size),
                    HorizontalSpan:new{ width = pad },
                    TextWidget:new{
                        text = self.source_name and T(_("Search %1…"), self.source_name) or _("Search"),
                        face = Font:getFace("cfont", 20),
                        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                        max_width = bar_inner_w - search_icon_size - 2 * pad,
                    },
                },
            },
        },
    }

    -- Warning at the bottom while adult content is shown.
    local warning
    if self.adult_shown then
        warning = FrameContainer:new{
            bordersize = border,
            radius = Size.radius.window,
            padding = Size.padding.default,
            padding_left = pad,
            padding_right = pad,
            TextWidget:new{
                text = _("Adult content is visible. Long-press the logo to hide it."),
                face = Font:getFace("cfont", 16),
                bold = true,
                max_width = content_w - 2 * pad - 2 * border,
            },
        }
    else
        warning = VerticalSpan:new{ width = 0 }
    end

    -- Room left for the tiles, after everything else and the spacing.
    local spaces = 7
    local fixed = top:getSize().h + logo:getSize().h + title:getSize().h + chip:getSize().h
        + bar_h + warning:getSize().h + spaces * gap
    local tiles = self.tiles or {}
    local cols = landscape and math.min(#tiles, 6) or 3
    if cols < 1 then cols = 1 end
    local rows = math.ceil(#tiles / cols)
    local tile_w = math.floor((content_w - gap * (cols - 1)) / cols)
    local avail = h - fixed
    local tile_h = math.max(Screen:scaleBySize(70),
        math.min(math.floor(tile_w * 0.9), math.floor((avail - gap * (rows - 1)) / math.max(rows, 1))))

    local grid = VerticalGroup:new{ align = "center" }
    for r = 1, rows do
        local row = HorizontalGroup:new{ align = "top" }
        for c = 1, cols do
            local t = tiles[(r - 1) * cols + c]
            if t then
                if c > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
                table.insert(row, self:tile(t, tile_w, tile_h, border))
            end
        end
        if r > 1 then table.insert(grid, VerticalSpan:new{ width = gap }) end
        table.insert(grid, row)
    end

    -- Spread what's left between the top and bottom of the page.
    local leftover = math.max(0, avail - grid:getSize().h)
    local function space(extra) return VerticalSpan:new{ width = gap + (extra or 0) } end

    return FrameContainer:new{
        width = w,
        height = h,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            top,
            space(math.floor(leftover * 0.3)),
            logo,
            space(),
            title,
            space(),
            chip,
            space(),
            bar,
            space(math.floor(leftover * 0.2)),
            grid,
            space(math.floor(leftover * 0.3)),
            warning,
        },
    }
end

function Home:tile(t, tile_w, tile_h, border)
    local icon_size = math.floor(math.min(tile_w, tile_h) * 0.34)
    local text_w = tile_w - 2 * Size.padding.default
    local content = VerticalGroup:new{
        align = "center",
        self:icon(t.icon, icon_size),
        VerticalSpan:new{ width = Size.padding.default },
        TextWidget:new{ text = t.label, face = Font:getFace("cfont", 17), max_width = text_w },
    }
    if t.count then
        table.insert(content, TextWidget:new{
            text = t.count,
            face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = text_w,
        })
    end
    return Tappable:new{
        on_tap = function() self.on_tile(t.id) end,
        FrameContainer:new{
            width = tile_w,
            height = tile_h,
            radius = Size.radius.window,
            bordersize = border,
            padding = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = tile_w - 2 * border, h = tile_h - 2 * border },
                content,
            },
        },
    }
end

function Home:onClose()
    -- Full refresh, or e-ink keeps showing the home screen after it closed.
    UIManager:close(self, "flashui")
    if self.close_callback then self.close_callback() end
    return true
end

function Home:onCloseWidget()
    if self[1] and self[1].free then self[1]:free() end
end

return Home
