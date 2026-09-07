-- /api/search/:id MGS fallback source: mgstage.com product detail pages.
--
-- MGS (MGStage / Prestige Group) works are not listed on FANZA; they live on
-- www.mgstage.com. When the requested 番号 begins with one of the known MGS
-- prefix fragments, /api/search goes straight to MGS (not through FANZA or
-- javbus) and reports `"source":"mgs"`.
--
-- Prefixes come in two flavours, treated equally:
--   * official system codes ("200GANA", "300MIUM", ...) and
--   * letter code prefixes ("ABF", "SIRO", "MAAN", ...).
-- A normalized 番号 (uppercased, dashes stripped, e.g. "200GANA2359") is
-- considered MGS when it starts with any prefix AND the character right after
-- the prefix is a digit. This avoids false hits like "GALS-001" (letter "S"
-- follows "GAL") while matching "GAL-123".
--
-- The product detail page requires the `adc=1` age-gate cookie; without it the
-- server returns the 年齢認証 page. We parse the server-rendered HTML directly.
--
--   GET /product/product_detail/{PREFIX}-{SERIAL}/
--     with Cookie: adc=1

local cjson = require "cjson"
local http = require "resty.http"

local _M = {}

-- Browser-like UA; MGS serves plain HTML to any modern UA.
local UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
local REQ_TIMEOUT = 10000

-- Official system codes and letter code prefixes (equal relation).
local PREFIXES = {
    -- official system codes
    "040KIR", "115KUMA", "118STA", "130ODK", "134TAP", "137HUNT",
    "174SGA", "177ARA", "182NAMA", "200GANA", "200HMN", "200NTK",
    "229MAAN", "229SCUTE", "230DCOL", "230DOC", "230MUGN", "230ORE",
    "230OREC", "230SHKD", "244DIC", "246SIRO", "248SHL", "259LUXU",
    "260DCOL", "261ARA", "277APA", "277DCV", "277DOC", "277URAN",
    "300MAAN", "300MIUM", "300NTK", "318LADY", "328HAP", "328HMDNC",
    "332NAMA", "380REI", "384DANDY", "390JNT", "396YTS", "428SUKE",
    "443TEN", "477MGT", "491TKWA", "520SSK", "558KRS",
    -- letter code prefixes
    "ABF", "ABP", "ABS", "ABW", "ABZ", "APA", "ARA", "BGN", "CHCH",
    "CHN", "DANDY", "DCOL", "DCV", "DIC", "DOC", "EVO", "EZD", "FPRE",
    "FSET", "GAL", "GANA", "GLP", "HAP", "HMDNC", "HMN", "HUNT", "JNT",
    "KANBI", "KB", "KIR", "KRS", "KUMA", "LADY", "LUS", "LUST", "LUXU",
    "MAAN", "MAD", "MAS", "MBM", "MGT", "MIUM", "MUGN", "NAMA", "NTK",
    "ODK", "ONEZ", "ORE", "OREC", "PPT", "PRED", "REI", "SCUTE", "SGA",
    "SHKD", "SHL", "SIRO", "SIV", "SPZ", "SSK", "STA", "SUKE", "TAP",
    "TBD", "TBH", "TEN", "TKWA", "URAN", "YTS",
}

