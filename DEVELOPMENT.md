# 开发说明

## 结构与数据

`Sources/PindoCore/` 负责模型、层级、快照、SQLite 和同步；`Sources/Pindo/` 负责 SwiftUI / AppKit 界面。Android 使用 Kotlin / Compose；`backend/cloudflare/` 提供 Workers / D1 服务。两端遵守同一当前协议，跨端样本位于 `sync-vectors/`。

SQLite 是本机资料权威：可见内容、同步状态、发件箱和快照归档保存在同一数据库。标题编辑不重写未修改备注或整个归档。导入与恢复先保护当前资料，再将目标内容与归档一同事务提交，失败整体回滚。损坏资料不得自动清空；损坏归档保留并提示，但不阻止有效当前资料保存。普通导出格式为 `{version:1,tasks,groups}`，不含本机偏好、凭据或同步队列；导入保留本机偏好，快照恢复可还原快照中的偏好。

事项最多三级。移动、删除、批量状态变更共用领域规则，校验循环、深度及完成状态；删除包含整棵子树。筛选结果中的父级上下文不参与批量全选。本机语言、字体、主题和窗口设置不进入云端。

## 原生交互

macOS 面板使用非激活、可调整尺寸的原生窗口；置顶控制隐藏与 Spaces 行为，清单通过原生 NSOutlineView 处理层级与拖动。状态栏、全局热键、焦点和多屏行为需要实机验收。

备注集成固定版本 SwiftMarkdownEngine，由引擎管理 TextKit 2、选区、撤销和 text-view delegate。不要访问 `layoutManager` 或接管 delegate。保存状态变化不重建编辑器；关闭前结束组词并同步提交。输入法预编辑不保存，外部文字或字体更新等组词结束后应用；预编辑内只补字体，保留输入法属性、字符及选区。间距与字体在同一编辑事务内计算，只写差异，不改变原文、选区或撤销栈。

应用文案同步维护中英文资源，第三方编辑器许可随包附带。音效离线打包，每次成功操作按需播放并释放。

## 同步与服务端

客户端使用 AES-256-GCM 和系统安全随机数，密钥及设备凭据进入 Keychain / Keystore。服务端只保存密文和必要元数据。库身份由稳定的 `serviceID`、`vaultID` 确定，地址和令牌不作为库身份。字段使用逻辑时钟，生命周期原子更新，备注保留因果并发版本，删除保留墓碑。

本地操作与持久发件箱一同提交；重试复用冻结的字节，回执不推进下载游标。下载先持久化再原子应用，分别维护 fetched / applied 游标。大操作通过不可变分块和认证清单整体应用。检查点只覆盖已应用连续前缀，发布前验证分块，保留两个检查点及所需尾日志；读取租约阻止过早回收。回执、墓碑和备注因果上下文不得按 TTL 删除。

服务端是 TypeScript Worker，通过 D1 binding `DB` 访问数据库；运行于 Cloudflare Workers，Node.js 22 仅用于构建和测试。D1 共 12 张表，保存资料库与设备身份、令牌哈希、密文日志、回执、分块、检查点、配对和读取租约。任务业务规则、解密与冲突合并在客户端执行；当前没有 R2、Durable Objects、WebSocket 或后台 Cron。

入口为 [`src/index.ts`](backend/cloudflare/src/index.ts)；[`src/v3/devices.ts`](backend/cloudflare/src/v3/devices.ts) 负责建库、配对和设备管理，[`src/v3/history.ts`](backend/cloudflare/src/v3/history.ts) 负责分块、检查点、租约和 GC。HTTP API 包括 `/health`、`/v3/bootstrap`，以及 `/v3/vaults/<vaultID>/` 下的 `info`、`push`、`pull`、`receipts/<batchID>`、`pairings`、`devices`、`artifacts/<digest>`、`checkpoints`、`leases/<id>` 和 `gc`。

每个服务仅允许首次创建一个资料库，适合个人部署后连接多台设备，尚无多用户注册。首次设备以 `BOOTSTRAP_SECRET` 建库；已有设备生成 10 分钟有效的一次性邀请供新设备加入。设备使用独立 Bearer token，D1 保存其 SHA-256 哈希，支持撤销与轮换。端到端数据加密密钥只在客户端持有。设备列表返回可读名称并标记本机；注册可带 `deviceName`，`POST devices/<自己的ID>/name` 传 `{epoch,name}` 修改本机名称。名称是共享的设备管理元数据，不进入待办密文或本机导出；重试注册不会覆盖已更名设备。

