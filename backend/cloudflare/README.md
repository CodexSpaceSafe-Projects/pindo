# Pindo Cloudflare v3：开发日志核心

当前交付包含协议原语、D1 schema、Worker 日志接口与本地运行时测试。支持独立 staging 部署；本地测试没有真实云账号依赖，桌面和 Android 客户端尚未连接此服务。完整协议与后续清单见 [CLOUDFLARE-V3.md](../../docs/CLOUDFLARE-V3.md)。

## 验证

Node 22+，使用锁定依赖：

```sh
cd backend/cloudflare
npm ci
npm run types
npm run typecheck
npm test
```

`npm test` 在 `work/` 生成 Worker 测试 bundle，用 Miniflare 启动真实 workerd / 本地 D1 SQLite 并自动应用 migration，在每个测试前重建隔离的假库和设备。测试不访问 Cloudflare 账号。运行时测试覆盖提交、幂等、相同 ID 的摘要冲突、并发 revision、撤销后的 SQL 条件校验、事务后步失败回滚、epoch / 维护 / 预算错误、分页、日志缺口、模拟 GC 后独立 head / 保留回执及共享加密向量。

CLI 固定为 `cf@1.0.0-beta.32`，配置为 `cloudflare.config.ts`，本地模式为 `development`，独立线上测试模式为 `staging`，生产模式仍直接拒绝。部署兼容日期为 2026-11-14；锁定的 Miniflare 4.20260730.0 本地运行时目前只支持到 2026-07-30，因此测试单独固定为该日期。后续发布前必须升级本地运行时并在部署兼容日期重跑，再进行专用 D1 真云验证；本地通过不替代此项。

## 运维边界

- 本批不提供 bootstrap / pairing HTTP 接口，绝不开放匿名建库。开发测试通过本地 D1 fixtures 创建假身份。真实初始化必须等到独立 bootstrap 秘密、一次性配对与设备注册事务完成。
- 本地配置使用固定假身份；`deployments/staging.json` 记录线上测试库的独立稳定身份。未来生产必须使用新的稳定 serviceID 和独立 D1，测试与生产不能共用。令牌、管理秘密和内容密钥不进入配置、仓库、日志或应用包。
- 使用 D1 binding，不启用读复制。所有成功回执来自提交完成后的结果；pull 的 metadata / page 同批读取。未来启用复制前增加 session / bookmark 和游标不回退测试。
- 当前 `batch_budget=1000`、`byte_budget=16 MiB` 只是开发硬门槛。保守记账为每批 base64 长度加 2048 字节，保留元数据和索引余量，不代替真实 D1 磁盘测量。接近预算停止追加，不能通过删回执、归零 counter 或提高预算绕过恢复设计。
- 不运行真正 GC，不修改服务 epoch，不将模拟测试中的直接 SQL 删除用于真实库。首次发布前必须实现分块完整性、两个可恢复检查点、CAS、读取 / 上传租约、日志与 artifact 回收和旧游标恢复。
- D1 恢复必须先维护停写，轮换 epoch 后客户端重基；不能回滚 counter 后继续确认旧请求。应用正常备份独立保留。
- 日志仅输出 route、实际 D1 rows_read / rows_written 和不含正文的故障事件。启用 Workers Logs 和 Traces，查询串脱敏。日志数据仍按账号的保留和额度策略管理。
- 本地测试尚未测量 Worker CPU、实际 D1 存储、设备 I/O 或恢复时间，不能宣称达到 Free 的 10 ms CPU 容量目标。

## 通过 Cloudflare 插件部署 staging

部署资源与 URL 在 `deployments/staging.json` 中版本化保存；该文件只包含非秘密配置。线上入口为 `https://pindo-sync-v3-staging.zhchain.workers.dev`，`GET /` 与 `GET /health` 返回健康状态及 `clientSyncAvailable:false`，资料 API 仍要求每设备令牌。

1. 运行本地测试，提交 backend 改动，再执行 `npm run build:staging`。脚本只打包并在仓库 `work/cloudflare-staging/` 生成 `worker.mjs`、Cloudflare API `metadata.json` 和带源提交 / SHA-256 的 `build.json`，不会创建资源或发布。存在未提交的 backend 修改时拒绝构建。
2. 通过 Cloudflare 插件确认账号和资源。在新的独立 D1 应用 `migrations/0001_log_core.sql`，随后记录 `pindo_migrations` 的文件名与摘要。已有 schema 先检查迁移账本，不重复执行非幂等 DDL。
3. 使用插件的 Worker multipart 上传 API，上传同一构建的源码和 metadata，并启用该 Worker 的 workers.dev 路由。metadata 启用日志、追踪和查询串脱敏；不修改账号计费方案，也不启用 R2。
4. 从线上检查健康接口、未授权 401，以及一次性随机测试库 / 设备下的 push、回执、重复提交、冲突、pull、epoch 和撤销。测试令牌只在执行期间存在，不进入文件、仓库和输出；结束后撤销并清理仅属于本轮测试的记录。
5. 从 Cloudflare API 读回版本、绑定和迁移账本，核对源提交与 bundle SHA-256。检查结果由本次部署记录说明。

staging 仅供开发联调，保留 1,000 批 / 16 MiB 的停止门槛，未开放匿名建库。P2 / P4 / P5 完成并通过专用测试库与实机验证后才能增加正式生产发布流程；部署 staging 不代表客户端已经可用。
