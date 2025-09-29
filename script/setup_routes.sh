#!/bin/bash

# 直接从 .env 文件读取 APISIX_ADMIN_KEY
ENV_FILE=".env"
if [ ! -f "$ENV_FILE" ]; then
    echo ".env file not found. Please run setup_env.sh first." >&2
    exit 1
fi

admin_key=$(grep "^APISIX_ADMIN_KEY=" "$ENV_FILE" | cut -d'=' -f2-)
if [ -z "$admin_key" ]; then
    echo "APISIX_ADMIN_KEY not found in .env file." >&2
    exit 1
fi

services=("linx" "synapse" "audit")

# 1. 为每个服务创建 /api/svc/* 路由
for svc in "${services[@]}"; do
    route_body=$(cat <<EOF
{
  "uri": "/api/$svc/*",
  "upstream": {
    "service_name": "$svc",
    "type": "roundrobin",
    "discovery_type": "nacos",
    "discovery_args": {
      "group_name": "DEFAULT_GROUP",
      "namespace_id": ""
    }
  },
  "plugins": {
    "proxy-rewrite": {
      "regex_uri": ["^/api/$svc/(.*)", "/\$1"]
    },
    "jwt-auth": {
      "key": "auth-service",
      "algorithm": "RS256",
      "jwks_uri": "http://127.0.0.1:9080/api/.well-known/jwks.json"
    }
  }
}
EOF
)

    echo "Creating route: /api/$svc/* to service:$svc"
    curl -X PUT "http://127.0.0.1:9180/apisix/admin/routes/$svc-route" \
         -H "X-API-KEY: $admin_key" \
         -H "Content-Type: application/json" \
         -d "$route_body"
done

# 2. 为 auth 服务添加带 /api 前缀的特殊路径，并重写
special_paths=("/.well-known/*" "/password/*" "/registration/*")

for path in "${special_paths[@]}"; do
    public_uri="/api$path"

    route_body=$(cat <<EOF
{
  "uri": "$public_uri",
  "upstream": {
    "service_name": "auth",
    "type": "roundrobin",
    "discovery_type": "nacos",
    "discovery_args": {
      "group_name": "DEFAULT_GROUP",
      "namespace_id": ""
    }
  },
  "plugins": {
    "proxy-rewrite": {
      "regex_uri": ["^/api/(.*)", "/\$1"]
    }
  }
}
EOF
)

    clean_path=$(echo "$public_uri" | sed 's/[^a-zA-Z0-9]/-/g' | sed 's/^-*//;s/-*$//')
    route_name="auth-api-special-$clean_path"

    echo "Creating API route: $public_uri to service:auth (rewritten to $path)"
    curl -X PUT "http://127.0.0.1:9180/apisix/admin/routes/$route_name" \
         -H "X-API-KEY: $admin_key" \
         -H "Content-Type: application/json" \
         -d "$route_body"
done

# 3. 为 auth 服务创建 /api/auth/* 路由
svc="auth"
route_body=$(cat <<EOF
{
  "uri": "/api/$svc/*",
  "upstream": {
    "service_name": "$svc",
    "type": "roundrobin",
    "discovery_type": "nacos",
    "discovery_args": {
      "group_name": "DEFAULT_GROUP",
      "namespace_id": ""
    }
  },
  "plugins": {
    "proxy-rewrite": {
      "regex_uri": ["^/api/$svc/(.*)", "/\$1"]
    }
  }
}
EOF
)

echo "Creating route: /api/$svc/* to service:$svc"
curl -X PUT "http://127.0.0.1:9180/apisix/admin/routes/$svc-route" \
     -H "X-API-KEY: $admin_key" \
     -H "Content-Type: application/json" \
     -d "$route_body"