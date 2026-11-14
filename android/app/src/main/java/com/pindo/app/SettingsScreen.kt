package com.pindo.app

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.core.graphics.toColorInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.time.LocalDate

@OptIn(ExperimentalLayoutApi::class)
@Composable internal fun AppSettingsScreen(store: AppStore, state: AppState, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var cloudOpen by rememberSaveable { mutableStateOf(false) }
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
        CloudSettingsScreen() { cloudOpen = false }
        return
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 18.dp, bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("设置", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
            Text("让 Pindo 更适合你的每一天", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
        }
        Surface(color = MaterialTheme.colorScheme.primaryContainer, shape = RoundedCornerShape(24.dp)) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.primary.copy(alpha = .12f)) {
                        Icon(Icons.Outlined.Security, null, Modifier.padding(13.dp).size(26.dp), tint = MaterialTheme.colorScheme.primary)
                    }
                    Column(Modifier.weight(1f).padding(start = 14.dp)) {
                        Text(if (state.syncEnabled) "已连接加密同步" else "安心记录，本地优先", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                        Text(if (state.syncEnabled) state.syncStatus else "离线也能随时记录和管理", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceAround) {
                    SettingsCount(state.tasks.size.toString(), "全部事项")
                    SettingsCount(state.tasks.count { it.phase != "completed" }.toString(), "未完成")
                    SettingsCount(state.groups.size.toString(), "我的分组")
                }
            }
        }
        SettingsSection("偏好设置") {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.Palette, null, tint = MaterialTheme.colorScheme.primary)
                    Text("外观", Modifier.padding(start = 12.dp), style = MaterialTheme.typography.titleSmall)
                }
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(Triple("system", "跟随系统", Icons.Outlined.Smartphone), Triple("light", "浅色", Icons.Outlined.LightMode), Triple("dark", "深色", Icons.Outlined.DarkMode)).forEach { (value, label, icon) ->
                        FilterChip(selected = state.preferences.theme == value, onClick = { store.setTheme(value) },
                            label = { Text(label) }, leadingIcon = { Icon(icon, null, Modifier.size(17.dp)) })
                    }
                }
            }
            HorizontalDivider(Modifier.padding(horizontal = 16.dp))
            Box {
                SettingsRow(Icons.Outlined.FolderOpen, "新待办默认分组", state.groups.find { it.id == state.preferences.defaultGroupID }?.name ?: "未分组") { defaultMenu = true }
                DropdownMenu(defaultMenu, onDismissRequest = { defaultMenu = false }) {
                    DropdownMenuItem(text = { Text("未分组") }, onClick = { store.setDefaultGroup(null); defaultMenu = false })
                    state.groups.forEach { group ->
                        DropdownMenuItem(text = { GroupName(group) }, onClick = { store.setDefaultGroup(group.id); defaultMenu = false })
                    }
                }
            }
            HorizontalDivider(Modifier.padding(horizontal = 16.dp))
            SettingsRow(Icons.Outlined.Folder, "分组管理", "名称、颜色与事项数量") { groupsOpen = true }
        }
        SettingsSection("数据与同步") {
            SettingsRow(Icons.Outlined.CloudSync, "云同步", "Cloudflare 同步正在开发 · 仅本机保存") { cloudOpen = true }
            HorizontalDivider(Modifier.padding(horizontal = 16.dp))
            SettingsRow(Icons.Outlined.FileDownload, "导出资料", "保存待办、分组与 Markdown 备注", !busy && !state.readOnly) { export.launch("Pindo-${LocalDate.now()}.json") }
            HorizontalDivider(Modifier.padding(horizontal = 16.dp))
            SettingsRow(Icons.Outlined.FileUpload, "导入资料", "支持 Android 与 macOS 导出的 JSON", !busy && !state.readOnly) { import.launch(arrayOf("application/json", "text/plain", "application/octet-stream")) }
            HorizontalDivider(Modifier.padding(horizontal = 16.dp))
            SettingsRow(Icons.Outlined.Restore, "恢复上次导入前的资料", if (state.hasLocalBackup) "已保留一份本机保护备份" else "导入资料时会自动建立保护备份", state.hasLocalBackup && !busy && !state.readOnly) { restoring = true }
        }
        Text("导出文件为明文，请自行保管；同步凭据和恢复密钥不会导出。导入会替换当前清单，并自动保留操作前的本机备份。", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
        if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        (message ?: state.error)?.let { text ->
            Surface(color = MaterialTheme.colorScheme.secondaryContainer, shape = RoundedCornerShape(14.dp)) {
                Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(text, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
                    IconButton(onClick = { message = null; store.dismissError() }) { Icon(Icons.Outlined.Close, "关闭提示") }
                }
            }
        }
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text("Pindo", fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.primary)
            Text("轻一点，专注每一件事", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelSmall)
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

@Composable private fun SettingsCount(value: String, label: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable private fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
        Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 4.dp))
        Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surface, tonalElevation = 1.dp) { Column(content = content) }
    }
}

