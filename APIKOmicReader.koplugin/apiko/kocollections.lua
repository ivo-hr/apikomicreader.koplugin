-- KOReader's own collections (Favorites and the ones made in its file
-- manager), so comics from the plugin's library can be added to them and show
-- up outside the plugin. Needs KOReader 2024.04 or newer (multiple
-- collections); on older versions available() is false and nothing happens.
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local KoCollections = {}

-- KOReader's collections module, up to date with its file, or nil.
local function rc()
    local ok, m = pcall(require, "readcollection")
    if not ok or type(m) ~= "table" or type(m.addCollection) ~= "function" then return nil end
    pcall(m._read, m)  -- re-reads only if the file changed
    if type(m.coll) ~= "table" or type(m.coll_settings) ~= "table" then return nil end
    return m
end

-- Collections keep resolved paths. Resolves the folder rather than the file,
-- so this also works for a file that was just moved or deleted.
local function real(path)
    local resolved = ffiUtil.realpath(path)
    if resolved then return resolved end
    local dir, name = path:match("^(.*)/([^/]+)$")
    local real_dir = dir and ffiUtil.realpath(dir)
    return real_dir and (real_dir .. "/" .. name) or path
end

local function save(m, name)
    local ok, err = pcall(m.write, m, name and { [name] = true } or nil)
    if not ok then logger.warn("APIKOmic: could not save KOReader collections", err) end
end

function KoCollections.available()
    return rc() ~= nil
end

-- The collections in KOReader's order: { { name = ..., text = ... }, ... }.
function KoCollections.list()
    local m = rc()
    if not m then return {} end
    local names = {}
    for name in pairs(m.coll) do table.insert(names, name) end
    local function order(name)
        local s = m.coll_settings[name]
        return type(s) == "table" and tonumber(s.order) or math.huge
    end
    table.sort(names, function(a, b)
        if order(a) ~= order(b) then return order(a) < order(b) end
        return a:lower() < b:lower()
    end)
    local list = {}
    for __, name in ipairs(names) do
        table.insert(list, {
            name = name,
            text = name == m.default_collection_name and _("Favorites") or name,
        })
    end
    return list
end

function KoCollections.exists(name)
    local m = rc()
    return m ~= nil and m.coll[name] ~= nil
end

-- How many of the files are in the collection.
function KoCollections.count(name, paths)
    local m = rc()
    local coll = m and m.coll[name]
    if not coll then return 0 end
    local n = 0
    for __, path in ipairs(paths) do
        if coll[real(path)] then n = n + 1 end
    end
    return n
end

-- Adds the files to the collection, creating it if needed.
function KoCollections.add(name, paths)
    local m = rc()
    if not m then return end
    if not m.coll[name] then m:addCollection(name) end
    for __, path in ipairs(paths) do
        if not m.coll[name][real(path)] and lfs.attributes(path, "mode") == "file" then
            m:addItem(path, name)
        end
    end
    save(m, name)
end

function KoCollections.remove(name, paths)
    local m = rc()
    local coll = m and m.coll[name]
    if not coll then return end
    for __, path in ipairs(paths) do
        coll[real(path)] = nil
    end
    save(m, name)
end

-- A comic was deleted: take it out of every collection.
function KoCollections.forget(path)
    local m = rc()
    if not m then return end
    pcall(m.removeItem, m, real(path))
end

-- A comic was moved: follow it in every collection.
function KoCollections.moved(old_path, new_path)
    local m = rc()
    if not m then return end
    pcall(m.updateItem, m, real(old_path), new_path)
end

return KoCollections
