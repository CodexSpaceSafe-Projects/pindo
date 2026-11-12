package com.pindo.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.time.LocalDate

private data class TaskEditor(val task: Todo? = null, val parent: Todo? = null)

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun PindoScreen(store: AppStore) {
    val state by store.state.collectAsStateWithLifecycle()
    var settings by rememberSaveable { mutableStateOf(false) }
    var groupsOpen by remember { mutableStateOf(false) }
    var editorKey by rememberSaveable { mutableStateOf<String?>(null) }
    val editor = editorKey?.let { key ->
        when {
            key.startsWith("edit:") -> state.tasks.find { it.id == key.removePrefix("edit:") }?.let { TaskEditor(task = it) }
            key.startsWith("child:") -> state.tasks.find { it.id == key.removePrefix("child:") }?.let { TaskEditor(parent = it) }
            else -> TaskEditor()
        }
    }
    var deleting by remember { mutableStateOf<Todo?>(null) }
    var dayText by rememberSaveable { mutableStateOf(LocalDate.now().toString()) }
    var filter by rememberSaveable { mutableStateOf<String?>(null) }
    var query by rememberSaveable { mutableStateOf("") }
    var completed by rememberSaveable { mutableStateOf(false) }
    var collapsed by rememberSaveable { mutableStateOf(emptyList<String>()) }
    val day = LocalDate.parse(dayText)
    if (settings) {
        CloudSettingsScreen(store, state) { settings = false }
        return
    }
    Scaffold(
        topBar = {
            TopAppBar(title = { Text("Pindo", fontWeight = FontWeight.SemiBold) }, actions = {
                TextButton(onClick = { groupsOpen = true }, enabled = !state.readOnly) { Text("分组") }
                TextButton(onClick = { store.requestSync(true) }, enabled = state.syncEnabled && !state.syncing && !state.readOnly) { Text(if (state.syncing) "同步中" else "同步") }
                TextButton(onClick = { settings = true }) { Text("设置") }
            })
        },
        floatingActionButton = {
            if (!state.readOnly) FloatingActionButton(onClick = { editorKey = "new" }) { Text("＋", fontSize = 28.sp) }
        },
        bottomBar = {
            Surface(tonalElevation = 2.dp) {
                Column(Modifier.navigationBarsPadding().padding(horizontal = 12.dp, vertical = 4.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        TextButton(onClick = { dayText = day.minusDays(1).toString() }) { Text("‹") }
                        TextButton(onClick = { dayText = LocalDate.now().toString() }, Modifier.weight(1f)) { Text(if (day == LocalDate.now()) "今天 · $day" else day.toString()) }
                        TextButton(onClick = { dayText = day.plusDays(1).toString() }) { Text("›") }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        GroupPicker(state.groups, filter, "全部分组", Modifier.weight(1f), includeUngrouped = true) { filter = it }
                        FilterChip(selected = completed, onClick = { completed = !completed }, label = { Text(if (completed) "已完成" else "未完成") })
                    }
                }
            }
        }
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            Text(state.syncStatus, Modifier.padding(horizontal = 18.dp, vertical = 4.dp), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            ErrorMessage(state.error, store::dismissError)
            OutlinedTextField(value = query, onValueChange = { query = it }, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
                placeholder = { Text("搜索标题或备注") }, singleLine = true)
            val matching = state.tasks.filter { task ->
                (if (completed) task.phase == "completed" && task.day == day else task.phase != "completed" &&
                    (task.day == day || task.phase == "inProgress" || day == LocalDate.now() && task.day < day)) &&
                    (filter == null || if (filter == "ungrouped") task.groupID == null else task.groupID == filter) &&
                    (query.isBlank() || task.title.contains(query, true) || task.note.contains(query, true))
            }
            val byID = state.tasks.associateBy { it.id }
            val roots = matching.map { task ->
                var root = task
                val seen = mutableSetOf(root.id)
                while (root.parentID != null && seen.add(root.parentID!!)) root = byID[root.parentID] ?: break
                root.id
            }.toSet()
            data class Row(val task: Todo, val depth: Int)
            val rows = mutableListOf<Row>()
            fun append(parent: String?, depth: Int) {
                state.tasks.filter { it.parentID == parent && (parent != null || it.id in roots) }
                    .sortedWith(compareBy<Todo> { it.order }.thenBy { it.id }).forEach { task ->
                        rows.add(Row(task, depth))
                        if (task.id !in collapsed) append(task.id, depth + 1)
                    }
            }
            append(null, 0)
            if (rows.isEmpty()) {
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    Text(if (state.readOnly) "资料暂不可编辑" else if (query.isBlank()) "没有${if (completed) "已完成" else "未完成"}事项" else "没有匹配的事项", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } else LazyColumn(contentPadding = PaddingValues(start = 12.dp, end = 12.dp, top = 6.dp, bottom = 80.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                items(rows, key = { it.task.id }) { row ->
                    val task = row.task
                    TaskRow(task, state.groups.find { it.id == task.groupID }, row.depth,
                        hasChildren = state.tasks.any { it.parentID == task.id }, expanded = task.id !in collapsed,
                        enabled = !state.readOnly,
                        onToggle = { store.advancePhase(task.id) },
                        onDisclosure = { collapsed = if (task.id in collapsed) collapsed - task.id else collapsed + task.id },
                        onEdit = { editorKey = "edit:${task.id}" }, onAddChild = { editorKey = "child:${task.id}" },
                        onDelete = { deleting = task }, onMove = { store.move(task.id, it) })
                }
            }
        }
    }
    editor?.let { value ->
        DisposableEffect(Unit) { store.setEditing(true); onDispose { store.setEditing(false) } }
        TaskEditorDialog(value, state, day,
        onDismiss = { editorKey = null }, onSave = { title, note, date, group, parent ->
            val saved = value.task?.let { store.editTask(it.id, title, note, date, group, parent) }
                ?: store.addTask(title, note, date, group, parent)
            if (saved) editorKey = null
        }) }
    deleting?.let { task ->
        val count = TodoRules.descendants(state.tasks, task.id).size
        AlertDialog(onDismissRequest = { deleting = null }, title = { Text("删除待办？") },
            text = { Text(if (count == 1) "这条待办及备注将被删除。" else "将同时删除这条待办、全部子项和备注，共 $count 条。") },
            confirmButton = { TextButton(onClick = { store.deleteTask(task.id); deleting = null }) { Text("删除") } },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("取消") } })
    }
    if (groupsOpen) GroupDialog(store, state) { groupsOpen = false }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable private fun TaskRow(task: Todo, group: TodoGroup?, depth: Int, hasChildren: Boolean, expanded: Boolean, enabled: Boolean,
    onToggle: () -> Unit, onDisclosure: () -> Unit, onEdit: () -> Unit, onAddChild: () -> Unit, onDelete: () -> Unit, onMove: (Int) -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val groupColor = group?.let { Color(android.graphics.Color.parseColor(it.color)) } ?: MaterialTheme.colorScheme.outlineVariant
    Row(Modifier.padding(start = (depth * 17).dp).clip(RoundedCornerShape(9.dp)).background(MaterialTheme.colorScheme.surfaceContainer)
        .height(IntrinsicSize.Min).combinedClickable(enabled = enabled, onClick = onEdit, onLongClick = { menu = true }), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.width(5.dp).fillMaxHeight().background(groupColor))
        if (hasChildren) TextButton(onClick = onDisclosure, contentPadding = PaddingValues(0.dp), modifier = Modifier.width(30.dp)) { Text(if (expanded) "▾" else "▸") }
        else Spacer(Modifier.width(8.dp))
        PhaseCircle(task.phase, enabled, onToggle)
        Text(task.title, Modifier.weight(1f).padding(horizontal = 10.dp, vertical = 11.dp), fontSize = 16.sp,
            textDecoration = if (task.phase == "completed") TextDecoration.LineThrough else TextDecoration.None,
            color = if (task.phase == "completed") MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface)
        if (task.note.isNotBlank()) TextButton(onClick = onEdit, contentPadding = PaddingValues(3.dp), modifier = Modifier.width(34.dp)) { Text("▤", modifier = Modifier.semantics { contentDescription = "打开备注" }) }
        Box {
            TextButton(onClick = { menu = true }, enabled = enabled, contentPadding = PaddingValues(2.dp), modifier = Modifier.width(30.dp)) { Text("⋮") }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text("修改待办 / 打开备注") }, onClick = { menu = false; onEdit() })
                if (depth < 2) DropdownMenuItem(text = { Text("添加子项") }, onClick = { menu = false; onAddChild() })
                HorizontalDivider()
                DropdownMenuItem(text = { Text("上移") }, onClick = { menu = false; onMove(-1) })
                DropdownMenuItem(text = { Text("下移") }, onClick = { menu = false; onMove(1) })
                DropdownMenuItem(text = { Text("删除待办") }, onClick = { menu = false; onDelete() })
            }
        }
    }
}