## Cloudflare 部署

配置入口为 [`backend/cloudflare/cloudflare.config.ts`](backend/cloudflare/cloudflare.config.ts)，使用锁定版本的 Cloudflare CLI `cf` 生成类型，不使用 Wrangler 配置。公开仓库仅保存[虚构示例](backend/cloudflare/deployments/staging.example.json)，真实配置保存为 Git 忽略的 `backend/cloudflare/deployments/staging.local.json`。开发、类型生成、测试和通用构建无需该私有文件；只有本机 `staging` 配置及私有部署打包会读取它。个人网址、账号、数据库和服务标识不得写入源码、文档或公开附件。

发布包由 esbuild 脚本读取本地配置生成，再通过 Workers API 上传。项目尚未安装 `cf deploy` 所需的默认构建实现，不能直接用 `npx cf deploy` 发布，也不能把本项目的包传给 `cf deploy --prebuilt`。若增加正式环境，应先加入独立本地配置、数据库和 Secret。

### 首次部署

1. 在 Cloudflare 控制台创建空 D1 数据库，进入该数据库的 Console，依次执行 [0001_schema.sql](backend/cloudflare/migrations/0001_schema.sql) 和 [0002_device_names.sql](backend/cloudflare/migrations/0002_device_names.sql)，各一次。已有数据库只执行尚未应用的增量迁移，不重跑完整初始化 schema。
2. 在 Workers & Pages 中创建 Worker，名称与下一步填写的 `workerName` 一致，先发布控制台的占位示例。在该 Worker 的 Settings → Variables and Secrets 中，将 `BOOTSTRAP_SECRET`、`RECOVERY_SECRET` 添加为 **Secret**，分别使用独立随机值。前者供首台设备初始化资料库；后者仅用于管理员维护与灾备，不是客户端的内容加密密钥。先建立 Worker 和 Secret，才能在后续上传时继承它们。
3. 在仓库根目录复制模板，再仅编辑本地副本，填写自己的 `accountId`、`workerName`、`databaseId`、`databaseName`、`endpoint` 和 `serviceID`：

   ```sh
   cp backend/cloudflare/deployments/staging.example.json backend/cloudflare/deployments/staging.local.json
   ```

   `staging.local.json` 已被 Git 忽略，不要强制加入版本控制。`serviceID` 使用新生成的 UUID，一旦建库便保持稳定；若改变域名，也要更新 `endpoint`。`endpoint`、`databaseRegion` 是本地记录，不会自动创建域名或改变数据库区域。
4. 使用 Node.js 22，在仓库根目录执行验证和打包：

   ```sh
   cd backend/cloudflare
   npm ci
   npm run types
   npm run typecheck
   npm test
   npm run build:staging
   ```

