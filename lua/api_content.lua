-- api_content.lua - FANZA video.dmm.co.jp GraphQL content lookup.
--
-- Looks up the full detail record for a DMM content id via the public (but
-- undocumented) GraphQL endpoint https://api.video.dmm.co.jp/graphql using the
-- "ContentPageData" operation. No login / cookies are required; the guestToken
-- is only used for basket queries we do not make, so an empty string works.
--
-- IMPORTANT: many search hits are DVD/mono items whose affiliate content_id
-- (e.g. "ipx685") is NOT the digital id (e.g. "ipx00685") that ppvContent
-- accepts. We therefore probe several id variants (see config.to_cids / the
-- 5-digit padding below) and take the first one that resolves.
--
-- Returns a normalized detail table, or nil when no digital content matches.

local cjson = require "cjson"
local config = require "config"
local http = require "resty.http"

if cjson.encode_empty_table_as_object then
    cjson.encode_empty_table_as_object(false)
end

local _M = {}

local CACHE_TTL = 7 * 3600
local REQ_TIMEOUT = 10000
local ENDPOINT = "https://api.video.dmm.co.jp/graphql"

local QUERY = [[query ContentPageData($id: ID!, $isLoggedIn: Boolean!, $isAmateur: Boolean!, $isAnime: Boolean!, $isAv: Boolean!, $isCinema: Boolean!, $shouldFetchRelatedTags: Boolean = false, $shouldGetBookmark: Boolean!, $guestToken: String!) {
  ppvContent(id: $id) {
    ...ContentData
    __typename
  }
  reviewSummary(contentId: $id) {
    ...ReviewSummary
    __typename
  }
}
fragment ContentData on PPVContent {
  id
  floor
  title
  isExclusiveDelivery
  releaseStatus
  description
  notices
  isNoIndex
  isAllowForeign
  isInWishList @include(if: $shouldGetBookmark)
  announcements {
    body
    __typename
  }
  featureArticles {
    link {
      url
      text
      __typename
    }
    __typename
  }
  packageImage {
    largeUrl
    mediumUrl
    __typename
  }
  sampleImages {
    number
    imageUrl
    largeImageUrl
    __typename
  }
  products {
    ...ProductData
    __typename
  }
  mostPopularContentImage {
    ... on ContentSampleImage {
      __typename
      largeImageUrl
      imageUrl
    }
    ... on PackageImage {
      __typename
      largeUrl
      mediumUrl
    }
    __typename
  }
  pricing {
    lowestEffectivePriceInclusiveTax
    lowestRegularPriceInclusiveTax
    sale {
      name
      id
      endAt
      __typename
    }
    pointRewardCampaign {
      name
      id
      endAt
      promotionId
      rate
      __typename
    }
    __typename
  }
  weeklyRanking: ranking(term: Weekly)
  monthlyRanking: ranking(term: Monthly)
  wishlistCount
  sample2DMovie {
    highestMovieUrl
    hlsMovieUrl
    __typename
  }
  sampleVRMovie {
    highestMovieUrl
    __typename
  }
  ...AmateurAdditionalContentData @include(if: $isAmateur)
  ...AnimeAdditionalContentData @include(if: $isAnime)
  ...AvAdditionalContentData @include(if: $isAv)
  ...CinemaAdditionalContentData @include(if: $isCinema)
  __typename
}
fragment ProductData on PPVProduct {
  id
  priority
  isInBasket @include(if: $isLoggedIn)
  isInGuestBasket(token: $guestToken)
  deliveryUnit {
    id
    priority
    streamMaxQualityGroup
    downloadMaxQualityGroup
    __typename
  }
  pricing {
    regularPriceInclusiveTax
    effectivePriceInclusiveTax
    __typename
  }
  expireDays
  utilizationStatus @include(if: $isLoggedIn)
  licenseType
  shopName
  couponDiscount {
    coupon {
      name
      expirationPolicy {
        ... on CouponExpirationAt {
          expirationAt
          __typename
        }
        ... on CouponExpirationDay {
          expirationDays
          __typename
        }
        __typename
      }
      expirationAt
      minPayment
      destinationUrl
      __typename
    }
    discountedPriceInclusiveTax
    __typename
  }
  __typename
}
fragment AmateurAdditionalContentData on PPVContent {
  deliveryStartDate
  saleEndDate
  duration
  amateurActress {
    id
    name
    imageUrl
    age
    waist
    bust
    bustCup
    height
    hip
    relatedContents {
      id
      title
      __typename
    }
    __typename
  }
  maker {
    id
    name
    __typename
  }
  label {
    id
    name
    __typename
  }
  genres {
    id
    name
    __typename
  }
  makerContentId
  playableInfo {
    ...PlayableInfo
    __typename
  }
  __typename
}
fragment PlayableInfo on PlayableInfo {
  playableDevices {
    deviceDeliveryUnits {
      id
      deviceDeliveryQualities {
        isDownloadable
        isStreamable
        __typename
      }
      __typename
    }
    device
    name
    priority
    isSupported
    __typename
  }
  deviceGroups {
    id
    devices {
      deviceDeliveryUnits {
        id
        deviceDeliveryQualities {
          isStreamable
          isDownloadable
          __typename
        }
        __typename
      }
      isSupported
      __typename
    }
    __typename
  }
  vrViewingType
  __typename
}
fragment AnimeAdditionalContentData on PPVContent {
  deliveryStartDate
  saleEndDate
  duration
  series {
    id
    name
    __typename
  }
  maker {
    id
    name
    __typename
  }
  label {
    id
    name
    __typename
  }
  genres {
    id
    name
    __typename
  }
  makerContentId
  playableInfo {
    ...PlayableInfo
    __typename
  }
  __typename
}
fragment AvAdditionalContentData on PPVContent {
  deliveryStartDate
  saleEndDate
  makerReleasedAt
  duration
  actresses {
    id
    name
    nameRuby
    imageUrl
    bustTop
    bust
    waist
    hip
    height
    ppvSummary(floor: AV) {
      contentCount
      __typename
    }
    isFavorite @include(if: $shouldGetBookmark)
    __typename
  }
  histrions {
    id
    name
    __typename
  }
  directors {
    id
    name
    __typename
  }
  series {
    id
    name
    __typename
  }
  maker {
    id
    name
    __typename
  }
  label {
    id
    name
    __typename
  }
  genres {
    id
    name
    __typename
  }
  contentType
  relatedTags(limit: 16) @include(if: $shouldFetchRelatedTags) {
    ... on ContentTagGroup {
      tags {
        id
        name
        __typename
      }
      __typename
    }
    ... on ContentTag {
      id
      name
      __typename
    }
    __typename
  }
  makerContentId
  playableInfo {
    ...PlayableInfo
    __typename
  }
  __typename
}
fragment CinemaAdditionalContentData on PPVContent {
  deliveryStartDate
  saleEndDate
  duration
  actresses {
    id
    name
    nameRuby
    imageUrl
    __typename
  }
  histrions {
    id
    name
    __typename
  }
  directors {
    id
    name
    __typename
  }
  authors {
    id
    name
    __typename
  }
  series {
    id
    name
    __typename
  }
  maker {
    id
    name
    __typename
  }
  label {
    id
    name
    __typename
  }
  genres {
    id
    name
    __typename
  }
  makerContentId
  playableInfo {
    ...PlayableInfo
    __typename
  }
  __typename
}
fragment ReviewSummary on ReviewSummary {
  average
  total
  withCommentTotal
  distributions {
    total
    withCommentTotal
    rating
    __typename
  }
  __typename
}]]

