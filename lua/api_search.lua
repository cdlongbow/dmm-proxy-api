-- /api/search/:id - FANZA 番号 search (no affiliate / appid required).
--
-- The path id is the 番号 (e.g. "abp-477"). It is matched case-insensitively:
-- the raw input is uppercased and normalized (whitespace stripped).
--
-- Instead of the DMM affiliate ItemList API, we expand the 番号 into candidate
-- digital content ids (maker + zero-padded serial, with common prefixes) and
-- probe them directly through video.dmm.co.jp's GraphQL ContentPageData
-- (see lua/api_content.lua:get_by_code). The first hit already carries the
-- full product detail, so no second enrichment request is needed and no
-- appid/affiliate_id is ever sent.
--
-- Usage:
--   GET /api/search/abp-477
--   GET /api/search/ABP-477?offset=0&hits=30     (kept for compatibility)

local cjson = require "cjson"
local content = require "api_content"
local searchrank = require "api_searchrank"

local _M = {}

local CACHE_TTL = 6 * 3600

local function cache_key(code, offset)
    return "sr:" .. code .. ":" .. tostring(offset)
end

local function cache_get(code, offset)
    local dict = ngx.shared.search_cache
    if not dict then
        return nil
    end
    return dict:get(cache_key(code, offset))
end

local function cache_set(code, offset, body)
    local dict = ngx.shared.search_cache
    if not dict then
        return
    end
    dict:set(cache_key(code, offset), body, CACHE_TTL)
end

-- Build the public work object straight from a GraphQL detail table.
local function work_from_detail(d)
    local w = {
        id = d.id or "",
        makerContentId = d.makerContentId or "",
        title = d.title or "",
        floor = d.floor,
        contentType = d.contentType,
        cover = d.cover or { medium = "", large = "" },
        deliveryStartAt = d.deliveryStartDate or "",
        deliveryStartDate = d.deliveryStartDate or "",
        makerReleasedAt = d.makerReleasedAt or "",
        saleEndAt = (d.saleEndDate == "" and "" or d.saleEndDate),
        description = d.description,
        wishlistCount = d.wishlistCount,
        actresses = d.actresses,
        directors = d.directors,
        series = d.series and { d.series } or {},
        maker = d.maker,
        label = d.label and { d.label } or {},
        genres = d.genres,
        relatedTags = d.relatedTags,
        playableDevices = d.playableDevices,
        review = d.review,
        sample2DMovie = d.sample2DMovie,
        sampleVRMovie = d.sampleVRMovie,
    }

    if d.duration and d.duration > 0 then
        w.duration = {
            seconds = d.duration,
            minutes = math.floor(d.duration / 60),
        }
    end

    if d.pricing then
        local list = tonumber(d.pricing.price) or 0
        local sale = tonumber(d.pricing.salePrice) or 0
        local p = sale > 0 and sale or list
        if p > 0 then
            w.price = {
                price = p,
                listPrice = list,
                salePrice = sale,
            }
        end
    end

    if d.sampleImages and #d.sampleImages > 0 then
        local imgs = {}
        for _, s in ipairs(d.sampleImages) do
            imgs[#imgs + 1] = {
                number = tonumber(s.number) or #imgs + 1,
                smallUrl = s.imageUrl or s.largeImageUrl or "",
                largeUrl = s.largeImageUrl or s.imageUrl or "",
            }
        end
        w.sampleImages = imgs
    end

    return w
end

function _M.handle(raw_id)
    -- Development aid: surface Lua runtime errors as JSON so they are visible
    -- without digging through nginx error logs.
    local ok, err_or_body = pcall(function()
        local args = ngx.req.get_uri_args()

        local code = string.upper(ngx.unescape_uri(raw_id or "")):gsub("%s+", "")
        if code == "" then
            ngx.status = 400
            ngx.header["Content-Type"] = "application/json; charset=utf-8"
            ngx.say(cjson.encode({
                error = "bad_request",
                message = "Missing id parameter. Usage: /api/search/:id",
            }))
            return
        end

        local offset = tonumber(args.offset) or 0
        if offset < 0 then
            offset = 0
        end

        searchrank.record(code)
        local cached = cache_get(code, offset)
        if cached then
            ngx.status = 200
            ngx.header["Content-Type"] = "application/json; charset=utf-8"
            ngx.say(cached)
            return
        end

        local mgs = require "api_mgs"

        local works = {}
        local source = "graphql"
        if mgs.is_mgs(code) then
            -- MGS 番号 goes straight to mgstage.com (not through FANZA/javbus).
            local mdet, merr = mgs.fetch(code)
            if mdet then
                works[1] = mdet
                source = "mgs"
            else
                ngx.log(ngx.ERR, "search " .. code .. ": mgs fetch failed: " .. tostring(merr))
            end
        else
            local detail = content.get_by_code(code)
            if detail then
                works[1] = work_from_detail(detail)
            else
                -- FANZA GraphQL found nothing -> javbus detail page as fallback.
                local javbus = require "api_javbus"
                local jdet, jerr = javbus.fetch(code)
                if jdet then
                    works[1] = jdet
                    source = "javbus"
                else
                    ngx.log(ngx.ERR, "search " .. code .. ": javbus fallback failed: " .. tostring(jerr))
                end
            end
        end

        local body = cjson.encode({
            keyword = code,
            source = source,
            total = #works,
            count = #works,
            hits = 1,
            limit = 1,
            offset = offset,
            hasNext = false,
            works = works,
        })
        cache_set(code, offset, body)

        ngx.status = 200
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.say(body)
    end)
    if not ok then
        ngx.status = 500
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.say(cjson.encode({
            error = "lua_error",
            message = tostring(err_or_body),
        }))
    end
end

return _M