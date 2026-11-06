# Pindo

面向多项目并行工作的 macOS 菜单栏待办。先记录想法，从清单挑一条交给 Codex；它运行时继续挑另一条，检查结果后再勾选完成。

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

每次推送分支、提交 Pull Request，或在 [Actions](https://github.com/CodexSpaceSafe-Projects/pindo/actions/workflows/macos.yml) 手动运行，都会在 macOS 上测试、编译并打包。成功后，在对应运行页面的 **Artifacts** 下载 `Pindo-macOS-版本号`，解压其中的应用压缩包得到 `Pindo.app`。构建产物保留 14 天，包含 Apple Silicon 与 Intel 通用二进制和 `SHA256SUMS` 校验文件。

发布正式版本时，推送版本标签，例如：

```bash
git tag v0.1.0
git push origin v0.1.0
```

标签构建成功后会自动创建 [GitHub Release](https://github.com/CodexSpaceSafe-Projects/pindo/releases)，附上应用压缩包和校验文件。`v0.2.0-beta.1` 会标记为预发布。应用版本取自标签，构建编号取自 Actions 运行编号。普通提交的版本号取自 `Resources/Info.plist`。

也可以在 Mac 上运行 `PINDO_UNIVERSAL=1 bash scripts/build-app.sh` 构建通用版。当前使用临时签名，尚未配置 Apple Developer ID 签名与公证；自动构建不会绕过 macOS 的安全检查。

## 使用

- **点击事项主体**打开其附属纯文本备注；右侧铅笔修改标题、日期和分组。备注自动保存，返回按钮和编辑区外的标题、留白、底栏均可返回。
- **待开始／进行中／已完成**：进行中可同时有多条，不受日期限制；分组仍可筛选。日期左右切换，向下展开附近日期和任意日期选择。
- **复制并切到 Codex**：待开始行的播放按钮先复制标题与备注，保存进行中状态，再激活已安装的 Codex 桌面应用。仍需在 Codex 选择或新建对应会话并粘贴发送。
- **返回 Codex**：进行中行的返回图标只打开应用，不自动定位具体任务，不自动发送消息或判断完成。
- **右键菜单**提供仅标记进行中、复制、移回待开始、上移／下移与删除等操作。
- **分组色条**宽 3px，名称和颜色在完整设置窗口中管理。删除分组保留事项及备注。
- **全局快捷键**默认 `Control + Option + Space` 快速记录，`Control + Option + P` 唤出清单；两者可分别录制、停用。注册冲突时保留原可用热键并提示。
- **快速记录**默认今天、未分组，支持可展开的附属备注。Esc 保留草稿，标题中 Return 添加，备注中 `Command + Return` 添加。

Codex 的应用标识根据[官方启动实现](https://github.com/openai/codex/blob/ddd1812a51f4aded35c3ec5446672474d5cb546b/codex-rs/cli/src/desktop_app/mac.rs)核实。Pindo 只使用应用激活，不调用下载／安装流程或猜测已有会话的 URL。

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

未提交的快速记录和清单输入草稿保存在本机 UserDefaults，不进入快照。当前数据格式与历史网页原型的浏览器存储不同，尚未提供浏览器原型数据导入器。

## 项目结构

```text
Sources/PindoCore/       数据模型、日期语义、文本差异、快照保留、原子保存和恢复日志
Sources/Pindo/           原生菜单栏、磨砂窗口、备注与设置、全局热键、Codex 切换
Tests/PindoCoreTests/    可跨平台运行的数据与恢复测试
Tests/PindoMacTests/     macOS 模型、交接流程、自动保存及视图构造测试
Resources/Info.plist     应用标识、菜单栏应用声明、最低系统版本
scripts/build-app.sh    构建、打包并检查本机签名
design/                 设计记录与较早的网页交互原型
```

## 验证范围

`swift test` 在 Linux 上编译和运行 `PindoCoreTests`；Mac 上还会编译原生应用并运行 `PindoMacTests`。`.github/workflows/macos.yml` 已配置 macOS 构建、测试、打包与进程启动检查，运行后可下载应用压缩包。

当前开发环境为 Linux，核心模块已实际编译测试；原生源码已做 Swift 语法解析，但这里无法执行 AppKit／SwiftUI 的 macOS 编译和真机交互。新增的 macOS 测试与 CI 配置不代表已经通过 macOS 验收。

首次 Mac 验收请覆盖：菜单栏与多屏位置、备注外部点击返回、全局快捷键与输入法、快捷键冲突回退、登录启动、两个 Codex 事项并行交接、30 秒快照及恢复。CI 的进程启动检查仅检查应用没有立即退出，不能替代这些交互验证。
