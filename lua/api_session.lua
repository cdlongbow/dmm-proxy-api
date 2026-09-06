local cjson = require "cjson"
local config = require "config"
local sign = require "sign"

local _M = {}

-- Issue a short-lived, client-IP-bound frontend session token. This is the
-- ONLY token the browser ever sees; the master DMM_AUTH_TOKEN never leaves
-- the server (config.js used to leak it — removed).
function _M.handle()
    local token = sign.mint_frontend()
    ngx.status = 200
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.header["Cache-Control"] = "no-store"
    ngx.say(cjson.encode({
        token = token,
        exp = ngx.time() + config.FRONTEND_TTL,
        ttl = config.FRONTEND_TTL,
    }))
end

return _M