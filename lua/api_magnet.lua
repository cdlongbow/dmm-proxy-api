-- /api/magnet/:id - magnet link aggregation from three independent sources:
--   * sukebei.nyaa.si  (RSS feed, magnet rebuilt from <nyaa:infoHash>)
--   * javdb.com        (search -> video detail page magnet table)
--   * javbus.com       (search -> detail gid/uc -> ajax magnet table)
--
-- The three sources are fetched concurrently (ngx.thread) and results are
-- cached per (source, code) to avoid hammering the upstream sites. Each result
-- is grouped by source so clients can tell where each magnet came from.
--
-- Usage:
--   GET /api/magnet/:id                -> all three sources
--   GET /api/magnet/:id?s=sukebei     -> only sukebei
--   GET /api/magnet/:id?s=javdb       -> only javdb
--   GET /api/magnet/:id?s=javbus      -> only javbus
--   GET /api/magnet/:id?s=javdb,javbus-> multiple (comma separated)

local cjson = require "cjson"
-- Encode empty Lua tables as [] (not {}). Every empty-shaped field in the
-- API response (magnets / tags) is a list; emitting {} makes frontends
-- treat it as an object and break (e.g. .slice / for..of on it).
if cjson.encode_empty_table_as_object then
    cjson.encode_empty_table_as_object(false)
end
local http = require "resty.http"

local _M = {}

-- How long a (source, code) result is cached (seconds).
local CACHE_TTL = 6 * 3600
-- Per upstream-request budget in ms.
local REQ_TIMEOUT = 8000

-- Browser-like UA + Accept-Language; some sites behave better with them.
local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
local ACCEPT_LANG = "zh-CN,zh;q=0.9,zh-TW;q=0.8,en-US;q=0.7,en;q=0.6,ja;q=0.5"

local SUKEBEI = "https://sukebei.nyaa.si"
local JAVDB = "https://javdb.com"
local JAVBUS = "https://www.javbus.com"

-- Trackers nyaa.si / sukebei bake into the magnet URIs it generates; they are
-- re-added here because the RSS feed only carries the info hash.
local NYAA_TRACKERS = {
    "http://nyaa.tracker.wf:7777/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://tracker.torrent.eu.org:451/announce",
}

-------------------------------------------------------------------------------
-- HTTP helpers
-------------------------------------------------------------------------------

-- GET `url`. Returns (res, err) where res is the request_uri response table
-- (with .status and .body) or nil. Extra headers can be passed in `headers`.
local function get(url, headers)
    local function do_get()
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
    local res, err = do_get()
    if not res then
        ngx.sleep(0.3)
        res, err = do_get()
    end
    return res, err
end

-- Fetch a cached (source, code) result as a Lua table, or nil.
local function cache_get(source, code)
    local dict = ngx.shared.magnet_cache
    if not dict then
        return nil
    end
    local ok, data = pcall(cjson.decode, dict:get("mg:" .. source .. ":" .. code) or "")
    if not ok then
        return nil
    end
    return data
end

-- Store `data` (a Lua table, NOT nil) for (source, code).
local function cache_set(source, code, data)
    local dict = ngx.shared.magnet_cache
    if not dict then
        return
    end
    local ok, json = pcall(cjson.encode, data)
    if ok then
        dict:set("mg:" .. source .. ":" .. code, json, CACHE_TTL)
    end
end

-------------------------------------------------------------------------------
-- Small parsing utilities
-------------------------------------------------------------------------------

