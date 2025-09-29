# infra-local

本地开发基础设施项目，基于 Apache APISIX、Nacos 和 etcd 构建微服务架构。

## 快速开始

### 1. 环境初始化
```powershell
# 生成环境变量配置文件和密钥
.\script\setup_env.ps1
```

### 2. 启动基础设施
```powershell
# 启动所有服务
docker-compose up -d

# 查看服务状态
docker-compose ps
```

### 3. 初始化 APISIX 配置
```powershell
# 初始化 APISIX config.yaml 并填充敏感信息
.\script\init_config.ps1
```

### 4. 配置 API 路由
```powershell
# 配置路由（脚本会自动从 .env 文件读取 APISIX_ADMIN_KEY）
.\script\setup_routes.ps1
```

## 架构组件

### 核心服务
- **APISIX** (端口 9080/9443/9180): API 网关
- **Nacos** (端口 8848): 服务发现和配置管理
- **etcd** (端口 2379): 键值存储

### 微服务
支持的微服务：`linx`、`synapse`、`audit`、`auth`

## API 访问模式

所有微服务通过统一的 API 网关访问：
- 外部访问：`http://localhost:9080/api/{service}/{path}`
- 内部重写：`/{path}`

### 认证
- JWT 认证（RS256 算法）
- JWKS 端点：`/api/.well-known/jwks.json`
- Auth 服务特殊路径无需认证：`/.well-known/*`、`/password/*`、`/registration/*`

## 管理界面

- **APISIX Dashboard**: http://localhost:9180
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