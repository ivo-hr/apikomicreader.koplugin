-- Registry of comic sources. Every .lua file in apiko/sources/ is loaded as a
-- source when KOReader starts (files starting with "_" are skipped). See
-- apiko/sources/_template.lua for the interface and a commented example.
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Sources = { list = {} }

local REQUIRED = { "search", "getChapters", "getPages" }

local function sourcesDir()
    -- This file's own folder: "@<plugin>/apiko/sources.lua" -> "<plugin>/apiko/sources"
    local here = debug.getinfo(1, "S").source:gsub("^@", "")
    return (here:gsub("[^/\\]+$", "")) .. "sources"
end

local function check(source, file)
    if type(source) ~= "table" then return "did not return a table" end
    if type(source.id) ~= "string" or not source.id:match("^[%w%-]+$") then
        return "needs an id made of letters, digits or '-'"
    end
    if type(source.name) ~= "string" then return "needs a name" end
    for __, fn in ipairs(REQUIRED) do
        if type(source[fn]) ~= "function" then return "is missing " .. fn .. "()" end
    end
    for __, other in ipairs(Sources.list) do
        if other.id == source.id then return "uses the id '" .. source.id .. "', already taken" end
    end
end

-- Must run while the plugin's folder is on package.path, i.e. when main.lua
-- is loaded, so require() finds the source modules.
local function load()
    local dir = sourcesDir()
    local names = {}
    local ok, iter, state = pcall(lfs.dir, dir)
    if not ok then
        logger.warn("APIKOmic: cannot read sources folder", dir, iter)
        return
    end
    for name in iter, state do
        if name:match("^[^_%.].*%.lua$") then table.insert(names, name) end
    end
    table.sort(names)
    for __, name in ipairs(names) do
        local module = "apiko.sources." .. name:gsub("%.lua$", "")
        local loaded, source = pcall(require, module)
        local problem = not loaded and tostring(source) or check(source, name)
        if problem then
            logger.warn("APIKOmic: skipping source", name, ":", problem)
        else
            source.base = source.base or ("https://" .. (source.domain or source.id))
            source.domain = source.domain or source.id
            if type(source.describe) ~= "function" then
                source.describe = function(self, item) return item.title end
            end
            table.insert(Sources.list, source)
            logger.info("APIKOmic: loaded source", source.id)
        end
    end
    -- Optional `order` field first (lower first), then by name.
    table.sort(Sources.list, function(a, b)
        local oa, ob = a.order or 100, b.order or 100
        if oa ~= ob then return oa < ob end
        return a.name:lower() < b.name:lower()
    end)
end

load()

function Sources.get(id)
    for __, source in ipairs(Sources.list) do
        if source.id == id then return source end
    end
end

return Sources
