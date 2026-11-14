# 验证记录

## 2026-11-14：修复中西文间距随输入闪动

- 已检查用户录屏：在下方数字行输入或移动光标时，上方 OpenWRT 两侧的留白会消失、再出现。代码中 Markdown 引擎重置属性后，Pindo 通过异步队列重新添加间距，造成两种字宽交替排版。
- 改为在 NSTextStorage.didProcessEditing 的同一编辑事务内补齐受影响段落，提交中文输入时同步补齐当前段落。先在独立副本计算完整结果，只写入最终属性有差异的范围；不先清空现场间距，也不重复写入未变化的文本。保留引擎负 kerning、中文组词、选区、撤销和 Markdown 原文。
- 中西文额外留白从 0.25em 调整为 0.125em，macOS 标题、备注及 Android 使用一致比例。文字仍不插入实际空格。
- 合入远端同步模块更新后，Linux `swift test --jobs 4` 的 113 项核心测试通过；`git diff --check` 通过。新增 macOS 原生回归记录每次编辑通知的间距，并比较下方连续输入、移光标前后的上方字形位置，另验证删除边界、撤销、中文提交和重复排版不产生 storage 编辑。原生执行与通用打包以本次提交 CI 为准，未在用户原机重新录制验收。

## 2026-11-14：Cloudflare staging 部署

- 新增独立 staging 资源清单、稳定服务身份、构建提交 / bundle SHA-256 和 Cloudflare multipart metadata 生成脚本。构建要求 backend 工作区已提交，生产模式继续关闭。
- 新增无需凭据的 `/` / `/health`，健康检查逐一验证四张必需表，同时返回 `clientSyncAvailable:false`；缺表返回 503，不影响资料 API 的设备鉴权。
- 13 项本地 workerd / D1 测试通过，开发与 staging 配置均生成类型并通过 TypeScript 检查。Cloudflare 插件已创建独立 D1、应用 schema / 迁移账本并读回确认，Worker 已上传并启用 workers.dev，API 确认版本分配 100%、绑定、兼容日期与 observability。
- 新增仓库 CI 的公开健康 / 未授权 401 探测，结果以当前提交为准。聊天环境与插件禁止直接 fetch workers.dev，因此没有在聊天中完成带令牌的线上 push / pull / 撤销验证，也没有创建公开令牌或永久测试设备。资源、构建摘要与边界见 [部署记录](docs/CLOUDFLARE-STAGING.md)，客户端仍未接入。

## 2026-11-14：Cloudflare v3 首批基础与旧云服务退役

- 移除 macOS / Android 的缤纷云连接与 S3 网络实现，取消自动连接 / 轮询，当前仅本机保存；保留旧副本、墓碑、冻结发件箱、库归档和加密凭据日志。新增两端启动与离线修改的保留回归，旧密码学、v1/v2 协议与迁移向量测试继续保留。
- 新增 v3 库身份、规范 AAD、AES-GCM 组合密文和共享向量，限定安全整数和大小边界；备注参考寄存器以实际观察的 note dot 仲裁，乱序替代、真实并发、空备注、重复和损坏上下文有可执行断言。这些原语尚未接入本机权威存储与领域投影。
- 新增 Workers + D1 开发日志核心。11 项本地 workerd / D1 测试通过，覆盖并发、幂等、撤销、事务后步失败整批回滚、分页 / 缺口、epoch / 预算、保留回执及模拟 GC 后不重用 revision。`npm run types`、TypeScript 类型检查通过。
- Linux Swift 6.0.3 的 113 项核心测试通过，`git diff --check` 通过。新增 macOS 加密与保留回归、Android 加密与保留回归，以及独立后端 CI；macOS 原生编译 / 通用包和 Android 测试 / lint / APK 等待本提交的 CI 确认。
- 首轮 Android CI 发现退役代码拆分时误删文件末尾的本地校验函数；已原样恢复到独立的 `DocumentValidation.kt`，普通备份和本机编辑继续使用同一套校验。后续 CI 结果以修复提交为准。
- 尚未完成 P0 全部操作契约、P1 / P2 / P4 / P5，也未部署 Cloudflare。没有测量真云 CPU / 容量，没有真云配对、GC、迁移或 Mac / Android 实机验收。锁定的本地运行时兼容日期为 2026-07-30，生产配置目标 2026-11-14，发布前必须升级运行时重测。

