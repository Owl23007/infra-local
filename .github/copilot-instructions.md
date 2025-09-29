# infra-local 项目 AI 编码助手指南

## 架构概览

这是一个基于微服务架构的本地开发基础设施项目，核心组件包括：

- **Apache APISIX**: API 网关（端口 9080/9443/9180），负责路由、认证和代理重写
- **Nacos**: 服务发现和配置管理（端口 8848），使用独立模式运行
- **etcd**: 键值存储（端口 2379），用于 APISIX 配置存储

## 关键服务和路由模式

系统支持以下微服务：`linx`、`synapse`、`audit`、`auth`

### API 路由规范
- 客户端访问：`/api/{service}/*` 
- 内部重写：`/{path}` （去除 `/api/{service}` 前缀）
- 认证：除 auth 服务外，所有服务都启用 JWT 认证（RS256 算法）

### 特殊路径处理（auth 服务）
- `/.well-known/*`、`/password/*`、`/registration/*` 
- 这些路径通过 `/api` 前缀暴露但直接重写为原路径

## 开发工作流

### 环境设置
```powershell
.\script\setup_env.ps1  # 生成 .env 文件和密钥
docker-compose up -d    # 启动基础设施
.\script\setup_routes.ps1  # 配置 API 路由
```

### 配置管理
- **敏感信息**: 使用 `.env` 文件，never hardcode（如 API keys）
- **APISIX 配置**: `apisix/config/config.yaml`
- **服务发现**: Nacos DEFAULT_GROUP，空 namespace

## 安全约定

### API 密钥管理
- APISIX admin API key 应从环境变量读取，不应硬编码在脚本中
- JWT 认证使用 RS256 算法，JWKS 端点：`/api/.well-known/jwks.json`

### 认证流程
- 所有业务服务（除 auth）都需要 JWT 认证
- Auth 服务负责用户认证和 JWT 签发
- 使用 `auth-service` 作为 JWT key 标识

## 关键文件和目录

- `docker-compose.yml`: 基础设施定义
- `script/setup_routes.ps1`: 路由配置脚本（需要重构以使用环境变量）
- `script/setup_env.ps1`: 环境初始化脚本
- `apisix/config/config.yaml`: APISIX 主配置
- `.env`: 环境变量文件（git ignored）

## 调试和监控

- **APISIX 管理界面**: http://localhost:9180
- **Nacos 控制台**: http://localhost:8848
- **日志位置**: `nacos/logs/`, `apisix/logs/`

## 代码规范

### PowerShell 脚本
- 使用 `Write-Host` 输出操作状态
- API 调用使用 `Invoke-WebRequest` 
- JSON 转换使用 `ConvertTo-Json -Depth 5`
- 路由 ID 命名：`{service}-route` 或 `{service}-api-special-{path}`

### Docker 配置
- 使用命名容器便于管理
- 挂载卷用于持久化数据和日志
- 依赖关系通过 `depends_on` 声明