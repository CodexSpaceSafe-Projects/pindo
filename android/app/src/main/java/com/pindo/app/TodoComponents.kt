package com.pindo.app

import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.selection.triStateToggleable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Notes
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import androidx.core.graphics.toColorInt
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

@Composable internal fun PindoSyncChip(state: AppState, onClick: () -> Unit) {
    val icon = when { state.readOnly -> Icons.Outlined.ErrorOutline; state.syncing -> Icons.Outlined.Sync; state.syncStatus.contains("失败") -> Icons.Outlined.CloudOff
        !state.syncEnabled -> Icons.Outlined.CloudOff; else -> Icons.Outlined.CloudDone }
    val label = when { state.readOnly -> "存储异常"; state.syncing -> "同步中"; state.syncStatus.contains("失败") -> "同步失败"; !state.syncEnabled -> "仅本机"; else -> "云同步" }
    Surface(onClick = onClick, shape = CircleShape, color = MaterialTheme.colorScheme.surfaceContainer) {
        Row(Modifier.heightIn(min = 48.dp).padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp),
                tint = if (state.readOnly || state.syncStatus.contains("失败")) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
            Text(label, style = MaterialTheme.typography.labelMedium)
        }
    }
}

@Composable internal fun PindoGroupPicker(groups: List<TodoGroup>, selected: String?, empty: String,
    modifier: Modifier = Modifier, includeUngrouped: Boolean = false, onSelect: (String?) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box(modifier) {
        OutlinedButton(onClick = { expanded = true }, contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)) {
            groups.find { it.id == selected }?.let { Box(Modifier.size(9.dp).background(Color(it.color.toColorInt()), CircleShape)); Spacer(Modifier.width(7.dp)) }
            Text(if (selected == "ungrouped") "未分组" else groups.find { it.id == selected }?.name ?: empty,
                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false).widthIn(max = 150.dp))
            Icon(Icons.Outlined.ExpandMore, null, Modifier.size(18.dp).padding(start = 3.dp))
        }
        DropdownMenu(expanded, onDismissRequest = { expanded = false }, modifier = Modifier.heightIn(max = 360.dp)) {
            DropdownMenuItem(text = { Text(empty) }, onClick = { expanded = false; onSelect(null) })
            if (includeUngrouped) DropdownMenuItem(text = { Text("未分组") }, onClick = { expanded = false; onSelect("ungrouped") })
            groups.forEach { group -> DropdownMenuItem(text = { Text(group.name) }, leadingIcon = {
                Box(Modifier.size(12.dp).background(Color(group.color.toColorInt()), CircleShape))
            }, onClick = { expanded = false; onSelect(group.id) }) }
        }
    }
}

