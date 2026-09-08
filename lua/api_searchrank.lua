-- /api/searchrank - Top 20 most-searched 番号 (by frequency).
--
-- Counts are accumulated in the `searchrank_cache` shared dict (1 m, declared
-- in nginx.conf).  Each code's TTL is refreshed to 7 days on every search so
-- that codes not searched in a week naturally expire.
--
-- The GET response is computed fresh from the analytics dict on every call
-- (the dict is tiny, at most a few hundred keys).

local cjson = require "cjson"

local _M = {}

local TTL = 7 * 86400   -- 7 days

-- ---- recording (called by api_search on every valid query) ----

function _M.record(code)
    local dict = ngx.shared.searchrank_cache
    if not dict then return end
    local _, err = dict:incr(code, 1, 0)
    if not _ then
        ngx.log(ngx.ERR, "searchrank incr " .. code .. ": " .. tostring(err))
        return
    end
    dict:expire(code, TTL)
end

-- ---- GET /api/searchrank ----

function _M.handle()
    local dict = ngx.shared.searchrank_cache
    if not dict then
        ngx.status = 200
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.say(cjson.encode({ total = 0, count = 0, items = cjson.empty_array }))
        return
    end

    local keys = dict:get_keys(0)
    local items = {}
    for _, key in ipairs(keys) do
        local n = dict:get(key)
        if n then
            items[#items + 1] = { code = key, count = n }
        end
    end

    table.sort(items, function(a, b) return a.count > b.count end)

    local top = {}
    for i = 1, math.min(20, #items) do
        top[i] = items[i]
    end

    ngx.status = 200
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.say(cjson.encode({
        total = #items,
        count = #top,
        items  = top,
    }))
end

return _M
