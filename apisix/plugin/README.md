## jwks-auth 插件说明

`jwks-auth.lua` 是为 Apache APISIX 网关设计的自定义 JWT 认证插件，支持通过远程 JWKS（JSON Web Key Set）自动拉取和缓存 RSA 公钥，实现高安全性和密钥轮换友好的 JWT 校验。

### 功能特性
- 支持 RS256 算法的 JWT 验证，自动从 JWKS URL 拉取公钥
- kid 时间戳排序，自动识别最新/次新密钥，兼容密钥轮换场景
- 缓存 JWKS，自动预加载新密钥，提升性能和安全性
- 支持校验 JWT 的 `issuer` 和 `audience` 字段
- 校验通过后自动将 payload 注入下游 ctx

### 配置参数
| 参数名      | 类型     | 必填 | 说明 |
| ----------- | -------- | ---- | ---- |
| jwks_uri    | string   | 是   | JWKS 公钥集的远程 URL |
| issuer      | string   | 否   | JWT 期望的签发方（iss）|
| audiences   | array    | 否   | 允许的 audience 列表 |

#### 示例配置
```json
{
	"jwks_uri": "https://auth.example.com/.well-known/jwks.json",
	"issuer": "auth-service",
	"audiences": ["linx", "synapse"]
}
```

### 路由绑定示例
在 APISIX 路由配置中添加插件：
```yaml
plugins:
	- name: jwks-auth
		enable: true
		config:
			jwks_uri: "https://auth.example.com/.well-known/jwks.json"
			issuer: "auth-service"
			audiences:
				- "linx"
				- "synapse"
```

### 使用场景
- 微服务网关统一 JWT 认证，支持密钥自动轮换
- 需要与外部认证服务（如 Auth0、Keycloak、自建 OIDC）集成的场景
- 业务服务间安全通信，防止伪造 Token

### 注意事项
- JWKS URL 必须可公网访问，且返回标准 JWK 格式
- kid 推荐采用 `时间戳_标识` 格式，便于插件自动识别最新密钥
- 插件仅支持 RS256 算法，不支持对称密钥
- 若 JWT 校验失败，将返回 401 并附带错误信息
- 建议结合 APISIX 路由配置，实现不同服务的独立认证策略

### 调试与日志
- 插件会在 APISIX 日志中输出 JWKS 拉取、密钥缓存、校验结果等信息
- 可通过 APISIX 管理界面或日志文件排查认证问题

---
如需扩展或定制，请参考 `jwks-auth.lua` 源码注释。