internal fun LazyListScope.pindoTaskItems(rows: List<TaskOutlineEntry>, state: AppState,
    collapsed: Set<String>, onDisclosure: (String) -> Unit, onEdit: (String, Boolean) -> Unit,
    onAddChild: (String) -> Unit, onDelete: (Set<String>) -> Unit, store: AppStore,
    selected: Set<String>? = null, onSelect: (String) -> Unit = {}, onEnterSelection: ((String) -> Unit)? = null,
    horizontalPadding: Dp = 0.dp) {
    items(rows, key = { it.task.id }) { row ->
        Box(Modifier.padding(horizontal = horizontalPadding)) {
            PindoTaskRow(row, state, expanded = row.task.id !in collapsed, onDisclosure = { onDisclosure(row.task.id) },
                onEdit = { onEdit(row.task.id, false) }, onWrite = { onEdit(row.task.id, true) }, onAddChild = { onAddChild(row.task.id) },
                onDelete = { onDelete(setOf(row.task.id)) }, onMove = { store.move(row.task.id, it) },
                onPhase = { store.batchPhase(setOf(row.task.id), if (row.task.phase == "completed") "pending" else "completed") },
                onStart = { store.batchPhase(setOf(row.task.id), "inProgress") },
                onReset = { store.batchPhase(setOf(row.task.id), "pending") }, selected = selected?.contains(row.task.id),
                onSelect = { onSelect(row.task.id) }, onEnterSelection = onEnterSelection?.let { callback -> { callback(row.task.id) } })
        }
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class, ExperimentalLayoutApi::class)
@Composable private fun PindoTaskRow(entry: TaskOutlineEntry, state: AppState, expanded: Boolean,
    onDisclosure: () -> Unit, onEdit: () -> Unit, onWrite: () -> Unit, onAddChild: () -> Unit, onDelete: () -> Unit,
    onMove: (Int) -> Unit, onPhase: () -> Unit, onStart: () -> Unit, onReset: () -> Unit,
    selected: Boolean?, onSelect: () -> Unit, onEnterSelection: (() -> Unit)?) {
    val task = entry.task
    val children = state.tasks.filter { it.parentID == task.id }
    val group = state.groups.find { it.id == task.groupID }
    var menu by remember { mutableStateOf(false) }
    val editable = !state.readOnly && entry.matchesQuery
    val today = LocalDate.now()
    val overdue = task.day < today && task.phase != "completed"
    Column(Modifier.fillMaxWidth().padding(start = (entry.depth * 12).dp)) {
        Surface(color = if (selected == true) MaterialTheme.colorScheme.primaryContainer else Color.Transparent,
            shape = MaterialTheme.shapes.medium) {
            Row(Modifier.fillMaxWidth().heightIn(min = 68.dp)
                .combinedClickable(enabled = selected == null || editable,
                    onClickLabel = if (selected != null) "选择事项" else "阅读事项",
                    onClick = { if (selected != null) onSelect() else onEdit() },
                    onLongClickLabel = "事项操作", onLongClick = if (selected == null && editable) ({ menu = true }) else null),
                verticalAlignment = Alignment.Top) {
                Box(Modifier.padding(top = 8.dp)) {
                    if (selected != null) Checkbox(checked = selected, onCheckedChange = { onSelect() }, enabled = editable, modifier = Modifier.size(48.dp))
                    else PindoPhaseCircle(task.title, task.phase, editable, onPhase, children.size)
                }
                Column(Modifier.weight(1f).padding(start = 4.dp, top = 14.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text(spacedText(task.title), style = MaterialTheme.typography.bodyLarge,
                        maxLines = 3, overflow = TextOverflow.Ellipsis,
                        textDecoration = if (task.phase == "completed") TextDecoration.LineThrough else TextDecoration.None,
                        color = if (task.phase == "completed" || !entry.matchesQuery) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface)
                    val labels = listOfNotNull(if (!entry.matchesQuery) "所在父项" else null,
                        if (task.day != today) relativeDay(task.day, today) else null,
                        if (task.phase == "inProgress") "进行中" else null, group?.name)
                    if (labels.isNotEmpty() || task.note.isNotBlank()) Row(verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        if (group != null) Box(Modifier.size(5.dp).background(Color(group.color.toColorInt()), CircleShape))
                        if (labels.isNotEmpty()) Text(labels.joinToString(" · "), modifier = Modifier.weight(1f, fill = false),
                            style = MaterialTheme.typography.bodySmall, maxLines = 2, overflow = TextOverflow.Ellipsis,
                            color = if (overdue) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                        if (task.note.isNotBlank()) Icon(Icons.AutoMirrored.Outlined.Notes, "含备注", Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (children.isNotEmpty() && selected == null) {
                        TextButton(onClick = onDisclosure, contentPadding = PaddingValues(horizontal = 0.dp),
                            modifier = Modifier.heightIn(min = 48.dp).semantics {
                                contentDescription = (if (expanded) "收起子项：" else "展开子项：") + task.title
                            }) {
                            Icon(if (expanded) Icons.Outlined.ExpandMore else Icons.Outlined.ChevronRight,
                                null, Modifier.size(18.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("子项 ${children.count { it.phase == "completed" }}/${children.size}", style = MaterialTheme.typography.labelMedium)
                        }
                    }
                }
                if (selected == null) Box(Modifier.padding(top = 8.dp)) {
                    IconButton(onClick = { menu = true }, enabled = editable, modifier = Modifier.size(48.dp)) {
                        Icon(Icons.Outlined.MoreHoriz, "事项操作：" + task.title, Modifier.size(21.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(text = { Text("修改待办") }, leadingIcon = { Icon(Icons.Outlined.Edit, null) }, onClick = { menu = false; onWrite() })
                        DropdownMenuItem(text = { Text("打开备注") }, leadingIcon = { Icon(Icons.AutoMirrored.Outlined.Notes, null) }, onClick = { menu = false; onEdit() })
                        if (task.phase != "inProgress") DropdownMenuItem(text = { Text("开始进行") }, leadingIcon = { Icon(Icons.Outlined.PlayArrow, null) }, onClick = { menu = false; onStart() })
                        if (task.phase == "inProgress") DropdownMenuItem(text = { Text("标记待办") }, leadingIcon = { Icon(Icons.Outlined.RadioButtonUnchecked, null) }, onClick = { menu = false; onReset() })
                        if (entry.depth < 2) DropdownMenuItem(text = { Text("添加子项") }, leadingIcon = { Icon(Icons.Outlined.Add, null) }, onClick = { menu = false; onAddChild() })
                        if (onEnterSelection != null) DropdownMenuItem(text = { Text("选择事项") }, leadingIcon = { Icon(Icons.Outlined.CheckBox, null) }, onClick = { menu = false; onEnterSelection() })
                        HorizontalDivider()
                        DropdownMenuItem(text = { Text("上移") }, leadingIcon = { Icon(Icons.Outlined.ArrowUpward, null) }, onClick = { menu = false; onMove(-1) })
                        DropdownMenuItem(text = { Text("下移") }, leadingIcon = { Icon(Icons.Outlined.ArrowDownward, null) }, onClick = { menu = false; onMove(1) })
                        DropdownMenuItem(text = { Text("删除待办", color = MaterialTheme.colorScheme.error) }, leadingIcon = { Icon(Icons.Outlined.DeleteOutline, null, tint = MaterialTheme.colorScheme.error) }, onClick = { menu = false; onDelete() })
                    }
                }
            }
        }
        HorizontalDivider(Modifier.padding(start = 52.dp, end = 8.dp), color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = .65f))
    }
}

@Composable private fun PindoPhaseCircle(title: String, phase: String, enabled: Boolean, onClick: () -> Unit, childCount: Int) {
    val state = when (phase) { "completed" -> ToggleableState.On; "inProgress" -> ToggleableState.Indeterminate; else -> ToggleableState.Off }
    Box(Modifier.size(48.dp).triStateToggleable(state, enabled = enabled, role = Role.Checkbox, onClick = onClick)
        .semantics {
            contentDescription = (if (phase == "completed") "恢复待办：" else "完成事项：") + title + if (childCount > 0) "，含 $childCount 个子项" else ""
            stateDescription = when (phase) { "inProgress" -> "进行中"; "completed" -> "已完成"; else -> "待办" }
        },
        contentAlignment = Alignment.Center) {
        Icon(when (phase) { "completed" -> Icons.Filled.CheckCircle; "inProgress" -> Icons.Outlined.RemoveCircleOutline; else -> Icons.Outlined.RadioButtonUnchecked },
            contentDescription = null, modifier = Modifier.size(23.dp), tint = if (!enabled) MaterialTheme.colorScheme.outlineVariant
            else if (phase == "pending") MaterialTheme.colorScheme.outline else MaterialTheme.colorScheme.primary)
    }
}

@Composable internal fun PindoEmptyState(title: String, description: String, icon: ImageVector = Icons.Outlined.TaskAlt,
    actionLabel: String? = null, onAction: () -> Unit = {}) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 34.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Surface(shape = CircleShape, color = MaterialTheme.colorScheme.primaryContainer) {
            Icon(icon, contentDescription = null, modifier = Modifier.padding(19.dp).size(30.dp), tint = MaterialTheme.colorScheme.primary)
        }
        Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Text(description, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (actionLabel != null) TextButton(onClick = onAction) { Text(actionLabel) }
    }
}

@Composable internal fun PindoErrorMessage(message: String?, dismiss: () -> Unit) {
    if (message != null) Surface(color = MaterialTheme.colorScheme.errorContainer, shape = RoundedCornerShape(14.dp)) {
        Row(Modifier.fillMaxWidth().padding(start = 14.dp, top = 5.dp, bottom = 5.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.Info, contentDescription = null, modifier = Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onErrorContainer)
            Text(message, Modifier.weight(1f).padding(horizontal = 10.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onErrorContainer)
            IconButton(onClick = dismiss) { Icon(Icons.Outlined.Close, "关闭提示", tint = MaterialTheme.colorScheme.onErrorContainer) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun PindoDatePickerDialog(initial: LocalDate, onDismiss: () -> Unit, onSelect: (LocalDate) -> Unit) {
    val state = rememberDatePickerState(initialSelectedDateMillis = initial.toEpochDay() * 86_400_000L)
    DatePickerDialog(onDismissRequest = onDismiss, confirmButton = {
        TextButton(onClick = { state.selectedDateMillis?.let { onSelect(LocalDate.ofEpochDay(it / 86_400_000L)) } }) { Text("确定") }
    }, dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } }) { DatePicker(state) }
}

internal fun relativeDay(day: LocalDate, today: LocalDate = LocalDate.now()): String = when (day) {
    today -> "今天"
    today.plusDays(1) -> "明天"
    today.minusDays(1) -> "昨天"
    else -> if (day < today) "逾期 " + ChronoUnit.DAYS.between(day, today) + " 天"
        else day.format(DateTimeFormatter.ofPattern("M月d日", Locale.SIMPLIFIED_CHINESE))
}

/** Scaffold and bottom-sheet bodies can be subcomposed after their parent
 * effects. Initial focus belongs to the actual, attached input node. */
@Composable internal fun Modifier.initialInputFocus(requester: FocusRequester, requested: Boolean, onFocused: () -> Unit = {}): Modifier {
    var placed by remember { mutableStateOf(false) }
    LaunchedEffect(placed, requested) {
        if (placed && requested) { requester.requestFocus(); onFocused() }
    }
    return focusRequester(requester).onGloballyPositioned { placed = true }
}
