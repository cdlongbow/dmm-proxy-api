# DMM Proxy API

基于 OpenResty (nginx + lua) 实现的 DMM 资源代理，通过日本节点（TUN）绕过 DMM 的地区封锁 / 403，为客户端提供封面、剧照和预告片的直链访问与视频流式转发。

- Base URL: `http://{host}:{DMM_PROXY_PORT}`（默认 `8080`）
- 鉴权方式: `Authorization: Bearer <token>`。token 可为 **主 token**（`DMM_AUTH_TOKEN`）或 **session token**（`/api/session` 签发，短时效、绑定客户端 IP）。浏览器前端**只用 session token**，主 token 永不下发前端；但所有 `/api/*` 接口两者都接受。
- 默认 `DMM_PROXY_PORT=80`、`DMM_PROXY_SSL_PORT=443`，详见 `.env`

---

## 防护开关（`DMM_API_PROTECT`）

`DMM_API_PROTECT` 控制**代理侧**的防滥用保护（签名 URL、限流、IP 白名单），取值：`on`/`true`/`1`/`yes`（开启）或 `off`/空（关闭）。

> 注意：**`/api/*` 接口始终需要 `Authorization: Bearer <token>`**（无论 `DMM_API_PROTECT` 是 `on` 还是 `off`）。`/proxy/*` **不需要 token**；该开关只控制 `/proxy/*` 是否需要签名、限流与 IP 白名单。

| 开关 | `/api/*` | `/proxy/*` |
|------|----------|------------|
| **on**（默认，推荐生产） | 需要 `Authorization: Bearer <token>` | **无需 token**，需 `DMM_SIGN_TTL`（默认 220s）内有效的**签名 URL** + 限流 + 可选 IP 白名单 |
| **off** | 需要 `Authorization: Bearer <token>`，返回的 `proxy.*` 为普通路径 | **无需 token**、不要求签名、无限流/IP 白名单 |

辅助配置：

| 环境变量 | 说明 | 默认 |
|----------|------|------|
| `DMM_AUTH_TOKEN` | API 主 token，同时作为签名 HMAC 密钥 | - |
| `DMM_SIGN_TTL` | 签名 URL 有效秒数 | `220` |
| `DMM_RATE_PER_MIN` | 单 IP 每分钟请求上限（on 时生效） | `240` |
| `DMM_ALLOW_IPS` | 可选 IP 白名单，逗号分隔 IP/CIDR，空=放行全部 | 空 |
| `DMM_FRONTEND_TTL` | session token 有效秒数（`/api/session` 签发，绑定客户端 IP） | `900` |
| `DMM_CACHE_TOTAL` | 全部查询结果缓存的共享内存总预算（MB），启动时按固定比例分配：findplay 2%、ranking 5%、search 5%、trailer 5%、todayupdate 5%、film_sample 20%、magnet 取剩余（58%）。非法值或 <30 回退 `250` | `250` |

### 签名 URL 说明（on 时）

`/api/cover`、`/api/film_sample` 和 `/api/trailer` 返回的 `proxy.*` 字段是短时效签名链接：
```
/proxy/video/{path}?sig=<hex-hmac>&exp=<unix_ts>
```
- `exp` = 签发时间 + `DMM_SIGN_TTL`，过期即 403
- `sig` = `HMAC-SHA256(DMM_AUTH_TOKEN, uri .. ":" .. exp)`
- 用于播放器/客户端直接拉流，可跨 IP 使用但仅在 `DMM_SIGN_TTL` 内有效

### 通用说明

所有 `/api/*` 接口**始终**需要携带请求头（无论 `DMM_API_PROTECT` 是 on 还是 off）：

```
Authorization: Bearer <主 token 或 session token>
```

- **主 token** = `DMM_AUTH_TOKEN`（身份/脚本/服务端调用）。
- **session token** = `GET /api/session` 签发（见第 1.1 节），**绑定客户端 IP + `DMM_FRONTEND_TTL` 内有效**，供浏览器前端使用；即使从 DevTools 抄走也无法长期复用。
- 校验顺序：token 等于主 token 直接放行；否则按 session token 验签（`HMAC(secret, "frontend:"..ip..":"..exp)`，须未过期且 IP 一致）。

| 状态码 | 含义 |
|--------|------|
| `200` | 成功 |
| `401` | 缺少 Authorization 头（始终生效，`/api/*`） |
| `403` | token 无效 / 已过期 / IP 不匹配；或 on 时签名无效/过期/IP 不在白名单 |
| `429` | 超出单 IP 限流（on 时） |
| `404` | 对应 DMM 资源未找到 |
| `400` | 参数缺失 |

`id`（番号）支持形如 `ABP-477`、`ssis497` 的输入，服务端内部会将其转换为多个候选的 DMM CID（如 `abp00477`、`abp0477`、`1abp477` 等）逐一探测，命中第一个可用项。

---

## 1. 健康检查

```
GET /health
```

无需鉴权。返回 `ok`。

---

## 1.1 前端会话令牌（Session Token）

```
GET /api/session
```

无需鉴权。签发一个**短时效、绑定客户端 IP** 的会话 token，供浏览器前端调用 `/api/*` 使用。前端**永远不会拿到 `DMM_AUTH_TOKEN`**（`/config.js` 注入主 token 的方案已移除，防止密钥泄露）。

**响应 `200`**

```json
{
  "token": "<64位hex-hmac>.<exp>",
  "exp": 1788691100,
  "ttl": 900
}
```

| 响应字段 | 说明 |
|----------|------|
| `token` | 会话 token，形如 `<hex-hmac>.<exp>`，`HMAC-SHA256(secret, "frontend:" .. ip .. ":" .. exp)` |
| `exp` | 过期 Unix 时间戳（签发时刻 + `DMM_FRONTEND_TTL`） |
| `ttl` | 有效秒数（默认 `900` = 15 分钟） |

| 响应头 | 值 |
|--------|-----|
| `Content-Type` | `application/json; charset=utf-8` |
| `Cache-Control` | `no-store` |

**要点**

- **IP 绑定**：token 绑定"客户端 IP"。后端按 `CF-Connecting-IP` → `X-Real-IP` → `remote_addr` 的优先级取 IP（CDN/反向代理后仍取到稳定的真实客户端 IP），签发与校验用同一套逻辑，IP 不一致或已过期即判无效（`403`）。
- **主 token 不受影响**：`/api/*` 仍同时接受 `Authorization: Bearer <DMM_AUTH_TOKEN>` 主 token 或 session token，两者混用均可。
- **过期自动刷新**：前端在 token 将过期（剩余 <30s）或收到 `401/403` 时自动调用 `/api/session` 重新签发并重试一次。

> 浏览器前端加载逻辑：`refreshSession()` 懒签发作一次，之后调用 `/api/*` 统一携带 `Authorization: Bearer <session token>`。

---

## 2. 封面 / 剧照信息

```
GET /api/cover/:id
```

根据番号返回封面（2K 高清优先）、小图与全部剧照的直链以及本机代理路径。

**示例请求**

```http
GET http://localhost:8080/api/cover/SONE-128
Authorization: Bearer <token>
```

**示例响应 `200`**

```json
{
  "id": "SONE-128",
  "cid": "sone00128",
  "cover": {
    "large": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/sone00128/sone00128pl.jpg",
    "hd": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/sone00128/sone00128pl.jpg",
    "sd": "https://pics.dmm.co.jp/digital/video/sone00128/sone00128pl.jpg",
    "small": "https://pics.dmm.co.jp/digital/video/sone00128/sone00128pt.jpg",
    "proxy": {
      "hd": "/proxy/aws/digital/video/sone00128/sone00128pl.jpg",
      "sd": "/proxy/pics/digital/video/sone00128/sone00128pl.jpg",
      "small": "/proxy/pics/digital/video/sone00128/sone00128pt.jpg"
    }
  }
}
```

