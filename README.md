# infra-local

本地开发基础设施项目，基于 Apache APISIX、Nacos 和 etcd 构建微服务架构，集成 **JWKS Auth** 自定义的 JWT 验证插件。

## 🌟 核心特性

- ✅ **智能 JWT 验证**: 自定义 JWKS 插件，支持动态密钥轮换
- ✅ **双密钥机制**: 与后端 current + next 密钥策略完美配合
- ✅ **按需预加载**: 仅在检测到最新 kid 时触发 JWKS 预加载
- ✅ **服务发现**: 基于 Nacos 的动态服务注册与发现
- ✅ **统一网关**: APISIX 提供统一的 API 路由和认证

## 🚀 快速开始

### 方法 1: 一键部署（推荐）

```powershell
# 自动完成环境配置、服务启动、插件加载和路由配置
.\script\quick_start.ps1
```

### 方法 2: 手动部署

#### 1. 环境初始化
```powershell
# 生成环境变量配置文件和密钥
.\script\setup_env.ps1
```

#### 2. 更新 Nacos 密码

```powershell
# 启动 Nacos 容器
docker-compose up -d nacos

# 访问 http://localhost:8848/nacos
# 默认用户名/密码: nacos/nacos
# 登录后修改密码，并更新到 .env 文件中的 NACOS_AUTH_PASSWORD
```

#### 3. 初始化 APISIX 配置
```powershell
# 初始化 APISIX config.yaml 并填充敏感信息
.\script\init_config.ps1
```

#### 4. 启动所有服务
```powershell
# 启动 etcd + Nacos + APISIX
docker-compose up -d

# 查看服务状态
docker-compose ps
```

#### 5. 配置 API 路由（使用智能认证）
```powershell
# 配置使用 jwks-smart-auth 插件的路由
.\script\setup_smart_auth.ps1
```

#### 6. 测试验证
```powershell
# 运行完整测试套件
.\script\test_smart_auth.ps1
```

## 架构组件

### 核心服务
- **APISIX** (端口 9080/9180/9443): API 网关 + JWKS Smart Auth 插件
- **Nacos** (端口 8848): 服务发现和配置管理
- **etcd** (端口 2379): 键值存储，APISIX 配置后端

### 自定义插件
- **jwks-smart-auth**: 智能 JWT 验证插件
  - 位置: `apisix/plugin/jwks-auth.lua`
  - 优先级: 2549
  - 文档: [插件详细说明](apisix/plugin/README.md)

## API 访问模式

### 认证流程
```
客户端 → APISIX (jwks-auth) → 后端服务
         ↓
      验证 JWT (kid 匹配)
         ↓
      检查 audience/issuer
         ↓
      通过/拒绝
```

### 路由规则

### 路由规则

所有微服务通过统一的 API 网关访问：

**业务服务（需要认证）:**
- 外部访问：`http://localhost:9080/api/{service}/{path}`
- 认证方式：Bearer Token (`Authorization: Bearer <JWT>`)
- 内部重写：`/{path}` （去除 `/api/{service}` 前缀）

**Auth 服务公开端点（无需认证）:**
- `GET /api/.well-known/jwks.json` → JWKS 公钥集
- `POST /api/password/*` → 密码重置
- `POST /api/registration/*` → 用户注册

## 🔐 JWT 认证说明

### Token 格式

```json
{
  "header": {
    "alg": "RS256",
    "typ": "JWT",
    "kid": "1759641511032_657000_26WqBZ1yAM"  // 密钥标识
  },
  "payload": {
    "sub": "abc123",           // Base62 编码的用户ID
    "iss": "auth",             // 签发者
    "aud": ["linx", "audit"],  // 受众服务列表
    "exp": 1672531200,         // 过期时间
    "iat": 1672527600,         // 签发时间
    "jti": "unique-token-id",  // Token 唯一ID
    "userId": 123,             // 用户ID（业务友好）
    "role": "user",            // 用户角色
    "scope": ["read", "write"] // 权限域
  }
}
```

### 密钥轮换机制

后端 `JwtUtil` 维护双密钥:
- **currentSigningKey**: 当前用于签发 Token
- **nextSigningKey**: 预备密钥（下一轮提升为 current）

网关 `jwks-smart-auth` 缓存策略:
- **second_latest_kid**: 对应 currentSigningKey
- **latest_kid**: 对应 nextSigningKey（触发器）

**触发条件**: 当 Token 使用 `latest_kid` 时，网关异步预加载下一轮 JWKS

## 📚 文档

- [部署指南](DEPLOYMENT.md) - 详细部署步骤和故障排查
- [插件文档](apisix/plugin/README.md) - JWKS Auth 插件说明

## ⚠️ 注意事项

1. **环境变量**: 所有敏感信息（API keys, 密码）必须通过 `.env` 文件管理
2. **密钥轮换**: 确保后端配置 `jwt.key.rotation.enabled=true`

## 🛠️ 故障排查

### 问题：插件未加载
```powershell
# 检查插件文件
docker exec apisix ls -la /usr/local/apisix/apisix/plugins/jwks-auth.lua

# 查看错误日志
docker logs apisix 2>&1 | Select-String "error"

# 重启 APISIX
docker-compose restart apisix
```

## 📄 许可证

MIT License

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

### 认证
- JWT 认证（RS256 算法）
- JWKS 端点：`/api/.well-known/jwks.json`
- Auth 服务特殊路径无需认证：`/.well-known/*`、`/password/*`、`/registration/*`

## 管理界面

- **APISIX Dashboard**: http://localhost:9180/ui/ #注意: admin key 在 .env 文件中已经同步到config.yaml
- **Nacos Console**: http://localhost:8080

## 安全注意事项

- 所有敏感配置存储在 `.env` 文件中
- 不要将 `.env` 文件提交到版本控制
- API 密钥通过环境变量管理，避免硬编码

## 目录结构

```
├── apisix/           # APISIX 配置和日志
├── nacos/            # Nacos 数据和日志
├── etcd/             # etcd 数据
├── script/           # 管理脚本
│   ├── init_config.ps1   # APISIX 配置初始化
│   ├── setup_env.ps1     # 环境初始化
│   └── setup_routes.ps1  # 路由配置
├── docker-compose.yml    # 服务编排
└── .env              # 环境变量（自动生成）
```