## 2026-11-14：备注集成 SwiftMarkdownEngine

- 将备注页和快速记录备注统一替换为固定版本 SwiftMarkdownEngine 0.15.0 的 NativeTextViewWrapper；删除旧 LiveMarkdown、装饰绘制和自研格式变换，格式命令通过每个编辑器独立的引擎通知总线执行。仅链接核心 MarkdownEngine 产品，SwiftMath 只随上游清单解析、不链接；Apache 2.0 许可随应用打包。
- 保留绑定与自动保存、关闭前同步提交、中文输入保护、字体补字、中西文间距、点击外部返回和多窗口编辑租约。原文／显示文本转换使用引擎 WikiLinkService，防止保存显示内容时丢失 wiki-link ID；排版不调用 TextKit 1 的 layoutManager。
- Linux `swift test --jobs 4` 的 109 项核心测试通过。原生回归改为挂载真实引擎，验证 TextKit 2、Markdown 样式、稳定实例、输入法、字体更新、格式与撤销、多编辑器隔离、关闭提交、wiki ID、原文复制及重复排版。既有自动保存、快速记录及关闭窗口／租约测试同步迁移。macOS 编译、完整原生测试和通用打包以本次提交 CI 为准；未进行 Mac 实机交互验收。

## 2026-11-14：事项标题与备注的中西文显示间距

- Swift／Kotlin 共用 Unicode 边界用例，中文与拉丁字母、数字之间增加 0.25em 视觉间距；保留已有空格、标点、组合重音、扩展汉字和 emoji 的原始 UTF-16 位置。全部处理仅发生在排版层，不修改资料、复制内容或同步协议。
- macOS 主清单、管理页标题、备注预览、各标题输入入口及实时 Markdown 备注共用排版规则；列表测量使用同一份带间距的文本。Markdown 隐藏标记不打断可见文字的间距，代码内部保持等宽；输入法组词期间不改文本或属性。标题输入沿用现有原生控件，保留绑定、提交和焦点管理。
- Android 标题、输入与备注预览使用附加样式，输入转换保持恒等位置映射。新增文本／样式保留、光标映射和代码排版测试；补齐上次父项状态测试缺少的 Android JSON 兼容扩展导入。
- Linux `swift test --jobs 4` 的 109 项核心测试全部通过；新增原生测试覆盖实际字宽增加、Markdown 可见边界及字号、编辑后的间距清理、选区／撤销和输入法保护。`git diff --check` 通过。macOS 原生测试、通用编译与打包及 Android 完整测试／lint／APK 构建由本次提交 CI 验证；未进行 Mac 或手机实机交互验收。

## 2026-11-14：父子项进度自动联动

- 统一 Swift 核心、Android 本地操作和两端同步投影的规则：子项存在进行中或部分完成时，上级逐级进入进行中；全部子项完成时，上级完成。重开、移动、删除子项后按剩余子项重新计算，保留父项手动开始的来源和本轮开始时间。
- 状态操作会检查完整祖先链，即使目标或中间父项的状态未变化，也能修正旧资料中仍为待办的上级。同步投影修正可见状态，不重写原始寄存器，v1／v2 共用新增的三级部分完成向量。
- 先用新规则复现原有失败，再运行 Linux Swift 6.0.3 的 `swift test --jobs 4`，106 项核心测试全部通过；覆盖九种子项状态组合、逐级完成／重开、移动／删除、开始时间保留、无状态变化时的祖先修正，以及共享同步向量。`git diff --check` 通过。
- 新增 macOS 状态点击、父项进度持久化与写失败整体回滚测试，以及 Android 对应的状态矩阵、开始时间和旧祖先状态回归。原生 macOS 与 Android 完整测试、编译和打包由本次提交的 CI 执行；Linux 核心测试不代表 Mac 实机交互验收。

## 多端云同步 v2 重设计