local function cache_get(cid)
    local dict = ngx.shared.search_cache
    if not dict then
        return nil
    end
    return dict:get("gc:" .. cid)
end

local function cache_set(cid, body)
    local dict = ngx.shared.search_cache
    if not dict then
        return
    end
    dict:set("gc:" .. cid, body, CACHE_TTL)
end

-- Build candidate digital ids from an affiliate content_id.
-- "ipx685" -> {"ipx685", "ipx00685"}; "ssis00666" -> {"ssis00666"}
local function content_variants(content_id)
    local seen, out = {}, {}
    local function add(s)
        if s and s ~= "" and not seen[s] then
            seen[s] = true
            out[#out + 1] = s
        end
    end
    add(content_id)
    local prefix = content_id:match("^%a+")
    local num = content_id:match("(%d+)$")
    if prefix and num and #num < 8 then
        add(prefix .. string.format("%05d", tonumber(num)))
        add(prefix .. string.format("%04d", tonumber(num)))
    end
    return out
end

-- Single GraphQL query for one id. Returns the raw ppvContent+reviewSummary
-- table or (nil, err).
local function fetch_raw(cid)
    local payload = cjson.encode({
        operationName = "ContentPageData",
        query = QUERY,
        variables = {
            id = cid,
            guestToken = config.VIDEO_GQL and config.VIDEO_GQL.guest_token or "",
            isLoggedIn = false,
            isAmateur = false,
            isAnime = false,
            isAv = true,
            isCinema = false,
            shouldFetchRelatedTags = true,
            shouldGetBookmark = false,
        },
    })

    local httpc = http.new()
    httpc:set_timeout(REQ_TIMEOUT)
    local res, err = httpc:request_uri(ENDPOINT, {
        method = "POST",
        ssl_verify = false,
        headers = {
            ["Content-Type"] = "application/json",
            ["fanza-device"] = "BROWSER",
            ["Origin"] = "https://video.dmm.co.jp",
            ["Referer"] = "https://video.dmm.co.jp/",
            ["User-Agent"] = config.WEB.ua,
            ["Accept"] = "application/graphql-response+json, application/json",
        },
        body = payload,
    })
    if not res then
        return nil, err
    end
    if res.status ~= 200 then
        return nil, "graphql status " .. res.status
    end

    local ok, data = pcall(cjson.decode, res.body)
    if not ok or type(data) ~= "table" then
        return nil, "invalid graphql json"
    end
    if type(data.errors) == "table" and #data.errors > 0 then
        local m = data.errors[1] and data.errors[1].message or "graphql error"
        return nil, m
    end
    -- cjson decodes JSON null to a lightuserdata sentinel; be strict here or the
    -- caller ends up indexing a userdata. A null ppvContent simply means "no
    -- digital content for this id" (e.g. DVD-only titles carry a different id).
    local pc = data.data and data.data.ppvContent
    if type(pc) ~= "table" then
        return nil, nil
    end
    return data.data
end

-- Normalize a part of the raw response into a friendly detail table.
local function normalize_detail(raw)
    if type(raw) ~= "table" or type(raw.ppvContent) ~= "table" then
        return nil
    end
    local pc = raw.ppvContent
    local rs = raw.reviewSummary

    local function names(field)
        local out = {}
        local arr = pc[field]
        if type(arr) == "table" then
            for _, v in ipairs(arr) do
                if type(v) == "table" and v.name then
                    out[#out + 1] = { id = v.id, name = v.name }
                end
            end
        end
        return out
    end

    local genres = names("genres")

    local relatedTags = {}
    if type(pc.relatedTags) == "table" then
        local seen = {}
        local function addtag(t)
            if t and t.name and not seen[t.name] then
                seen[t.name] = true
                relatedTags[#relatedTags + 1] = { id = t.id, name = t.name }
            end
        end
        for _, g in ipairs(pc.relatedTags) do
            if g.tags then
                for _, tg in ipairs(g.tags) do
                    addtag(tg)
                end
            else
                addtag(g)
            end
        end
    end

    local actresses = {}
    if type(pc.actresses) == "table" then
        for _, a in ipairs(pc.actresses) do
            actresses[#actresses + 1] = {
                id = a.id,
                name = a.name,
                nameRuby = a.nameRuby,
                imageUrl = a.imageUrl,
                bustTop = a.bustTop,
                bust = a.bust,
                waist = a.waist,
                hip = a.hip,
                height = a.height,
                contentCount = a.ppvSummary and a.ppvSummary.contentCount,
            }
        end
    end

    local playable = {}
    if pc.playableInfo and type(pc.playableInfo.playableDevices) == "table" then
        for _, d in ipairs(pc.playableInfo.playableDevices) do
            if d and d.name then
                playable[#playable + 1] = { device = d.device, name = d.name }
            end
        end
    end

    local pricing = pc.pricing or {}
    local detail = {
        id = pc.id or "",
        floor = pc.floor or "",
        title = pc.title or "",
        description = pc.description or "",
        contentType = pc.contentType or "",
        cover = {
            medium = pc.packageImage and pc.packageImage.mediumUrl or "",
            large = pc.packageImage and pc.packageImage.largeUrl or "",
        },
        sampleImages = {},
        duration = tonumber(pc.duration) or 0,
        deliveryStartDate = pc.deliveryStartDate or "",
        saleEndDate = pc.saleEndDate or "",
        makerReleasedAt = pc.makerReleasedAt or "",
        makerContentId = pc.makerContentId or "",
        wishlistCount = pc.wishlistCount,
        actresses = actresses,
        directors = names("directors"),
        series = (function()
            local s = pc.series
            if type(s) == "table" and s.name then
                return { id = s.id, name = s.name }
            end
            return nil
        end)(),
        maker = (function()
            local m = pc.maker
            if type(m) == "table" and m.name then
                return { id = m.id, name = m.name }
            end
            return nil
        end)(),
        label = (function()
            local l = pc.label
            if type(l) == "table" and l.name then
                return { id = l.id, name = l.name }
            end
            return nil
        end)(),
        genres = genres,
        relatedTags = relatedTags,
        review = (function()
            local isTab = type(rs) == "table"
            return {
                average = isTab and (tonumber(rs.average) or 0) or 0,
                count = isTab and (tonumber(rs.total) or 0) or 0,
            }
        end)(),
        pricing = {
            price = tonumber(pricing.lowestRegularPriceInclusiveTax) or 0,
            salePrice = tonumber(pricing.lowestEffectivePriceInclusiveTax) or 0,
        },
        playableDevices = playable,
        sample2DMovie = (function()
            local m = pc.sample2DMovie
            if type(m) == "table" then
                return {
                    highestMovieUrl = m.highestMovieUrl or "",
                    hlsMovieUrl = m.hlsMovieUrl or "",
                }
            end
            return nil
        end)(),
        sampleVRMovie = (function()
            local m = pc.sampleVRMovie
            if type(m) == "table" then
                return m.highestMovieUrl or ""
            end
            return nil
        end)(),
    }

    if type(pc.sampleImages) == "table" then
        for _, s in ipairs(pc.sampleImages) do
            detail.sampleImages[#detail.sampleImages + 1] = {
                number = tonumber(s.number) or #detail.sampleImages + 1,
                imageUrl = s.imageUrl or "",
                largeImageUrl = s.largeImageUrl or "",
            }
        end
    end

    return detail
end

-- Public entry point: get(affiliate_content_id) -> normalized detail or nil.
function _M.get(content_id)
    if not content_id or content_id == "" then
        return nil
    end

    local variants = content_variants(content_id)
    for _, cid in ipairs(variants) do
        local cached = cache_get(cid)
        if cached then
            local ok, body = pcall(cjson.decode, cached)
            if ok and body and body.resolved_id then
                return body
            end
        end

        local raw, err = fetch_raw(cid)
        if raw then
            local detail = normalize_detail(raw)
            detail.resolved_id = cid
            local body = cjson.encode(detail)
            cache_set(cid, body)
            return detail
        elseif err then
            ngx.log(ngx.ERR, "content fetch failed for cid=" .. cid .. ": " .. tostring(err))
        end
    end
    return nil
end

-- Expand a 番号 (e.g. "SSIS-666", "1NAMH-00075") into candidate digital ids.
--
-- Digital ids observed in the wild are almost always `<maker><serial5>`
-- (ssis00666, ipx00685), occasionally carrying a `1`, `d_` or `h_` prefix
-- (1namh00075, d_abp00477) and/or shorter serial padding. The 番号 itself may
-- carry the same numeric `1`/`d_`/`h_` prefix, which must survive the
-- candidate expansion. We probe a small deduped candidate set via
-- ContentPageData (no affiliate/appid involved) and stop at the first hit.
local function candidate_ids(code)
    local prefix, maker, digits
    maker, digits = code:match("^1(%a+)(%d+)$")
    if maker then
        prefix = "1"
    else
        maker, digits = code:match("^d_(%a+)(%d+)$")
        if maker then
            prefix = "d_"
        else
            maker, digits = code:match("^h_(%a+)(%d+)$")
            if maker then
                prefix = "h_"
            else
                prefix, maker, digits = "", code:match("^(%a+)(%d+)$")
            end
        end
    end
    if not maker then
        return {}
    end
    maker = maker:lower()
    local serial = tonumber(digits) or 0
    local seen, out = {}, {}
    local function put(id)
        if id and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    local pads = { 5, 4, 3 }
    for _, pad in ipairs(pads) do
        local body = string.format("%s%0" .. pad .. "d", maker, serial)
        -- For the widest padding, sweep all common prefixes; for shorter
        -- paddings keep the input's own prefix to stay close to the source.
        local plist = { prefix }
        if pad == 5 then
            plist = { "", "1", "d_", "h_" }
        end
        for _, p in ipairs(plist) do
            put(p .. body)
        end
    end
    return out
end

-- Look up a 番号 directly via ContentPageData by probing candidate digital
-- ids in priority order. Returns the normalized detail or nil.
function _M.get_by_code(code)
    if not code or code == "" then
        return nil
    end
    local normalized = tostring(code):gsub("%s+", ""):gsub("-", "")
    if normalized == "" then
        return nil
    end
    local cands = candidate_ids(normalized)
    for _, cid in ipairs(cands) do
        local detail = _M.get(cid)
        if detail then
            return detail
        end
    end
    return nil
end

return _M