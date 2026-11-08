# Pindo

[![macOS build](https://github.com/CodexSpaceSafe-Projects/pindo/actions/workflows/macos.yml/badge.svg)](https://github.com/CodexSpaceSafe-Projects/pindo/actions/workflows/macos.yml)

轻量的 macOS 菜单栏待办，支持分组、日期、备注和本地快照。清单可随时唤出，也可 pin 在前台持续查看。

原生实现使用 **SwiftUI + AppKit**，最低 macOS 14，无第三方运行时依赖。

## 构建与运行

在 Mac 上安装 Xcode 15+ 或其 Command Line Tools，然后在仓库根目录运行：

```bash
swift test --jobs 4
bash scripts/build-app.sh
open dist/Pindo.app
```

应用出现在菜单栏，不显示 Dock 图标。需要登录启动时，先把 `dist/Pindo.app` 移到 `/Applications`，从该位置启动，再到设置开启。该构建使用本机临时签名，尚未提供公证过的发布版本。

开发时也可以运行 `swift run Pindo`；先退出已经运行的 Pindo，避免同时启动开发版与打包版。每个云任务已隔离，直接使用现有检出即可，不需要另建 Git worktree。

## GitHub 自动构建与下载

每次推送 `main` 或在 `main` 上手动运行 [Actions](https://github.com/CodexSpaceSafe-Projects/pindo/actions/workflows/macos.yml)，通过测试、编译和打包后，都会自动创建 [GitHub Release](https://github.com/CodexSpaceSafe-Projects/pindo/releases/latest)。无需手动打标签：自动发布的标签为 `build-构建编号`，标题为 `Pindo 版本号 (build 构建编号)`，并附上对应提交和构建记录。

在 Release 中下载 `Pindo-版本号-macOS-universal.zip`，解压得到 `Pindo.app`；同时提供 `SHA256SUMS` 校验文件。应用兼容 Apple Silicon 和 Intel。每次成功构建保留独立 Release，最新构建会更新 Releases 的 Latest 下载入口。

其他分支和 Pull Request 同样执行构建，但不自动发布 Release。所有成功构建也会提供保留 14 天的 **Artifacts → Pindo-macOS-版本号** 下载。重跑同一次工作流会更新该次 Release 的附件。

发布正式版本时，推送版本标签，例如：

```bash
git tag v0.1.0
git push origin v0.1.0
```

标签构建成功后会自动创建对应版本的 [GitHub Release](https://github.com/CodexSpaceSafe-Projects/pindo/releases)，附上应用压缩包和校验文件。`v0.2.0-beta.1` 会标记为预发布，并保留已有 Latest 指向。应用版本取自标签，构建编号取自 Actions 运行编号。普通提交的版本号取自 `Resources/Info.plist`。

也可以在 Mac 上运行 `PINDO_UNIVERSAL=1 bash scripts/build-app.sh` 构建通用版。当前使用临时签名，尚未配置 Apple Developer ID 签名与公证；自动构建不会绕过 macOS 的安全检查。

## 使用

- **自适应清单**：拖动窗口边框调整大小，重新打开时保留尺寸。顶部保留 pin 和设置，待办占据主要区域；日期切换、日历和带下拉箭头的分组筛选位于底部。添加栏一直显示，点击文字区或上下留白均可聚焦输入；右侧可独立选择分组，Return 提交。
- **日期概览**：点击底部日期展开月历，每天以橙色显示未完成数量、绿色显示已完成数量，按计划日期统计并跟随分组筛选；可以切换月份或回到今天。
- **pin 置顶**：清单唤出时始终显示在普通窗口前方，再次点击状态栏图标收起清单。固定后切换应用仍保留；取消固定后，点击其他窗口或切换应用会收起清单。面板独立于菜单栏弹出层，唤出时不激活应用菜单栏。
- **菜单栏快捷菜单**：右键单击、触摸板双指点按或 Control 点按 Pindo 图标，直接显示「添加事项」「设置」「退出」三个选项。添加事项打开快速记录；左键仍用于打开或收起清单。
- **界面语言**：默认跟随 macOS 首选语言，中文显示简体中文，其他未支持的语言使用英文。在「设置 → 通用 → 语言」可切换，立即生效；待办内容和已有分组名称不变。
- **备注与 Markdown**：点击待办打开备注，直接实时渲染标题、加粗、斜体、删除线、链接文字、引用和代码等常用格式；编辑当前段落时显示语法标记，资料始终保存为原始 Markdown。点击编辑区外的标题、留白或底部状态区域即可返回，也可按 Esc。编辑器保留原生输入法组词和文本撤销，组词期间不重写文本或样式、不保存未提交的拼音。
- **未完成／已完成**：分组标题整行可点击展开，包括文字旁的留白；之前未完成的事项可批量移到今天。已有进行中事项保留并可手动管理。
- **管理待办**：在「设置 → 管理待办」查看所有日期的待办，支持按标题或备注搜索、状态和分组筛选，以及完成、编辑、删除和打开备注。
- **右键菜单**提供复制内容、手动调整状态、上移／下移、修改和删除。
- **紧凑事项列表**使用 15 号标题、较小的上下留白与行距，完成圆圈随整行垂直居中；长标题仍可换行。逐条分组文字改由左侧 5px 色带表达，色带填满行高并贴合行的圆角。
- **分组颜色**在「设置 → 分组」从七种预设色中选择，或选择列表最后的「自定义颜色…」打开 macOS 颜色面板。预设取自 [Paul Tol 的 Bright 分类色板](https://sronpersonalpages.nl/~pault/data/colourschemes.pdf)（图 1），菜单和当前选择同时显示色块与名称。删除分组保留事项及备注。
- **新待办默认分组**在「设置 → 通用」中选择，初始为未分组。快速记录与“全部分组”清单中新建的事项使用该分组；指定分组或“未分组”清单中新建时沿用当前筛选。删除默认分组会重置为未分组。
- **全局快捷键**默认 `Control + Option + Space` 快速记录，`Control + Option + P` 唤出清单；两者可分别录制、停用。注册冲突时保留原可用热键并提示。
- **快速记录**默认今天，分组使用设置中的默认值，也可手动选择其他分组或未分组，支持可展开的附属备注。拖动后记住上次位置，重启后继续使用；断开显示器时自动移回可见区域。Esc 保留草稿，标题中 Return 添加，备注中 `Command + Return` 添加。
- **提示音**：成功添加待办或标记完成时播放轻量系统提示音。连续操作时，每次成功操作都可立即播放，上一声不会阻挡下一声。保存失败、重复完成和恢复未完成不播放。

## 保存、快照与恢复

资料位于 `~/Library/Application Support/Pindo/`：

| 文件 | 内容 |
| --- | --- |
| `data.json` | 当前待办、备注、分组和偏好 |
| `Backups/snapshots.json` | 基线加增量组成的快照包，最多 100 份、30,000,000 字节 |
| `recovery.json` | 恢复／导入期间使用的恢复日志，成功后移除 |

文字停止输入约 **600ms** 后保存；返回、关闭面板、应用退出时补存。**30 秒**定时检查相对上一份快照是否有变化，有变化才生成一份快照。同一周期内的多次编辑合并，普通浏览和未提交草稿不产生快照。

达到数量或容量上限时，把最旧增量合并进基线后清理，不破坏剩余版本。备份过大或损坏不会覆盖原备份，当前资料仍可保存。普通文本编辑继续使用系统的撤销；主界面没有应用级撤销按钮。

在「设置 → 备份与恢复」中按需选择版本。恢复或导入前保护当前资料，事务日志保证中断后可继续恢复；恢复失败时阻止继续修改，提供重试。可以导出当前资料、原备份包，或确认后导入结构化资料。不会在读取失败时用空数据覆盖旧文件。

如果容量不足以同时保留操作前的保护版本和替换后的版本，会取消恢复或导入，保留当前资料与原备份，并提示原因。

未提交的快速记录和清单输入草稿保存在本机 UserDefaults，不进入快照。当前数据格式与历史网页原型的浏览器存储不同，尚未提供浏览器原型数据导入器。

## 项目结构

```text
Sources/PindoCore/       数据模型、日期语义、文本差异、快照保留、原子保存和恢复日志
Sources/Pindo/           原生菜单栏、自适应置顶面板、实时 Markdown 编辑器、月历、设置与全局热键
Tests/PindoCoreTests/    可跨平台运行的数据与恢复测试
Tests/PindoMacTests/     macOS 模型、编辑器组词、自动保存、管理列表及视图构造测试
Resources/Info.plist     应用标识、菜单栏应用声明、最低系统版本
scripts/build-app.sh    构建、打包并检查本机签名
design/                 设计记录与较早的网页交互原型
```

## 验证范围

`swift test` 在 Linux 上编译和运行 `PindoCoreTests`；Mac 上还会编译原生应用并运行 `PindoMacTests`。`.github/workflows/macos.yml` 已配置 macOS 构建、测试、打包与进程启动检查，运行后可下载应用压缩包。

当前开发环境为 Linux，核心模块已实际编译测试。[较早版本的 macOS CI 记录](https://github.com/CodexSpaceSafe-Projects/pindo/actions/runs/42206508251)通过了原生编译、通用版打包、签名和启动检查；该记录不代表本轮面板和编辑器变更已通过原生构建。最新验证范围见 VALIDATION.md。

Mac 验收请覆盖：自动隐藏菜单栏、多屏及全屏位置、pin 前台保留与取消、快捷键长按与再次唤出、中文组词时等待保存和快照、候选字鼠标选择、Markdown 预览、全部待办管理、登录启动及快照恢复。CI 的进程启动检查不能替代这些交互验证。