- 先完成现有 Swift/Kotlin 协议、传输、控制器和持久化审查，再按 [七步实施计划与 36 类故障矩阵](docs/SYNC-REDESIGN.md) 改造。使用和迁移规则见 [同步说明](docs/SYNC.md)。
- 云端改为密文摘要寻址的不可变完整检查点；两端保留精确字节的本地发件箱，PUT 后用 GET 校验再确认。版本确认、远端缓存和可见文档／副本在同一原子文件中推进；旧上传晚到不会覆盖新对象。已缓存对象的 ETag 改变会强制重新校验内容摘要。
- v2 生命周期采用单独原子寄存器；v1 原始状态／时间寄存器保留，升级不伪造混合事件。每次应用启动（包括断开状态）轮换未来操作 actor；恢复、导入、同库重连和 A→B→A 保留对应历史／墓碑。
- 配置先只读验证目标库，再提交凭据日志与本机事务标记；通过磁盘提交点决定恢复。FileStorage 将可能失败的写入、权限设置和 fsync 放在原子 rename 前，提交后不再抛错；目录 fsync 仍为 best effort，不承诺所有硬件／文件系统的断电耐久。
- 编辑保护覆盖嵌套租约、管理页和多窗口同事项互斥；事项表单仅提交实际修改字段。Android 还验证配置恢复和 UI 就绪边界，避免旧草稿晚于远端合并才恢复。
- Linux `swift test --jobs 4` 的 102 项核心测试已实际通过；包含真实双向 Swift/Kotlin v2 向量、三 actor 乱序／重复／分区、迁移同态、事务、写失败、发件箱确认和资料库归档。Swift 原生应用、控制器、编辑器及传输测试由本次提交的 macOS CI 执行，语法解析不代表原生编译或界面验收。
- Android 纯 JVM 分组测试已分别通过；本地 Gradle 已实际通过应用／单元测试源码编译和 APK 构建。完整 Robolectric 与 lint 所需的 nativeruntime JAR 被允许的官方 Maven 源重定向到环境未放行域名，未在本地跳过检查；完整测试、lint 和两端最终 CI 以本次提交记录为准。没有真实缤纷云账号、桶或恢复密钥参与测试，未进行双设备／三设备实机与真实网络演练。
- 本版保留历史和墓碑，不自动删除云对象；10,000 对象、7 MiB 明文／10 MiB 密文、8 库及 64 MiB 本地归档是明确安全边界。故障矩阵区分已实现机制、自动验收要求和仍需实测的场景，不将其表述为“现实中的所有故障均已验证”。

## 2026-11-13：编辑待办时设置弹窗误触发防护

- 代码检查发现：原颜色菜单将空选项和未知选项统一解释为“自定义颜色”；颜色、字体控件均使用 `NSPopUpButton` 和 `choose:` 回调，缺少发送控件与当前菜单归属检查，销毁时也未完整清理动作。这些是与串窗现象相关的风险，尚未在用户原机上确认完整触发链。
- 颜色与字体控件改用独立原生类型和动作名，每次更新重新绑定目标；拒绝其他控件、未知选项、失效菜单、隐藏窗口和被待办编辑 sheet 覆盖的设置动作。仅明确选择当前菜单的“自定义颜色…”才打开颜色面板；移除所属控件时关闭对应面板并清理回调。
- 修改待办的分组选择改用现有的独立平铺菜单，保留分组 ID 绑定和取消／完成逻辑。
- Linux Swift 6.0.3 的 74 项核心测试通过。新增 4 项 macOS 回归测试，覆盖错误控件／菜单通知、空与未知选项、正常选色和选字体、隐藏及 sheet 覆盖、销毁清理，以及界面未变化时恢复正确动作目标。原生执行结果以本次提交的 `Build macOS app` 为准。
- 尚未实机复现用户的完整步骤。Mac 验收需重复“添加 → 多次修改 → 连续更换分组 → 点击完成”，分别覆盖主清单与管理待办入口，并确认设置颜色／字体界面保持关闭，正常设置操作仍可用。

## 2026-11-13：备注页直接编辑事项内容

