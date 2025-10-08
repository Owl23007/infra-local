-- jwks-auth.lua
-- 基于 JWKS 的 JWT 认证插件，支持密钥轮换（active key + next key）
-- 作者: Your Team
-- 版本: 1.0

local core = require("apisix.core")
local cjson = require("cjson")
local http = require("resty.http")
local jwt = require("resty.jwt")
local ngx = ngx

local plugin_name = "jwks-auth"

-- 插件配置 Schema
local schema = {
    type = "object",
    properties = {
        jwks_uri = { type = "string", format = "uri" },  -- JWKS 端点地址
        issuer = { type = "string" },                    -- 预期签发者（可选）
        audiences = {                                    -- 预期受众列表（可选）
            type = "array",
            items = { type = "string" },
        },
    },
    required = { "jwks_uri" },
}

-- 全局缓存：kid -> PEM 格式公钥
local pub_keys = core.tablepool.fetch("pub_keys", 0, 10)
-- 缓存最后更新时间（Unix 时间戳）
local last_fetch_time = 0
-- 缓存中最新的 kid（基于时间戳判断，对应 next key）
local latest_kid = nil
-- 缓存中次新的 kid（对应当前 active key）
local second_latest_kid = nil

--- 提取 kid 中的时间戳前缀
-- @param kid string, 格式如 "1712345678_abc"
-- @return number, 时间戳；若无则返回 0
local function get_kid_timestamp(kid)
    local ts = string.match(kid, "^(%d+)_")
    return ts and tonumber(ts) or 0
end

--- 将 JWK (RSA) 转换为 PEM 格式公钥
-- @param jwk table, JWK 对象
-- @return string|nil, PEM 字符串 或 错误信息
local function jwk_to_pem(jwk)
    if jwk.kty ~= "RSA" or not jwk.n or not jwk.e then
        return nil, "invalid JWK"
    end

    -- Base64URL 解码辅助函数
    local function b64url_decode(str)
        str = string.gsub(str, "-", "+")
        str = string.gsub(str, "_", "/")
        local pad = #str % 4
        if pad == 2 then
            str = str .. "=="
        elseif pad == 3 then
            str = str .. "="
        end
        return ngx.decode_base64(str)
    end

    local n_bytes = b64url_decode(jwk.n)
    local e_bytes = b64url_decode(jwk.e)

    if not n_bytes or not e_bytes then
        return nil, "base64 decode failed"
    end

    -- 构造 ASN.1 DER 格式的 RSA 公钥
    local der = {}
    table.insert(der, "\x30")  -- SEQUENCE

    -- 处理 modulus（确保非负）
    local n_len = #n_bytes
    if n_bytes:byte(1) >= 128 then
        n_len = n_len + 1
        n_bytes = "\x00" .. n_bytes
    end

    -- 处理 exponent（确保非负）
    local e_len = #e_bytes
    if e_bytes:byte(1) >= 128 then
        e_len = e_len + 1
        e_bytes = "\x00" .. e_bytes
    end

    local total_len = 14 + n_len + e_len
    if total_len > 127 then
        table.insert(der, "\x81")
    end
    table.insert(der, string.char(total_len))

    -- INTEGER (modulus)
    table.insert(der, "\x02")
    table.insert(der, string.char(n_len))
    table.insert(der, n_bytes)

    -- INTEGER (exponent)
    table.insert(der, "\x02")
    table.insert(der, string.char(e_len))
    table.insert(der, e_bytes)

    local der_bin = table.concat(der)
    return "-----BEGIN PUBLIC KEY-----\n" ..
           ngx.encode_base64(der_bin):gsub(".{64}", "%0\n") ..
           "\n-----END PUBLIC KEY-----"
end

