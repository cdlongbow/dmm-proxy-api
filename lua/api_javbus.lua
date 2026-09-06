-- /api/search/:id fallback source: javbus.com detail data via a JSON API.
--
-- When the FANZA GraphQL probe (lua/api_content.lua) comes up empty for a
-- 番号, /api/search falls back to javbus. Scraping javbus.com HTML directly is
-- unreliable (its Cloudflare gates OpenResty cosocket TLS fingerprints and
-- serves region-stripped pages), so we query a third-party javbus JSON API
-- (javbus-api.131433.xyz) that returns the same fields without scraping:
--
--   id / title / img / date / videoLength / director / producer / publisher /
--   series / genres / stars / samples
--
-- The response shape is kept compatible with the GraphQL path so the frontend
-- needs no changes; the API response just reports `"source":"javbus"`.

local cjson = require "cjson"
local http = require "resty.http"

local _M = {}

local API_BASE = "https://javbus-api.131433.xyz"

-- Browser-like UA; the API is a plain JSON server so no special headers needed.
local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
local REQ_TIMEOUT = 10000

--------------------------------------------------------------------------------
-- JSON API -> public work object.
--------------------------------------------------------------------------------

-- API fields -> work object (shape compatible with the GraphQL path).
local function parse(j)
    local id = j.id or ""

    local samples = {}
    if type(j.samples) == "table" then
        for _, s in ipairs(j.samples) do
            -- src is an external CDN (mgstage / dmm); thumbnail points at
            -- javbus's own /pics/ which browsers block for CORS. Use src for
            -- both so the frontend can load them.
            local src = s.src or ""
            samples[#samples + 1] = {
                number = #samples + 1,
                smallUrl = src,
                largeUrl = src,
            }
        end
    end

    local genres = {}
    if type(j.genres) == "table" then
        for _, g in ipairs(j.genres) do
            if type(g) == "table" and g.name then
                genres[#genres + 1] = g.name
            end
        end
    end

    local actresses = {}
    if type(j.stars) == "table" then
        for _, s in ipairs(j.stars) do
            if type(s) == "table" and s.name then
                actresses[#actresses + 1] = s.name
            end
        end
    end

    local director
    if type(j.director) == "table" and j.director.name then
        director = j.director.name
    elseif type(j.director) == "string" and j.director ~= "" then
        director = j.director
    end

    local producer = (type(j.producer) == "table") and (j.producer.name or "") or ""
    local publisher = (type(j.publisher) == "table") and (j.publisher.name or "") or ""
    local series = (type(j.series) == "table") and (j.series.name or "") or ""

    local w = {
        id = id,
        makerContentId = id,
        title = j.title or "",
        floor = "javbus",
        contentType = nil,
        cover = (j.img and j.img ~= "") and { medium = j.img, large = j.img } or { medium = "", large = "" },
        deliveryStartDate = j.date or "",
        makerReleasedAt = j.date or "",
        director = director or "未知",
        series = series ~= "" and { series } or {},
        maker = producer,
        label = publisher ~= "" and { publisher } or {},
        genres = genres,
        actresses = actresses,
        sampleImages = samples,
        webUrl = id ~= "" and ("https://www.javbus.com/" .. id) or "",
    }

    local mins = tonumber(j.videoLength)
    if mins and mins > 0 then
        w.duration = {
            seconds = mins * 60,
            minutes = mins,
        }
    end

    return w
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Resolve `code` (e.g. "ABF-364") through the javbus JSON API and return a
-- public work object, or (nil, reason).
function _M.fetch(code)
    local norm = string.upper(code):gsub("%s+", "")
    if norm == "" then
        return nil, "bad code"
    end

    local url = API_BASE .. "/api/movies/" .. ngx.escape_uri(norm)
    local httpc = http.new()
    httpc:set_timeout(REQ_TIMEOUT)
    local res, err = httpc:request_uri(url, {
        method = "GET",
        ssl_verify = false,
        headers = {
            ["User-Agent"] = UA,
            ["Accept"] = "application/json",
        },
    })
    if not res then
        return nil, "javbus-api request failed: " .. tostring(err)
    end
    if res.status ~= 200 then
        -- 404 => no such 番号 in javbus.
        return nil, "javbus-api status=" .. res.status
    end

    local ok, j = pcall(cjson.decode, res.body or "")
    if not ok or type(j) ~= "table" or not j.id then
        return nil, "javbus-api bad json"
    end

    return parse(j)
end

return _M