5. 准备有目标账号 **Workers Scripts Write** 权限的 API token，在终端中设置 `CLOUDFLARE_API_TOKEN` 环境变量；不要写进仓库。在上一步的 `backend/cloudflare/` 目录继续执行：

   ```sh
   cd ../..
   PINDO_CF_ACCOUNT_ID="$(node -p "require('./backend/cloudflare/deployments/staging.local.json').accountId")"
   PINDO_CF_WORKER_NAME="$(node -p "require('./backend/cloudflare/deployments/staging.local.json').workerName")"
   curl --fail-with-body --request PUT \
     "https://api.cloudflare.com/client/v4/accounts/${PINDO_CF_ACCOUNT_ID}/workers/scripts/${PINDO_CF_WORKER_NAME}?bindings_inherit=strict" \
     --header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
     --form 'metadata=@work/cloudflare-staging/metadata.json;type=application/json' \
     --form 'worker.mjs=@work/cloudflare-staging/worker.mjs;type=application/javascript+module'
   ```

   该请求上传并部署模块 Worker，同时绑定 D1 为 `DB`，设置 `SERVICE_ID`、`SYNC_ENABLED=true`，继承目标 Worker 已有的两个 Secret。`bindings_inherit=strict` 会在 Secret 缺失时拒绝上传，避免静默丢失绑定。确认响应 `success:true`；请求格式见 [Workers Upload Worker API](https://developers.cloudflare.com/api/resources/workers/subresources/scripts/methods/update/)。

6. 在 Worker 的 Domains & Routes 中确认 `workers.dev` 地址或配置自定义域名，与 `endpoint` 一致。检查 `<endpoint>/health` 返回 200、正确 `serviceID` 和同步能力；未带设备令牌访问资料 API 应返回 401。然后在首台客户端填写服务地址和 `BOOTSTRAP_SECRET` 建库，生成邀请让另一台设备加入，实际验证新增事项、备注修改和离线重连。公共健康检查不代表双端同步已验收。

### 更新已有服务与构建包

更新已有 Worker 时，保留原 D1、`serviceID` 和 Secret，按上面的步骤 4–6 重新验证、打包、上传并检查结果。不要重新执行初始化 SQL，也不要通过重置 `service_state.bootstrapped` 创建第二个资料库。

`npm run build:staging` 只把 `worker.mjs`、`metadata.json`、`build.json` 写到仓库根目录被忽略的 `work/cloudflare-staging/`，不执行部署。该包包含个人部署标识和端点，只在本机使用，不上传到 GitHub、Release 或 CI 附件。构建记录包含 `sourceRevision`、`sourceDirty` 和 bundle SHA-256；其中 metadata 继承目标 Worker 已有 Secret，首次部署不能仅靠该构建包创建 Secret。它是手动 API 上传用的包，不是 `cf deploy --prebuilt` 的 Build Output。

[服务端 CI](.github/workflows/cloudflare.yml) 无需个人配置，运行本地 Worker / D1 测试与 `npm run build:bundle`，只上传通用 `worker.mjs`、虚构配置示例和 SQL；**不访问个人线上服务，也不自动部署**。GitHub 构建成功、客户端 Release 发布或 `/health` 正常，都不表示最新源码已经上线。每次发布后应在自己的 Cloudflare 部署记录确认当前生效版本，并核对发布提交；手动上传构建包时还可核对 annotation 中的源码提交与 bundle 摘要。文档不记录个人部署地址或某次线上提交。

管理员恢复须先进入维护模式，再轮换 epoch：`POST /v3/admin/maintenance` 传 `{vaultID, enabled:true}`，`POST /v3/admin/recover` 传 `{vaultID, epoch:新UUID}`，使用服务端 `RECOVERY_SECRET` 作为 Bearer。D1 时间点恢复同样需要轮换 epoch；客户端保留未确认操作，恢复后重新提交。

已有数据库只需执行新增的 `0002_device_names.sql`（添加 `devices.name`），不可重跑完整 `0001_schema.sql`。现有设备在新版客户端打开设备管理时，仅对自己的空名称补上本机默认名；已有自定义名不会被覆盖。

## 验证

Swift 需要 5.9+；Linux 安装 SQLite 开发头文件，`swift test --jobs 4` 仅运行跨平台核心测试。macOS 同一命令还编译应用及运行原生测试；发布前运行 `PINDO_UNIVERSAL=1 bash scripts/build-app.sh`，检查通用包、资源、签名及启动。

Android：在 `android/` 运行 `./gradlew testDebugUnitTest lintDebug assembleDebug`，需要 JDK 17 / SDK 35。

服务端使用 Node.js 22，在 `backend/cloudflare/` 运行：

```sh
npm ci
npm run types
npm run typecheck
npm test
npm run build:bundle
```

跨端 HTTP 测试使用真实本地 Worker / D1。仓库根目录运行 `npm --prefix backend/cloudflare run build:test`，再启动 `node backend/cloudflare/test/http-server.mjs`；客户端测试设置 `PINDO_SYNC_TEST_ENDPOINT=http://127.0.0.1:8787`。CI 在同一 Worker 上验证 Swift 写入、Android 读取并写回、Swift 读取；具体阶段以 `.github/workflows/macos.yml` 为准。

中文字体回归按固定摘要下载测试字体，不能随应用打包：

```sh
bash scripts/prepare-macos-font-test.sh /tmp/pindo-fonts/SourceHanSerifSC-Regular.otf
PINDO_TEST_CJK_FONT_PATH=/tmp/pindo-fonts/SourceHanSerifSC-Regular.otf swift test --jobs 4 --filter SquirrelFontTests
```

三份工作流分别验证 macOS、Android、Worker；`main` 构建成功后自动发布客户端。验证结果以当前提交的 CI 为准。模拟运行时、协议测试、进程启动均不能代替真实设备上的中文组词、多屏、焦点、拖动和云同步验收。
