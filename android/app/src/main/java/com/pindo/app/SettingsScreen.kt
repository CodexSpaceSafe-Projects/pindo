package com.pindo.app

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.platform.testTag
import androidx.core.content.pm.PackageInfoCompat
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.graphics.toColorInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.time.LocalDate

@OptIn(ExperimentalLayoutApi::class, ExperimentalMaterial3Api::class)
@Composable internal fun AppSettingsScreen(store: AppStore, state: AppState, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val installedPackage = remember(context) { context.packageManager.getPackageInfo(context.packageName, 0) }
    var cloudOpen by rememberSaveable { mutableStateOf(false) }
    var updateOpen by rememberSaveable { mutableStateOf(false) }
    var groupsOpen by rememberSaveable { mutableStateOf(false) }
    var defaultMenu by remember { mutableStateOf(false) }
    var importText by remember { mutableStateOf<String?>(null) }
    var importError by remember { mutableStateOf<String?>(null) }
    var restoring by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        if (uri != null) scope.launch {
            busy = true
            try {
                val bytes = store.exportData().toByteArray(Charsets.UTF_8)
                withContext(Dispatchers.IO) {
                    context.contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                        ?: error("无法打开所选文件。")
                }
                message = "资料已导出，包含待办、分组和备注。"
            } catch (_: Exception) { message = "导出失败，请检查文件位置和可用空间。" }
            finally { busy = false }
        }
    }
    val import = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            busy = true
            importError = null
            try {
                importText = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.use { input ->
                        val out = ByteArrayOutputStream()
                        val chunk = ByteArray(8192)
                        while (true) {
                            val count = input.read(chunk)
                            if (count < 0) break
                            require(out.size() + count <= 10 * 1024 * 1024) { "文件超过 10 MiB 上限。" }
                            out.write(chunk, 0, count)
                        }
                        Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(out.toByteArray())).toString()
                    } ?: error("无法读取所选文件。")
                }
            } catch (_: Exception) { message = "无法读取此文件，请选择 10 MiB 以内的 Pindo JSON 资料。" }
            finally { busy = false }
        }
    }
    if (cloudOpen) {
        CloudSettingsScreen(store, state) { cloudOpen = false }
        return
    }
    if (updateOpen) {
        AppUpdateScreen { updateOpen = false }
        return
    }
    BackHandler(onBack = onBack)
    Scaffold(containerColor = MaterialTheme.colorScheme.background, topBar = {
        SettingsTopBar("设置", "返回清单", onBack)
    }) { padding ->
        Box(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = 720.dp).fillMaxSize()
                .verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 8.dp, bottom = 28.dp),
                verticalArrangement = Arrangement.spacedBy(24.dp)) {
                SyncStatusCard(state, onClick = { cloudOpen = true })
                if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                (message ?: state.error)?.let { text ->
                    SettingsMessage(text, isError = message == null && state.error != null) {
                        message = null; store.dismissError()
                    }
                }
                SettingsSection("偏好设置") {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text("外观", style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium)
                        Row(Modifier.fillMaxWidth().selectableGroup(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            listOf(Triple("system", "跟随系统", Icons.Outlined.Smartphone), Triple("light", "浅色", Icons.Outlined.LightMode), Triple("dark", "深色", Icons.Outlined.DarkMode)).forEach { (value, label, icon) ->
                                val selected = state.preferences.theme == value
                                Surface(Modifier.weight(1f), shape = RoundedCornerShape(12.dp),
                                    color = if (selected) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerLow) {
                                    Column(Modifier.fillMaxWidth().heightIn(min = 72.dp)
                                        .selectable(selected, role = Role.RadioButton, onClick = { store.setTheme(value) })
                                        .padding(horizontal = 4.dp, vertical = 12.dp), horizontalAlignment = Alignment.CenterHorizontally,
                                        verticalArrangement = Arrangement.spacedBy(7.dp)) {
                                        Icon(icon, null, Modifier.size(21.dp), tint = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                                        Text(label, style = MaterialTheme.typography.labelMedium, textAlign = TextAlign.Center,
                                            color = if (selected) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurfaceVariant)
                                    }
                                }
                            }
                        }
                    }
                    SettingsDivider()
                    Box {
                        SettingsRow(Icons.Outlined.FolderOpen, "新待办默认分组", state.groups.find { it.id == state.preferences.defaultGroupID }?.name ?: "未分组") { defaultMenu = true }
                        DropdownMenu(defaultMenu, onDismissRequest = { defaultMenu = false }) {
                            DropdownMenuItem(text = { Text("未分组") }, onClick = { store.setDefaultGroup(null); defaultMenu = false })
                            state.groups.forEach { group ->
                                DropdownMenuItem(text = { GroupName(group) }, onClick = { store.setDefaultGroup(group.id); defaultMenu = false })
                            }
                        }
                    }
                    SettingsDivider()
                    SettingsRow(Icons.Outlined.Folder, "分组管理", "名称、颜色与事项数量") { groupsOpen = true }
                }
                SettingsSection("应用") {
                    SettingsRow(Icons.Outlined.SystemUpdate, "应用更新", "当前 ${installedPackage.versionName ?: "未知版本"}",
                        !busy, Modifier.testTag("open-app-update")) {
                        updateOpen = true
                    }
                }
                SettingsSection("资料与备份") {
                    SettingsRow(Icons.Outlined.FileDownload, "导出资料", "待办、分组与 Markdown 备注", !busy && !state.readOnly) { export.launch("Pindo-${LocalDate.now()}.json") }
                    SettingsDivider()
                    SettingsRow(Icons.Outlined.FileUpload, "导入资料", "读取 Android 或 macOS 的 JSON 资料", !busy && !state.readOnly) { import.launch(arrayOf("application/json", "text/plain", "application/octet-stream")) }
                    SettingsDivider()
                    SettingsRow(Icons.Outlined.Restore, "恢复上次导入前的资料", if (state.hasLocalBackup) "本机保护备份已就绪" else "导入时自动建立保护备份", state.hasLocalBackup && !busy && !state.readOnly) { restoring = true }
                }
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("导出为明文，不含同步凭据或密钥。导入会替换当前资料，并先保留一份本机备份。",
                        color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                    Text("Pindo · ${installedPackage.versionName ?: "未知"} (${PackageInfoCompat.getLongVersionCode(installedPackage)})",
                        style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
    if (groupsOpen) GroupDialog(store, state) { groupsOpen = false }
    if (importText != null) AlertDialog(onDismissRequest = { importText = null; importError = null }, icon = { Icon(Icons.Outlined.FileUpload, null) },
        title = { Text("导入并替换当前资料？") }, text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("当前 ${state.tasks.size} 条事项将被替换。操作前会自动保存一份本机保护备份；同步连接和密钥保持不变。")
                importError?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium) }
            }
        },
        confirmButton = { TextButton(onClick = {
            val incoming = importText
            if (incoming != null) {
                if (store.importData(incoming)) { importText = null; importError = null; message = "资料已导入，原资料已保留为保护备份。" }
                else importError = store.state.value.error ?: "导入失败，当前资料未被替换。请检查文件后重试。"
            }
        }) { Text("导入") } },
        dismissButton = { TextButton(onClick = { importText = null; importError = null }) { Text("取消") } })
    if (restoring) AlertDialog(onDismissRequest = { restoring = false }, icon = { Icon(Icons.Outlined.Restore, null) },
        title = { Text("恢复保护备份？") }, text = { Text("将替换当前清单，并保留当前资料作为新的保护备份。云同步会把恢复内容作为新修改合并。") },
        confirmButton = { TextButton(onClick = { if (store.restoreBackup()) { restoring = false; message = "保护备份已恢复。" } }) { Text("恢复") } },
        dismissButton = { TextButton(onClick = { restoring = false }) { Text("取消") } })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun SettingsTopBar(title: String, backLabel: String, onBack: () -> Unit) {
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
        TopAppBar(modifier = Modifier.widthIn(max = 720.dp),
            title = { Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold) },
            navigationIcon = { IconButton(onClick = onBack, modifier = Modifier.size(48.dp)) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, backLabel)
            } },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background))
    }
}

