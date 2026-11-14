# Pindo Android

Android 8.0+ 的客户端，使用 Kotlin、Jetpack Compose 和系统 Android Keystore。待办可以离线使用；支持日期、分组、备注、三种状态，以及最多三级子项、展开/收起、移动父项和删除整棵子树。

## 界面与管理

- **清单**：今日进度、逾期概览、快速记录，以及今天／近 7 天／全部范围；可按分组、完成状态和标题或备注搜索。事项保留三级缩进与展开按钮，进行中仍以状态圆圈内的半绿色表示。
- **日历**：按月翻页，日期显示未完成及完成数量；点选日期查看当天事项，也可以直接为选中日期添加待办。
- **管理**：查看所有日期，按状态、分组和关键词筛选，按手动顺序、计划日期或最近修改排序。多选后可批量完成、恢复待办、移动日期、修改分组和删除。搜索结果中的父级上下文不参与全选，删除确认包含完整子树数量。
- **事项详情**：日期选择器及今天／明天／一周后快捷日期、分组色块、可搜索的父事项选择、状态编辑，以及备注 Markdown 编辑和只读预览。支持标题、强调、清单、引用和代码，不执行 HTML 或加载远端图片。
- **设置**：跟随系统／浅色／深色外观、新待办默认分组、分组名称与颜色编辑、同步状态及资料导入导出。外观与默认分组仅保存在当前设备。

导出文件是明文待办与分组 JSON，不包含云凭据、恢复密钥、同步身份或本机偏好。导入会替换当前事项，先显示确认，并将替换前的资料作为一份保护备份保存在本机；可在设置中恢复，导入与保护备份一起原子提交。可导入 Android 导出文件和 macOS 的 `data.json` 导出资料，上限为 10MiB。恢复备份属于新的本地修改，连接同步后也会传播到其他设备。

## 构建

安装 JDK 17 和 Android SDK 35 后：

```sh
cd android
./gradlew testDebugUnitTest lintDebug assembleDebug
```

APK 位于 `app/build/outputs/apk/debug/app-debug.apk`。GitHub 的 `Build Android app` 工作流也会运行上述检查，并在 `main` 成功后发布到 [Android 下载列表](https://github.com/CodexSpaceSafe-Projects/pindo/releases?q=android-build-&expanded=true)。打开对应版本，点击附件 `Pindo-Android-debug.apk` 可直接下载，不需要 GitHub 登录或解压。每个版本附带 `SHA256SUMS-Android`。Actions 的 `Pindo-Android-debug` 产物仅作为需要登录、保留 14 天的备用入口。Debug APK 用于试用，不是商店发行签名。

## 云同步调整

缤纷云连接界面、S3 客户端与签名实现已移除。本版本仅在本机保存；Cloudflare v3 正在开发，尚未开放连接。旧本机副本、墓碑、冻结发件箱及 Keystore 加密凭据文件保留，不会自动清空或发送到新服务。设置中的 JSON 导出只包含可见资料，不能代替这些本机恢复信息的完整备份。

跨端协议基础与后端进度见 [Cloudflare v3 契约](../docs/CLOUDFLARE-V3.md)。

当前 Android 版本保留 Markdown 原文并提供本地预览；尚未提供 macOS 的原生拖动预览、系统菜单栏或自动快照历史。自动检查包括 JVM 合并／密码学／层级测试、Robolectric 中的 Compose 布局与交互检查，以及 Android Lint、APK 编译；模拟 Android 运行时的截图不等同于手机或真实云服务联调。
