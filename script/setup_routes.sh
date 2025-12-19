#!/bin/bash

set -e

# --- 路径与配置 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "❌ Error: .env file not found at $ENV_FILE" >&2
    exit 1
fi

# 安全读取 APISIX_ADMIN_KEY（去除首尾空白和换行）
APISIX_ADMIN_KEY=$(grep -E '^APISIX_ADMIN_KEY=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '\r\n' | xargs)
if [[ -z "$APISIX_ADMIN_KEY" ]]; then
    echo "❌ Error: APISIX_ADMIN_KEY not found or empty in .env" >&2
    exit 1
fi

# CORS 插件配置（只构建一次）
cors_plugin=$(jq -n \
    --arg origins "http://localhost:5173" \
    --arg methods "GET,POST,PUT,DELETE,OPTIONS" \
    --arg headers "Content-Type,Authorization,Origin,Refresh-Token" \
    --arg expose "Content-Length,X-Request-ID,X-RateLimit-Limit" \
    --argjson max_age 300 \
    --argjson allow_credential true \
    '{
        allow_origins: $origins,
        allow_methods: $methods,
        allow_headers: $headers,
        expose_headers: $expose,
        max_age: $max_age,
        allow_credential: $allow_credential
    }'
)

APISIX_ADMIN_URL="http://127.0.0.1:9180/apisix/admin"

# --- 1. 通用服务路由: /api/{svc}/* → service:{svc} ---
services=("linx" "synapse" "audit")
for svc in "${services[@]}"; do
    route_body=$(jq -n \
        --arg uri "/api/$svc/*" \
        --arg svc_name "$svc" \
        --arg cors "$cors_plugin" \
        --arg jwks_uri "http://127.0.0.1:9080/api/.well-known/jwks.json" \
        --arg issuer "auth" \
        --argjson audiences "[\"$svc\"]" \
        '{
            uri: $uri,
            upstream: {
                service_name: $svc_name,
                type: "roundrobin",
                discovery_type: "nacos",
                discovery_args: {
                    group_name: "DEFAULT_GROUP",
                    namespace_id: ""
                }
            },
            plugins: {
                "proxy-rewrite": {
                    regex_uri: ["^/api/" + ($svc_name | @uri) + "/(.*)", "/$1"]
                },
                "jwks-auth": {
                    jwks_uri: $jwks_uri,
                    issuer: $issuer,
                    audiences: $audiences
                },
                "cors": ($cors | fromjson)
            }
        }')

    echo "🌐 Creating route: /api/$svc/* → service:$svc"
    curl -X PUT "$APISIX_ADMIN_URL/routes/$svc-route" \
        -H "X-API-KEY: $APISIX_ADMIN_KEY" \
        -H "Content-Type: application/json" \
        -d "$route_body"
    echo
done

# --- 2. Auth 特殊路径（无需认证）---
special_paths=("/.well-known/*" "/password/*" "/registration/*" "/profile/*")
for path in "${special_paths[@]}"; do
    public_uri="/api$path"
    # 生成合法路由名（避免特殊字符）
    clean_name=$(echo "$public_uri" | sed 's/[^a-zA-Z0-9]/-/g' | sed 's/^-//' | sed 's/-$//')
    route_name="auth-api-special-$clean_name"

    route_body=$(jq -n \
        --arg uri "$public_uri" \
        --arg cors "$cors_plugin" \
        '{
            uri: $uri,
            upstream: {
                service_name: "auth",
                type: "roundrobin",
                discovery_type: "nacos",
                discovery_args: {
                    group_name: "DEFAULT_GROUP",
                    namespace_id: ""
                }
            },
            plugins: {
                "proxy-rewrite": {
                    regex_uri: ["^/api/(.*)", "/$1"]
                },
                "cors": ($cors | fromjson)
            }
        }')

    echo "🔑 Creating public auth route: $public_uri → auth"
    curl -X PUT "$APISIX_ADMIN_URL/routes/$route_name" \
        -H "X-API-KEY: $APISIX_ADMIN_KEY" \
        -H "Content-Type: application/json" \
        -d "$route_body"
    echo
done

# --- 3. 通用 Auth 路由: /api/auth/* ---
svc="auth"
route_body=$(jq -n \
    --arg uri "/api/$svc/*" \
    --arg cors "$cors_plugin" \
    '{
        uri: $uri,
        upstream: {
            service_name: "auth",
            type: "roundrobin",
            discovery_type: "nacos",
            discovery_args: {
                group_name: "DEFAULT_GROUP",
                namespace_id: ""
            }
        },
        plugins: {
            "proxy-rewrite": {
                regex_uri: ["^/api/(.*)", "/$1"]
            },
            "cors": ($cors | fromjson)
        }
    }')

echo "🔐 Creating protected auth route: /api/auth/* → auth"
curl -X PUT "$APISIX_ADMIN_URL/routes/${svc}-route" \
    -H "X-API-KEY: $APISIX_ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -d "$route_body"
echo

# --- 4. WebSocket 路由: /stomp ---
svc="linx"
route_body=$(jq -n \
    --arg uri "/stomp" \
    --arg svc "$svc" \
    --arg cors "$cors_plugin" \
    '{
        uri: $uri,
        enable_websocket: true,
        upstream: {
            service_name: $svc,
            type: "roundrobin",
            discovery_type: "nacos",
            discovery_args: {
                group_name: "DEFAULT_GROUP",
                namespace_id: ""
            }
        },
        plugins: {
            "cors": ($cors | fromjson)
        }
    }')

echo "📡 Creating WebSocket route: /stomp → service:$svc"
curl -X PUT "$APISIX_ADMIN_URL/routes/${svc}-ws-route" \
    -H "X-API-KEY: $APISIX_ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -d "$route_body"
echo

echo "✅ All APISIX routes configured successfully!"