-- Strip HTML tags + collapse whitespace + trim.
local function strip_html(s)
    if not s then
        return ""
    end
    return (s:gsub("<[^>]+>", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Decode common XML/HTML entities contained in scraped attributes.
local function unescape_uri(s)
    if not s then
        return ""
    end
    return s:gsub("&amp;", "&"):gsub("&#x27;", "'"):gsub("&quot;", '"'):gsub("&nbsp;", " ")
end

-- RFC-822 pubDate like "Tue, 11 Nov 2025 04:39:51 -0000" -> epoch seconds.
local function rss_date_to_epoch(pub)
    if not pub or pub == "" then
        return nil
    end
    return ngx.parse_http_time(pub:gsub("%s%+?%-?0000$", " GMT"))
end

-- Build a magnet URI from an info hash + display name (nyaa-style).
local function build_magnet(info_hash, name)
    local parts = { "magnet:?xt=urn:btih:" .. info_hash }
    if name and name ~= "" then
        parts[#parts + 1] = "dn=" .. ngx.escape_uri(name)
    end
    for _, tr in ipairs(NYAA_TRACKERS) do
        parts[#parts + 1] = "tr=" .. ngx.escape_uri(tr)
    end
    return table.concat(parts, "&")
end

-- Normalise an info hash to lowercase hex (nil when it isn't hex).
local function normalize_hash(h)
    local hex = h and h:match("%x+")
    if not hex then
        return nil
    end
    return string.lower(hex)
end

-------------------------------------------------------------------------------
-- Source 1: sukebei.nyaa.si (RSS)
-------------------------------------------------------------------------------

function _M.parse_sukebei(xml)
    local magnets = {}
    for item in xml:gmatch("<item>(.-)</item>") do
        local info_hash = normalize_hash(item:match("infoHash[^>]*>([^<]+)<"))
        if info_hash then
            local view = item:match("<guid[^>]*>(.-)</guid>") or item:match("<link>(.-)</link>")
            local name = item:match("<title>(.-)</title>") or ""
            local epoch = rss_date_to_epoch(item:match("<pubDate>(.-)</pubDate>"))
            magnets[#magnets + 1] = {
                name = name,
                magnet = build_magnet(info_hash, name),
                info_hash = info_hash,
                size = item:match("size[^>]*>([^<]+)<") or "",
                seeders = tonumber(item:match("seeders[^>]*>([^<]+)<") or "0") or 0,
                leechers = tonumber(item:match("leechers[^>]*>([^<]+)<") or "0") or 0,
                downloads = tonumber(item:match("downloads[^>]*>([^<]+)<") or "0") or 0,
                category = item:match("category[^>]*>([^<]+)<") or "",
                date = epoch,
                date_str = epoch and os.date("%Y-%m-%d", epoch) or "",
                url = view,
                torrent_url = item:match("<link>(.-)</link>"),
            }
        end
    end
    return magnets
end

local function fetch_sukebei(code)
    local url = SUKEBEI .. "/?page=rss&q=" .. ngx.escape_uri(code) .. "&c=0_0&f=0"
    local res, err = get(url, { ["Accept"] = "application/rss+xml, text/xml, */*" })
    if not res or res.status ~= 200 then
        ngx.log(ngx.ERR, "sukebei status=" .. (res and res.status or "nil") .. " err=" .. tostring(err))
        return nil, "sukebei request failed"
    end
    return _M.parse_sukebei(res.body)
end

-------------------------------------------------------------------------------
-- Source 2: javdb.com
-------------------------------------------------------------------------------

-- Find the nearest '<a ' open tag strictly before `before` whose attributes
-- contain `class_marker` (plain substring), and return its href attribute.
-- Used to map a scraped title/id node back to its enclosing result anchor
-- regardless of attribute order or line breaks.
local function anchor_href_before(html, before, class_marker)
    local i = before - 1
    while i > 1 do
        if html:sub(i, i + 2) == "<a " then
            local e = html:find(">", i, true)
            if not e then
                return nil
            end
            local tag = html:sub(i, e)
            if tag:find(class_marker, 1, true) then
                return tag:match('href="([^"]+)"')
            end
            return nil
        end
        i = i - 1
    end
    return nil
end

-- Search page: find the video box whose <strong> id matches (case-insens).
-- Returns the video path (/v/xxx) plus the box id.
function _M.parse_javdb_search(html, code)
    local needle = '<div class="video-title"><strong>'
    local pos = 1
    while true do
        local s = html:find(needle, pos, true)
        if not s then
            return nil
        end
        local e = html:find("</strong>", s, true)
        local id_text = html:sub(s + #needle, e - 1)
        if id_text and string.upper(id_text) == code then
            local href = anchor_href_before(html, s, 'class="box"')
            if href then
                return href, id_text
            end
        end
        pos = e + 1
    end
end

-- Detail page: magnet rows start at `class="magnet-name ..."`.
function _M.parse_javdb_detail(html, detail_url)
    local magnets = {}
    local needle = 'class="magnet-name column is-four-fifths"'
    local start = 1
    while true do
        local s = html:find(needle, start, true)
        if not s then
            break
        end
        local magnet = html:match('<a href="(magnet:[^"]+)"', s)
        if magnet then
            local decoded = unescape_uri(magnet)
            local tags = {}
            local tag_block = html:match('<div class="tags">(.-)</div>', s)
            if tag_block then
                for t in tag_block:gmatch('<span class="tag[^>]*>([^<]+)</span>') do
                    tags[#tags + 1] = strip_html(t)
                end
            end
            magnets[#magnets + 1] = {
                name = strip_html(html:match('<span class="name">(.-)</span>', s) or ""),
                magnet = decoded,
                info_hash = normalize_hash(decoded:match("urn:btih:([%w]+)")),
                size = strip_html(html:match('<span class="meta">(.-)</span>', s) or ""),
                date = strip_html(html:match('<span class="time">(.-)</span>', s) or ""),
                date_str = (function()
                    local d = strip_html(html:match('<span class="time">(.-)</span>', s) or "")
                    if d ~= "" and d ~= "0000-00-00" then
                        return d
                    end
                    local head = html:sub(math.max(1, s - 500), s - 1)
                    local dd = head:match('data%-date="([^"]+)"') or head:match("data%-date='([^']+)'")
                    if dd then
                        local y, m, day = dd:match("(%d%d%d%d)(%d%d)(%d%d)")
                        if y then return y .. "-" .. m .. "-" .. day end
                    end
                    return d
                end)(),
                files = (function()
                    local head = html:sub(math.max(1, s - 500), s - 1)
                    return tonumber(head:match('data%-files="(%d+)"') or head:match("data%-files='(%d+)'"))
                end)(),
                tags = tags,
                url = detail_url,
            }
        end
        start = s + 1
    end
    return magnets
end

local function fetch_javdb(code)
    -- 1. Search for the exact code.
    local search_url = JAVDB .. "/search?q=" .. ngx.escape_uri(code) .. "&f=all"
    local res, err = get(search_url, {
        ["Accept-Language"] = ACCEPT_LANG,
        ["Referer"] = JAVDB .. "/",
    })
    if not res or res.status ~= 200 then
        ngx.log(ngx.ERR, "javdb search status=" .. (res and res.status or "nil") .. " err=" .. tostring(err))
        return nil, "javdb search failed"
    end
    local vid = _M.parse_javdb_search(res.body, code)
    if not vid then
        ngx.log(ngx.ERR, "javdb no exact match for " .. code)
        return nil, "javdb: no exact match"
    end

    -- 2. Detail page -> magnet table.
    local detail_url = JAVDB .. vid
    local res2, err2 = get(detail_url, {
        ["Accept-Language"] = ACCEPT_LANG,
        ["Referer"] = search_url,
    })
    if not res2 or res2.status ~= 200 then
        ngx.log(ngx.ERR, "javdb detail status=" .. (res2 and res2.status or "nil") .. " err=" .. tostring(err2))
        return nil, "javdb detail failed"
    end
    return _M.parse_javdb_detail(res2.body, detail_url)
end

-------------------------------------------------------------------------------
-- Source 3: javbus.com
-------------------------------------------------------------------------------

-- Search page: find the movie-box whose first <date> id matches (case-insens).
-- Returns the movie URL plus the box id.
function _M.parse_javbus_search(html, code)
    local pos = 1
    while true do
        local s, e = html:find("<date>", pos, true)
        if not s then
            return nil
        end
        local e2 = html:find("</date>", s, true)
        local id_text = html:sub(s + 6, e2 - 1)
        if id_text and string.upper(id_text) == code then
            local href = anchor_href_before(html, s, 'class="movie-box"')
            if href then
                return href, id_text
            end
        end
        pos = e2 + 1
    end
end

-- Detail page: fetch gid/uc.
function _M.parse_javbus_detail(html)
    local gid = html:match("var gid = (%d+);")
    local uc = html:match("var uc = (%d+);")
    return gid, uc
end

-- Magnet AJAX page: rows of <tr> with three <td>s.
function _M.parse_javbus_magnets(html, movie_url)
    local magnets = {}
    for tr in html:gmatch("<tr[^>]*>(.-)</tr>") do
        local magnet = tr:match('href="(magnet:[^"]+)"')
        if magnet then
            local tds = {}
            for td in tr:gmatch("<td[^>]*>(.-)</td>") do
                tds[#tds + 1] = td
            end
            local decoded = unescape_uri(magnet)
            magnets[#magnets + 1] = {
                name = strip_html(tds[1] or ""),
                magnet = decoded,
                info_hash = normalize_hash(decoded:match("urn:btih:([%w]+)")),
                size = strip_html(tds[2] or ""),
                date = strip_html(tds[3] or ""),
                date_str = strip_html(tds[3] or ""),
                url = movie_url,
            }
        end
    end
    return magnets
end

local function fetch_javbus(code)
    -- 1. Search; keep the movie whose <date> id matches (case-insensitive).
    local search_url = JAVBUS .. "/search/" .. ngx.escape_uri(code) .. "/1&type=1"
    local res, err = get(search_url, {
        ["Accept-Language"] = ACCEPT_LANG,
        ["Cookie"] = "existmag=mag",
        ["Referer"] = JAVBUS .. "/",
    })
    if not res or res.status ~= 200 then
        ngx.log(ngx.ERR, "javbus search status=" .. (res and res.status or "nil") .. " err=" .. tostring(err))
        return nil, "javbus search failed"
    end

    -- Search may land on an age-gate page; retry once when no exact match.
    local movie_url = _M.parse_javbus_search(res.body, code)
    if not movie_url and res.body:find("driver%-verify", 1, true) then
        ngx.sleep(0.5)
        res, err = get(search_url, {
            ["Accept-Language"] = ACCEPT_LANG,
            ["Cookie"] = "existmag=mag",
            ["Referer"] = JAVBUS .. "/",
        })
        if not res or res.status ~= 200 then
            ngx.log(ngx.ERR, "javbus search retry status=" .. (res and res.status or "nil") .. " err=" .. tostring(err))
            return nil, "javbus search failed"
        end
        movie_url = _M.parse_javbus_search(res.body, code)
    end
    if not movie_url then
        ngx.log(ngx.ERR, "javbus no exact match for " .. code)
        return nil, "javbus: no exact match"
    end

    -- 2. Detail page -> gid / uc. Retry once against the intermittent age-gate.
    local gid, uc
    for attempt = 1, 2 do
        local res2, err2 = get(movie_url, {
            ["Accept-Language"] = ACCEPT_LANG,
            ["Cookie"] = "existmag=mag",
            ["Referer"] = search_url,
        })
        if not res2 or res2.status ~= 200 then
            ngx.log(ngx.ERR, "javbus detail attempt " .. attempt .. " status=" .. (res2 and res2.status or "nil") .. " err=" .. tostring(err2))
        else
            gid, uc = _M.parse_javbus_detail(res2.body)
            if gid then
                break
            end
        end
        if attempt == 1 then
            ngx.sleep(0.5)
        end
    end
    if not gid then
        return nil, "javbus: gid not found"
    end

    -- 3. Magnet AJAX table.
    local ajax_url = JAVBUS .. "/ajax/uncledatoolsbyajax.php?lang=zh&gid=" .. gid .. "&uc=" .. (uc or "0")
    local res3, err3 = get(ajax_url, {
        ["Accept-Language"] = ACCEPT_LANG,
        ["Cookie"] = "existmag=mag",
        ["Referer"] = movie_url,
    })
    if not res3 or res3.status ~= 200 then
        ngx.log(ngx.ERR, "javbus ajax status=" .. (res3 and res3.status or "nil") .. " err=" .. tostring(err3))
        return nil, "javbus ajax failed"
    end
    return _M.parse_javbus_magnets(res3.body, movie_url)
end

-------------------------------------------------------------------------------
-- Aggregation
-------------------------------------------------------------------------------

local SOURCES = {
    { key = "sukebei", label = "sukebei", fetch = fetch_sukebei },
    { key = "javdb",   label = "javdb",   fetch = fetch_javdb },
    { key = "javbus",  label = "javbus",  fetch = fetch_javbus },
}

-- Parse the ?s= query: "sukebei/javdb/javbus", comma separated, empty = all.
-- Unknown tokens are ignored.
local function parse_sources(raw)
    if not raw or raw == "" then
        return SOURCES
    end
    local wanted = {}
    for token in (raw .. ""):gmatch("[^,%s]+") do
        wanted[token:lower()] = true
    end
    local out = {}
    for _, src in ipairs(SOURCES) do
        if wanted[src.key] then
            out[#out + 1] = src
        end
    end
    if #out == 0 then
        return SOURCES
    end
    return out
end

-- Fetch a single source with caching + error capture.
-- Returns (magnets|nil, err).
local function lookup_source(src, code)
    local cached = cache_get(src.key, code)
    if cached and type(cached) == "table" and #cached > 0 then
        return cached, nil
    end
    local ok, magnets, err = pcall(src.fetch, code)
    if not ok then
        ngx.log(ngx.ERR, "magnet " .. src.key .. " pcall error: " .. tostring(magnets))
        return nil, src.key .. ": internal error"
    end
    if not magnets or #magnets == 0 then
        return nil, err or (src.key .. ": no results")
    end
    cache_set(src.key, code, magnets)
    return magnets, nil
end

function _M.handle(raw_id)
    local code = string.upper(raw_id or ""):gsub("%s+", "")
    if code == "" then
        ngx.status = 400
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.say(cjson.encode({
            error = "bad_request",
            message = "Missing id parameter. Usage: /api/magnet/:id",
        }))
        return
    end

    local args = ngx.req.get_uri_args()
    local sources = parse_sources(args.s)

    local threads = {}
    for i, src in ipairs(sources) do
        threads[i] = ngx.thread.spawn(lookup_source, src, code)
    end

    local results = {}
    local total = 0
    for i, src in ipairs(sources) do
        local ok, magnets, err = ngx.thread.wait(threads[i])
        local entry = { source = src.label }
        if ok and magnets then
            entry.count = #magnets
            entry.magnets = magnets
            total = total + #magnets
        else
            entry.count = 0
            entry.magnets = {}
            entry.error = err or (src.label .. ": failed")
        end
        results[i] = entry
    end

    ngx.status = 200
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.say(cjson.encode({
        code = code,
        count = total,
        sources = results,
    }))
end

-- Exposed for the offline test harness (luajit, no OpenResty).
_M.fetch_sukebei = fetch_sukebei
_M.fetch_javdb = fetch_javdb
_M.fetch_javbus = fetch_javbus

return _M