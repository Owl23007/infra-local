

# 直接从 .env 文件读取 APISIX_ADMIN_KEY（兼容 Windows 路径）
$envFile = "$PSScriptRoot\..\.env"
if (-not (Test-Path $envFile)) {
    Write-Error ".env file not found. Please run setup_env.ps1 first."
    exit 1
}
$adminKey = (Get-Content $envFile | Where-Object { $_ -match "^APISIX_ADMIN_KEY=" } | ForEach-Object { 
    # 正确处理包含 = 字符的 base64 值
    $parts = $_.Split('=', 2)
    if ($parts.Length -ge 2) { $parts[1] } else { $null }
})
if (-not $adminKey) {
    Write-Error "APISIX_ADMIN_KEY not found in .env file."
    exit 1
}

$services = @("linx", "synapse", "audit")

# 1. 为每个服务创建 /api/svc/* 路由
foreach ($svc in $services) {
    $routeBody = @{
        uri = "/api/$svc/*"
        upstream = @{
            service_name = $svc
            type = "roundrobin"
            discovery_type = "nacos"
            discovery_args = @{
                group_name = "DEFAULT_GROUP"
                namespace_id = ""
            }
        }
        plugins = @{
            "proxy-rewrite" = @{
              regex_uri = @("^/api/$svc/(.*)", '/$1')
            }
            "jwks-auth" = @{
                            jwks_uri = "http://192.168.56.1:9080/api/.well-known/jwks.json"
                            issuer    = "auth"
                            audiences = @($svc)
            }
        }
    } | ConvertTo-Json -Depth 6

    Write-Host "Creating route: /api/$svc/* to service:$svc"
    Invoke-WebRequest `
        -Uri "http://127.0.0.1:9180/apisix/admin/routes/$svc-route" `
        -Headers @{ "X-API-KEY" = $adminKey } `
        -Method PUT `
        -Body $routeBody `
        -ContentType "application/json"
}

# 2. 为 auth 服务添加带 /api 前缀的特殊路径，并重写
$specialPaths = @("/.well-known/*", "/password/*", "/registration/*")

foreach ($path in $specialPaths) {
    # 客户端访问的路径：/api + $path
    $publicUri = "/api" + $path

    $routeBody = @{
        uri = $publicUri
        upstream = @{
            service_name = "auth"
            type = "roundrobin"
            discovery_type = "nacos"
            discovery_args = @{
                group_name = "DEFAULT_GROUP"
                namespace_id = ""
            }
        }
        plugins = @{
            "proxy-rewrite" = @{
                # 匹配 /api/(.*)，重写为 /$1
               regex_uri = @("^/api/(.*)", '/$1')
            }
        }
    } | ConvertTo-Json -Depth 5

    # 生成合法的 route ID（避免特殊字符）
    $cleanPath = ($publicUri -replace "[^a-zA-Z0-9]", "-").Trim("-")
    $routeName = "auth-api-special-$cleanPath"

    Write-Host "Creating API route: $publicUri to service:auth (rewritten to $path)"
    Invoke-WebRequest `
        -Uri "http://127.0.0.1:9180/apisix/admin/routes/$routeName" `
        -Headers @{ "X-API-KEY" = $adminKey } `
        -Method PUT `
        -Body $routeBody `
        -ContentType "application/json"
}

#3. 为 auth 服务创建 /api/auth/* 路由

$svc = "auth"
$routeBody = @{
    uri = "/api/$svc/*"
     upstream = @{
            service_name = $svc
            type = "roundrobin"
            discovery_type = "nacos"
            discovery_args = @{
                group_name = "DEFAULT_GROUP"
                namespace_id = ""
            }
        }
        plugins = @{
            "proxy-rewrite" = @{
              regex_uri = @("^/api/(.*)", '/$1')
            }
        }
    } | ConvertTo-Json -Depth 5

    Write-Host "Creating route: /api/$svc/* to service:$svc"
    Invoke-WebRequest `
        -Uri "http://127.0.0.1:9180/apisix/admin/routes/$svc-route" `
        -Headers @{ "X-API-KEY" = $adminKey } `
        -Method PUT `
        -Body $routeBody `
        -ContentType "application/json"