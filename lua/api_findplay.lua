-- /api/findplay/:id - for a given DMM code, concurrently probe which of the
-- streaming platforms below can actually play it, and return a jump-to-search
-- link for the ones that can.
--
--   * missav   https://missav.ai/en/search/<code>       (result grid cards)
--   * supjav   https://supjav.com/?s=<code>             (WordPress post cards)
--   * jable    https://jable.tv/search/<code>/          (detail card list)
--   * 123av    https://123av.com/en/search?keyword=<code> (v/<code> links)
--
-- The id is case-insensitive; every search URL is built from the id uppercased.
-- A platform is reported as playable only when its search page (HTTP 200)
-- shows an actual result card for the code. `verified` tells whether the page
-- actually loaded (true) or the probe was blocked/failed (false, e.g. HTTP 403
-- on all mirrors). Blocked probes are retried once and are NOT cached, so a
-- Cloudflare block never masquerades as "confirmed not playable". Only judged
-- verdicts are cached per platform.
--
-- Usage:
--   GET /api/findplay/:id

local cjson = require "cjson"
local http = require "resty.http"

local _M = {}

-- How long a "playable" verdict is cached (seconds).
local CACHE_TTL = 6 * 3600
-- Shorter TTL for "not playable" so newer uploads surface sooner.
local CACHE_TTL_EMPTY = 3600
-- Per upstream-request budget in ms.
local REQ_TIMEOUT = 8000

-- Browser-like UA + Accept-Language; streaming sites behave better with them.
local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
local ACCEPT_LANG = "zh-CN,zh;q=0.9,zh-TW;q=0.8,en-US;q=0.7,en;q=0.6,ja;q=0.5"

-------------------------------------------------------------------------------
-- HTTP helpers
-------------------------------------------------------------------------------

-- GET `url`. Returns (res, err) where res has .status and .body, or nil.
local function get(url, headers)
    local httpc = http.new()
    httpc:set_timeout(REQ_TIMEOUT)
    local all_headers = { ["User-Agent"] = UA }
    if headers then
        for k, v in pairs(headers) do
            all_headers[k] = v
        end
    end
    return httpc:request_uri(url, {
        method = "GET",
        ssl_verify = false,
        headers = all_headers,
    })
end

-- Read a cached (platform, code) verdict as a boolean, or nil.
local function cache_get(platform, code)
    local dict = ngx.shared.findplay_cache
    if not dict then
        return nil
    end
    local raw = dict:get("fp:" .. platform .. ":" .. code)
    if not raw or raw == "" then
        return nil
    end
    local ok, verdict = pcall(cjson.decode, raw)
    if not ok or type(verdict) ~= "boolean" then
        return nil
    end
    return verdict
end

-- Store `verdict` (a boolean) for (platform, code).
local function cache_set(platform, code, verdict)
    local dict = ngx.shared.findplay_cache
    if not dict then
        return
    end
    local ok, json = pcall(cjson.encode, verdict)
    if ok then
        dict:set("fp:" .. platform .. ":" .. code, json,
                 verdict and CACHE_TTL or CACHE_TTL_EMPTY)
    end
end

-------------------------------------------------------------------------------
-- Presence detectors
-------------------------------------------------------------------------------

local function lower(s)
    return s and (s:lower()) or ""
end

-- missav: a search hit shows thumbnails in a result grid. The empty page only
-- echoes the query back in the search box, so require a thumbnail card too.
function _M.parse_missav(html, code)
    local h = lower(html)
    if not (h:find('class="thumbnail"', 1, true)
            or h:find("class='thumbnail'", 1, true)) then
        return false
    end
    return h:find(lower(code), 1, true) ~= nil
end

-- supjav: WordPress search. A hit renders `div.post` cards whose permalinks
-- carry `.html`; a miss shows an empty message and no posts. The search box
-- echoes the query back, so the code alone must not be trusted.
function _M.parse_supjav(html, code)
    local h = lower(html)
    if not (h:find('class="post', 1, true) or h:find("class='post", 1, true)) then
        return false
    end
    if not h:find(".html", 1, true) then
        return false
    end
    return h:find(lower(code), 1, true) ~= nil
end

-- jable: search results are `div.detail > h6 > a` cards holding the code.
-- Require both the card class and an <h6> so the empty state (no cards)
-- cannot pass.
function _M.parse_jable(html, code)
    local h = lower(html)
    if not (h:find('class="detail"', 1, true)
            or h:find("class='detail'", 1, true)) then
        return false
    end
    if not h:find("<h6", 1, true) then
        return false
    end
    return h:find(lower(code), 1, true) ~= nil
end

-- 123av: verified live. On a hit the result grid links /en/v/<code> (or the
-- zh variant). On a miss 123av shows an unrelated fallback grid and only
-- echoes the code in <title>, so we must require the `v/<code>` link.
function _M.parse_123av(html, code)
    local h = lower(html)
    local slug = lower(code)
    return (h:find("/en/v/" .. slug, 1, true) ~= nil)
        or (h:find("/zh/v/" .. slug, 1, true) ~= nil)