--- 从 JWKS URL 拉取并更新公钥缓存
-- @param jwks_uri string
-- @return boolean, 是否成功
local function fetch_jwks(jwks_uri)
    local httpc = http.new()
    local res, err = httpc:request_uri(jwks_uri, {
        method = "GET",
        ssl_verify = false,
        timeout = 3000,
    })

    if not res or res.status ~= 200 or not res.body then
        core.log.error("failed to fetch JWKS from ", jwks_uri, ": ", err or res.reason)
        return false
    end

    local jwks, err = cjson.decode(res.body)
    if not jwks or type(jwks.keys) ~= "table" then
        core.log.error("invalid JWKS response")
        return false
    end

    -- 清空旧缓存
    for k in pairs(pub_keys) do
        pub_keys[k] = nil
    end

    -- 构建 kid 与时间戳映射，用于排序
    local kid_with_ts = {}
    for _, key in ipairs(jwks.keys) do
        if key.kid then
            local pem, err = jwk_to_pem(key)
            if pem then
                local ts = get_kid_timestamp(key.kid)
                pub_keys[key.kid] = pem
                table.insert(kid_with_ts, {kid = key.kid, ts = ts})
            else
                core.log.warn("skip invalid JWK kid: ", key.kid, " err: ", err)
            end
        end
    end

    -- 按时间戳降序排序（新密钥在前）
    table.sort(kid_with_ts, function(a, b) return a.ts > b.ts end)

    -- 更新最新和次新 kid
    if #kid_with_ts >= 1 then
        latest_kid = kid_with_ts[1].kid
    end
    if #kid_with_ts >= 2 then
        second_latest_kid = kid_with_ts[2].kid
    end

    last_fetch_time = ngx.time()
    core.log.info("JWKS refreshed, total keys: ", #kid_with_ts)
    core.log.info("  - Latest kid (next key): ", latest_kid or "none")
    core.log.info("  - Second latest kid (active key): ", second_latest_kid or "none")
    return true
end

-- 插件元信息
local _M = {
    version = 0.1,
    priority = 2549,  -- 高于 proxy-rewrite 等插件
    name = plugin_name,
    schema = schema,
}

--- 配置校验
function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

--- 认证主逻辑
function _M.access(conf, ctx)
    -- 1. 获取 Authorization 头
    local token = ngx.var.http_authorization
    if not token then
        return core.response.exit(401, { message = "missing Authorization header" })
    end

    -- 2. 去除 Bearer 前缀
    token = string.gsub(token, "^Bearer%s+", "")

    -- 3. 解析 JWT Header 获取 kid
    local jwt_obj = jwt:load_jwt(token)
    if not jwt_obj or not jwt_obj.header or not jwt_obj.header.kid then
        return core.response.exit(401, { message = "missing kid in JWT header" })
    end

    local kid = jwt_obj.header.kid

    -- 4. 缓存未命中时拉取 JWKS（兜底）
    if not pub_keys[kid] or last_fetch_time == 0 then
        core.log.warn("kid not in cache or first fetch, pulling JWKS: ", kid)
        fetch_jwks(conf.jwks_uri)
    end

    -- 5. 获取公钥并验证
    local pub_key = pub_keys[kid]
    if not pub_key then
        return core.response.exit(401, { message = "public key not found for kid: " .. tostring(kid) })
    end

    local verified = jwt:verify_jwt_obj(pub_key, jwt_obj)
    if not verified or not verified.verified then
        return core.response.exit(401, { message = "invalid JWT signature or claims" })
    end

    -- 6. 验证 issuer（如果配置）
    if conf.issuer and jwt_obj.payload.iss ~= conf.issuer then
        return core.response.exit(401, { message = "invalid issuer" })
    end

    -- 7. 验证 audience（如果配置）
    if conf.audiences and #conf.audiences > 0 then
        local aud = jwt_obj.payload.aud
        local valid_aud = false

        if type(aud) == "string" then
            for _, expected_aud in ipairs(conf.audiences) do
                if aud == expected_aud then
                    valid_aud = true
                    break
                end
            end
        elseif type(aud) == "table" then
            for _, expected_aud in ipairs(conf.audiences) do
                for _, token_aud in ipairs(aud) do
                    if token_aud == expected_aud then
                        valid_aud = true
                        break
                    end
                end
                if valid_aud then break end
            end
        end

        if not valid_aud then
            return core.response.exit(401, { message = "invalid audience" })
        end
    end

    -- 8. 密钥轮换预加载：当使用 latest_kid 时，异步拉取新 JWKS
    if kid == latest_kid and latest_kid ~= second_latest_kid then
        core.log.info("Latest kid detected in use, scheduling JWKS preload: ", kid)
        ngx.timer.at(0, function(premature, uri)
            if not premature then
                core.log.info("Preloading JWKS due to latest kid usage")
                fetch_jwks(uri)
            end
        end, conf.jwks_uri)
    end

    -- ==================================================================
    -- 注入用户身份头
    -- 根据 JWT 字段规范，仅透传以下字段：
    --   sub       → X-User-ID
    --   userId    → X-User-Long-ID
    --   role      → X-User-Role
    --   scope     → X-User-Scopes
    --   jti       → X-Token-JTI
    --   type      → X-Token-Type
    -- ==================================================================
    ngx.req.clear_header("X-User-ID")
    ngx.req.clear_header("X-User-Long-ID")
    ngx.req.clear_header("X-User-Role")
    ngx.req.clear_header("X-User-Scopes")
    ngx.req.clear_header("X-Token-JTI")
    ngx.req.clear_header("X-Token-Type")

    local payload = jwt_obj.payload

    -- sub = userId.toString()
    if payload.sub then
        ngx.req.set_header("X-User-ID", payload.sub)
    end

    -- userId (Long)
    if payload.userId then
        ngx.req.set_header("X-User-Long-ID", tostring(payload.userId))
    end

    -- role
    if payload.role then
        ngx.req.set_header("X-User-Role", payload.role)
    end

    -- scope (List<String>)
    if payload.scope then
        local scopes_str = type(payload.scope) == "table" and table.concat(payload.scope, ",") or tostring(payload.scope)
        ngx.req.set_header("X-User-Scopes", scopes_str)
    end

    -- jti
    if payload.jti then
        ngx.req.set_header("X-Token-JTI", payload.jti)
    end

    -- type ("access" or "refresh")
    if payload.type then
        ngx.req.set_header("X-Token-Type", payload.type)
    end

    -- 供其他插件或日志使用
    ctx.jwt_payload = payload
end

return _M