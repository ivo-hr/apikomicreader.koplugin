-- Where the plugin keeps its files: a hidden folder in KOReader's data
-- directory (hidden from the file browser by default), with one folder per
-- source:  .apikomic/<source>/history  and  .apikomic/<source>/library
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local Paths = {}

local function ensure(dir)
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    return dir
end

function Paths.root()
    return ensure(DataStorage:getDataDir() .. "/.apikomic")
end

function Paths.sourceDir(source_id)
    return ensure(Paths.root() .. "/" .. source_id)
end

-- Scratch space for pages being downloaded.
function Paths.tmp()
    return ensure(Paths.root() .. "/tmp")
end

-- Downloaded for reading; the oldest are deleted automatically.
function Paths.history(source_id)
    return ensure(Paths.sourceDir(source_id) .. "/history")
end

-- Saved by the user; never deleted automatically.
function Paths.library(source_id)
    return ensure(Paths.sourceDir(source_id) .. "/library")
end

function Paths.isOurs(file)
    return type(file) == "string" and file:match("/%.apikomic/[^/]+/[^/]+/[^/]+%.cbz$") ~= nil
end

-- The plugin's own folder: the one containing this file's "apiko" folder.
function Paths.pluginDir()
    local here = debug.getinfo(1, "S").source:gsub("^@", "")
    local dir = here:gsub("[/\\]?apiko[/\\]paths%.lua$", "")
    return dir ~= "" and dir or "."
end

-- A file shipped in the plugin's assets folder.
function Paths.asset(name)
    return Paths.pluginDir() .. "/assets/" .. name
end

local function copyIfChanged(src, dest)
    local size = lfs.attributes(src, "size")
    if not size or lfs.attributes(dest, "size") == size then return end
    local fin = io.open(src, "rb")
    if not fin then return end
    local data = fin:read("*a")
    fin:close()
    local fout = io.open(dest, "wb")
    if not fout then return end
    fout:write(data)
    fout:close()
end

-- Copies the app icon into KOReader's user icons folder, where launchers such
-- as ZenOS offer it in their icon picker and KOReader finds it by name
-- ("apikomicreader"). The SVG is preferred where supported (it stays sharp
-- at any size); the PNG is the fallback. Only writes missing or changed files.
function Paths.installIcon()
    local dir = ensure(DataStorage:getDataDir() .. "/icons")
    for __, name in ipairs{ "apikomicreader.svg", "apikomicreader.png" } do
        copyIfChanged(Paths.asset(name), dir .. "/" .. name)
    end
end

return Paths