@Composable private fun PhaseCircle(phase: String, enabled: Boolean, onClick: () -> Unit) {
    val green = Color(0xFF309B66)
    val outline = if (phase == "pending") MaterialTheme.colorScheme.outline else green
    Canvas(Modifier.size(32.dp).semantics { contentDescription = when (phase) { "inProgress" -> "进行中，点击完成"; "completed" -> "已完成，点击恢复待办"; else -> "待办，点击开始" } }
        .clickable(enabled = enabled, onClick = onClick).padding(4.dp)) {
        val r = size.minDimension / 2 - 1.dp.toPx(); val cx = size.width / 2; val cy = size.height / 2
        if (phase == "completed") {
            drawCircle(green, r)
            drawPath(Path().apply { moveTo(cx - r * .5f, cy); lineTo(cx - r * .1f, cy + r * .4f); lineTo(cx + r * .55f, cy - r * .4f) }, Color.White, style = Stroke(2.dp.toPx()))
        } else {
            if (phase == "inProgress") drawPath(Path().apply {
                moveTo(cx, cy - r)
                arcTo(Rect(cx - r, cy - r, cx + r, cy + r), -90f, 180f, false)
                cubicTo(cx + r * .75f, cy + r, cx + r * .75f, cy, cx, cy)
                cubicTo(cx - r * .75f, cy, cx - r * .75f, cy - r, cx, cy - r)
                close()
            }, green)
            drawCircle(outline, r, style = Stroke(1.6.dp.toPx()))
        }
    }
}