@Composable private fun SettingsRow(icon: ImageVector, title: String, subtitle: String, enabled: Boolean = true, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(enabled = enabled, onClick = onClick).padding(horizontal = 16.dp, vertical = 15.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = if (enabled) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline)
        Column(Modifier.weight(1f).padding(horizontal = 13.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge, color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.outline)
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Icon(Icons.Outlined.ChevronRight, null, tint = MaterialTheme.colorScheme.outline, modifier = Modifier.size(20.dp))
    }
}

@Composable private fun GroupName(group: TodoGroup) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(12.dp).background(Color(group.color.toColorInt()), CircleShape))
        Text(group.name, Modifier.padding(start = 10.dp))
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun CloudSettingsScreen(onBack: () -> Unit) {
    BackHandler(onBack = onBack)
    Scaffold(topBar = { TopAppBar(title = { Text("云同步") }, navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.Outlined.ArrowBack, "返回设置") } }) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(20.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Text("Cloudflare", style = MaterialTheme.typography.titleLarge)
            Text("Cloudflare 同步正在开发，当前仅保存在本机。")
            Text("旧云服务已停用。本机资料、离线修改和恢复信息会继续保留。")
            Text("可在设置中导出待办、分组和备注。", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable internal fun GroupDialog(store: AppStore, state: AppState, onDismiss: () -> Unit) {
    var editingID by rememberSaveable { mutableStateOf<String?>(null) }
    var name by rememberSaveable { mutableStateOf("") }
    var color by rememberSaveable { mutableStateOf("#4477AA") }
    var deleting by remember { mutableStateOf<TodoGroup?>(null) }
    val colors = listOf("#4477AA" to "青蓝", "#EE6677" to "珊瑚", "#228833" to "松绿", "#CCBB44" to "姜黄", "#66CCEE" to "天青", "#AA3377" to "紫红", "#BBBBBB" to "岩灰")
    DisposableEffect(Unit) { val lease = store.beginEditing(); onDispose { store.endEditing(lease) } }
    Dialog(onDismissRequest = onDismiss) {
        Surface(shape = RoundedCornerShape(26.dp), color = MaterialTheme.colorScheme.surface) {
            Column(Modifier.heightIn(max = 640.dp).verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) { Text("我的分组", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold); Text("用颜色整理不同的生活片段", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    IconButton(onClick = onDismiss) { Icon(Icons.Outlined.Close, "关闭分组管理") }
                }
                state.groups.forEach { group ->
                    Row(Modifier.fillMaxWidth().background(if (editingID == group.id) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceContainerLow, RoundedCornerShape(14.dp)).padding(start = 12.dp, top = 5.dp, bottom = 5.dp), verticalAlignment = Alignment.CenterVertically) {
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
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    colors.forEach { (hex, label) ->
                        FilterChip(selected = color.equals(hex, true), onClick = { color = hex }, label = { Text(label) }, leadingIcon = { Box(Modifier.size(14.dp).background(Color(hex.toColorInt()), CircleShape)) })
                    }
                }
                OutlinedTextField(color, { color = it }, label = { Text("自定义颜色 #RRGGBB") }, modifier = Modifier.fillMaxWidth(), singleLine = true, isError = !color.matches(Regex("#[0-9a-fA-F]{6}")))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    if (editingID != null) TextButton(onClick = { editingID = null; name = "" }) { Text("取消编辑") }
                    Button(onClick = {
                        val saved = editingID?.let { store.updateGroup(it, name, color) } ?: store.addGroup(name, color)
                        if (saved) { editingID = null; name = "" }
                    }, enabled = !state.readOnly && name.isNotBlank() && color.matches(Regex("#[0-9a-fA-F]{6}"))) { Text(if (editingID == null) "添加分组" else "保存修改") }
                }
                state.error?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
            }
        }
    }
    deleting?.let { group -> AlertDialog(onDismissRequest = { deleting = null }, title = { Text("删除「${group.name}」？") }, text = { Text("分组中的事项和备注会保留，并移入未分组。") },
        confirmButton = { TextButton(onClick = { if (store.deleteGroup(group.id)) { deleting = null; if (editingID == group.id) { editingID = null; name = "" } } }) { Text("删除分组") } }, dismissButton = { TextButton(onClick = { deleting = null }) { Text("取消") } }) }
}
