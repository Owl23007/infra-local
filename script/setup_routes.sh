#!/bin/bash

# 获取脚本目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

if [ ! -f "$ENV_FILE" ]; then
    echo ".env file not found. Please run setup_env.sh first." >&2
    exit 1
fi

# 从 .env 文件读取 APISIX_ADMIN_KEY（处理包含 = 字符的 base64 值）
admin_key=$(grep "^APISIX_ADMIN_KEY=" "$ENV_FILE" | cut -d'=' -f2-)
if [ -z "$admin_key" ]; then
    echo "APISIX_ADMIN_KEY not found in .env file." >&2
    exit 1
fi

# CORS 插件配置
cors_plugin='{
    "allow_origins": "http://localhost:5173",
    "allow_methods": "GET,POST,PUT,DELETE,OPTIONS",
    "allow_headers": "Content-Type,Authorization,Origin,Refresh-Token",
    "expose_headers": "Content-Length,X-Request-ID,X-RateLimit-Limit",
    "max_age": 300,
    "allow_credential": true
}'

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
    "jwks-auth": {
      "jwks_uri": "http://127.0.0.1:9080/api/.well-known/jwks.json",
      "issuer": "auth",
      "audiences": ["$svc"]
    },
    "cors": $cors_plugin
  }
}
EOF
)

    echo "Debug JSON:"
    echo "$route_body"
    echo ""
    echo "Creating route: /api/$svc/* to service:$svc"
    
    curl -X PUT "http://127.0.0.1:9180/apisix/admin/routes/$svc-route" \
         -H "X-API-KEY: $admin_key" \
         -H "Content-Type: application/json" \
         -d "$route_body"
    echo ""
done

# 2. 为 auth 服务添加带 /api 前缀的特殊路径，并重写
special_paths=("/.well-known/*" "/password/*" "/registration/*")

for path in "${special_paths[@]}"; do
    # 客户端访问的路径：/api + $path
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
    },
    "cors": $cors_plugin
  }
}
EOF
)

    # 生成合法的 route ID（避免特殊字符）
    clean_path=$(echo "$public_uri" | sed 's/[^a-zA-Z0-9]/-/g' | sed 's/^-\+\|-\+$//g')
    route_name="auth-api-special-$clean_path"

    echo "Creating API route: $public_uri to service:auth (rewritten to $path)"
    curl -X PUT "http://127.0.0.1:9180/apisix/admin/routes/$route_name" \
         -H "X-API-KEY: $admin_key" \
         -H "Content-Type: application/json" \
         -d "$route_body"
    echo ""
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
      "regex_uri": ["^/api/(.*)", "/\$1"]
    },
    "cors": $cors_plugin
  }
}
EOF
)

echo "Creating route: /api/$svc/* to service:$svc"
curl -X PUT "http://127.0.0.1:9180/apisix/admin/routes/$svc-route" \
     -H "X-API-KEY: $admin_key" \
     -H "Content-Type: application/json" \
     -d "$route_body"
echo ""

# 4. 创建 /api/linx/ws/* 路由
svc="linx"
route_body=$(cat <<EOF
{
  "uri": "/api/$svc/ws/*",
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
      "regex_uri": ["^/api/(.*)", "/\$1"]
    },
    "cors": $cors_plugin
  }
}
EOF
)

echo "Creating route: /api/$svc/ws/* to service:$svc"
curl -X PUT "http://127.0.0.1:9180/apisix/admin/routes/$svc-ws-route" \
     -H "X-API-KEY: $admin_key" \
     -H "Content-Type: application/json" \
     -d "$route_body"
echo ""