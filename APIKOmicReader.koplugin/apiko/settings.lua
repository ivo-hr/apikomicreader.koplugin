-- Persistent plugin settings, stored inside KOReader's settings.reader.lua.
local Settings = {}

local KEY = "apikomicreader"

local DEFAULTS = {
    -- Id of the source in use; only one is active at a time.
    active_source = "mangadex",
    -- Whether adult sources and titles are shown, when no PIN is set. With a
    -- PIN, they are shown only after entering it (until the plugin is left).
    show_adult = false,
    -- Language for chapters (sources that have translations), e.g. "en", "es".
    language = "en",
    -- Smaller page images where the source offers them.
    data_saver = true,
    -- How many comics each source's History keeps before deleting the oldest.
    cache_keep = 20,
    -- "grid", "list_icons" or "list".
    view_mode = "grid",
    -- What to set Panels+ to when one of our comics opens: "manga", "comic" or "off".
    panels_mode = "manga",
    -- pin_hash: set when a parental-controls PIN is configured.
}

local data

function Settings.get()
    if not data then
        data = G_reader_settings:readSetting(KEY) or {}
        for k, v in pairs(DEFAULTS) do
            if data[k] == nil then data[k] = v end
        end
    end
    return data
end

function Settings.save()
    G_reader_settings:saveSetting(KEY, Settings.get())
    G_reader_settings:flush()
end

return Settings
