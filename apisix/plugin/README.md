# JWKS Smart Auth 插件

## 概述

这是一个为 APISIX 自定义的 JWT 验证插件，配合后端的双密钥轮换机制（current + next）使用。

## 核心特性

### 1. 智能预加载机制
- **按需拉取**: 只有当使用最新 kid (latest_kid) 时才触发预加载
- **平滑过渡**: 与后端 `JwtUtil` 的双密钥策略完美配合
- **性能优化**: 避免频繁拉取 JWKS，减少延迟

### 2. 密钥缓存策略
```
后端密钥状态:
├── currentSigningKey (次新)  ← 正在使用签发 Token
└── nextSigningKey (最新)     ← 预备密钥

网关缓存状态:
├── second_latest_kid  ← 对应 currentSigningKey
└── latest_kid         ← 对应 nextSigningKey (触发器)
```

### 3. 触发逻辑
```lua
if kid == latest_kid and latest_kid ~= second_latest_kid then
    -- 检测到最新密钥被使用，异步预加载下一轮 JWKS
    ngx.timer.at(0, function() fetch_jwks() end)
end
```

## 工作流程

### 场景 1: 正常验证（使用 currentSigningKey）
```
1. 客户端携带 JWT (kid=1759641511032_657000_26WqBZ1yAM)
2. 网关从缓存中找到对应公钥
3. 验证通过，不触发预加载
4. 快速响应
```

### 场景 2: 密钥轮换检测（使用 nextSigningKey）
```
1. 后端密钥轮换：currentSigningKey → nextSigningKey
2. 客户端携带新 JWT (kid=1759641511877_777200_AiaeakHx72)
3. 网关检测到 kid == latest_kid
4. 异步拉取 JWKS（不阻塞请求）
5. 缓存更新，新的 nextSigningKey 被加载
6. 下次轮换时仍能流畅验证
```

### 场景 3: 兜底机制（缓存未命中）
```
1. 客户端携带未知 kid 的 JWT
2. 网关缓存中找不到该 kid
3. 立即同步拉取 JWKS
4. 验证通过或失败
```

## 配置说明

### 插件配置项

```lua
{
    jwks_uri = "http://auth-service/api/.well-known/jwks.json",  -- JWKS 端点
    issuer = "auth",                                              -- JWT 签发者
    audiences = {"linx", "synapse", "audit"}                     -- 受众服务列表
}
```

### APISIX 路由配置示例

```bash
curl http://localhost:9180/apisix/admin/routes/1 \
  -H "X-API-KEY: $APISIX_ADMIN_KEY" \
  -X PUT -d '
{
  "uri": "/api/linx/*",
  "plugins": {
    "jwks-smart-auth": {
      "jwks_uri": "http://nacos:8848/nacos/v1/ns/instance/list?serviceName=auth-service&groupName=DEFAULT_GROUP&namespaceId=&healthyOnly=true",
      "issuer": "auth",
      "audiences": ["linx"]
    },
    "proxy-rewrite": {
      "regex_uri": ["^/api/linx/(.*)", "/$1"]
    }
  },
  "upstream": {
    "type": "roundrobin",
    "discovery_type": "nacos",
    "service_name": "linx-service"
  }
}'
```

## 部署步骤

### 1. 安装插件

```bash
# 复制插件到 APISIX 插件目录
cp jwks-auth.lua /usr/local/apisix/apisix/plugins/

# 或通过 docker-compose 挂载
# volumes:
#   - ./apisix/plugin/jwks-auth.lua:/usr/local/apisix/apisix/plugins/jwks-smart-auth.lua
```

### 2. 启用插件

编辑 `apisix/config/config.yaml`:

```yaml
plugins:
  - jwks-smart-auth  # 添加到插件列表
  # ... 其他插件
```

### 3. 重启 APISIX

```bash
docker-compose restart apisix
```

### 4. 验证插件加载

