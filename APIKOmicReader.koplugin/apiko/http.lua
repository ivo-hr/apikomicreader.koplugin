-- Small HTTP client: redirects, timeouts and readable errors.
local http = require("socket.http")
local json = require("json")
local logger = require("logger")
local socket = require("socket")
local socketutil = require("socketutil")
local _ = require("gettext")
local T = require("ffi/util").template

local Http = {}

local USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"

local function resolve(base, loc)
    if loc:match("^%a+://") then return loc end
    if loc:sub(1, 2) == "//" then return base:match("^(%a+:)") .. loc end
    if loc:sub(1, 1) == "/" then return base:match("^(%a+://[^/]+)") .. loc end
    return (base:gsub("[^/]*$", "")) .. loc
end

local function rawRequest(url, headers)
    local chunks = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, resp_headers = socket.skip(1, http.request{
        url = url,
        method = "GET",
        headers = headers,
        sink = socketutil.table_sink(chunks),
        redirect = false,
    })
    socketutil:reset_timeout()
    if type(code) ~= "number" then
        return nil, tostring(code)
    end
    return table.concat(chunks), code, resp_headers or {}
end

local function follow(url, opts)
    local headers = {
        ["user-agent"] = opts.user_agent or USER_AGENT,
        ["accept"] = opts.accept or "*/*",
        ["accept-language"] = "en-US,en;q=0.9",
        ["referer"] = opts.referer,
    }
    local body, code, resp_headers
    for __ = 1, 5 do
        body, code, resp_headers = rawRequest(url, headers)
        if not body then break end
        if code >= 300 and code < 400 and resp_headers.location then
            url = resolve(url, resp_headers.location)
        else
            break
        end
    end
    return body, code, resp_headers
end

-- Cloudflare either serves a challenge page or just answers 403/503 itself.
local function isCloudflareBlock(code, headers, body)
    if headers["cf-mitigated"] == "challenge" then return true end
    if code ~= 403 and code ~= 503 then return false end
    if headers["server"] and headers["server"]:lower():find("cloudflare", 1, true) then
        return true
    end
    return (body:find("cf_chl", 1, true) or body:find("challenge-platform", 1, true)
            or body:find("Just a moment", 1, true)) and true or false
end

local function isWebFilter(body)
    return body:find("FortiGuard", 1, true) or body:find("Fortinet", 1, true)
end

local function networkError(err)
    local msg = T(_("Network error: %1"), err)
    if err:find("certificate", 1, true) or err:find("handshake", 1, true) then
        msg = msg .. "\n" .. _("A filtering proxy (e.g. FortiGuard) can cause TLS errors. Try another network.")
    end
    return msg
end

-- Returns body, or nil and a human-readable error.
-- opts: accept, referer, user_agent
function Http.get(url, opts)
    opts = opts or {}
    local body, code, headers = follow(url, opts)
    if not body then
        return nil, networkError(code)
    end
    if code ~= 200 then
        logger.warn("APIKOmic: HTTP", code, url, "server:", headers["server"], "body:", body:sub(1, 300))
        if isWebFilter(body) then
            return nil, _("Blocked by the network's web filter (FortiGuard). Try another Wi-Fi network or a phone hotspot.")
        end
        if isCloudflareBlock(code, headers, body) then
            return nil, T(_("Blocked by Cloudflare (HTTP %1). The site may have started protecting this address."), code)
        end
        return nil, T(_("HTTP error %1"), code)
    end
    return body
end

function Http.getJson(url, opts)
    opts = opts or {}
    opts.accept = "application/json"
    local body, err = Http.get(url, opts)
    if not body then return nil, err end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then
        logger.warn("APIKOmic: invalid JSON from", url, body:sub(1, 300))
        if isWebFilter(body) then
            return nil, _("Blocked by the network's web filter (FortiGuard). Try another Wi-Fi network or a phone hotspot.")
        end
        return nil, _("The site returned something that is not valid JSON.")
    end
    return data
end

function Http.urlEncode(str)
    return (str:gsub("[^%w%-_%.~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

return Http