**响应字段**

| 字段 | 说明 |
|------|------|
| `id` | 用户传入的番号（大写） |
| `cid` | 探测命中的 DMM 内容 ID |
| `cover.large` | 最优封面（2K 高清优先，其次标准） |
| `cover.hd` | 2K 高清封面（`awsimgsrc.dmm.co.jp`），可能不存在 |
| `cover.sd` | 标准封面（`pics.dmm.co.jp`） |
| `cover.small` | 小图 `pt.jpg` |
| `cover.proxy.hd/sd/small` | 经本机代理的路径（客户端据此避开 DMM 地区封锁） |

失败返回 `404`：

```json
{ "error": "not_found", "message": "Cover not found for id: ABP-477" }
```

---

## 3. 剧照（Film Sample）信息

```
GET /api/film_sample/:id
```

根据番号返回全部剧照（标准图 + 高清图）的直链与本机代理路径。

> 通过 DMM 官方公开的 **FANZA TV GraphQL API**（`https://api.tv.dmm.co.jp/graphql`）一次性获取全部剧照，无需逐个探测，响应快且可拿到 `2K` 高清大图（`awsimgsrc.dmm.co.jp/dig_white`）。

> **缓存**：**成功结果**按 CID 缓存 **8 小时**（`lua_shared_dict film_sample_cache`，容量由 `DMM_CACHE_TOTAL` 分配，占 20%）；404（确认无剧照）**不缓存**，避免把一时的上游抖动固化。容器重启后清空。

**示例请求**

```http
GET http://localhost:8080/api/film_sample/SSIS-497
Authorization: Bearer <token>
```

**示例响应 `200`**

```json
{
  "id": "SSIS-497",
  "cid": "ssis00497",
  "total": 10,
  "samples": [
    {
      "index": 1,
      "small": "https://awsimgsrc.dmm.co.jp/dig_white/digital/video/ssis00497/ssis00497-1.jpg",
      "large": "https://awsimgsrc.dmm.co.jp/dig_white/digital/video/ssis00497/ssis00497jp-1.jpg",
      "proxy": "/proxy/sample/digital/video/ssis00497/ssis00497jp-1.jpg"
    },
    {
      "index": 2,
      "small": "https://awsimgsrc.dmm.co.jp/dig_white/digital/video/ssis00497/ssis00497-2.jpg",
      "large": "https://awsimgsrc.dmm.co.jp/dig_white/digital/video/ssis00497/ssis00497jp-2.jpg",
      "proxy": "/proxy/sample/digital/video/ssis00497/ssis00497jp-2.jpg"
    }
  ]
}
```

**响应字段**

| 字段 | 说明 |
|------|------|
| `id` | 用户传入的番号（大写） |
| `cid` | 探测命中的 DMM 内容 ID |
| `total` | 剧照总数 |
| `samples[].index` | 剧照序号（从 1 开始） |
| `samples[].small` | 标准剧照直链（`awsimgsrc.dmm.co.jp/dig_white`） |
| `samples[].large` | 高清剧照直链（`jp-N.jpg`） |
| `samples[].proxy` | 本机代理路径（推荐使用，可避开地区封锁） |

失败返回 `404`：

```json
{ "error": "not_found", "message": "No sample images found for id: ABP-477" }
```

---

## 4. 预告片信息

```
GET /api/trailer/:id
```

根据番号返回预告片的多个码率直链与本机代理路径。仅返回探测存在的码率；探测顺序从最高档开始，且只探测最高三档（`hhb`/1080p、`hmb`/720p、`mhb`/480p），更低的 `dmb`/`dm`/`sm` 档不再返回。

**示例请求**

```http
GET http://localhost:8080/api/trailer/SSIS-497
Authorization: Bearer <token>
```

**示例响应 `200`**

```json
{
  "id": "SSIS-497",
  "cid": "ssis00497",
  "trailers": [
    { "quality": "hmb", "bitrate": 3000, "url": "https://cc3001.dmm.co.jp/litevideo/freepv/s/ssi/ssis00497/ssis00497_hmb_w.mp4", "proxy": "/proxy/video/litevideo/freepv/s/ssi/ssis00497/ssis00497_hmb_w.mp4" },
    { "quality": "mhb", "bitrate": 2500, "url": "https://cc3001.dmm.co.jp/litevideo/freepv/s/ssi/ssis00497/ssis00497_mhb_w.mp4", "proxy": "/proxy/video/litevideo/freepv/s/ssi/ssis00497/ssis00497_mhb_w.mp4" }
  ]
}
```

**响应字段**

| 字段 | 说明 |
|------|------|
| `id` | 用户传入的番号（大写） |
| `cid` | 探测命中的 DMM 内容 ID |
| `trailers[].quality` | 码率档位：`hhb`(5000k/1080p) / `hmb`(3000k/720p) / `mhb`(2500k/480p) |
| `trailers[].bitrate` | 码率（kbps） |
| `trailers[].url` | DMM 预告片直链 |
| `trailers[].proxy` | 本机代理路径（推荐使用，可避开地区封锁） |

> 极少数片子没有预告片，返回 `404`：
> ```json
> { "error": "not_found", "message": "Trailer not found for id: SONE-128" }
> ```

---

## 4.1 预告片直链（多源并发 + 缓存）

```
GET /api/trailer_direct/:id
```

按番号返回一个**可直接播放的预告片直链**（来自第三方源，非本机代理）。

**鉴权**：请求**始终需要** `Authorization: Bearer <token>`（与其它 `/api/*` 一致）。

**输入**：`:id` 为番号（如 `SNOS-213`）。服务端会**规范化**为全大写并去空白后作为缓存键与查询关键词；**不做格式校验**，任意字符串都接受，任何源都查不到才返回 `404`。

**流程**：

1. 先查内存缓存（`trailer_cache`，`lua_shared_dict`，键为 `td:<规范化番号>`），命中直接返回。
2. 未命中则**并发请求三个源**（AVWikiDB / DMM FANZA / JAVDatabase），谁先成功用谁的；单路超时 5 秒。
3. 命中后写入缓存（URL 与 source 各 7 天 TTL），并附带 `source` 字段。

> 注意：
> - 缓存为纯内存（`lua_shared_dict`），**容器重启会清空**，但重查一次即重新缓存 7 天。
> - **AVWikiDB 源**位于 Cloudflare 反爬（"Just a moment..." JS 挑战）之后，会拒绝数据中心/VPS IP，通常返回 `403`（详见代码注释）。正常主要由 **DMM FANZA** 与 **JAVDatabase** 两路提供结果。

**示例请求**

```http
GET http://localhost:8080/api/trailer_direct/SNOS-213
Authorization: Bearer <token>
```

**示例响应 `200`**

```json
{
  "code": "SNOS-213",
  "trailer": "https://cc3001.dmm.co.jp/pv/EDR4RCcjis11tGx2qP81rb6ZHD-bXv-mJM9oT8ultnH13mhCLb2MriUh1-SGjA/snos00213mhb.mp4",
  "source": "javdatabase"
}
```

**响应字段**

| 字段 | 说明 |
|------|------|
| `code` | 规范化的番号（大写、去空格） |
| `trailer` | 可直连播放的预告片 URL（来自第三方源） |
| `source` | 命中的来源：`avwikidb` / `dmm` / `javdatabase` |

**错误码**

| 状态 | 场景 |
|------|------|
| `400` | 缺少番号 |
| `404` | 三个源均未找到预告片 |

`400` 示例（未带番号）：

```json
{ "error": "bad_request", "message": "Missing code" }
```

`404` 示例：