end

-------------------------------------------------------------------------------
-- Platform definitions
-------------------------------------------------------------------------------

-- build_url(code) -> the canonical jump link (always the primary domain).
-- build_probe(domain) -> the on-server path for `domain`.
local PLATFORMS = {
    {
        key = "missav",
        label = "MissAV",
        domains = { "missav.ai", "missav.ws", "missav123.com", "missav.live" },
        build_url = function(code) return "https://missav.ai/en/search/" .. code end,
        build_probe = function() return "/en/search/%s" end,
        headers = function() return { ["Referer"] = "https://missav.ai/", ["Accept-Language"] = ACCEPT_LANG } end,
        parse = _M.parse_missav,
    },
    {
        key = "supjav",
        label = "SupJAV",
        domains = { "supjav.com" },
        build_url = function(code) return "https://supjav.com/?s=" .. code end,
        build_probe = function() return "/?s=%s" end,
        headers = function() return { ["Referer"] = "https://supjav.com/", ["Accept-Language"] = ACCEPT_LANG } end,
        parse = _M.parse_supjav,
    },
    {
        key = "jable",
        label = "JableTV",
        domains = { "jable.tv", "fs1.app" },
        build_url = function(code) return "https://jable.tv/search/" .. code .. "/" end,
        build_probe = function() return "/search/%s/" end,
        headers = function() return { ["Referer"] = "https://jable.tv/", ["Accept-Language"] = "zh-TW,zh;q=0.9" } end,
        parse = _M.parse_jable,
    },
    {
        key = "123av",
        label = "123AV",
        domains = { "123av.com" },
        build_url = function(code) return "https://123av.com/en/search?keyword=" .. code end,
        build_probe = function() return "/en/search?keyword=%s" end,
        headers = function() return { ["Accept-Language"] = "en-US,en;q=0.9" } end,
        parse = _M.parse_123av,
    },
}

-------------------------------------------------------------------------------
-- Probing
-------------------------------------------------------------------------------

-- Probe one platform: walk its mirror domains until an HTTP 200 is returned,
-- then decide playable from the page. Returns (playable, verified, err):
--   verified = true  -> the page actually loaded and we judged it
--   verified = false -> request blocked / failed (403, timeout, …)
-- A blocked probe is retried once across all mirrors before giving up.
local function fetch_verdict(platform, code)
    local path_tpl = platform.build_probe()
    local last_err = platform.key .. ": no reachable mirror"
    for attempt = 1, 2 do
        for _, domain in ipairs(platform.domains) do
            local res, err = get("https://" .. domain .. string.format(path_tpl, code),
                                 platform.headers())
            if res and res.status == 200 then
                return platform.parse(res.body, code), true, nil
            end
            last_err = platform.key .. ": HTTP " .. (res and res.status or "nil") ..
                       (err and (" (" .. err .. ")") or "")
        end
        if attempt == 1 then
            ngx.sleep(0.5)
        end
    end
    return false, false, last_err
end

-- Cached wrapper over fetch_verdict. Only verified verdicts are cached: a
-- blocked/failed probe must not be persisted as "confirmed not playable".
-- Returns (playable, verified, err).
local function probe_platform(platform, code)
    local cached = cache_get(platform.key, code)
    if cached ~= nil then
        return cached, true, nil
    end
    local verdict, verified, err = fetch_verdict(platform, code)
    if verified then
        cache_set(platform.key, code, verdict)
        return verdict, true, nil
    end
    return false, false, err
end

function _M.handle(raw_id)
    local code = string.upper(raw_id or ""):gsub("%s+", "")
    if code == "" then
        ngx.status = 400
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.say(cjson.encode({
            error = "bad_request",
            message = "Missing id parameter. Usage: /api/findplay/:id",
        }))
        return
    end

    local threads = {}
    for i, platform in ipairs(PLATFORMS) do
        threads[i] = ngx.thread.spawn(probe_platform, platform, code)
    end

    local results = {}
    local count = 0
    for i, platform in ipairs(PLATFORMS) do
        local ok, playable, verified, err = ngx.thread.wait(threads[i])
        local entry = {
            platform = platform.key,
            label = platform.label,
            url = platform.build_url(code),
            playable = ok and playable == true or false,
            verified = ok and verified == true or false,
        }
        if not entry.playable then
            if ok and entry.verified then
                entry.error = platform.key .. ": no result"
            else
                entry.error = (ok and err) or (platform.key .. ": probe failed")
            end
        else
            count = count + 1
        end
        results[i] = entry
    end

    ngx.status = 200
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.say(cjson.encode({
        code = code,
        count = count,
        results = results,
    }))
end

-- Exposed for the offline test harness (luajit, no OpenResty).
_M.PLATFORMS = PLATFORMS
return _M