@Composable private fun GroupPicker(groups: List<TodoGroup>, selected: String?, empty: String, modifier: Modifier = Modifier,
    includeUngrouped: Boolean = false, onSelect: (String?) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box(modifier) {
        TextButton(onClick = { expanded = true }) {
            groups.find { it.id == selected }?.let { Box(Modifier.size(10.dp).background(Color(android.graphics.Color.parseColor(it.color)), RoundedCornerShape(3.dp))); Spacer(Modifier.width(6.dp)) }
            Text(if (selected == "ungrouped") "未分组" else groups.find { it.id == selected }?.name ?: empty)
            Text(" ▾")
        }
        DropdownMenu(expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(text = { Text(empty) }, onClick = { expanded = false; onSelect(null) })
            if (includeUngrouped) DropdownMenuItem(text = { Text("未分组") }, onClick = { expanded = false; onSelect("ungrouped") })
            groups.forEach { group -> DropdownMenuItem(text = {
                Row(verticalAlignment = Alignment.CenterVertically) { Box(Modifier.size(12.dp).background(Color(android.graphics.Color.parseColor(group.color)), RoundedCornerShape(3.dp))); Spacer(Modifier.width(10.dp)); Text(group.name) }
            }, onClick = { expanded = false; onSelect(group.id) }) }
        }
    }
}

@Composable private fun TaskEditorDialog(editor: TaskEditor, state: AppState, selectedDay: LocalDate, onDismiss: () -> Unit,
    onSave: (String, String, LocalDate, String?, String?) -> Unit) {
    var title by rememberSaveable { mutableStateOf(editor.task?.title ?: "") }
    var note by rememberSaveable { mutableStateOf(editor.task?.note ?: "") }
    var day by rememberSaveable { mutableStateOf((editor.task?.day ?: editor.parent?.day ?: selectedDay).toString()) }
    var group by rememberSaveable { mutableStateOf(editor.task?.groupID ?: editor.parent?.groupID) }
    var parent by rememberSaveable { mutableStateOf(editor.task?.parentID ?: editor.parent?.id) }
    var parentMenu by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text(if (editor.task != null) "修改待办" else if (editor.parent != null) "添加子项" else "添加待办") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(title, { title = it }, label = { Text("事项标题") }, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(note, { note = it }, label = { Text("备注 · Markdown 原文") }, modifier = Modifier.fillMaxWidth(), minLines = 4, maxLines = 8)
                OutlinedTextField(day, { day = it }, label = { Text("日期 YYYY-MM-DD") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                GroupPicker(state.groups, group, "未分组") { group = it }
                Box {
                    TextButton(onClick = { parentMenu = true }) { Text("父项：${state.tasks.find { it.id == parent }?.title ?: "主待办"} ▾") }
                    DropdownMenu(parentMenu, onDismissRequest = { parentMenu = false }) {
                        DropdownMenuItem(text = { Text("主待办") }, onClick = { parent = null; parentMenu = false })
                        state.tasks.filter { candidate -> runCatching { TodoRules.validateParent(state.tasks, editor.task?.id, candidate.id) }.isSuccess }
                            .forEach { candidate -> DropdownMenuItem(text = { Text(candidate.title) }, onClick = { parent = candidate.id; parentMenu = false }) }
                    }
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        }, confirmButton = { TextButton(onClick = {
            val parsed = runCatching { LocalDate.parse(day) }.getOrNull()
            when { title.isBlank() -> error = "请填写事项内容。"; parsed == null -> error = "日期格式应为 YYYY-MM-DD。"; else -> onSave(title, note, parsed, group, parent) }
        }, enabled = !state.readOnly) { Text("保存") } }, dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } })
}

@Composable private fun ErrorMessage(message: String?, dismiss: () -> Unit) {
    if (message != null) Surface(color = MaterialTheme.colorScheme.errorContainer, modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp), shape = RoundedCornerShape(8.dp)) {
        Row(Modifier.padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(message, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
            TextButton(onClick = dismiss) { Text("关闭") }
        }
    }
}