```json
{ "error": "not_found", "message": "No trailer found for code: ZZZ-99999" }
```

---

## 4.2 每日更新列表

```
GET /api/todayupdate
```

获取指定日期的 DMM 作品更新列表。不传 `date` 参数时默认获取**今日**（JST 时区）的数据。

通过 DMM FANZA GraphQL API（`https://api.video.dmm.co.jp/graphql`）查询按 `deliveryStartDate` 排序的最新作品。

> **缓存**：结果按 `(date, limit, offset)` 缓存 **8 小时**（`lua_shared_dict todayupdate_cache`，容量由 `DMM_CACHE_TOTAL` 分配，占 5%）。容器重启后清空。

**请求参数**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `date` | string | 否 | 日期，格式 `YYYY-MM-DD`，默认今日（JST） |
| `limit` | int | 否 | 每页数量，仅允许 `30` / `60` / `120`，默认 `30` |
| `offset` | int | 否 | 偏移量，用于分页，默认 `0` |

**示例请求**

```http
# 获取今日更新
GET http://localhost:8080/api/todayupdate
Authorization: Bearer <token>

# 获取指定日期，每页 120 条，第二页
GET http://localhost:8080/api/todayupdate?date=2026-09-03&limit=120&offset=120
Authorization: Bearer <token>
```

**示例响应 `200`**

```json
{
  "date": "2026-09-03",
  "total": 99,
  "limit": 30,
  "offset": 0,
  "hasNext": true,
  "count": 30,
  "works": [
    {
      "id": "1fns00241",
      "title": "雪国育ちの色白スレンダーBODYを性感開発する初イキッ3本番！ 柏木雫",
      "cover": {
        "medium": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/1fns00241/1fns00241ps.jpg",
        "large": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/1fns00241/1fns00241pl.jpg"
      },
      "deliveryStartAt": "2026-09-03T00:00:59+09:00",
      "actresses": [{ "id": "1112624", "name": "柏木雫" }],
      "maker": { "id": "40488", "name": "FALENO" },
      "isOnSale": true,
      "review": { "average": 5, "count": 1 },
      "releaseStatus": "LATEST_RELEASE",
      "price": {
        "productId": "1fns00241dl",
        "price": 2480,
        "discountPrice": null
      },
      "hasMultiplePrices": true,
      "sampleMovie": {
        "mp4": "https://cc3001.dmm.co.jp/pv/.../1fns002414k.mp4",
        "hls": "https://cc3001.dmm.co.jp/pv/.../playlist.m3u8"
      },
      "sampleImages": [
        { "number": 1, "largeUrl": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/1fns00241/1fns00241jp-1.jpg" },
        { "number": 2, "largeUrl": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/1fns00241/1fns00241jp-2.jpg" }
      ]
    }
  ]
}
```

**响应字段**

| 字段 | 说明 |
|------|------|
| `date` | 查询的日期 |
| `total` | 该日期的总作品数 |
| `limit` | 当前分页大小 |
| `offset` | 当前偏移量 |
| `hasNext` | 是否有下一页 |
| `count` | 当前返回的作品数 |
| `works[].id` | DMM 产品 ID |
| `works[].title` | 作品标题 |
| `works[].cover.medium` | 中等尺寸封面直链 |
| `works[].cover.large` | 大尺寸封面直链 |
| `works[].deliveryStartAt` | 发布时间（ISO 8601，含时区） |
| `works[].actresses` | 演员列表 `[{id, name}]` |
| `works[].maker` | 制作商 `{id, name}` |
| `works[].isOnSale` | 是否在售 |
| `works[].review` | 评分 `{average, count}` |
| `works[].releaseStatus` | 发布状态（如 `LATEST_RELEASE`） |
| `works[].price` | 价格信息 `{productId, price, discountPrice}`，可能不存在 |
| `works[].hasMultiplePrices` | 是否有多种价格版本 |
| `works[].sampleMovie` | 预告片链接 `{mp4, hls}`，可能不存在 |
| `works[].sampleImages` | 剧照列表 `[{number, largeUrl}]`，可能不存在 |

**错误码**

| 状态码 | 场景 |
|--------|------|
| `502` | 上游 DMM GraphQL API 请求失败 |
| `401` | 缺少 Authorization 头 |
| `403` | token 无效 / 已过期 / IP 不匹配 |

---

## 4.3 热门排行榜

```
GET /api/ranking
```

获取 DMM 热门作品排行榜，按销售排名分数（`SALES_RANK_SCORE`）排序。默认返回 30 条。

通过 DMM FANZA GraphQL API 查询，与每日更新使用相同的上游接口但排序方式不同。

> **缓存**：结果按 `(limit, offset)` 缓存 **8 小时**（`lua_shared_dict ranking_cache`，容量由 `DMM_CACHE_TOTAL` 分配，占 5%）。`offset >= 100` 取的是上游快路径且仍会缓存。容器重启后清空。

**请求参数**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `limit` | int | 否 | 每页数量，仅允许 `30` / `60` / `120`，默认 `30` |
| `offset` | int | 否 | 偏移量，用于分页，默认 `0` |

**示例请求**

```http
# 默认热门 Top 30
GET http://localhost:8080/api/ranking
Authorization: Bearer <token>

# 第二页（第 31-60 名）
GET http://localhost:8080/api/ranking?limit=30&offset=30
Authorization: Bearer <token>

# 每页 120 条
GET http://localhost:8080/api/ranking?limit=120
Authorization: Bearer <token>
```

**示例响应 `200`**

```json
{
  "total": 478397,
  "limit": 30,
  "offset": 0,
  "hasNext": true,
  "count": 30,
  "works": [
    {
      "rank": 1,
      "id": "sqte00683",
      "title": "いつでも使えるオナホ後輩 花守夏歩",
      "cover": {
        "medium": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/sqte00683/sqte00683ps.jpg",
        "large": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/sqte00683/sqte00683pl.jpg"
      },
      "deliveryStartAt": "2026-05-16T00:00:00+09:00",
      "actresses": [{ "id": "1099813", "name": "花守夏歩" }],
      "maker": { "id": "45414", "name": "S-Cute" },
      "isOnSale": true,
      "review": { "average": 4.94, "count": 32 },
      "releaseStatus": "SEMI_NEW_RELEASE",
      "bookmarkCount": 31336,
      "price": {
        "productId": "sqte00683",
        "price": 580,
        "discountPrice": 290
      },
      "hasMultiplePrices": true,
      "sampleMovie": {
        "mp4": "https://cc3001.dmm.co.jp/pv/.../sqte00683hhb.mp4",
        "hls": "https://cc3001.dmm.co.jp/pv/.../playlist.m3u8"
      },
      "sampleImages": [
        { "number": 1, "largeUrl": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/sqte00683/sqte00683jp-1.jpg" }
      ]
    }
  ]
}
```

**响应字段**

| 字段 | 说明 |
|------|------|
| `total` | 总作品数（排行榜全量） |
| `limit` | 当前分页大小 |
| `offset` | 当前偏移量 |
| `hasNext` | 是否有下一页 |
| `count` | 当前返回的作品数 |
| `works[].rank` | 排名（从 1 开始，基于 offset + 序号） |
| `works[].id` | DMM 产品 ID |
| `works[].title` | 作品标题 |
| `works[].cover.medium` | 中等尺寸封面直链 |
| `works[].cover.large` | 大尺寸封面直链 |
| `works[].deliveryStartAt` | 发布时间（ISO 8601，含时区） |
| `works[].actresses` | 演员列表 `[{id, name}]` |
| `works[].maker` | 制作商 `{id, name}` |
| `works[].isOnSale` | 是否在售 |
| `works[].review` | 评分 `{average, count}` |
| `works[].releaseStatus` | 发布状态 |
| `works[].bookmarkCount` | 收藏数（人气指标） |
| `works[].price` | 价格信息 `{productId, price, discountPrice}`，可能不存在 |
| `works[].hasMultiplePrices` | 是否有多种价格版本 |
| `works[].sampleMovie` | 预告片链接 `{mp4, hls}`，可能不存在 |
| `works[].sampleImages` | 剧照列表 `[{number, largeUrl}]`，可能不存在 |