```bash
curl http://localhost:9180/apisix/admin/plugins/jwks-smart-auth
```

预期响应:
```json
{
  "version": 0.1,
  "priority": 2549,
  "name": "jwks-smart-auth"
}
```

## 监控和调试

### 查看日志

```bash
# 实时查看 APISIX 日志
docker logs -f apisix

# 关键日志标识
# [info] JWKS refreshed, total keys: 2
# [info] - Latest kid (预期签名密钥): 1759641511877_777200_AiaeakHx72
# [info] - Second latest kid (当前签名密钥): 1759641511032_657000_26WqBZ1yAM
# [info] Latest kid detected in use, scheduling JWKS preload: 1759641511877_777200_AiaeakHx72
```

### 测试验证

```bash
# 获取 Access Token
TOKEN=$(curl -X POST http://localhost:9080/api/login \
  -H "Content-Type: application/json" \
  -d '{"username":"test","password":"password"}' | jq -r '.accessToken')

# 使用 Token 访问受保护资源
curl http://localhost:9080/api/linx/users \
  -H "Authorization: Bearer $TOKEN"
```

## 性能优化

### 1. 减少 JWKS 拉取频率
- ✅ 只在检测到最新 kid 时触发
- ✅ 异步拉取，不阻塞请求
- ✅ 本地缓存，避免重复验证

### 2. 内存占用
```
每个 RSA-2048 公钥 ≈ 1KB
双密钥 + 1个旧密钥 ≈ 3KB
可忽略不计
```

### 3. 延迟对比
```
传统方案: 每次验证都查询 JWKS → 50-200ms
智能方案: 缓存命中 → <1ms，仅首次/轮换时拉取
```

## 故障排查

### 问题 1: 插件未加载
```bash
# 检查插件文件权限
ls -la /usr/local/apisix/apisix/plugins/jwks-smart-auth.lua

# 检查 config.yaml 配置
cat /usr/local/apisix/conf/config.yaml | grep jwks-smart-auth

# 查看 APISIX 错误日志
docker logs apisix 2>&1 | grep -i error
```

### 问题 2: JWKS 拉取失败
```bash
# 检查网络连通性
docker exec apisix curl http://nacos:8848/nacos/v1/ns/instance/list?serviceName=auth-service

# 检查 auth-service 健康状态
curl http://localhost:8848/nacos/v1/ns/instance/list?serviceName=auth-service
```

### 问题 3: JWT 验证失败
```bash
# 解码 JWT Header
echo $TOKEN | cut -d'.' -f1 | base64 -d | jq

# 检查 kid 是否在 JWKS 中
curl http://localhost:9080/api/.well-known/jwks.json | jq '.keys[].kid'
```

## 与后端配置对接

### 后端 application.yml 配置

```yaml
jwt:
  issuer: auth
  expire:
    access-token: 3600000    # 1小时
    refresh-token: 604800000 # 7天
  key:
    size: 2048
    rotation:
      enabled: true
      interval-hours: 48     # 48小时轮换一次
```

### 确保时钟同步

后端和网关的系统时钟必须同步（使用 NTP），否则可能导致：
- Token 过期判断错误
- kid 时间戳排序混乱

```bash
# 检查时间
docker exec apisix date
docker exec auth-service date
```

## 安全建议

1. **HTTPS 强制**: 生产环境必须使用 HTTPS 传输 JWT
2. **最小权限**: audience 字段限制 Token 访问范围
3. **日志审计**: 记录所有认证失败事件
4. **密钥轮换**: 定期轮换 RSA 密钥（建议 48-168 小时）
5. **撤销机制**: 配合 Redis 实现 Token 黑名单

## 版本兼容性

- APISIX: >= 3.0.0
- OpenResty: >= 1.21.4
- lua-resty-jwt: >= 0.2.3
- 后端 JwtUtil: 见源码版本

## 许可证

MIT License
