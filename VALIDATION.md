# 验证记录

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
