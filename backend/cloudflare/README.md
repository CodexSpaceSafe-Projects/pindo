# Cloudflare encrypted sync v3

Workers + D1 提供设备配对、每设备凭据、不可变密文分块、顺序日志、永久轻量回执、检查点 CAS、读取租约和分批 GC。内容和恢复密钥仅存在客户端；服务端只见密文及必要元数据。macOS 和 Android 使用同一协议与 SQLite 持久化队列。

```
npm ci
npm run types
npm run typecheck
npm test
# 提交 backend 后：
npm run build:staging
```

部署包在 `work/cloudflare-staging/`，CI 上传同名服务端构建产物。`metadata.json` 继承已安装的 `BOOTSTRAP_SECRET` / `RECOVERY_SECRET`，不包含密钥。首次部署必须通过 Cloudflare Secrets API 独立设置两个随机密钥，然后上传 bundle 并应用按名称及 SHA-256 登记的 migrations。已有库不可重复执行 ALTER TABLE。默认库容量预算 64 MiB，保留日志最多 1000 批；不启用 R2 或付费计划。

首次客户端使用服务地址和初始化密钥创建库；服务在同一 D1 事务内关闭后续 bootstrap。客户端生成自己的恢复密钥、设备 token 和密钥验证探针，先持久化待连接凭据，再注册、校验探针和提交本地库绑定。以后从已连接设备生成 10 分钟一次性配对信息。配对信息包含客户端恢复密钥，应仅在自己的设备之间传递。

暂停同步仍记录离线 outbox。上传冻结确切字节后重试；ACK 不推进下载游标。下载持久化 inbox 后按创建依赖应用，单独维护 fetched / applied 游标。大批量动作与大备注作为不可变分块和认证 manifest 原子应用。字段 LWW、生命周期原子、备注按记录保存因果 MV 寄存器；保留删除墓碑。

检查点只覆盖已应用连续前缀，分块上传后逐块读回，CAS 发布并读取验证。保留两个检查点及所需尾日志；读取租约阻止 GC 越过使用中的前缀。日志回执、墓碑和备注因果上下文不按 TTL 删除。管理员恢复必须先维护模式，再通过独立恢复密钥切换 epoch；客户端保留旧冻结队列，恢复旧前缀并在新 epoch 显式重建基线。

`POST /v3/admin/maintenance` body `{vaultID, enabled: true}`；`POST /v3/admin/recover` body `{vaultID, epoch: 新UUID}`，均使用恢复密钥作为 Bearer。D1 时间点恢复后也必须切换 epoch，避免历史回执混用。

线上地址见 `deployments/staging.json`。本地 Miniflare 锁定版本仅支持 2026-07-30，云部署兼容日期 2026-11-14；本地验证和线上验证在交付中分别记录。`test/http-server.mjs` 只绑定 loopback，使用公开测试凭据，供 CryptoKit / Java AES-GCM 客户端互通测试，不能部署到公网。