- 主清单和管理页共用的备注页将事项标题改为原生可编辑输入框；标题和备注共用 600ms 自动保存，返回时补存，空标题草稿离开输入框后恢复上次有效内容。
- Linux Swift 6.0.3 已通过 74 项核心测试；新增标题与备注合并保存、空标题拒绝、写入失败重试、元数据保留及同步载荷标题更新检查。`git diff --check` 通过。
- 新增 macOS 测试覆盖标题和备注自动保存、返回补存、中文组词期间不发布或替换输入、空草稿恢复，以及标题区域不触发备注页退出。原生编译和测试由本次提交的 `Build macOS app` 工作流运行。
- 当前执行环境为 Linux，未进行 Mac 实机交互验收；需在 Mac 上确认点击标题与备注切换、中文候选字选择、撤销、长标题换行及 Esc 返回。

## 2026-11-12：Android 0.2 界面与管理功能

- 重构清单、日历、管理、设置四页；新增主题、批量操作、分组编辑、日期选择、Markdown 预览和资料导入／保护备份。
- 本地已实际通过应用和测试源码编译。新增查询、批量层级校验、资料白名单与 Markdown 解析测试；Compose 界面测试在 Robolectric Android 34 原生图形模式运行，生成浅色、深色、日历、批量管理、编辑及大字号截图。
- 本地 Robolectric 原生图库下载被网络策略阻止；已在 GitHub Android CI 实际运行并通过 53 项测试（含 5 项运行时界面与本地恢复测试）。生成并查看 8 张真实 Compose／原生 Skia 渲染截图，覆盖浅色、深色、日历、批量管理、事项编辑、备注预览与大字号；截图随 Android Release 提供。
- 截图使用实际 Android View 的原生 Canvas 绘制，避免 Robolectric 不支持的 GPU frame-commit 回调；保留全部交互断言及非空画面检查。层级行保留相同宽度的展开控件槽位，子项标题依深度递增缩进，另有几何位置回归检查。
- 这仍不等同于真实手机或真实缤纷云双设备联调。云同步数据格式保持 v1，本机外观、默认分组和导入保护备份不进入云端载荷。

## 2026-11-12：缤纷云加密同步与 Android 初版

- Linux Swift 6.0.3 的 64 项跨平台测试通过；本轮增加同步合并、墓碑、并发备注、层级修复、本地原子保存失败和共享协议向量测试。实际 Kotlin 输出经 Swift 解码验证一致。原生 macOS 测试另覆盖固定 AES-GCM / SigV4 向量、模拟 S3 网络和同步控制器重试、断开连接，执行结果以本次提交的 CI 为准。
- Android 为 Kotlin + Compose，使用原子本地 JSON 文档与 Android Keystore。本地完整运行 `testDebugUnitTest lintDebug assembleDebug` 成功，25 项单元测试零失败，已实际生成 Debug APK；其中包括读取 Swift 生成的协议样本、密码学和签名测试。GitHub 同样运行这些检查。
- 没有配置真实缤纷云桶或凭据，未进行真实云端联调；没有 macOS/Android 实机界面验收。模拟 HTTP、固定协议向量、源码解析和成功构建均不能代替真实双设备同步或后台调度验证。
- 双设备验收：使用相同私有桶和恢复密钥，分别新增/修改/删除事项，检查离线并发备注保留、父子完成联动、重新联网合并，以及断开同步后本地仍可编辑。说明见 [docs/SYNC.md](docs/SYNC.md)。

## 历史记录：提示音、菜单栏快捷菜单、语言和分组配色

- 在 macOS 27.0.1 上用本机的 macOS 26.5 SDK 原生编译、打包并验证应用签名。已核对打包的简体中文和英文资源、翻译键和格式参数。
- 用本机 AppKit 对添加和完成音效分别发起两次连续静音播放请求，两次都被接受。本机命令行工具未包含 XCTest，完整测试由 GitHub 的 macOS 工作流运行。
- 实机验收：连续完成两条不同的待办，两次都应有音效；左键打开和收起清单，单击右键不打开菜单，双击右键打开菜单，逐项检查设置、退出和添加待办。
- 在通用设置中来回切换英文、简体中文和跟随系统，检查已打开的面板、日历、设置与菜单；重启后保留选择。检查新建及已有分组的七色列表，只有点击末尾的自定义选项才打开系统颜色面板。

## 之前版本的验证记录

Earlier development environment: Linux x86_64, Swift 6.0.3 in Swift 5 language mode.

