-- jwks-auth.lua
-- 基于 JWKS 的 JWT 认证插件，支持密钥轮换
-- 作者: Oii Woof
-- 版本: 1.0.0
-- 兼容 APISIX >= 2.13

local core = require("apisix.core")
local cjson = require("cjson")
local http = require("resty.http")
local jwt = require("resty.jwt")
local ngx = ngx
local bit = require("bit")

local plugin_name = "jwks-auth"

-- 插件配置 Schema
local schema = {
    type = "object",
    properties = {
        jwks_uri = {
            type = "string",
            format = "uri",
            description = "JWKS 端点地址，必须可公开访问"
        },
        issuer = {
            type = "string",
            description = "预期的 JWT 签发者（iss），留空则不验证"
        },
        audiences = {
            type = "array",
            items = { type = "string" },
            description = "预期的 JWT 受众列表（aud），留空则不验证"
        },
        clock_skew = {
            type = "integer",
            minimum = 0,
            default = 0,
            description = "时钟偏移容忍秒数"
        }
    },
    required = { "jwks_uri" },
    additionalProperties = false
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
    if not kid then
        return 0
    end
    local ts = string.match(kid, "^(%d+)_")
    return ts and tonumber(ts) or 0
end

--- Base64URL 解码函数
-- @param str string, Base64URL 编码的字符串
-- @return string|nil, 解码后的二进制数据
local function b64url_decode(str)
    if not str or str == "" then
        return nil
    end
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

local function jwk_to_pem(jwk)
    if not jwk or jwk.kty ~= "RSA" then
        return nil, "invalid JWK: missing or invalid kty"
    end
    if not jwk.n or not jwk.e then
        return nil, "invalid JWK: missing n or e"
    end

    local n_bytes = b64url_decode(jwk.n)
    local e_bytes = b64url_decode(jwk.e)
    if not n_bytes or not e_bytes then
        return nil, "base64url decode failed"
    end

    -- 添加前导零（如果最高位 >= 0x80）
    if n_bytes:byte(1) >= 128 then n_bytes = "\0" .. n_bytes end
    if e_bytes:byte(1) >= 128 then e_bytes = "\0" .. e_bytes end

    -- 编码 DER 长度字段（支持多字节）
    local function der_len(n)
        if n < 128 then
            return string.char(n)
        else
            local bytes = {}
            while n > 0 do
                table.insert(bytes, 1, string.char(n % 256))
                n = math.floor(n / 256)
            end
            return string.char(128 + #bytes) .. table.concat(bytes)
        end
    end

    -- 编码 DER INTEGER
    local function der_integer(data)
        return "\x02" .. der_len(#data) .. data
    end

    -- 1. RSAPublicKey SEQUENCE
    local rsa_seq = der_integer(n_bytes) .. der_integer(e_bytes)
    local rsa_der = "\x30" .. der_len(#rsa_seq) .. rsa_seq

    -- 2. BIT STRING (with leading unused bits = 0)
    local bit_string = "\x00" .. rsa_der
    local bit_der = "\x03" .. der_len(#bit_string) .. bit_string

    -- 3. AlgorithmIdentifier for RSA (rsaEncryption)
    local alg_id = "\x30\x0d\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01\x05\x00"

    -- 4. SubjectPublicKeyInfo SEQUENCE
    local spki_seq = alg_id .. bit_der
    local spki_der = "\x30" .. der_len(#spki_seq) .. spki_seq

    -- 5. PEM encode
    local b64 = ngx.encode_base64(spki_der)
    local pem = "-----BEGIN PUBLIC KEY-----\n"
    for i = 1, #b64, 64 do
        pem = pem .. string.sub(b64, i, math.min(i + 63, #b64)) .. "\n"
    end
    pem = pem .. "-----END PUBLIC KEY-----"
    return pem
end

--- 从 JWKS URL 拉取并更新公钥缓存
-- @param jwks_uri string, JWKS 端点地址
-- @return boolean, 是否成功
local function fetch_jwks(jwks_uri)
    core.log.info("Fetching JWKS from: ", jwks_uri)
    
    local httpc = http.new()
    httpc:set_timeout(3000)  -- 3秒超时
    
    local res, err = httpc:request_uri(jwks_uri, {
        method = "GET",
        ssl_verify = false,  -- 生产环境建议设为 true 并配置 CA
        headers = {
            ["User-Agent"] = "APISIX/jwks-auth-plugin"
        }
    })

    if not res then
        core.log.error("Failed to connect to JWKS endpoint: ", err)
        return false
    end
    
    if res.status ~= 200 then
        core.log.error("JWKS endpoint returned status: ", res.status, ", reason: ", res.reason)
        return false
    end
    
    if not res.body or res.body == "" then
        core.log.error("JWKS response body is empty")
        return false
    end

    -- 解析 JSON
    local jwks, err = cjson.decode(res.body)
    if not jwks then
        core.log.error("Failed to decode JWKS JSON: ", err)
        return false
    end
    
    if type(jwks.keys) ~= "table" then
        core.log.error("Invalid JWKS format: missing or invalid 'keys' array")
        return false
    end

    -- 清空旧缓存
    for k in pairs(pub_keys) do
        pub_keys[k] = nil
    end

    -- 构建 kid 与时间戳映射，用于排序
    local kid_with_ts = {}
    local valid_key_count = 0
    
    for i, key in ipairs(jwks.keys) do
        if not key.kid then
            core.log.warn("Skipping JWK at index ", i, ": missing kid")
            goto continue
        end
        
        -- 只处理 RSA 密钥
        if key.kty ~= "RSA" then
            core.log.warn("Skipping non-RSA JWK kid: ", key.kid, " (kty: ", key.kty or "nil", ")")
            goto continue
        end
        local pem, err = jwk_to_pem(key)
        if pem then
            core.log.info("Generated PEM for kid ", key.kid, ":\n", pem)
            local ts = get_kid_timestamp(key.kid)
            pub_keys[key.kid] = pem
            table.insert(kid_with_ts, {kid = key.kid, ts = ts})
            valid_key_count = valid_key_count + 1
        else
            core.log.warn("Skipping invalid JWK kid: ", key.kid, ", error: ", err)
        end
        
        ::continue::
    end

    -- 按时间戳降序排序（新密钥在前）
    table.sort(kid_with_ts, function(a, b) return a.ts > b.ts end)

    -- 更新最新和次新 kid
    latest_kid = nil
    second_latest_kid = nil
    if #kid_with_ts >= 1 then
        latest_kid = kid_with_ts[1].kid
    end
    if #kid_with_ts >= 2 then
        second_latest_kid = kid_with_ts[2].kid
    end

    last_fetch_time = ngx.time()
    core.log.info("JWKS refreshed successfully")
    core.log.info("  - Total keys processed: ", #jwks.keys)
    core.log.info("  - Valid RSA keys cached: ", valid_key_count)
    core.log.info("  - Latest kid (next key): ", latest_kid or "none")
    core.log.info("  - Second latest kid (active key): ", second_latest_kid or "none")
    
    return true
end

-- 插件元信息
local _M = {
    version = 0.2,
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
        return core.response.exit(401, { 
            message = "Missing Authorization header",
            error = "invalid_request"
        })
    end

    -- 2. 去除 Bearer 前缀
    token = string.match(token, "^Bearer%s+(.+)$")
    if not token then
        return core.response.exit(401, { 
            message = "Invalid Authorization header format",
            error = "invalid_request"
        })
    end

    -- 3. 解析 JWT Header 获取 kid
    local jwt_obj = jwt:load_jwt(token)
    if not jwt_obj then
        return core.response.exit(401, { 
            message = "Invalid JWT format",
            error = "invalid_token"
        })
    end
    
    if not jwt_obj.header or not jwt_obj.header.kid then
        return core.response.exit(401, { 
            message = "Missing kid in JWT header",
            error = "invalid_token"
        })
    end

    local kid = jwt_obj.header.kid

    -- 4. 缓存未命中时拉取 JWKS（兜底）
    if not pub_keys[kid] or last_fetch_time == 0 then
        core.log.warn("Kid not in cache or first fetch, pulling JWKS: ", kid)
        local success = fetch_jwks(conf.jwks_uri)
        if not success then
            return core.response.exit(500, { 
                message = "Failed to fetch JWKS from authentication server",
                error = "server_error"
            })
        end
    end

    -- 5. 获取公钥并验证
    local pub_key = pub_keys[kid]
    if not pub_key then
        return core.response.exit(401, { 
            message = "Public key not found for kid: " .. tostring(kid),
            error = "invalid_token"
        })
    end

    -- 配置 JWT 验证选项
    local jwt_opts = {
        -- 时钟偏移容忍（秒）
        leeway = conf.clock_skew or 0
    }

    local verified = jwt:verify_jwt_obj(pub_key, jwt_obj, nil, {
    leeway = conf.clock_skew or 0
    })
    if not verified or not verified.verified then
        local reason = verified and verified.reason or "unknown"
        core.log.warn("JWT verification failed for kid ", kid, ": ", reason)
        return core.response.exit(401, { 
            message = "Invalid JWT signature or claims",
            error = "invalid_token",
            reason = reason
        })
    end

    -- 6. 验证 issuer
    if conf.issuer and jwt_obj.payload.iss ~= conf.issuer then
        return core.response.exit(401, { 
            message = "Invalid issuer",
            error = "invalid_token",
            expected_iss = conf.issuer,
            actual_iss = jwt_obj.payload.iss
        })
    end

    -- 7. 验证 audience
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
            return core.response.exit(401, { 
                message = "Invalid audience",
                error = "invalid_token",
                expected_aud = conf.audiences,
                actual_aud = aud
            })
        end
    end

    -- 8. 密钥轮换预加载：当使用 latest_kid 时，异步拉取新 JWKS
    if kid == latest_kid and latest_kid ~= second_latest_kid then
        core.log.info("Latest kid detected in use, scheduling JWKS preload: ", kid)
        local ok, err = ngx.timer.at(0, function(premature, uri)
            if not premature then
                core.log.info("Preloading JWKS due to latest kid usage")
                fetch_jwks(uri)
            end
        end, conf.jwks_uri)
        
        if not ok then
            core.log.warn("Failed to create preload timer: ", err)
        end
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
        ngx.req.set_header("X-User-ID", tostring(payload.sub))
    end

    -- userId (Long)
    if payload.userId then
        ngx.req.set_header("X-User-Long-ID", tostring(payload.userId))
    end

    -- role
    if payload.role then
        ngx.req.set_header("X-User-Role", tostring(payload.role))
    end

    -- scope (List<String>)
    if payload.scope then
        local scopes_str
        if type(payload.scope) == "table" then
            scopes_str = table.concat(payload.scope, ",")
        else
            scopes_str = tostring(payload.scope)
        end
        ngx.req.set_header("X-User-Scopes", scopes_str)
    end

    -- jti
    if payload.jti then
        ngx.req.set_header("X-Token-JTI", tostring(payload.jti))
    end

    -- type ("access" or "refresh")
    if payload.type then
        ngx.req.set_header("X-Token-Type", tostring(payload.type))
    end

    -- 供其他插件或日志使用
    ctx.jwt_payload = payload
    
    -- 认证成功日志（调试用，生产环境可注释）
    core.log.info("JWT authentication successful for user: ", payload.sub or "unknown")
end

return _M