@Composable private fun SyncStatusCard(state: AppState, statusModifier: Modifier = Modifier, onClick: (() -> Unit)? = null) {
    val failed = state.readOnly || state.syncStatus.contains("失败")
    val accent = if (failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary
    Surface(modifier = Modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
        color = MaterialTheme.colorScheme.surface, shape = RoundedCornerShape(16.dp)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Surface(shape = CircleShape, color = accent.copy(alpha = .09f)) {
                    Icon(if (failed) Icons.Outlined.SyncProblem else Icons.Outlined.Security,
                        null, Modifier.padding(10.dp).size(22.dp), tint = accent)
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text("云同步", style = MaterialTheme.typography.labelMedium, color = accent)
                    Text(when {
                        state.readOnly -> "本机资料需要检查"
                        failed -> "同步连接失败"
                        state.syncEnabled -> "已连接加密同步"
                        state.syncing -> "正在连接加密同步"
                        else -> "本机资料已保留"
                    }, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(state.syncStatus, statusModifier, style = MaterialTheme.typography.bodySmall,
                        color = if (failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (onClick != null) Icon(Icons.Outlined.ChevronRight, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (state.syncing) LinearProgressIndicator(Modifier.fillMaxWidth())
        }
    }
}

@Composable private fun SettingsMessage(text: String, isError: Boolean = false, onDismiss: () -> Unit) {
    Surface(color = if (isError) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.surfaceContainerHigh,
        shape = RoundedCornerShape(12.dp)) {
        Row(Modifier.padding(start = 16.dp, end = 4.dp, top = 4.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(text, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium,
                color = if (isError) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.onSurface)
            IconButton(onClick = onDismiss, modifier = Modifier.size(48.dp)) { Icon(Icons.Outlined.Close, "关闭提示") }
        }
    }
}

@Composable private fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(title, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 4.dp))
        Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surface) { Column(content = content) }
    }
}

@Composable private fun SettingsDivider() {
    HorizontalDivider(Modifier.padding(start = 52.dp, end = 16.dp), color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = .6f))
}

@Composable private fun SettingsRow(icon: ImageVector, title: String, subtitle: String, enabled: Boolean = true,
    modifier: Modifier = Modifier, onClick: () -> Unit) {
    Row(modifier.fillMaxWidth().heightIn(min = 72.dp).clickable(enabled = enabled, onClick = onClick)
        .padding(horizontal = 16.dp, vertical = 13.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(21.dp), tint = if (enabled) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.outline)
        Column(Modifier.weight(1f).padding(horizontal = 13.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge, color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.outline)
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Icon(Icons.Outlined.ChevronRight, null, tint = MaterialTheme.colorScheme.outline, modifier = Modifier.size(18.dp))
    }
}

@Composable private fun GroupName(group: TodoGroup) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(12.dp).background(Color(group.color.toColorInt()), CircleShape))
        Text(group.name, Modifier.weight(1f).padding(start = 10.dp))
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun CloudSettingsScreen(store: AppStore, state: AppState, onBack: () -> Unit) {
    BackHandler(onBack = onBack)
    if (state.readOnly) {
        // Opening the coordinator would reopen the unreadable SQLite database.
        // Keep this explanation reachable without touching storage or secrets.
        Scaffold(containerColor = MaterialTheme.colorScheme.background, topBar = {
            SettingsTopBar("云同步", "返回设置", onBack)
        }) { padding ->
            Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())
                .padding(20.dp).testTag("sync-read-only"), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                SyncStatusCard(state)
                Text(state.error ?: "本机资料暂不可读取，同步已暂停，原文件已保留。",
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error)
            }
        }
        return
    }
    var endpoint by rememberSaveable { mutableStateOf("") }
    var creating by rememberSaveable { mutableStateOf(false) }
    var secret by remember { mutableStateOf("") }
    var invite by remember { mutableStateOf("") }
    val context = LocalContext.current
    val sync = store.sync
    var deviceToDelete by remember { mutableStateOf<Pair<String, String>?>(null) }
    deviceToDelete?.let { (id, name) ->
        AlertDialog(onDismissRequest = { deviceToDelete = null },
            title = { Text("删除这个设备？") },
            text = { Text("$name\n\n将永久删除该设备的云端登记、访问凭据、配对信息和同步租约。共享事项和对方本机资料会保留，再次连接需要重新配对。") },
            confirmButton = {
                TextButton(onClick = { sync.deleteDevice(id); deviceToDelete = null }, enabled = !state.syncing && state.syncEnabled,
                    modifier = Modifier.testTag("sync-confirm-delete-device"),
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text("删除这个设备") }
            }, dismissButton = { TextButton(onClick = { deviceToDelete = null }) { Text("取消") } })
    }
    val nameEditable = !state.syncing && !state.readOnly && (sync.active == null || state.syncEnabled)
    var deviceName by remember(sync) { mutableStateOf(sync.deviceName) }
    var requestedDevices by remember(sync) { mutableStateOf(false) }
    LaunchedEffect(sync.deviceName) { deviceName = sync.deviceName }
    LaunchedEffect(state.syncEnabled, state.syncing) {
        if (!state.syncEnabled) requestedDevices = false
        else if (!state.syncing && !requestedDevices && sync.listDevices()) requestedDevices = true
    }
    LaunchedEffect(state.syncEnabled) {
        if (state.syncEnabled) { invite = ""; secret = "" }
    }
    var connectionOpen by rememberSaveable { mutableStateOf(false) }
    Scaffold(modifier = Modifier.imePadding(), containerColor = MaterialTheme.colorScheme.background, topBar = {
        SettingsTopBar("云同步", "返回设置", onBack)
    }) { padding ->
        Box(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = 720.dp).fillMaxSize().verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp).padding(top = 8.dp, bottom = 28.dp),
                verticalArrangement = Arrangement.spacedBy(24.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    SyncStatusCard(state, Modifier.testTag("sync-status"))
                    if (state.syncEnabled) {
                        OutlinedButton(onClick = { sync.sync() }, enabled = !state.syncing,
                            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                            Icon(Icons.Outlined.Sync, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text("立即同步")
                        }
                    } else if (sync.canReconnect) {
                        Button(onClick = { sync.reconnect() }, enabled = !state.syncing,
                            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("继续同步") }
                    }
                    Text("离线修改保存在本机，连接后继续同步。", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    state.error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium) }
                }
                if (!state.syncEnabled) {
                    SettingsSection(if (sync.canReconnect) "连接其他资料库" else "连接设备") {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(if (creating) "创建资料库" else "配对连接", Modifier.weight(1f),
                                    style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                                TextButton(onClick = { creating = !creating }, enabled = !state.syncing,
                                    modifier = Modifier.heightIn(min = 48.dp)) { Text(if (creating) "加入已有库" else "首次创建") }
                            }
                            if (creating) {
                                Text("填写自己部署的服务地址和初始化密钥。", style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                                OutlinedTextField(endpoint, { endpoint = it }, label = { Text("服务地址") },
                                    placeholder = { Text("https://example.com") }, modifier = Modifier.fillMaxWidth(),
                                    singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                                    shape = RoundedCornerShape(12.dp))
                                OutlinedTextField(secret, { secret = it }, label = { Text("服务初始化密钥") },
                                    modifier = Modifier.fillMaxWidth(), singleLine = true,
                                    visualTransformation = PasswordVisualTransformation(), shape = RoundedCornerShape(12.dp),
                                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                                Text("首次创建会同步本机事项；服务只需初始化一次。", style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Button(onClick = { sync.create(endpoint.trim(), secret) },
                                    enabled = !state.syncing && !state.readOnly && secret.isNotBlank(),
                                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp), shape = RoundedCornerShape(12.dp)) {
                                    Text("创建加密同步库", textAlign = TextAlign.Center)
                                }
                            } else {
                                Text("在已连接的设备上生成配对信息，再粘贴到这里。", style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                                OutlinedTextField(invite, { invite = it }, label = { Text("粘贴设备配对信息") },
                                    modifier = Modifier.fillMaxWidth().testTag("sync-invitation"), minLines = 2, maxLines = 4,
                                    visualTransformation = PasswordVisualTransformation(), shape = RoundedCornerShape(12.dp),
                                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                                Button(onClick = { sync.join(invite) }, enabled = !state.syncing && !state.readOnly && invite.isNotBlank(),
                                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("sync-join"), shape = RoundedCornerShape(12.dp)) {
                                    Text("连接并合并本机资料", textAlign = TextAlign.Center)
                                }
                            }
                        }
                    }
                }
                SettingsSection("本机设备") {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        OutlinedTextField(deviceName, { deviceName = it }, label = { Text("本机设备名称") },
                            modifier = Modifier.fillMaxWidth().testTag("sync-device-name"), singleLine = true, enabled = nameEditable,
                            shape = RoundedCornerShape(12.dp), trailingIcon = {
                                TextButton(onClick = { sync.saveDeviceName(deviceName) }, enabled = nameEditable && deviceName.isNotBlank(),
                                    modifier = Modifier.heightIn(min = 48.dp).testTag("sync-save-device-name").semantics { contentDescription = "保存设备名称" }) { Text("保存") }
                            })
                        if (sync.active != null && !state.syncEnabled) Text("继续同步后可修改设备名称",
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        else Text("这个名称会显示在其他已连接设备上。", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                if (state.syncEnabled) {
                    SettingsSection("设备管理") {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                Text("已连接设备", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                                TextButton(onClick = { sync.listDevices() }, enabled = !state.syncing,
                                    modifier = Modifier.heightIn(min = 48.dp)) { Text("刷新设备列表") }
                            }
                            val devices = sync.devices
                            if (devices.length() == 0) Text("暂未显示设备，可刷新列表。", style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                            for (i in 0 until devices.length()) {
                                val device = devices.getJSONObject(i)
                                val id = device.getString("id")
                                val name = (device.opt("name") as? String)?.takeIf { it.isNotBlank() } ?: "未命名设备"
                                if (i > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = .6f))
                                DeviceSettingsRow(id, name, sync.isCurrentDevice(id), !state.syncing) { deviceToDelete = id to name }
                            }
                            Text("删除会清除服务器上的设备信息，保留共享事项和对方本机资料。当前设备不能删除。",
                                Modifier.padding(top = 8.dp), style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    SettingsSection("添加其他设备") {
                        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text("配对信息包含恢复密钥，只传给自己的设备。", style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                            val invitation = sync.invitation
                            if (invitation != null) {
                                Button(onClick = {
                                    val clip = android.content.ClipData.newPlainText("Pindo 加密配对", invitation)
                                    if (android.os.Build.VERSION.SDK_INT >= 33) clip.description.extras = android.os.PersistableBundle().apply {
                                        putBoolean("android.content.extra.IS_SENSITIVE", true)
                                    }
                                    (context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager).setPrimaryClip(clip)
                                }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp), shape = RoundedCornerShape(12.dp)) {
                                    Text("复制配对信息（10 分钟内有效）", textAlign = TextAlign.Center)
                                }
                            }
                            OutlinedButton(onClick = { sync.pair() }, enabled = !state.syncing,
                                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp), shape = RoundedCornerShape(12.dp)) {
                                Icon(Icons.Outlined.AddLink, null, Modifier.size(19.dp)); Spacer(Modifier.width(8.dp))
                                Text("生成设备配对信息", textAlign = TextAlign.Center)
                            }
                        }
                    }
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable { connectionOpen = !connectionOpen }
                            .padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text("连接管理", Modifier.weight(1f), style = MaterialTheme.typography.labelLarge,
                                fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Icon(if (connectionOpen) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null,
                                Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        if (connectionOpen) Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surface) {
                            Column {
                                SettingsRow(Icons.Outlined.Autorenew, "轮换此设备凭据", "更新本机访问凭据", !state.syncing) { sync.rotate() }
                                SettingsDivider()
                                SettingsRow(Icons.Outlined.PauseCircleOutline, "暂停同步", "保留本机记录与离线修改", !state.syncing) { sync.disconnect() }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable private fun DeviceSettingsRow(id: String, name: String, current: Boolean, enabled: Boolean, onDelete: () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxWidth().padding(vertical = 10.dp)) {
        val stack = maxWidth < 300.dp || LocalDensity.current.fontScale > 1.3f
        val identity: @Composable RowScope.() -> Unit = {
            Icon(if (current) Icons.Outlined.Smartphone else Icons.Outlined.Devices, null,
                Modifier.size(22.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Column(Modifier.weight(1f).padding(start = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(name, Modifier.testTag("sync-device-$id"), style = MaterialTheme.typography.bodyLarge)
                if (current) Text("此设备", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
            }
        }
        val delete: @Composable () -> Unit = {
            TextButton(onClick = onDelete, enabled = enabled,
                modifier = Modifier.testTag("sync-delete-device-$id").heightIn(min = 48.dp),
                colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text("删除这个设备") }
        }
        if (stack) Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically, content = identity)
            if (!current) Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) { delete() }
        } else Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
            identity()
            if (!current) delete()
        }
    }
}

@OptIn(ExperimentalLayoutApi::class, ExperimentalMaterial3Api::class)
@Composable internal fun GroupDialog(store: AppStore, state: AppState, onDismiss: () -> Unit) {
    var editingID by rememberSaveable { mutableStateOf<String?>(null) }
    var name by rememberSaveable { mutableStateOf("") }
    var color by rememberSaveable { mutableStateOf("#4477AA") }
    var deleting by remember { mutableStateOf<TodoGroup?>(null) }
    val colors = listOf("#4477AA" to "青蓝", "#EE6677" to "珊瑚", "#228833" to "松绿", "#CCBB44" to "姜黄", "#66CCEE" to "天青", "#AA3377" to "紫红", "#BBBBBB" to "岩灰")
    DisposableEffect(Unit) { val lease = store.beginEditing(); onDispose { store.endEditing(lease) } }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = MaterialTheme.colorScheme.surface,
        modifier = Modifier.imePadding()) {
        Column(Modifier.fillMaxWidth().heightIn(max = 640.dp).verticalScroll(rememberScrollState())
            .navigationBarsPadding().padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) { Text("我的分组", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold); Text("管理名称与颜色", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    IconButton(onClick = onDismiss) { Icon(Icons.Outlined.Close, "关闭分组管理") }
                }
                state.groups.forEach { group ->
                    Row(Modifier.fillMaxWidth().heightIn(min = 64.dp).background(if (editingID == group.id) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceContainerLow, MaterialTheme.shapes.medium).padding(start = 12.dp, top = 5.dp, bottom = 5.dp), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(14.dp).background(Color(group.color.toColorInt()), CircleShape))
                        Column(Modifier.weight(1f).padding(start = 10.dp)) { Text(group.name, style = MaterialTheme.typography.bodyMedium); Text("${state.tasks.count { it.groupID == group.id }} 条事项", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        IconButton(onClick = { editingID = group.id; name = group.name; color = group.color }, enabled = !state.readOnly) { Icon(Icons.Outlined.Edit, "修改${group.name}", Modifier.size(19.dp)) }
                        IconButton(onClick = { deleting = group }, enabled = !state.readOnly) { Icon(Icons.Outlined.DeleteOutline, "删除${group.name}", Modifier.size(19.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant) }
                    }
                }
                if (state.groups.isEmpty()) Text("还没有分组。先为工作或生活选一种颜色。", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                HorizontalDivider()
                Text(if (editingID == null) "新建分组" else "编辑分组", style = MaterialTheme.typography.titleSmall)
                OutlinedTextField(name, { name = it }, label = { Text("分组名称") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).selectableGroup(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    colors.forEach { (hex, label) ->
                        val selected = color.equals(hex, true)
                        Column(Modifier.widthIn(min = 48.dp).selectable(selected, role = Role.RadioButton, onClick = { color = hex })
                            .padding(vertical = 8.dp), horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Box(Modifier.size(28.dp).background(Color(hex.toColorInt()), CircleShape), contentAlignment = Alignment.Center) {
                                if (selected) Icon(Icons.Outlined.Check, null, Modifier.size(18.dp),
                                    tint = if (Color(hex.toColorInt()).luminance() > .45f) Color(0xFF20252C) else Color.White)
                            }
                            Text(label, style = MaterialTheme.typography.labelSmall,
                                color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                OutlinedTextField(color, { color = it }, label = { Text("自定义颜色 #RRGGBB") }, modifier = Modifier.fillMaxWidth(), singleLine = true, isError = !color.matches(Regex("#[0-9a-fA-F]{6}")))
                FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (editingID != null) TextButton(onClick = { editingID = null; name = "" }, modifier = Modifier.heightIn(min = 48.dp)) { Text("取消编辑") }
                    Button(onClick = {
                        val saved = editingID?.let { store.updateGroup(it, name, color) } ?: store.addGroup(name, color)
                        if (saved) { editingID = null; name = "" }
                    }, enabled = !state.readOnly && name.isNotBlank() && color.matches(Regex("#[0-9a-fA-F]{6}")), modifier = Modifier.heightIn(min = 48.dp)) { Text(if (editingID == null) "添加分组" else "保存修改") }
                }
                state.error?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
        }
    }
    deleting?.let { group -> AlertDialog(onDismissRequest = { deleting = null }, title = { Text("删除「${group.name}」？") }, text = { Text("分组中的事项和备注会保留，并移入未分组。") },
        confirmButton = { TextButton(onClick = { if (store.deleteGroup(group.id)) { deleting = null; if (editingID == group.id) { editingID = null; name = "" } } }) { Text("删除分组") } }, dismissButton = { TextButton(onClick = { deleting = null }) { Text("取消") } }) }
}