**错误码**

| 状态码 | 场景 |
|--------|------|
| `502` | 上游 DMM GraphQL API 请求失败 |
| `401` | 缺少 Authorization 头 |
| `403` | token 无效 / 已过期 / IP 不匹配 |

---

## 4.4 磁力链接聚合

```
GET /api/magnet/:id
```

按番号从三个独立站点聚合磁力链接：**sukebei**（sukebei.nyaa.si）、**javdb**（javdb.com 官方 App JSON API，优先）、**javbus**（javbus.com）。结果按来源分组，客户端可据此区分收藏/排序。


**鉴权**：请求**始终需要** `Authorization: Bearer <token>`（与其它 `/api/*` 一致）。

**输入**：`:id` 为番号（如 `ssni-730`）。服务端会**规范化**为全大写、去空白后作为查询关键词与缓存键，大小写不敏感。

**请求参数**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `s` | string | 否 | 指定来源，取值 `sukebei` / `javdb` / `javbus`，可逗号分隔多个（如 `s=javdb,javbus`）。`s` 为空、缺失或未知时默认返回全部三个来源 |

**流程**

1. 先查内存缓存（`magnet_cache`，`lua_shared_dict`，键为 `mg:<source>:<code>`），命中直接返回。
2. 未命中则**并发请求**三个来源（`ngx.thread`，单路超时 8 秒）。
   - **sukebei**：RSS 搜索页，RSS 只带 infoHash，磁力链接由 infoHash + nyaa 官方 tracker 列表重建。
   - **javdb**：**官方 App JSON API**（`https://jdforrepam.com`，App 专用后端，无 Cloudflare 地区门控、无需登录）：请求带 `jdsignature` 签名头（`<ts>.lpw6vgqzsp.<md5(ts+STR1)>`，`STR1` 为固定常量）与固定 query 参数（`platform=android` 等），先用 `GET /api/v2/search?q=<番号>&limit=10` 定位精确匹配的视频（取 `movie.magnets_count > 0` 的 `id`，如多个精确匹配取磁力数最多者），再 `GET /api/v1/movies/{id}/magnets` 取磁力列表（`cnsub`/`hd` 映射为 `tags`，`size` 字节数、`files_count`、`created_at`）。App API 搜索未命中或请求失败时**回落 javdb.com 网页抓取**（搜索页 → 详情页磁力表格）。
   - **javbus**：搜索页（自带 `existmag=mag` Cookie 开启磁力 → 详情页取 `gid/uc` → ajax 磁力表格）。遇到间歇性年龄验证页会自动重试一次。
3. 任一来源查询失败不影响其它来源：该来源返回 `count: 0` 并附 `error` 说明。

**缓存**：结果按 `(source, code)` 缓存 **6 小时**（`CACHE_TTL=21600`）；容器重启后内存缓存清空，重新查询即回落。命中缓存的来源不再访问上游站点。

**示例请求**

```http
# 全部三个来源
GET http://localhost:8080/api/magnet/ssni-730
Authorization: Bearer <token>

# 只查 javdb
GET http://localhost:8080/api/magnet/SSNI-730?s=javdb
Authorization: Bearer <token>

# 只查 javbus
GET http://localhost:8080/api/magnet/SSNI-730?s=javbus
Authorization: Bearer <token>

# 多来源（逗号分隔）
GET http://localhost:8080/api/magnet/SSNI-730?s=javdb,javbus
Authorization: Bearer <token>
```

**示例响应 `200`**（节选）

```json
{
  "code": "SSNI-730",
  "count": 25,
  "sources": [
    {
      "source": "sukebei",
      "count": 6,
      "magnets": [
        {
          "name": "SSNI-730 ...",
          "magnet": "magnet:?xt=urn:btih:1a2b...&dn=...&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce",
          "info_hash": "1a2b...",
          "size": "1.9 GiB",
          "seeders": 12,
          "leechers": 3,
          "downloads": 108,
          "category": "English Translated",
          "date": 1762843191,
          "url": "https://sukebei.nyaa.si/view/123456",
          "torrent_url": "https://sukebei.nyaa.si/download/123456.torrent"
        }
      ]
    },
    {
      "source": "javdb",
      "count": 14,
      "magnets": [
        {
          "name": "SSNI-730 無修正 中文字幕",
          "magnet": "magnet:?xt=urn:btih:5c6d...&dn=SSNI-730...",
          "info_hash": "5c6d...",
          "size": "3.5 GB",
          "size_bytes": 3758096384,
          "date": "2025-11-11",
          "date_str": "2025-11-11",
          "files": 4,
          "tags": ["中字", "高清"]
        }
      ]
    },
    {
      "source": "javbus",
      "count": 5,
      "magnets": [
        {
          "name": "SSNI-730...",
          "magnet": "magnet:?xt=urn:btih:...",
          "info_hash": "9e8f...",
          "size": "2.4 GB",
          "date": "2025-11-15",
          "url": "https://www.javbus.com/SSNI-730"
        }
      ]
    }
  ]
}
```

**响应字段**

| 字段 | 说明 |
|------|------|
| `code` | 规范化的番号（大写、去空格） |
| `count` | 全部来源磁力总数 |
| `sources[].source` | 来源标识：`sukebei` / `javdb` / `javbus` |
| `sources[].count` | 该来源磁力数 |
| `sources[].error` | 该来源失败原因（如 `javdb: no exact match`）；成功时不存在 |
| `sources[].magnets[].magnet` | 完整 magnet URI |
| `sources[].magnets[].info_hash` | 40 位小写 info hash |
| `sources[].magnets[].name` | 种子标题 |
| `sources[].magnets[].size` | 文件大小（字符串，原始文本，如 `1.9 GiB`） |
| `sources[].magnets[].date` | sukebei 为 pubDate 的 epoch 秒；javdb/javbus 为上传日期字符串 |
| `sources[].magnets[].date_str` | 仅 javdb（App API 路径）：与 `date` 相同，格式化为日期字符串 |
| `sources[].magnets[].files` | 仅 javdb（App API 路径）：文件数 |
| `sources[].magnets[].size_bytes` | 仅 javdb（App API 路径）：字节数（整数） |
| `sources[].magnets[].url` | 来源详情页 URL（javdb 仅网页兜底路径有） |
| `sources[].magnets[].seeders/leechers/downloads` | 仅 sukebei：做种/下载/完成数 |
| `sources[].magnets[].category` | 仅 sukebei：分类 |
| `sources[].magnets[].torrent_url` | 仅 sukebei：`.torrent` 文件直链 |
| `sources[].magnets[].tags` | 仅 javdb：App API 路径由 `cnsub`/`hd` 映射为 `["中字","高清"]`；网页兜底路径为页面原始标签（如 `["字幕"]`） |

**错误码**

| 状态 | 场景 |
|------|------|
| `400` | 缺少番号 |
| `200` | 正常返回；各来源可能 `count: 0` 并带 `error`（单个来源失败不影响整体） |

`400` 示例（未带番号）：

```json
{ "error": "bad_request", "message": "Missing id parameter. Usage: /api/magnet/:id" }
```

> 注：该接口**不返回 404**——只要请求带上番号即为 `200`，每个来源单独报 `error`。

---

## 4.5 播放平台探测

```
GET /api/findplay/:id
```

