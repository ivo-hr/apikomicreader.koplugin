-- Minimal streaming ZIP writer (stored entries only). Images are already
-- compressed, and writing each page straight to disk keeps memory use low.
local bit = require("bit")

local band, bxor, rshift = bit.band, bit.bxor, bit.rshift

local crc_table = {}
for i = 0, 255 do
    local c = i
    for __ = 1, 8 do
        if band(c, 1) ~= 0 then
            c = bxor(0xEDB88320, rshift(c, 1))
        else
            c = rshift(c, 1)
        end
    end
    crc_table[i] = c
end

local function crc32(s)
    local c = 0xFFFFFFFF
    for i = 1, #s do
        c = bxor(crc_table[band(bxor(c, s:byte(i)), 0xFF)], rshift(c, 8))
    end
    return bxor(c, 0xFFFFFFFF)
end

local function u16(n)
    return string.char(band(n, 0xFF), band(rshift(n, 8), 0xFF))
end

local function u32(n)
    return string.char(band(n, 0xFF), band(rshift(n, 8), 0xFF),
                       band(rshift(n, 16), 0xFF), band(rshift(n, 24), 0xFF))
end

local function dosDateTime()
    local t = os.date("*t")
    local time = t.hour * 2048 + t.min * 32 + math.floor(t.sec / 2)
    local date = (t.year - 1980) * 512 + t.month * 32 + t.day
    return time, date
end

local ZipWriter = {}
ZipWriter.__index = ZipWriter

function ZipWriter.open(path)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    local time, date = dosDateTime()
    return setmetatable({ f = f, entries = {}, offset = 0, time = time, date = date }, ZipWriter)
end

function ZipWriter:add(name, data)
    local crc = crc32(data)
    local header = table.concat{
        u32(0x04034b50), u16(10), u16(0), u16(0), u16(self.time), u16(self.date),
        u32(crc), u32(#data), u32(#data), u16(#name), u16(0),
    }
    self.f:write(header, name, data)
    table.insert(self.entries, { name = name, crc = crc, size = #data, offset = self.offset })
    self.offset = self.offset + #header + #name + #data
end

function ZipWriter:close()
    local cd_start = self.offset
    local cd_size = 0
    for __, e in ipairs(self.entries) do
        local rec = table.concat{
            u32(0x02014b50), u16(20), u16(10), u16(0), u16(0), u16(self.time), u16(self.date),
            u32(e.crc), u32(e.size), u32(e.size), u16(#e.name), u16(0), u16(0),
            u16(0), u16(0), u32(0), u32(e.offset), e.name,
        }
        self.f:write(rec)
        cd_size = cd_size + #rec
    end
    self.f:write(table.concat{
        u32(0x06054b50), u16(0), u16(0), u16(#self.entries), u16(#self.entries),
        u32(cd_size), u32(cd_start), u16(0),
    })
    self.f:close()
end

function ZipWriter:abort()
    self.f:close()
end

-- Data of the first entry of a ZIP written by this module (stored, no
-- compression), e.g. a CBZ's first page. Returns nil for anything else.
function ZipWriter.readFirstEntry(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local header = f:read(30)
    if not header or #header < 30 or header:sub(1, 4) ~= "PK\3\4" then
        f:close()
        return nil
    end
    local function le16(i)
        local a, b = header:byte(i, i + 1)
        return a + b * 256
    end
    local function le32(i)
        local a, b, c, d = header:byte(i, i + 3)
        return a + b * 256 + c * 65536 + d * 16777216
    end
    if le16(9) ~= 0 then  -- compressed: not one of ours
        f:close()
        return nil
    end
    f:seek("cur", le16(27) + le16(29))
    local data = f:read(le32(19))
    f:close()
    return data
end

return ZipWriter
