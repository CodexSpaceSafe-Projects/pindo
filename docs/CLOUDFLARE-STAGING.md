# Cloudflare 线上测试服务

部署地址：<https://pindo-sync-v3-staging.zhchain.workers.dev>。这是 v3 开发日志核心的 staging 部署；客户端仍未接入，生产模式继续关闭。可用资料接口为带设备鉴权的 info、push、pull、receipts，尚不包含配对、artifact、检查点和 GC。

## 资源与来源

| 项目 | 值 |
| --- | --- |
| Worker | `pindo-sync-v3-staging` |
| D1 | `pindo-sync-v3-staging`，WEUR，读复制关闭 |
| 数据库 ID | `5bb85b98-3ec9-46fd-8736-8ae585f7c172` |
| 稳定 serviceID | `4aca4b5f-31da-45b3-9f79-c897ac1d63a7` |
| 部署兼容日期 | `2026-11-14` |
| 首次构建源提交 | `8a4ffc511b79c5030daba03ff0c0b447dec7eaac` |
| Worker bundle SHA-256 | `081de59436033881ce6f8aad4a3c6aa0940d4782d30d9148d8d9a0b6c69cfbb4` |
| 初始 migration SHA-256 | `61c11e17e327cc405b4e3a1ea82bd39fdd45a2e7e93db2dbae6534c0dcb0e662` |

Cloudflare 插件已创建独立 D1、应用并读回 `0001_log_core.sql` 迁移账本，上传 Worker，并开启该 Worker 的 workers.dev 路由。已通过 API 读回确认部署版本分配 100%、D1 binding、服务身份、兼容日期和日志 / 追踪配置。已有其他 Worker 和数据库未修改，也未更改账号计费方案或启用 R2。

后续部署的实际源提交与 bundle 摘要在 Worker settings 的 `workers/message` annotation 中；当前发布版本通过 Worker deployments API 读回核对。稳定服务身份和数据库 ID 不随路由、令牌或代码发布更换。

## 验证范围

13 项本地 workerd / D1 测试通过。仓库 CI 的 `Test Cloudflare sync core / staging-smoke` 从普通 GitHub runner 检查 `/health`、`/` 返回 200，匹配 serviceID 和 `clientSyncAvailable:false`，并确认无设备令牌访问资料 API 返回 401。结果以对应提交的 CI 为准，不能把 Cloudflare API 上传成功当作这些 HTTP 检查已经通过。

当前聊天执行环境与 Cloudflare 插件的直接 fetch 都拒绝访问此 workers.dev 域名，因此未从聊天直接完成带随机设备令牌的线上 push / pull / 回执 / 撤销验收。没有为此创建公开令牌或测试用永久设备。实际设备联调、配对和完整恢复仍待后续阶段完成。

## 操作边界

- 本次没有创建用户资料库或可连接的用户设备；HTTP 不提供匿名 bootstrap。后续初始化须通过独立受保护的管理流程。
- `/health` 仅验证 D1 四张业务表能被查询，不返回令牌或用户资料。它不代表双端同步已就绪。
- 开发预算仍为每库 1,000 批 / 16 MiB，达到门槛停止写入。不要删除回执或重置 counter 来延长运行。
- 不运行真实 GC；D1 恢复必须维护停写并轮换 epoch。P2 / P4 / P5 完成前不发布生产客户端同步。