按番号**并发探测** missav / supjav / jable / 123av 四个在线播放平台中哪些可以播放该番号，返回每个平台的可跳转搜索链接与「可跳转标识」（`playable`），客户端可就地展示「去这个平台看」按钮。

**鉴权**：请求**始终需要** `Authorization: Bearer <token>`（与其它 `/api/*` 一致）。

**输入**：`:id` 为番号（如 `ssni-730`）。服务端会**规范化**为全大写、去空白后作为查询关键词与缓存键，大小写不敏感。

**平台与搜索 URL**

| `platform` | `label` | 跳转/搜索 URL 模板 | 判定依据 |
|------|------|------|------|
| `missav` | MissAV | `https://missav.ai/en/search/{CODE}` | 页面 `class="thumbnail"` 结果卡片 + 番号出现（空结果页只回显查询词，不算命中） |
| `supjav` | SupJAV | `https://supjav.com/?s={CODE}` | WordPress `class="post"` 结果卡片 + 番号出现 |
| `jable` | JableTV | `https://jable.tv/search/{CODE}/` | `class="detail"` 结果卡片 + 番号出现 |
| `123av` | 123AV | `https://123av.com/en/search?keyword={CODE}` | 结果链接命中 `v/{code}`（无番号结果时 123av 会回滚展示无关影片，因此只看番号文本会误判，必须以链接为准） |

URL 一律使用**大写**番号；各站点搜索本身对大小写不敏感。

**流程**

1. 先查内存缓存（`findplay_cache`，`lua_shared_dict`，容量由 `DMM_CACHE_TOTAL` 分配、占 2%，键为 `fp:<platform>:<code>`），命中直接返回。
2. 未命中则**并发**请求四个平台（`ngx.thread`，单路超时 8 秒）的搜索页。
3. 平台页面 `HTTP 200` 且检测到「结果卡片 + 番号」才算 `playable: true`；页面 `200` 但无结果 → `playable: false`。请求被拦截（403/超时）→ `verified: false`（既非"可播放"也非"确认无片源"，而是**探测失败**）。
4. 镜像域故障自动轮换：missav 依次 `missav.ai → missav.ws → missav123.com → missav.live`；jable 依次 `jable.tv → fs1.app`。全部未拿到 `200` 时自动**整轮重试一次**（间隔 0.5s）再判失败。

**缓存**：
- 只有**真正拿到页面判定**（`verified: true`）的结果才会被缓存：`playable: true` 缓存 **6 小时**，`playable: false` 缓存 **1 小时**（让新上架更快出现）。
- **探测失败（403/超时等）不缓存**——避免把一次临时反爬封锁误当成"该平台确认无片源"定格 1 小时；客户端可稍后重试。
- 容器重启后内存缓存清空。

**示例请求**

```http
GET http://localhost:8080/api/findplay/waaa-321
Authorization: Bearer <token>
```

**示例响应 `200`**

```json
{
  "code": "WAAA-321",
  "count": 4,
  "results": [
    { "platform": "missav", "label": "MissAV", "url": "https://missav.ai/en/search/WAAA-321", "playable": true, "verified": true },
    { "platform": "supjav", "label": "SupJAV", "url": "https://supjav.com/?s=WAAA-321", "playable": true, "verified": true },
    { "platform": "jable",  "label": "JableTV", "url": "https://jable.tv/search/WAAA-321/", "playable": true, "verified": true },
    { "platform": "123av",  "label": "123AV", "url": "https://123av.com/en/search?keyword=WAAA-321", "playable": true, "verified": true }
  ]
}
```

**响应字段**

| 字段 | 说明 |
|------|------|
| `code` | 规范化的番号（大写、去空格） |
| `count` | `playable: true` 的平台数 |
| `results[].platform` | 平台标识：`missav` / `supjav` / `jable` / `123av` |
| `results[].label` | 平台显示名 |
| `results[].url` | 可跳转的搜索链接（直接打开即该番号的搜索结果） |
| `results[].playable` | **可跳转标识**：`true` = 该平台有该番号的片源，可跳转播放；`false` = 无结果或探测失败 |
| `results[].verified` | 判定可信度：`true` = 页面真实加载并给出判定（无结果/有结果均可信）；`false` = 探测被拦截/失败（403、超时等），`playable: false` 仅表示"本次未能验证"，不代表该平台无片源 |
| `results[].error` | 仅 `playable: false` 时存在，失败原因（如 `jable: HTTP 403` = 探测失败、`missav: no result` = 确认无片源） |

> 全部平台都被反爬拦截（`verified: false`）时，返回 `200` 且 `count: 0`——此时各平台的 `error` 均含 `HTTP 403` 等状态码，**应视作"探测失败，可稍后重试"，而非"确认无片源"**；失败结果不会写入缓存。

**错误码**

| 状态 | 场景 |
|------|------|
| `400` | 缺少番号 |
| `200` | 正常返回；各平台单独报 `playable` 与 `error`，不返回 404 |

`400` 示例（未带番号）：

```json
{ "error": "bad_request", "message": "Missing id parameter. Usage: /api/findplay/:id" }
```

---

## 4.6 FANZA 番号搜索

```
GET /api/search/:id
```

按番号搜索 DMM 数字版作品，供前端「番号搜索」按钮使用。**不依赖 affiliate appid / `DMM_API_ID`**——番号直接展开为候选数字版 content id（`maker` + 补零序号，含 `1`/`d_`/`h_` 前缀组合），逐一带 `video.dmm.co.jp` 的 GraphQL `ContentPageData` 探测（见 `lua/api_content.lua`），首个命中即返回**完整详情**，无需第二次富化请求。**MGS 番号不依赖 DMM**：命中 MGS 前缀的番号（如 `ABF-365`）直接走 mgstage.com 详情页抓取（`source="mgs"`），见下方流程第 2 步。

**鉴权**：请求**始终需要** `Authorization: Bearer <token>`（与其它 `/api/*` 一致）。

**输入**：`:id` 为番号（如 `abp-477`、`IPX-685`）。**大小写不敏感、忽略连字符与空白**——`/api/search/abp-477` 等价于 `/api/search/ABP-477`。

**参数**

| 参数 | 说明 |
|------|------|
| `offset` | 保留字段，恒为 0（精确番号命中通常只有一部，`hasNext` 恒 `false`） |

**流程**