local PREFIXES_BY_LEN = {}
do
    local tmp = {}
    for _, p in ipairs(PREFIXES) do
        tmp[#tmp + 1] = p
    end
    table.sort(tmp, function(a, b) return #a > #b end)
    PREFIXES_BY_LEN = tmp
end

-- Normalize a raw input the same way api_search does (uppercase, strip
-- whitespace) and additionally strip dashes for prefix matching.
local function normalize(code)
    return string.upper(tostring(code or "")):gsub("%s+", ""):gsub("-", "")
end

-- True when the normalized 番号 starts with an MGS prefix followed by a digit.
function _M.is_mgs(code)
    local norm = normalize(code)
    if norm == "" then
        return false
    end
    for _, p in ipairs(PREFIXES_BY_LEN) do
        if norm:sub(1, #p) == p then
            local next_c = norm:sub(#p + 1, #p + 1)
            if next_c ~= "" and next_c:match("%d") then
                return true
            end
        end
    end
    return false
end

-- Match the longest prefix of `norm` that also starts the string. Returns the
-- prefix (used to reconstruct "{PREFIX}-{SERIAL}").
local function match_prefix(norm)
    for _, p in ipairs(PREFIXES_BY_LEN) do
        if norm:sub(1, #p) == p then
            local next_c = norm:sub(#p + 1, #p + 1)
            if next_c ~= "" and next_c:match("%d") then
                return p
            end
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- HTML parsing helpers
--------------------------------------------------------------------------------

local function strip_tags(s)
    if not s then
        return ""
    end
    s = s:gsub("<script[^>]*>.-</script>", "")
    s = s:gsub("<style[^>]*>.-</style>", "")
    s = s:gsub("<[^>]+>", "")
    s = s:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- Split a cell's raw inner html into its anchor texts (one item per <a>),
-- falling back to every whitespace-delimited token of the text when there are
-- no anchors.
local function cell_items(cell)
    local items = {}
    if not cell then
        return items
    end
    local anchored = false
    for txt in cell:gmatch('<a[^>]*>(.-)</a>') do
        txt = strip_tags(txt)
        if txt ~= "" then
            items[#items + 1] = txt
            anchored = true
        end
    end
    if not anchored then
        for tok in strip_tags(cell):gmatch("%S+") do
            items[#items + 1] = tok
        end
    end
    return items
end

-- Parse every spec row "<th>LABEL：</th><td>...</td>" into a label->raw cell map.
local function parse_spec(html)
    local spec = {}
    for th, td in html:gmatch("<th[^>]*>(.-)</th>%s*<td[^>]*>(.-)</td>") do
        local key = strip_tags(th):gsub("：", ""):gsub("%s+$", "")
        if key ~= "" then
            spec[key] = td
        end
    end
    return spec
end

-- Extract the 商品紹介 body: <dl id="introduction"><p class="txt introduction">…
-- `<br>` preserved as newlines, `…すべてを見る` link text dropped.
local function parse_description(html)
    local s, e = html:find('<p class="txt introduction">', 1, true)
    if not s then
        return nil
    end
    local e2 = html:find("</dl>", e, true)
    local seg = e2 and html:sub(e + 1, e2 - 1) or html:sub(e + 1)
    seg = seg:gsub("<%s*/?%s*p[^>]*>", "\n")
    seg = seg:gsub("<br%s*/?>", "\n")
    seg = seg:gsub("<[^>]+>", "")
    seg = seg:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
    local out = {}
    for line in seg:gmatch("[^\r\n]+") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and not line:find("すべてを見る", 1, true) then
            out[#out + 1] = line
        end
    end
    if #out == 0 then
        return nil
    end
    return table.concat(out, "\n")
end

--------------------------------------------------------------------------------
-- Detail page -> public work object
--------------------------------------------------------------------------------

local function parse(html, code)
    -- title: og:title 「…」 or <title> 「…」
    local title = html:match('<meta[^>]+property="og:title"[^>]+content="([^"]+)"')
        or html:match('<meta[^>]+content="([^"]+)"[^>]+property="og:title"')
        or html:match("<title>(.-)</title>")
    if title then
        title = title:match("「(.-)」") or title
    end
    title = strip_tags(title or "")

    local cover = html:match('<meta[^>]+property="og:image"[^>]+content="([^"]+)"')
        or html:match('<meta[^>]+content="([^"]+)"[^>]+property="og:image"') or ""

    local spec = parse_spec(html)

    local maker = strip_tags(spec["メーカー"] or "")
    local label = strip_tags(spec["レーベル"] or "")
    local series = strip_tags(spec["シリーズ"] or "")
    local dur_min = tonumber(strip_tags(spec["収録時間"] or ""):match("(%d+)"))
    local delivery = strip_tags(spec["配信開始日"] or "")
    local sales_date = strip_tags(spec["商品発売日"] or "")
    if sales_date:find("未発売", 1, true) then
        sales_date = ""
    end

    local actresses = cell_items(spec["出演"])
    local genres = cell_items(spec["ジャンル"])
    local description = parse_description(html)

    -- rating: <span class="star_45_49"></span>4.4 (16 件) — use the text right
    -- after the star badge. Fallback: "5点満点中 4.5点 / レビュー数 21 件".
    local review
    local star_e = html:find("class=\"star_%d%d_%d%d\"", 1)
    if star_e then
        local tail = html:sub(star_e, star_e + 120)
        local val_s = tail:match("(%d%.%d)%s*%(")
        local cnt_s = tail:match("%((%d+)%s*件%)")
        if not val_s then
            val_s = tail:match("(%d%.%d)%s*点")
            cnt_s = tail:match("レビュー数%s+(%d+)%s*件")
        end
        if val_s then
            review = {
                average = tonumber(val_s),
                count = tonumber(cnt_s) or 0,
            }
        end
    end

    -- price: <span class="now-price">1,980<span class="price-suffix">円(税込)</span></span>
    local price = 0
    local ns, ne = html:find("class=\"now-price\">", 1, true)
    if ns then
        local w1, w2 = html:sub(ne + 1, ne + 32):match("(%d+),?(%d*)")
        price = tonumber(w1) or 0
        if w2 ~= "" then
            price = price * 1000 + (tonumber(w2) or 0)
        end
    end

    -- samples: <a class="sample_image" href="https://image.mgstage.com/.../cap_e_0_....jpg">
    local samples = {}
    for h in html:gmatch('class="sample_image" href="([^"]+)"') do
        samples[#samples + 1] = {
            number = #samples + 1,
            smallUrl = h,
            largeUrl = h,
        }
    end

    local w = {
        id = code,
        makerContentId = code,
        title = title,
        floor = "mgs",
        contentType = nil,
        cover = cover ~= "" and { medium = cover, large = cover } or { medium = "", large = "" },
        deliveryStartDate = delivery,
        makerReleasedAt = sales_date,
        salesDate = sales_date,
        description = description,
        director = "未知",
        series = series ~= "" and { series } or {},
        maker = maker ~= "" and maker or nil,
        label = label ~= "" and { label } or {},
        genres = genres,
        actresses = actresses,
        sampleImages = samples,
        webUrl = "https://www.mgstage.com/product/product_detail/" .. code .. "/",
    }

    if dur_min and dur_min > 0 then
        w.duration = {
            seconds = dur_min * 60,
            minutes = dur_min,
        }
    end
    if price > 0 then
        w.price = {
            price = price,
            listPrice = price,
            salePrice = price,
        }
    end
    if review then
        w.review = review
        w.mgs = review
        w.mgs.price = price
    end

    return w
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Resolve an MGS 番号 through the product detail page and return a public work
-- object, or (nil, reason).
function _M.fetch(code)
    local norm = normalize(code)
    if norm == "" then
        return nil, "bad code"
    end
    local prefix = match_prefix(norm)
    if not prefix then
        return nil, "not an mgs code"
    end

    local code = prefix .. "-" .. norm:sub(#prefix + 1)

    local url = "https://www.mgstage.com/product/product_detail/" .. code .. "/"

    -- The Docker DNS resolver intermittently fails to resolve
    -- www.mgstage.com ("could not be resolved (2: Server failure)"). Treat a
    -- hard transport err as transient and retry a few times.
    local res, err
    for attempt = 1, 3 do
        local httpc = http.new()
        httpc:set_timeout(REQ_TIMEOUT)
        res, err = httpc:request_uri(url, {
            method = "GET",
            ssl_verify = false,
            headers = {
                ["User-Agent"] = UA,
                ["Cookie"] = "adc=1",
            },
        })
        if res or not err then
            break
        end
        if attempt < 3 then
            ngx.log(ngx.WARN, "mgs fetch failed for code=" .. code
                .. ": " .. tostring(err) .. ", retrying (" .. attempt .. "/2)")
            ngx.sleep(attempt * 0.3)
        else
            ngx.log(ngx.ERR, "mgs fetch failed for code=" .. code .. ": " .. tostring(err))
        end
    end
    if not res then
        return nil, "mgstage request failed: " .. tostring(err)
    end
    if res.status ~= 200 then
        -- 302 -> redirected to top page when the 番号 does not exist.
        return nil, "mgstage status=" .. res.status
    end

    local body = res.body or ""
    -- age gate without cookie / not-found page: both lack the spec table
    if not body:find("メーカー：", 1, true) and not body:find("品番：", 1, true) then
        if body:find("年齢認証", 1, true) or body:find("adc", 1, true) then
            return nil, "mgstage age gate"
        end
        return nil, "mgstage detail not found"
    end

    return parse(body, code)
end

return _M