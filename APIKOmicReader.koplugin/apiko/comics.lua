-- Downloaded comics on disk, in a source's History (auto-pruned) or Library
-- (kept). File names are "<source>_<id> - <title>.cbz", with a "+" after the
-- id for adult content ("<source>_<id>+ - <title>.cbz"). KOReader keeps each
-- one's reading progress in a "<name>.sdr" folder next to it.
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Paths = require("apiko.paths")

local Comics = {}

local function sidecar(path)
    return (path:gsub("%.cbz$", ".sdr"))
end

function Comics.fileName(source_id, id, adult, title)
    return string.format("%s_%s%s - %s.cbz", source_id, id, adult and "+" or "", title)
end

-- source_id, id, adult, title; or nil if the name isn't one of ours.
function Comics.parseName(name)
    local source_id, id, plus, title = name:match("^([%w%-]+)_([^%s%+]+)(%+?) %- (.+)%.cbz$")
    if not source_id then return nil end
    return source_id, id, plus == "+", title
end

-- Newest first.
function Comics.list(dir)
    local items = {}
    for name in lfs.dir(dir) do
        local source_id, id, adult, title = Comics.parseName(name)
        if source_id then
            local path = dir .. "/" .. name
            table.insert(items, {
                source_id = source_id,
                id = id,
                adult = adult,
                title = title,
                path = path,
                mtime = lfs.attributes(path, "modification") or 0,
            })
        end
    end
    table.sort(items, function(a, b) return a.mtime > b.mtime end)
    return items
end

-- Path of the comic with this "<source>_<id>" key in dir, if any.
function Comics.find(dir, key)
    local plain, adult = key .. " - ", key .. "+ - "
    for name in lfs.dir(dir) do
        if name:match("%.cbz$") and (name:sub(1, #plain) == plain or name:sub(1, #adult) == adult) then
            return dir .. "/" .. name
        end
    end
end

local READ_AT = 0.97  -- this far through counts as read
local progress_cache = {}  -- path -> { mtime = progress file time, result = {...} }

-- Reading state of a comic, from the progress KOReader keeps next to it:
-- { status = "unread" | "reading" | "read", percent = 0..1, last_read = time }.
-- Comics never opened have no progress file, so this is cheap for them.
function Comics.progress(path)
    local DocSettings = require("docsettings")
    local sidecar
    pcall(function()
        if DocSettings.getSidecarFile then
            sidecar = DocSettings:getSidecarFile(path)
        elseif DocSettings.hasSidecarFile then
            sidecar = DocSettings:hasSidecarFile(path)
        end
    end)
    if not sidecar then return { status = "unread", percent = 0, last_read = 0 } end
    local mtime = type(sidecar) == "string" and lfs.attributes(sidecar, "modification") or nil
    local cached = progress_cache[path]
    if mtime and cached and cached.mtime == mtime then return cached.result end
    local result = { status = "unread", percent = 0, last_read = mtime or 0 }
    local ok, settings = pcall(DocSettings.open, DocSettings, path)
    if ok and settings then
        local percent = tonumber(settings:readSetting("percent_finished")) or 0
        local summary = settings:readSetting("summary")
        local complete = type(summary) == "table" and summary.status == "complete"
        result.percent = percent
        if complete or percent >= READ_AT then
            result.status = "read"
        elseif percent > 0 then
            result.status = "reading"
        end
    end
    if mtime then progress_cache[path] = { mtime = mtime, result = result } end
    return result
end

-- Removes our comics from KOReader's own reading history and "last file", so
-- their titles don't show up outside the plugin.
function Comics.forget(path)
    local real = ffiUtil.realpath(path) or path
    pcall(function()
        local ReadHistory = require("readhistory")
        ReadHistory:removeItemByPath(real)
        if real ~= path then ReadHistory:removeItemByPath(path) end
    end)
    local last = G_reader_settings:readSetting("lastfile")
    if Paths.isOurs(last) then G_reader_settings:delSetting("lastfile") end
end

function Comics.delete(path)
    os.remove(path)
    local source_id, id = Comics.parseName(path:match("([^/]+)$") or "")
    if source_id then
        pcall(function() require("apiko.store").removeChapterMeta(source_id .. "_" .. id) end)
    end
    local sdr = sidecar(path)
    if lfs.attributes(sdr, "mode") == "directory" then
        pcall(ffiUtil.purgeDir, sdr)
    end
    Comics.forget(path)
end

-- Moves a comic (and its reading progress) into dir. Returns the new path.
function Comics.move(path, dir)
    local dest = dir .. "/" .. path:match("([^/]+)$")
    local ok, err = os.rename(path, dest)
    if not ok then
        logger.warn("APIKOmic: move failed", path, dest, err)
        return nil, err
    end
    local sdr = sidecar(path)
    if lfs.attributes(sdr, "mode") == "directory" then os.rename(sdr, sidecar(dest)) end
    Comics.forget(path)
    return dest
end

-- Makes room in a source's History for one more comic, keeping the newest
-- (keep - 1); also removes leftovers of interrupted downloads.
function Comics.prune(source_id, keep)
    local dir = Paths.history(source_id)
    for name in lfs.dir(dir) do
        if name:match("%.part$") then os.remove(dir .. "/" .. name) end
    end
    local items = Comics.list(dir)
    for i = math.max(1, keep), #items do
        Comics.delete(items[i].path)
    end
end

return Comics