1. 先查内存缓存（`search_cache`，`lua_shared_dict`，容量由 `DMM_CACHE_TOTAL` 分配、占 5%，键为 `sr:<CODE>:<offset>`），命中直接返回（TTL 6 小时）。
2. **MGS 分支（`source="mgs"`）**：番号统一大写 + 去空白后，若以 MGS 前缀开头（官方系统码如 `200GANA` / `300MIUM`，字母码如 `ABF` / `SIRO` / `MAAN`，**前缀后紧跟数字**才算命中，避免 `GALS-001` 因 `GAL`+`S` 而误判；完整前缀表见 `lua/api_mgs.lua`）→ **跳过 DMM 与 javbus**，直接抓 `www.mgstage.com/product/product_detail/<前缀>-<序号>/`（`Cookie: adc=1` 年龄门；DMM 不收录这些作品）。DNS 抖动会重试 3 次。
3. 非 MGS 番号展开为候选数字版 id：`<maker>` + `%05d` / `%04d` / `%03d`，并叠加 `1`、`d_`、`h_` 前缀（去重后按优先序探测，通常第 1 个即命中）。仅纯 `<字母><数字>` 形态的候选会被再次补零展开——带 `d_` / `h_` 前缀的候选按原样探测，避免把 `d_smgn00124` 错拆成无关的 `d0124` 造成误命中。
4. 对每个候选调 `ContentPageData`（`isAv=true`）；命中后**校验一致性**：返回的 `id` 必须等于发出去的候选 cid，且 `makerContentId` 的 maker 与序号必须匹配请求番号（容忍 `1` / `d_` / `h_` 前缀）。校验失败的候选视为查询错误（如 `d0124`=HANY-D—029 原初是 `SMGN-124` 的错误命中），跳过。
5. **素人（amateur）分支**：a) 若某个 AV 候选命中但 `floor=AMATEUR`，改以 `isAmateur=true`（`isAv=false`）在素人命名空间重查同一 cid，以补齐 `amateurActress` 等素人专属字段；b) 若整个 AV 候选全部未命中 / 全部失配，则以去掉连字符的原始番号（如 `SMGN-124` → id `smgn124`）在素人命名空间直查。素人命中的 `floor="AMATEUR"`，`cover` 图源为 `pics_dig/digital/amateur/<id>/`。
6. **javbus 兜底（`source="javbus"`）**：查询 javbus 第三方 JSON API（`https://javbus-api.131433.xyz/api/movies/<番号>`，社区维护的 javbus 数据接口，返回结构化 JSON 而非 HTML），命中后解析为与前端兼容的 work 对象（旧实现直接抓 javbus.com HTML，因反爬 + 地区门控，且 javbus 自身 `/pics/` 图片会被浏览器 CORS 拦截而弃用）。javbus 来源的字段形如：`id`（=番号）、`title`、`director`（缺失 → `"未知"`）、`maker`（製作商）、`label`（發行商，数组）、`series`（系列，数组）、`genres` / `actresses`（纯字符串数组）、`sampleImages`（`smallUrl`/`largeUrl` 均取外部 CDN，如 mgstage，避免 CORS）、`cover`（javbus 图源）、`webUrl`（javbus 详情页原链）；无 `description` / `price` / `review` / `directors` 数组等 DMM 专属字段。前端按 `source` 区分渲染。
7. 两者皆无结果 → `works` 为空（`200`）。
8. 详情结果在 `search_cache` 以 `gc:<cid>`（AV）或 `gc:a:<cid>`（素人）键缓存（TTL 7 小时），同一数字 id 翻页/重复搜索不再请求。

**示例请求**

```http
GET http://localhost:8080/api/search/ipx-685
Authorization: Bearer <token>
```

**示例响应 `200`**

```json
{
  "keyword": "IPX-685",
  "source": "graphql",
  "total": 1,
  "count": 1,
  "hits": 1,
  "limit": 1,
  "offset": 0,
  "hasNext": false,
  "works": [
    {
      "id": "ipx00685",
      "makerContentId": "IPX-685",
      "title": "微笑みお姉さんが優しい口調で強●ザーメン強奪 エロギャップ痴女エステ 栗山莉緒",
      "floor": "AV",
      "duration": { "seconds": 7440, "minutes": 124 },
      "description": "...",
      "cover": { "medium": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/ipx00685/...", "large": "..." },
      "deliveryStartAt": "2023-04-06T00:00:00Z",
      "makerReleasedAt": "2023-04-06T00:00:00Z",
      "actresses": [{ "id": "1126056", "name": "栗山莉緒" }],
      "directors": [{ "name": "..." }],
      "maker": { "id": "7808", "name": "アイデアポケット" },
      "label": [{ "id": "3474", "name": "IDEA POCKET" }],
      "genres": [{ "id": "...", "name": "ギリモザ" }],
      "relatedTags": [{ "id": "...", "name": "微笑みお姉さん" }],
      "review": { "average": 4.12, "count": 17 },
      "price": { "price": 300, "listPrice": 300, "salePrice": 300 },
      "playableDevices": [{ "device": "PLAY_DEVICE_PC", "name": "パソコン" }],
      "sampleImages": [{ "number": 1, "smallUrl": "...", "largeUrl": "..." }],
      "sample2DMovie": { "hlsMovieUrl": "...", "highestMovieUrl": "..." }
    }
  ]
}
```

> 候选探测基于 DMM 数字版 id 规律（`maker + 5 位补零序号` 最常见）。对不遵守该规律的少量老作品（如 REBD 系列 ID 为 `h_346rebd1061` 而非 `rebd01061`）会在 javbus 兜底命中；若 javbus 亦无收录才返回空 `works`。

**javbus 兜底示例响应 `200`（`source="javbus"`）**

```json
{
  "keyword": "REBD-1061",
  "source": "javbus",
  "total": 1,
  "count": 1,
  "hits": 1,
  "limit": 1,
  "offset": 0,
  "hasNext": false,
  "works": [
    {
      "id": "REBD-1061",
      "makerContentId": "REBD-1061",
      "title": "REBD-1061 Sora 空色のファーストノート・小松空",
      "floor": "javbus",
      "duration": { "seconds": 4800, "minutes": 80 },
      "cover": { "medium": "https://www.javbus.com/pics/cover/chz4_b.jpg", "large": "https://www.javbus.com/pics/cover/chz4_b.jpg" },
      "deliveryStartDate": "2026-08-27",
      "makerReleasedAt": "2026-08-27",
      "director": "沢村力",
      "series": ["Sora（小松空）"],
      "maker": "REbecca",
      "label": ["REbecca"],
      "genres": ["高", "紹介影片", "性感的", "高畫質", "巨乳", "單體作品"],
      "actresses": ["小松空"],
      "sampleImages": [{ "number": 1, "smallUrl": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/h_346rebd01061/h_346rebd01061jp-1.jpg", "largeUrl": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/h_346rebd01061/h_346rebd01061jp-1.jpg" }],
      "webUrl": "https://www.javbus.com/REBD-1061"
    }
  ]
}
```

**MGS 示例响应 `200`（`source="mgs"`，番号命中 MGS 前缀时走 mgstage.com）**

```json
{
  "keyword": "ABF-365",
  "source": "mgs",
  "total": 1,
  "count": 1,
  "hits": 1,
  "limit": 1,
  "offset": 0,
  "hasNext": false,
  "works": [
    {
      "id": "ABF-365",
      "makerContentId": "ABF-365",
      "title": "リミットブレイクSEX 絶対的美少女の殻をブチ破るドM覚醒性交 VOL.13 釈アリス",
      "floor": "mgs",
      "duration": { "seconds": 8100, "minutes": 135 },
      "cover": { "medium": "https://image.mgstage.com/images/prestige/abf/365/pb_e_abf-365.jpg", "large": "https://image.mgstage.com/images/prestige/abf/365/pb_e_abf-365.jpg" },
      "deliveryStartDate": "2026/07/02",
      "makerReleasedAt": "2026/07/17",
      "salesDate": "2026/07/17",
      "description": "プレステージ専属女優『釈 アリス』が拘束×玩具責めで気が狂う程のイキ地獄を味わう。…",
      "director": "未知",
      "series": ["リミットブレイクSEX"],
      "maker": "プレステージ",
      "label": ["ABSOLUTELY FANTASIA"],
      "genres": ["フルハイビジョン(FHD)", "単体作品", "長身", "パイパン", "オモチャ", "顔射"],
      "actresses": ["釈アリス"],
      "review": { "average": 4.4, "count": 16, "price": 2430 },
      "mgs": { "average": 4.4, "count": 16, "price": 2430 },
      "price": { "price": 2430, "listPrice": 2430, "salePrice": 2430 },
      "sampleImages": [{ "number": 1, "smallUrl": "https://image.mgstage.com/images/prestige/abf/365/cap_e_0_abf-365.jpg", "largeUrl": "https://image.mgstage.com/images/prestige/abf/365/cap_e_0_abf-365.jpg" }],
      "webUrl": "https://www.mgstage.com/product/product_detail/ABF-365/"
    }
  ]
}
```

**素人示例响应 `200`（`source="graphql"`，`floor="AMATEUR"`）**

