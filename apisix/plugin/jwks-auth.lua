-- jwks-auth.lua
local core = require("apisix.core")
local cjson = require("cjson")
local http = require("resty.http")
local jwt = require("resty.jwt")
local ngx = ngx

local plugin_name = "jwks-auth"

local schema = {
    type = "object",
    properties = {
        jwks_uri = { type = "string", format = "uri" },
        issuer = { type = "string" },
        audiences = {
            type = "array",
            items = { type = "string" },
        },
    },
    required = { "jwks_uri" },
}

-- 全局缓存：kid -> {pem: string, timestamp: number}
local pub_keys = core.tablepool.fetch("pub_keys", 0, 10)
-- 缓存最后更新时间
local last_fetch_time = 0
-- 缓存中最新的 kid（基于时间戳判断）
local latest_kid = nil
-- 缓存中次新的 kid（预签名密钥）
local second_latest_kid = nil

-- 提取 kid 时间戳
local function get_kid_timestamp(kid)
    local ts = string.match(kid, "^(%d+)_")
    return ts and tonumber(ts) or 0
end

-- 从 JWK 生成 PEM 格式公钥（RSA）
local function jwk_to_pem(jwk)
    if jwk.kty ~= "RSA" or not jwk.n or not jwk.e then
        return nil, "invalid JWK"
    end

    -- base64url decode
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
    -- SEQUENCE
    table.insert(der, "\x30")
    -- modulus
    local n_len = #n_bytes
    if n_bytes:byte(1) >= 128 then
        n_len = n_len + 1
        n_bytes = "\x00" .. n_bytes
    end
    -- exponent
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

-- 从 JWKS URL 拉取并更新 pub_keys 缓存
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

    -- 构建时间戳 -> kid 映射,用于排序
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

    -- 按时间戳降序排序
    table.sort(kid_with_ts, function(a, b) return a.ts > b.ts end)

    -- 更新最新和次新的 kid
    if #kid_with_ts >= 1 then
        latest_kid = kid_with_ts[1].kid
    end
    if #kid_with_ts >= 2 then
        second_latest_kid = kid_with_ts[2].kid
    end

    last_fetch_time = ngx.time()
    core.log.info("JWKS refreshed, total keys: ", #kid_with_ts)
    core.log.info("  - Latest kid (预期签名密钥): ", latest_kid or "none")
    core.log.info("  - Second latest kid (当前签名密钥): ", second_latest_kid or "none")
    return true
end

local _M = {
    version = 0.1,
    priority = 2549,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    local token = ngx.var.http_authorization
    if not token then
        return core.response.exit(401, { message = "missing Authorization header" })
    end

    -- 支持 Bearer 前缀
    token = string.gsub(token, "^Bearer%s+", "")

    -- 解析 JWT header 获取 kid
    local jwt_obj = jwt:load_jwt(token)
    if not jwt_obj or not jwt_obj.header or not jwt_obj.header.kid then
        return core.response.exit(401, { message = "missing kid in JWT header" })
    end

    local kid = jwt_obj.header.kid

    -- 如果缓存中没有该 kid，立即拉取 JWKS（理论上不应发生，但兜底）
    if not pub_keys[kid] or last_fetch_time == 0 then
        core.log.warn("kid not in cache or first fetch, pulling JWKS: ", kid)
        fetch_jwks(conf.jwks_uri)
    end

    -- 再次检查（防止拉取失败）
    local pub_key = pub_keys[kid]
    if not pub_key then
        return core.response.exit(401, { message = "public key not found for kid: " .. tostring(kid) })
    end

    -- 验证 JWT
    local verified = jwt:verify_jwt_obj(pub_key, jwt_obj)
    
    if not verified or not verified.verified then
        return core.response.exit(401, { message = "invalid JWT signature or claims" })
    end

    -- 验证 issuer 和 audience（如果配置）
    if conf.issuer and jwt_obj.payload.iss ~= conf.issuer then
        return core.response.exit(401, { message = "invalid issuer" })
    end

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

    -- 验证通过后，检查是否使用了最新的 kid（触发预加载）
    -- 只有当使用的是 latest_kid 时才预加载下一轮密钥
    if kid == latest_kid and latest_kid ~= second_latest_kid then
        core.log.info("Latest kid detected in use, scheduling JWKS preload: ", kid)
        -- 后台异步拉取（请求结束后执行）
        ngx.timer.at(0, function(premature, uri)
            if not premature then
                core.log.info("Preloading JWKS due to latest kid usage")
                fetch_jwks(uri)
            end
        end, conf.jwks_uri)
    end

    -- 可选：将 payload 注入下游
    ctx.jwt_payload = jwt_obj.payload
end

return _M