#!/bin/bash

set -e  # 遇错退出

# 定位 .env 文件（相对脚本位置）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: .env file not found at $ENV_FILE. Please run setup_env.sh first." >&2
    exit 1
fi

# 从 .env 中提取 APISIX_ADMIN_KEY（支持值中含 = 的情况）
APISIX_ADMIN_KEY=$(grep -E '^APISIX_ADMIN_KEY=' "$ENV_FILE" | cut -d '=' -f2-)
if [[ -z "$APISIX_ADMIN_KEY" ]]; then
    echo "Error: APISIX_ADMIN_KEY not found in .env file." >&2
    exit 1
fi

# CORS 配置（用 jq 构建）
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

# 1. 为每个服务创建 /api/svc/* 路由
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

    echo "Creating route: /api/$svc/* → service:$svc"
    curl -X PUT "http://127.0.0.1:9180/apisix/admin/routes/$svc-route" \
        -H "X-API-KEY: $APISIX_ADMIN_KEY" \
        -H "Content-Type: application/json" \
        -d "$route_body"
    echo
done

# 2. 为 auth 服务添加特殊路径（带 /api 前缀）
special_paths=("/.well-known/*" "/password/*" "/registration/*" "/profile/*")
for path in "${special_paths[@]}"; do
    public_uri="/api$path"
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

    echo "Creating API route: $public_uri → auth (rewritten to $path)"
    curl -X PUT "http://127.0.0.1:9180/apisix/admin/routes/$route_name" \
        -H "X-API-KEY: $APISIX_ADMIN_KEY" \
        -H "Content-Type: application/json" \
        -d "$route_body"
    echo
done

# 3. 为 auth 服务创建通用 /api/auth/* 路由
svc="auth"
route_body=$(jq -n \
    --arg uri "/api/$svc/*" \
    --arg cors "$cors_plugin" \
    '{
        uri: $uri,
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
            "proxy-rewrite": {
                regex_uri: ["^/api/(.*)", "/$1"]
            },
            "cors": ($cors | fromjson)
        }
    }')

echo "Creating route: /api/auth/* → service:auth"
curl -X PUT "http://127.0.0.1:9180/apisix/admin/routes/${svc}-route" \
    -H "X-API-KEY: $APISIX_ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -d "$route_body"
echo

# 4. 创建 /stomp WebSocket 路由（用于 linx）
svc="linx"
route_body=$(jq -n \
    --arg uri "/stomp" \
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

echo "Creating WebSocket route: /stomp → service:$svc"
curl -X PUT "http://127.0.0.1:9180/apisix/admin/routes/${svc}-ws-route" \
    -H "X-API-KEY: $APISIX_ADMIN_KEY" \
    -H "Content-Type: application/json" \
    -d "$route_body"
echo

echo "✅ All routes configured successfully."