```json
{
  "keyword": "SMGN-124",
  "source": "graphql",
  "total": 1,
  "count": 1,
  "hits": 1,
  "limit": 1,
  "offset": 0,
  "hasNext": false,
  "works": [
    {
      "id": "smgn124",
      "makerContentId": "SMGN-124",
      "title": "ひな＆みく",
      "floor": "AMATEUR",
      "duration": { "seconds": 2299, "minutes": 38 },
      "cover": { "medium": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/amateur/smgn124/smgn124jp.jpg", "large": "" },
      "deliveryStartAt": "2026-09-02T15:00:00Z",
      "deliveryStartDate": "2026-09-02T15:00:00Z",
      "actresses": [{ "id": "smgn124", "name": "ひな＆みく", "imageUrl": "https://awsimgsrc.dmm.co.jp/pics_dig/digital/amateur/smgn124/smgn124jp.jpg" }],
      "maker": { "id": "312269", "name": "素人ムクムク-ゲノム-" },
      "label": [{ "id": "2067646", "name": "素人ムクムク-ゲノム-" }],
      "genres": [{ "id": "4005", "name": "乱交" }, { "id": "1031", "name": "痴女" }],
      "review": { "average": 0, "count": 0 },
      "price": { "price": 1280, "listPrice": 1280, "salePrice": 0 }
    }
  ]
}
```

**响应字段**

| 字段 | 说明 |
|------|------|
| `keyword` | 规范化番号（大写、去空白） |
| `source` | `graphql`（DMM 数字版，含素人）或 `javbus`（DMM 未命中兜底）或 `mgs`（MGS 番号直查 mgstage） |
| `total` / `count` | 命中数（0 或 1） |
| `works[].id` | 数字版 content id（如 `ipx00685`；素人为番号本体如 `smgn124`，用作「配信品番」） |
| `works[].makerContentId` | メーカー品番（如 `SSIS-666`、`SMGN-124`） |
| `works[].title` | 作品标题 |
| `works[].description` | 内容简介（素人可能为空） |
| `works[].floor` | 分类（`AV` / `AMATEUR`（素人）/ `javbus` / `mgs`） |
| `works[].contentType` | 内容类型（`TWO_DIMENSION` / VR 等） |
| `works[].cover.medium` / `cover.large` | 封面直链 |
| `works[].duration` | `{ seconds, minutes }` 收録时长 |
| `works[].deliveryStartAt` / `deliveryStartDate` | 配信開始日（ISO 8601） |
| `works[].makerReleasedAt` | 商品発売日（ISO 8601，JST +9h） |
| `works[].saleEndAt` | 促销截止时间（可空） |
| `works[].wishlistCount` | 收藏/加入愿望单数量 |
| `works[].actresses` | 出演者列表（含 `nameRuby` / 三围 / `contentCount` 等）；素人作品取自 `amateurActress` |
| `works[].directors` | 監督列表 `[{id, name}]` |
| `works[].series` | 系列列表 `[{id, name}]` |
| `works[].maker` | メーカー `{id, name}` |
| `works[].label` | レーベル列表（数组） |
| `works[].genres` | ジャンル列表 `[{id, name}]` |
| `works[].relatedTags` | 相关标签列表（拍平去重） |
| `works[].playableDevices` | 対応デバイス列表 `[{name, device}]` |
| `works[].review` | 平均評価 `{average, count}` |
| `works[].price` | 价格 `{price, listPrice, salePrice}` |
| `works[].sampleImages` | 剧照列表 `[{number, smallUrl, largeUrl}]` |
| `works[].sample2DMovie` | 2D 预告片 `{hlsMovieUrl, highestMovieUrl}` |
| `works[].sampleVRMovie` | VR 预告片链接（VR 作品才有） |
| `works[].mgs` | 仅 MGS：`{average, count, price}`（评价与 `review` 相同，另带价格） |
| `works[].webUrl` | javbus / mgs 兜底时附带：源站详情页链接 |

> `source="javbus"` 时字段结构与源不同：`id`/`makerContentId` 均等于番号；`director` 为纯字符串（缺失为 `"未知"`）；`series`/`label`/`genres`/`actresses` 为纯字符串数组（非 `{id,name}` 对象）；`maker` 为纯字符串；`sampleImages.smallUrl`/`largeUrl` 取外部 CDN 源（mgstage 等，非 javbus `/pics/`）；不含 `description`/`price`/`review`/`directors`。前端按 `source` 分支渲染。

> `source="mgs"`（mgstage 直查）时同样为纯字符串风格：`deliveryStartDate`（配信開始日）/ `makerReleasedAt`（商品発売日）/ `salesDate` 为 `YYYY/MM/DD`（无 ISO 后缀）；`director` 缺失为 `"未知"`；`series`（系列）/ `maker`（メーカー）/ `label`（レーベル）/ `genres` / `actresses` 均为纯字符串或数组；评分与价格在 `review` 中（含 `price`），并在 `mgs` 字段重复一份 `{average, count, price}`；另附 `webUrl`（mgstage 详情页原链）。封面与样图走 mgstage CDN（不会被 CORS 拦截），画质为 `pb_e_`/`cap_e_`。不含 DMM 专属的 `directors`/`relatedTags`/`playableDevices`/`sample2DMovie` 等字段；mgstage 的「対応デバイス（播放设备）」字段有意不采集。

**错误码**

| 状态 | 场景 |
|------|------|
| `400` | 缺少番号 |
| `200`（`works` 为空） | 未探测到候选数字版 id（含 GraphQL 失败，见日志） |
| `401`/`403` | 未带 / 无效 token |

> **搜索频次统计**：每次 `/api/search/:id` 的有效查询都会把该番号计入「搜索排行榜」分析字典（`searchrank_cache`，见下节 4.7），供前端「热门搜索 Top 20」展示。仅记录番号与其出现次数，不记录任何个人信息。

---

## 4.7 搜索排行榜（Search Ranking）

展示搜索频率最高的 20 个番号，供前端「番号搜索」页面的「热门搜索 Top 20」按钮使用。

```
GET /api/searchrank
```

**鉴权**：与其它 `/api/*` 一致，需要 `Authorization: Bearer <token>`。

**数据来源与存储**：每个有效番号搜索（见 4.6）都会在 `searchrank_cache` 共享字典（`lua_shared_dict`，固定 **1m**，在 `nginx.conf` 声明，不随 `DMM_CACHE_TOTAL` 分配）中把该番号的计数 +1。由于只存番号和次数、不存个人数据，1m 足够容纳数千个不重复番号。每个番号的 TTL 在每次搜索时刷新为 **7 天**（`7*86400` 秒），超过 7 天未被搜索的番号自动过期。响应每次实时从该字典统计排序得出，不做二次缓存。

**响应 `200`**

```json
{
  "total": 42,
  "count": 20,
  "items": [
    { "code": "IPX-685", "count": 37 },
    { "code": "ABP-477", "count": 29 }
  ]
}
```

| 字段 | 说明 |
|------|------|
| `total` | 当前字典中不重复番号总数 |
| `count` | 实际返回条数（≤ 20） |
| `items` | 按 `count` 降序前 20 条；`code` 为番号，`count` 为搜索次数 |

**注意**：排行榜数据为进程内、易失且非严格一致——多 worker 下计数按 worker 分别累加，重启容器即清零（计时统计场景足够，非持久化数据库）。

---

## 5. 封面图片代理

```
GET /proxy/aws/{path}
GET /proxy/pics/{path}
```

把 DMM 图片 CDN 的请求经本机（日本节点）转发，客户端直接可访问而不被 DMM 地区限制挡掉。通常由 `/api/cover` 返回的 `proxy.*` 路径使用。

