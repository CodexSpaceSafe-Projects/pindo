package com.pindo.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.graphics.toColorInt
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable internal fun TaskEditorSheet(store: AppStore, state: AppState, taskID: String?, parentID: String?, initialDay: LocalDate, onDismiss: () -> Unit) {
    val task = state.tasks.find { it.id == taskID }
    val initialParent = state.tasks.find { it.id == parentID }
    val originalTitle = task?.title ?: ""
    val originalNote = task?.note ?: ""
    val originalDay = task?.day ?: initialParent?.day ?: initialDay
    val originalGroup = when { task != null -> task.groupID; initialParent != null -> initialParent.groupID; else -> state.preferences.defaultGroupID }
    val originalParent = task?.parentID ?: parentID
    var title by rememberSaveable(taskID, parentID) { mutableStateOf(originalTitle) }
    var note by rememberSaveable(taskID, parentID, stateSaver = TextFieldValue.Saver) { mutableStateOf(TextFieldValue(originalNote)) }
    var day by rememberSaveable(taskID, parentID) { mutableStateOf(originalDay.toString()) }
    var group by rememberSaveable(taskID, parentID) { mutableStateOf(originalGroup) }
    var parent by rememberSaveable(taskID, parentID) { mutableStateOf(originalParent) }
    var phase by rememberSaveable(taskID, parentID) { mutableStateOf(task?.phase ?: "pending") }
    var preview by rememberSaveable { mutableStateOf(false) }
    var datePicker by remember { mutableStateOf(false) }
    var parentPicker by remember { mutableStateOf(false) }
    var discard by remember { mutableStateOf(false) }
    var validation by remember { mutableStateOf<String?>(null) }
    val dirty = title != originalTitle || note.text != originalNote || day != originalDay.toString() || group != originalGroup || parent != originalParent || phase != (task?.phase ?: "pending")
    val requestClose = { if (dirty) discard = true else onDismiss() }
    DisposableEffect(Unit) { store.setEditing(true); onDispose { store.setEditing(false) } }
    fun save() {
        if (title.isBlank()) { validation = "先写下这件事的标题。"; return }
        val parsed = runCatching { LocalDate.parse(day) }.getOrNull()
        if (parsed == null) { validation = "请选择有效日期。"; return }
        val saved = if (taskID == null) store.addTask(title, note.text, parsed, group, parent)
            else store.editTask(taskID, title, note.text, parsed, group, parent, phase)
        if (saved) onDismiss()
    }
    Dialog(onDismissRequest = requestClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        BackHandler(onBack = requestClose)
        Surface(Modifier.fillMaxSize().testTag("task-editor"), color = MaterialTheme.colorScheme.background) {
            Scaffold(
                topBar = {
                    TopAppBar(title = { Text(if (taskID != null) "事项详情" else if (parentID != null) "添加子项" else "记录新事项", style = MaterialTheme.typography.titleMedium) },
                        navigationIcon = { IconButton(onClick = requestClose) { Icon(Icons.Outlined.Close, "关闭编辑") } },
                        actions = { Button(onClick = ::save, enabled = !state.readOnly && title.isNotBlank(), modifier = Modifier.padding(end = 12.dp)) { Icon(Icons.Outlined.Check, null, Modifier.size(18.dp)); Spacer(Modifier.width(5.dp)); Text("保存") } })
                }
            ) { padding ->
                Column(Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                    OutlinedTextField(title, { title = it; validation = null }, placeholder = { Text("准备做些什么？") },
                        modifier = Modifier.fillMaxWidth().testTag("task-title"), textStyle = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.SemiBold),
                        shape = RoundedCornerShape(18.dp), minLines = 2, maxLines = 5,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next))
                    if (taskID != null) {
                        EditorSection("事项状态", Icons.Outlined.CheckCircleOutline) {
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                listOf("pending" to "待办", "inProgress" to "进行中", "completed" to "已完成").forEach { (value, label) ->
                                    FilterChip(selected = phase == value, onClick = { phase = value }, label = { Text(label) },
                                        leadingIcon = if (phase == value) ({ Icon(Icons.Outlined.Check, null, Modifier.size(16.dp)) }) else null)
                                }
                            }
                            if (state.tasks.any { it.parentID == taskID && it.phase != "completed" }) Text("子项全部完成后，父项才能标记完成。", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    EditorSection("计划日期", Icons.Outlined.Event) {
                        Text(LocalDate.parse(day).format(DateTimeFormatter.ofPattern("M 月 d 日 · EEEE")), style = MaterialTheme.typography.titleMedium)
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            listOf(LocalDate.now() to "今天", LocalDate.now().plusDays(1) to "明天", LocalDate.now().plusDays(7) to "一周后").forEach { (date, label) ->
                                FilterChip(selected = day == date.toString(), onClick = { day = date.toString() }, label = { Text(label) })
                            }
                            AssistChip(onClick = { datePicker = true }, label = { Text("选择日期") }, leadingIcon = { Icon(Icons.Outlined.CalendarMonth, null, Modifier.size(16.dp)) })
                        }
                    }
                    EditorSection("所属分组", Icons.Outlined.FolderOpen) {
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                            FilterChip(selected = group == null, onClick = { group = null }, label = { Text("未分组") })
                            state.groups.forEach { item -> FilterChip(selected = group == item.id, onClick = { group = item.id },
                                label = { Text(item.name) }, leadingIcon = { Box(Modifier.size(11.dp).background(Color(item.color.toColorInt()), CircleShape)) }) }
                        }
                        if (state.groups.isEmpty()) Text("可以稍后在设置中建立工作、生活等分组。", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Surface(shape = RoundedCornerShape(18.dp), color = MaterialTheme.colorScheme.surfaceContainerLow, modifier = Modifier.fillMaxWidth().clickable { parentPicker = true }) {
                        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Outlined.SubdirectoryArrowRight, null, tint = MaterialTheme.colorScheme.primary)
                            Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                                Text("父事项", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Text(state.tasks.find { it.id == parent }?.title ?: "作为主待办", style = MaterialTheme.typography.bodyLarge, maxLines = 2)
                            }
                            Icon(Icons.Outlined.ChevronRight, null, tint = MaterialTheme.colorScheme.outline)
                        }
                    }
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Outlined.Notes, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(21.dp))
                            Text("备注", Modifier.weight(1f).padding(start = 9.dp), style = MaterialTheme.typography.titleSmall)
                            TextButton(onClick = { preview = !preview }) { Icon(if (preview) Icons.Outlined.Edit else Icons.Outlined.Visibility, null, Modifier.size(16.dp)); Spacer(Modifier.width(5.dp)); Text(if (preview) "继续编辑" else "预览") }
                        }
                        if (preview) {
                            Surface(shape = RoundedCornerShape(18.dp), color = MaterialTheme.colorScheme.surfaceContainerLow, modifier = Modifier.fillMaxWidth().heightIn(min = 180.dp)) {
                                MarkdownPreview(note.text, Modifier.padding(16.dp))
                            }
                        } else {
                            OutlinedTextField(note, { note = it }, placeholder = { Text("写下细节、清单或想法…\n支持 Markdown 格式") }, modifier = Modifier.fillMaxWidth().heightIn(min = 180.dp).testTag("task-note"), minLines = 6, shape = RoundedCornerShape(18.dp))
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                listOf("加粗" to "**", "斜体" to "*", "代码" to "`").forEach { (label, token) ->
                                    TextButton(onClick = { note = surroundNote(note, token, token) }, contentPadding = PaddingValues(horizontal = 10.dp)) { Text(label) }
                                }
                                TextButton(onClick = { note = surroundNote(note, "\n- [ ] ", "") }, contentPadding = PaddingValues(horizontal = 10.dp)) { Text("清单") }
                                TextButton(onClick = { note = surroundNote(note, "\n## ", "") }, contentPadding = PaddingValues(horizontal = 10.dp)) { Text("标题") }
                            }
                        }
                        Text("${note.text.length} 字符 · Markdown 原文保存在本地并加密同步", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    (validation ?: state.error)?.let { text ->
                        Surface(color = MaterialTheme.colorScheme.errorContainer, shape = RoundedCornerShape(14.dp)) { Text(text, Modifier.padding(13.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onErrorContainer) }
                    }
                    task?.json?.optDouble("updatedAt")?.takeIf { it.isFinite() }?.let { seconds ->
                        val updated = Instant.ofEpochMilli(((seconds + 978307200) * 1000).toLong()).atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ofPattern("yyyy/M/d HH:mm"))
                        Text("最近修改 $updated", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
        if (datePicker) {
            val pickerState = rememberDatePickerState(initialSelectedDateMillis = LocalDate.parse(day).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli())
            DatePickerDialog(onDismissRequest = { datePicker = false }, confirmButton = { TextButton(onClick = {
                pickerState.selectedDateMillis?.let { day = Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate().toString() }
                datePicker = false
            }) { Text("确定") } }, dismissButton = { TextButton(onClick = { datePicker = false }) { Text("取消") } }) { DatePicker(pickerState) }
        }
        if (parentPicker) ParentPicker(state.tasks, taskID, parent, onChoose = { parent = it; parentPicker = false }, onDismiss = { parentPicker = false })
        if (discard) AlertDialog(onDismissRequest = { discard = false }, title = { Text("放弃未保存的修改？") }, text = { Text("当前填写的内容还没有保存。") },
            confirmButton = { TextButton(onClick = onDismiss) { Text("放弃修改") } }, dismissButton = { TextButton(onClick = { discard = false }) { Text("继续编辑") } })
    }
}

@Composable private fun EditorSection(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) { Icon(icon, null, Modifier.size(21.dp), tint = MaterialTheme.colorScheme.primary); Text(title, Modifier.padding(start = 9.dp), style = MaterialTheme.typography.titleSmall) }
        content()
    }
}

