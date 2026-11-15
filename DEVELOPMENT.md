# 开发说明

## 结构与数据

`Sources/PindoCore/` 负责模型、层级、快照、SQLite 和同步；`Sources/Pindo/` 负责 SwiftUI / AppKit 界面。Android 使用 Kotlin / Compose；`backend/cloudflare/` 提供 Workers / D1 服务。两端遵守同一当前协议，跨端样本位于 `sync-vectors/`。

SQLite 是本机资料权威：可见内容、同步状态、发件箱和快照归档保存在同一数据库。标题编辑不重写未修改备注或整个归档。导入与恢复先保护当前资料，再将目标内容与归档一同事务提交，失败整体回滚。损坏资料不得自动清空；损坏归档保留并提示，但不阻止有效当前资料保存。普通导出格式为 `{version:1,tasks,groups}`，不含本机偏好、凭据或同步队列；导入保留本机偏好，快照恢复可还原快照中的偏好。

事项最多三级。移动、删除、批量状态变更共用领域规则，校验循环、深度及完成状态；删除包含整棵子树。筛选结果中的父级上下文不参与批量全选。本机语言、字体、主题和窗口设置不进入云端。

## 原生交互

macOS 面板使用非激活、可调整尺寸的原生窗口；置顶控制隐藏与 Spaces 行为，清单通过原生 NSOutlineView 处理层级与拖动。状态栏、全局热键、焦点和多屏行为需要实机验收。

备注集成固定版本 SwiftMarkdownEngine，由引擎管理 TextKit 2、选区、撤销和 text-view delegate。不要访问 `layoutManager` 或接管 delegate。保存状态变化不重建编辑器；关闭前结束组词并同步提交。输入法预编辑不保存，外部文字或字体更新等组词结束后应用；预编辑内只补字体，保留输入法属性、字符及选区。间距与字体在同一编辑事务内计算，只写差异，不改变原文、选区或撤销栈。

应用文案同步维护中英文资源，第三方编辑器许可随包附带。音效离线打包，每次成功操作按需播放并释放。

## 同步与部署

客户端使用 AES-256-GCM 和系统安全随机数，密钥及设备凭据进入 Keychain / Keystore。服务端只保存密文和必要元数据。库身份由稳定的 `serviceID`、`vaultID` 确定，地址和令牌不作为库身份。字段使用逻辑时钟，生命周期原子更新，备注保留因果并发版本，删除保留墓碑。

本地操作与持久发件箱一同提交；重试复用冻结的字节，回执不推进下载游标。下载先持久化再原子应用，分别维护 fetched / applied 游标。大操作通过不可变分块和认证清单整体应用。检查点只覆盖已应用连续前缀，发布前验证分块，保留两个检查点及所需尾日志；读取租约阻止过早回收。回执、墓碑和备注因果上下文不得按 TTL 删除。

Cloudflare 资源标识与服务地址以 `backend/cloudflare/deployments/staging.json` 为准，部署配置为 `cloudflare.config.ts`。全新 D1 使用 `migrations/0001_schema.sql` 初始化，不能把该完整 schema 当增量套用到已有数据库。服务要求独立的 `BOOTSTRAP_SECRET` 和 `RECOVERY_SECRET` secret bindings；首次客户端使用初始化密钥创建库，其他设备通过 10 分钟一次性配对加入。生成包不含密钥，输出到忽略的 `work/cloudflare-staging/`，记录源码提交、未提交状态和 bundle 摘要。禁止提交凭据或将本地测试服务器部署到公网。

管理员恢复须先进入维护模式，再轮换 epoch：`POST /v3/admin/maintenance` 传 `{vaultID, enabled:true}`，`POST /v3/admin/recover` 传 `{vaultID, epoch:新UUID}`，使用恢复密钥作为 Bearer。D1 时间点恢复同样需要轮换 epoch；客户端保留未确认操作，恢复后重新提交。公共 `/health` 只证明服务健康，不证明客户端同步正确。

## 验证

Swift 需要 5.9+；Linux 安装 SQLite 开发头文件，`swift test --jobs 4` 仅运行跨平台核心测试。macOS 同一命令还编译应用及运行原生测试；发布前运行 `PINDO_UNIVERSAL=1 bash scripts/build-app.sh`，检查通用包、资源、签名及启动。

Android：在 `android/` 运行 `./gradlew testDebugUnitTest lintDebug assembleDebug`，需要 JDK 17 / SDK 35。

服务端使用 Node.js 22，在 `backend/cloudflare/` 运行：

```sh
npm ci
npm run types
npm run typecheck
npm test
npm run build:staging
```

跨端 HTTP 测试使用真实本地 Worker / D1。仓库根目录运行 `npm --prefix backend/cloudflare run build:test`，再启动 `node backend/cloudflare/test/http-server.mjs`；客户端测试设置 `PINDO_SYNC_TEST_ENDPOINT=http://127.0.0.1:8787`。CI 在同一 Worker 上验证 Swift 写入、Android 读取并写回、Swift 读取；具体阶段以 `.github/workflows/macos.yml` 为准。

中文字体回归按固定摘要下载测试字体，不能随应用打包：

```sh
bash scripts/prepare-macos-font-test.sh /tmp/pindo-fonts/SourceHanSerifSC-Regular.otf
PINDO_TEST_CJK_FONT_PATH=/tmp/pindo-fonts/SourceHanSerifSC-Regular.otf swift test --jobs 4 --filter SquirrelFontTests
```

三份工作流分别验证 macOS、Android、Worker；`main` 构建成功后自动发布客户端。验证结果以当前提交的 CI 为准。模拟运行时、协议测试、进程启动均不能代替真实设备上的中文组词、多屏、焦点、拖动和云同步验收。