**鉴权**：请求**无需携带 token**；`on` 时需有效签名 `?sig=&exp=`（`/api/cover` 返回时已附带），`off` 时直接访问。

| 代理路径 | 上游 CDN |
|----------|----------|
| `/proxy/aws/{path}` | `https://awsimgsrc.dmm.co.jp/pics_dig/{path}`（2K 高清封面） |
| `/proxy/sample/{path}` | `https://awsimgsrc.dmm.co.jp/dig_white/{path}`（高清剧照） |
| `/proxy/pics/{path}` | `https://pics.dmm.co.jp/{path}`（标准） |

- 访问 `/proxy/*` 时**无需携带 token**。
- `DMM_API_PROTECT=off` 时：直接使用 `/api/cover` 返回的原始 `proxy.*` 路径（无签名）。
- `DMM_API_PROTECT=on` 时：`/api/cover` 返回的 `proxy.*` 已自带 `?sig=&exp=`，直接使用即可；若去掉签名参数或已过期，返回 `403`。

**示例**（off 时的原始路径）

```http
GET /proxy/aws/digital/video/sone00128/sone00128pl.jpg

GET /proxy/pics/digital/video/sone00128/sone00128pl.jpg
```

响应为 `image/jpeg`，支持 Range。

---

## 6. 预告片视频流代理

```
GET /proxy/video/{path}
```

把 DMM 预告片 CDN（`cc3001.dmm.co.jp`）经本机（日本节点）代理转发，支持 HTTP Range（可在播放器内拖动进度条）。通常由 `/api/trailer` 返回的 `proxy` 路径使用。

- 请求头自动携带浏览器 UA 与 `Referer: https://www.dmm.co.jp/`，避免 CDN 403
- `proxy_buffering off`，边下边播
- **无需携带 token**
- `DMM_API_PROTECT=on` 时，路径需带签名 `?sig=&exp=`（`/api/trailer` 返回时已附带），否则 `403`

**示例**（off 时的原始路径，on 时末尾追加 `?sig=&exp=`）

```http
GET /proxy/video/litevideo/freepv/s/ssi/ssis00497/ssis00497_mhb_w.mp4
```

响应 `Content-Type: video/mp4`，支持 `Range`（返回 `206 Partial Content`）。

---

## 鉴权失败响应

```json
{ "error": "unauthorized", "message": "Missing Authorization header. Use: Authorization: Bearer <token>" }   // 401
{ "error": "forbidden", "message": "Invalid token" }                                                         // 403
```

---

## 前端界面

访问 `http://localhost:80` 打开内置 SPA 浏览界面。前端通过 `GET /api/session` 获取**短时效 session token**，再携带 `Authorization: Bearer <session token>` 调用数据接口；主 token 永不进入浏览器。

### 功能

- **今日更新**：7 天时间线选择器 + 卡片网格浏览
- **热门排行**：销量排名展示，含排名序号与收藏数
- **番号搜索**：输入番号（如 `ABP-477`、`ABF-365`）一键搜索：MGS 番号（`ABF`/`SIRO`/`MAAN` 等前缀）走 mgstage.com 抓取，其余走 GraphQL 数字版直接探测（无 appid），DMM 查不到时自动用 javbus JSON API 兜底，前端按 `source` 分支独立渲染 DMM / javbus / mgs 三组字段（javbus/mgs 为纯字符串风格字段、导演缺失显示「未知」）；搜索框带一键清空 ✕；搜索页提供「热门搜索 Top 20」按钮展示搜索排行榜（`/api/searchrank`），点击榜单项直达搜索
- **本地收藏**：卡片 ♡ 收藏到浏览器本地（IndexedDB，经 `idb` 库读写，`<script src="lib/idb.min.js">` 引入）。「我的收藏」页面支持：每页 20 条分页、按标题/演员/番号关键词搜索、单选/批量/清空删除（删除前弹确认框）、导入/导出 JSON（`dm9-favorites.json`）；旧的 `dm9_favs` localStorage 数据在首次加载时自动迁移到 IndexedDB 并清除；删除单个收藏时弹「确认删除收藏「%s」？」确认框。数据全部本地存储，不上传任何服务器
- **图片预览**：点击卡片封面弹出大图弹窗，封面 + 剧照轮播，键盘 `←` `→` / `Esc` 导航；点击**番号**自动复制到剪贴板（含弹窗内番号，带"已复制"提示）；javbus 来源的封面（`www.javbus.com` 域，浏览器 CORS 拦截）在卡片与大图弹窗中替换为内置占位图，mgs 样图/封面与 javbus 兜底的样图（均 mgstage CDN）正常显示
- **磁力面板**：三个来源（SUKEBEI / JAVDB / JAVBUS）Tab 展示磁力列表，磁力点击复制；**某个来源失败时该 Tab 内显示「重新获取」按钮**（`?s=<来源>` 定向重拉）；三个来源全为空的番号显示"当前番号暂无磁力链接"+「重新获取」按钮（全量重拉）
- **播放平台**：点「跳转播放」并发探测 missav / supjav / jable / 123av 是否可播，可跳转的显示按钮、探测失败的标注"探测失败"
- **配色主题**：6 套小清新风格一键切换（薄荷绿 / 樱花粉 / 薰衣草 / 海洋蓝 / 暖杏色 / 夜猫黑）
- **中英双语**：界面语言一键切换
- **Mock 降级**：API 不可用时自动使用内置 mock 数据
- **隐私声明**：页脚常驻「本站不会收集您的任何数据，收藏数据在您本地。」——收藏、主题、语言等偏好全部存于浏览器本地（IndexedDB / localStorage），不上传服务器

### 前端调用的接口

| 接口 | 用途 | 鉴权 |
|------|------|------|
| `GET /api/session` | 签发前端用 session token | 无需 |
| `GET /api/todayupdate?date=YYYY-MM-DD&offset=0&limit=30` | 今日更新列表 | `Bearer <token>` |
| `GET /api/ranking?offset=0&limit=30` | 热门排行榜 | `Bearer <token>` |
| `GET /api/search/:id?offset=0&hits=30` | FANZA 番号搜索（上游大写） | `Bearer <token>` |
| `GET /api/searchrank` | 搜索频率前 20 的番号 | `Bearer <token>` |
| `GET /api/magnet/:id` | 磁力链接聚合（可选 `?s=<来源>` 定向） | `Bearer <token>` |
| `GET /api/findplay/:id` | 播放平台探测 | `Bearer <token>` |

### 字段映射（API → 前端）

| API 字段 | 前端用途 |
|----------|----------|
| `cover.medium / cover.large` | 卡片封面图（javbus 来源为 javbus 域封面 → 替换为内置占位图；mgs 为 mgstage CDN 正常显示） |
| `sampleImages[].largeUrl` | 弹窗图片列表（封面 + 全部剧照；javbus 来源无封面，仅样图，样图为外部 CDN） |
| `price.price / price.discountPrice` | 卡片价格显示（单位为円） |
| `priceTag` | 搜索结果价格角标 `<span class="sr-price-tag">…円</span>`，仅 DMM（graphql）与 MGS 来源有价格 |
| `actresses` | 卡片演员标签（graphql 取 `[].name`；javbus / mgs 为纯字符串数组） |
| `maker` | 卡片商家标签（graphql 为对象取其 `name`；javbus 为纯字符串「製作商」，mgs 为「メーカー」） |
| `director` / `directors` | 搜索详情行「監督」：javbus / mgs 用 `director` 字符串（缺失 `"未知"`），graphql 用 `directors[].name` |
| `bookmarkCount` | 排行榜收藏数（♥ N） |
| `rank` (offset + i) | 排行榜排名（#N） |
| `hasNext / total / offset / limit` | 分页控制 |