## Local pre-push checks

| Check | Result |
| --- | --- |
| Platform-independent tests | **31 executed, 0 failures** |
| Native app and macOS tests | Swift frontend parse passed for arm64 macOS 14; **not macOS type checking or execution** |
| Patch whitespace | git diff --check passed |
| macOS build and application launch | Run by the corresponding commit's Actions workflow after push |
| Visual interaction and audible feedback | Require manual Mac acceptance |

Core coverage includes: snapshots and protected replacements at the real 30 MB boundary; corruption and interrupted recovery; default-group persistence and legacy document compatibility; Markdown blocks; shortcut press/release tracking; calendar month/year boundaries, leap days and daylight-saving transitions; daily counts including pending, in-progress and completed tasks.

The macOS tests cover model saving, task status, group-aware ordering and creation, explicit composer selection, pin callbacks, management search/edit/delete, stable marked-text composition across editor synchronization and live styling, and view construction. Panel regressions check floating level, nonactivating presentation and native resizing. Editor tests check rendered font attributes, raw source/selection/undo preservation and outside-click hit testing that excludes resize borders and other windows. Counts are checked against group filters. These tests execute in the corresponding [macOS workflow](https://github.com/CodexSpaceSafe-Projects/pindo/actions/workflows/macos.yml) after every push; Linux cannot execute them.

Additional regressions cover immediate status-icon toggling, native quick-add frames, dragged-position restoration, top-left anchoring through height changes/display removal, and feedback only after successful task writes (including a forced disk-write failure).

## Mac acceptance

Build and run with the README commands, then check:

1. Enable macOS menu-bar auto-hide. With an ordinary window of another app covering the screen, open the unpinned list by status icon and shortcut: it must appear above that window. Repeat after pinning/unpinning and with a completely occluded list. Move the pointer away, click another app, and switch with Command-Tab. Unpinned panels should close without keeping the menu bar visible.
2. Hold and release each shortcut, press it again, and switch between quick add and the list. A held key must not immediately toggle the new panel closed. Check shortcut conflicts too.
3. Pin the list, switch apps and Spaces, open settings, then unpin and click outside. Verify frontmost retention only while pinned, and positioning on multiple displays/full screen.
4. Resize the window from every edge at minimum and large sizes, reopen it, and check both light/dark appearances for corner fringes. Check long titles/group names, full-row section disclosures, the fixed composer and the bottom group dropdown. Open the calendar, navigate months and compare orange/green counts with filtered tasks on past/future dates.
5. Enter Chinese in notes. Leave a composition open for more than 600 ms and across a 30-second snapshot check; select candidates with keyboard and mouse. Verify that saving does not reset composition, caret or selection. Check undo/redo and returning by clicking header/footer/margins. Editor clicks, scrollbars, IME candidates and window resize handles must keep the note open.
6. Edit headings, bold/italic, strikethrough, link labels, quotes, lists and code blocks in place. Syntax should appear in the active paragraph and be subdued/hidden elsewhere. Text must stay local and raw Markdown must round-trip through save/restore; formatting must not add undo entries. Check quick-add notes and management notes too.
7. In Settings > 管理待办, search across old and future tasks and notes, filter by state/group, complete/reopen, edit, open notes and delete. Check login startup and snapshot recovery.
8. Open quick add with the shortcut in light/dark appearance and check all four corners. Drag it, close/reopen, restart and disconnect a display. Check that the header stays anchored when notes expand. Settings content should meet the title bar with square corners. Verify flat group menus and the 34px-high composer group buttons at minimum width, plus 6px group stripes and matching name colors in both lists. Listen for distinct quiet add/complete sounds and verify no sound after a failed save or duplicate completion.

## Earlier native CI

[Successful historical run](https://github.com/CodexSpaceSafe-Projects/pindo/actions/runs/42206508251) validated commit e31dc33 on macOS 15 / Xcode 16.4: compilation, tests, arm64/x86_64 universal packaging, ad hoc signing, five-second process launch and artifact upload.

That run predates this panel/editor change and is not evidence that the current native code compiles or that the interaction issues are resolved on a Mac. Release artifacts use ad hoc signing without Developer ID signing or Apple notarization.