@Composable private fun ParentPicker(tasks: List<Todo>, editingID: String?, selected: String?, onChoose: (String?) -> Unit, onDismiss: () -> Unit) {
    var search by rememberSaveable { mutableStateOf("") }
    val candidates = tasks.filter { candidate ->
        candidate.title.contains(search, true) && runCatching { TodoRules.validateParent(tasks, editingID, candidate.id) }.isSuccess
    }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("选择父事项") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedTextField(search, { search = it }, placeholder = { Text("搜索事项") }, leadingIcon = { Icon(Icons.Outlined.Search, null) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            LazyColumn(Modifier.heightIn(max = 360.dp)) {
                item { ListItem(headlineContent = { Text("作为主待办") }, leadingContent = { Icon(Icons.Outlined.FolderOpen, null) }, trailingContent = { if (selected == null) Icon(Icons.Outlined.Check, null, tint = MaterialTheme.colorScheme.primary) }, modifier = Modifier.clickable { onChoose(null) }) }
                items(candidates, key = { it.id }) { candidate ->
                    ListItem(headlineContent = { Text(candidate.title, maxLines = 2) }, supportingContent = { Text(if (candidate.parentID == null) "主待办" else "子待办") }, trailingContent = { if (candidate.id == selected) Icon(Icons.Outlined.Check, null, tint = MaterialTheme.colorScheme.primary) }, modifier = Modifier.clickable { onChoose(candidate.id) })
                }
                if (candidates.isEmpty()) item { Text("没有可用的父事项", Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
        }
    }, confirmButton = { TextButton(onClick = onDismiss) { Text("取消") } })
}

private fun surroundNote(value: TextFieldValue, prefix: String, suffix: String): TextFieldValue {
    val start = value.selection.min
    val end = value.selection.max
    val text = value.text.substring(0, start) + prefix + value.text.substring(start, end) + suffix + value.text.substring(end)
    return TextFieldValue(text, TextRange(start + prefix.length, end + prefix.length))
}
