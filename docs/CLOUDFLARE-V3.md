# Cloudflare v3 首批契约与实施边界

输入方案从第 5 节中段开始，未提供第 1–4 节和完整的 5.1 / 5.2。本提交仅建立可执行的协议基础与开发日志服务，以下新增约定在完整操作格式、迁移和性能测量完成前均不视为生产协议冻结。v1 / v2 的完整状态模型继续用于旧本机恢复，与 v3 类型分离。

## 库、整数与认证

本机逻辑库身份为 `(provider=cloudflare-v3, serviceID, vaultID)`。后两者及 epoch、批次 ID 使用规范小写 UUID；地址和令牌不参与身份。epoch 标识恢复轮次。所有线上的计数器和 revision 为 JSON 安全整数 `0...9,007,199,254,740,991`，操作 dot 从 1 开始。

每台设备使用独立 32 字节安全随机令牌的无填充 base64url 字符串，以 `Authorization: Bearer ...` 传入，D1 只存令牌字符串的 SHA-256。当前没有匿名 bootstrap、配对、设备管理或生产初始化入口。测试在隔离本地 D1 中种入固定假设备；这些固定身份和令牌不得用于生产。内容恢复密钥不发送给 Worker。

## 加密与摘要

AES-256-GCM 的冻结字节为 `12-byte nonce || ciphertext || 16-byte tag`，以标准有填充 base64 放入 `ciphertext` 字段。AAD 是以下 UTF-8 行，以 LF 连接，最后一行可以为空，不另附结束 LF：

```text
PindoSync/v3
<serviceID>
<vaultID>
<epoch>
<batch|checkpoint|chunk>
<objectID>
<以逗号连接的 artifact SHA-256 列表>
```

artifact 摘要只接受 64 位小写十六进制，必须升序、无重复，最多 50 个。日志核心首批仅接受没有 artifact 引用的普通批次；其他请求明确返回 `unsupported_feature`。普通密文上限 128 KiB（含 nonce 和 tag）；chunk 密文预算 64 KiB。普通操作最多 50 个是后续操作契约的预算，Worker 无法从密文确认操作数量，必须由客户端验证。未完成 artifact 发布事务前，不支持通过拆包暴露领域动作的中间状态。

回执摘要是 `SHA256(AAD || 0x00 || combinedCiphertext)`。Worker 计算该摘要以绑定身份、批次及外部引用，不接收客户端自报摘要作为事实。客户端必须在应用前核对摘要、AAD、AEAD、操作格式和外部清单；服务端无法验证 CRDT 明文。固定密钥和 nonce 只存在于共享测试向量 `sync-vectors/v3-contract.json`，产品加密使用平台安全随机 nonce。

## 开发 API

共同前缀 `/v3/vaults/<vaultID>`，除鉴权头以外不通过 URL 传递秘密。响应禁用缓存，不包含服务端异常正文。

| 请求 | 内容 / 结果 |
| --- | --- |
| `GET /`、`GET /health`（无需库前缀） | 检查必需的 D1 schema，返回服务状态及 `clientSyncAvailable:false`，不返回令牌 |
| `GET /info` | `version, serviceID, vaultID, epoch, head, gcFloor, capabilities` |
| `POST /push` | JSON `{version:3, epoch, batchID, ciphertext, artifactIDs?:[]}`；返回绑定库 / epoch 的 `{receipt:{batchID, revision, digest}}` |
| `GET /receipts/<batchID>?epoch=...` | 查询原回执；不存在返回 `not_found`，不根据本机状态推测成功 |
| `GET /pull?epoch=...&after=...` | 一致返回 `head, gcFloor, commits, nextCursor, hasMore`；每页最多 8 批 |

push 回执没有 `nextCursor`。收到回执只允许确认对应冻结 outbox 字节；只有本机事务成功应用一页全部内容，才能持久推进 pull 游标。这一客户端事务尚待 P2 / P4 实现，不能用当前 JSON 全库快照同步引擎模拟。

错误区分 `authentication_required, unsupported_version, epoch_mismatch, batch_conflict, checkpoint_required, corrupt_data, quota_unavailable, storage_unavailable, maintenance, invalid_request, cursor_mismatch, not_found, unsupported_feature`。认证 401；未知版本 426；epoch / 批次 / 游标 / 检查点冲突 409；暂时无法使用 503。旧游标的检查点恢复接口尚未实现，首批服务不可执行真正 GC。

## D1 提交与读取

一个 `batch()` 中条件插入 `head+1` 的 commit，按批次身份选中前步结果写回执，再依该 commit 推进独立 counter，最后读取授权状态和回执。不动态复用 `RETURNING` 结果，不使用 `FOR UPDATE`，不以 `MAX(revision)` 推算 head。撤销、epoch、维护状态和预算在写入 SQL 内检查。相同 ID 与相同摘要返回原回执，摘要不同返回冲突，响应丢失后重试不重复收费或分配 revision。

约束失败由 D1 回滚整批，未知数据库错误返回 `storage_unavailable`，不会误当作幂等成功。当前 D1 的串行事务加条件插入避免了预先分配 revision 的竞争；没有泛化吞掉唯一约束的重试逻辑。pull 元数据和页面在同一主库 batch 中读取，授权也在该 batch 中复查，发现日志缺口时拒绝返回可推进的游标。

开发预算默认最多 1,000 批、16 MiB 保守计费预算，每批计 `base64长度+2048` 字节，以预留元数据和索引空间。这不是 D1 实际磁盘用量，也不是容量实测结论。实际 D1 `rows_read / rows_written` 随请求输出结构化日志，不记录 token、密文和恢复密钥。未完成 P5 前到达预算会停止追加，不靠无限日志运行。

## 备注因果参考与后续工作

v3 备注参考寄存器使用该记录备注实际观察到的 dot 集合，绝不从全局标题 / 字段时钟推导。观察移除集合持久保留，即使被替代的旧写入尚未到达，也不会在乱序到达时复活。空备注属于真实版本；同 dot 的文字或 observed 上下文不同会报损坏；合并错误不留下半修改。这个参考寄存器尚未接入领域投影和本机持久存储，dot 集合的容量策略仍待完整 P0 / P1 冻结。旧 v2 向量和升级测试继续保留原 stamp、墓碑与 legacy 语义，不把旧历史重新打时间戳。

后续依次完成：完整字段操作与原子领域批次；SQLite 权威存储及可恢复 JSON 迁移；一次性配对、撤销 / 轮换及 artifact；双端连接事务与独立 ACK / 游标；两个保留检查点、CAS 发布、租约、GC 和 epoch 恢复；专用真云和多设备验收。P2 / P4 / P5 未完成前不得开放客户端连接或生产发布。独立 staging 可用于服务器联调，必须使用与本地向量和未来生产不同的服务身份 / D1；配置记录在 `backend/cloudflare/deployments/staging.json`。

官方依据：[D1 batch 与 session](https://developers.cloudflare.com/d1/worker-api/d1-database/)、[D1 limits](https://developers.cloudflare.com/d1/platform/limits/)、[Workers limits](https://developers.cloudflare.com/workers/platform/limits/)。本地 workerd 成功不代表部署 CPU 达到 10 ms 预算。
