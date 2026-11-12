# Pindo Android

Android 8.0+ 的初版客户端，使用 Kotlin、Jetpack Compose 和系统 Android Keystore。待办可以离线使用；支持日期、分组、备注、三种状态，以及最多三级子项、展开/收起、移动父项和删除整棵子树。

## 构建

安装 JDK 17 和 Android SDK 35 后：

```sh
cd android
./gradlew testDebugUnitTest lintDebug assembleDebug
```

APK 位于 `app/build/outputs/apk/debug/app-debug.apk`。GitHub 的 `Build Android app` 工作流也会运行上述检查并提供 `Pindo-Android-debug` 安装包产物。Debug APK 用于试用，不是商店发行签名。

## 缤纷云同步

1. 在缤纷云创建私有存储桶，准备仅允许访问该桶的 Access Key 和 Secret Key。
2. 打开应用的「设置」，填写 Bucket、控制台提供的 S3 Endpoint 和 Region。
3. 首台设备生成恢复密钥；其他设备填入同一密钥。所有设备使用相同的桶、Endpoint 和 Region。
4. 打开启用云同步，保存设置。保存前不会联网。

默认 Endpoint 为 `https://s3.bitiful.net`，Region 为 `cn-east-1`；以实际桶配置为准。只有缤纷云的 HTTPS S3 接入点可以接收凭据。恢复密钥保存在系统安全存储中，复制按钮便于配置其他设备；云端只保存 AES-256-GCM 加密数据。恢复密钥与云账号凭据不同，遗失后无法从云端找回明文。

前台约每 30 秒拉取变化，修改后约 1 秒尝试上传；无变化时不反复上传。错误后逐步退避，支持手动重试。编辑事项时暂缓合并云端修改，关闭编辑窗口后恢复。后台没有常驻服务，不保证秒级同步。同步状态与本机资料存入同一原子文件，失败时保留本机修改；本机快照、macOS 偏好和凭据不进入同步内容。

当前 Android 版本编辑 Markdown 原文；尚未提供 macOS 的原生拖动预览、系统菜单栏或本地快照界面。自动检查包括 JVM 合并/密码学/签名/层级测试和 Android Lint、APK 编译；这些不等同于手机或缤纷云真实账号联调。
