package com.pindo.app

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Notes
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.graphics.toColorInt
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

@Composable internal fun PindoPageHeader(title: String, subtitle: String, trailing: @Composable () -> Unit = {}) {
    Row(Modifier.fillMaxWidth().padding(top = 12.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
            Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 5.dp))
        }
        trailing()
    }
}

@Composable internal fun PindoSyncChip(state: AppState, onClick: () -> Unit) {
    val icon = when { state.syncing -> Icons.Outlined.Sync; !state.syncEnabled -> Icons.Outlined.CloudOff
        state.syncStatus.contains("失败") -> Icons.Outlined.CloudOff; else -> Icons.Outlined.CloudDone }
    val label = when { state.syncing -> "同步中"; !state.syncEnabled -> "本机保存"; state.syncStatus.contains("失败") -> "同步失败"; else -> "云同步" }
    Surface(onClick = onClick, shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh) {
        Row(Modifier.padding(horizontal = 10.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.primary)
            Text(label, style = MaterialTheme.typography.labelMedium)
        }
    }
}

@Composable internal fun PindoGroupChips(groups: List<TodoGroup>, selected: String?, onSelect: (String?) -> Unit) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FilterChip(selected = selected == null, onClick = { onSelect(null) }, label = { Text("全部分组") },
            leadingIcon = { Icon(Icons.Outlined.Widgets, null, Modifier.size(16.dp)) })
        groups.forEach { group ->
            FilterChip(selected = selected == group.id, onClick = { onSelect(group.id) }, label = {
                Text(group.name, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 130.dp))
            }, leadingIcon = { Box(Modifier.size(9.dp).background(Color(group.color.toColorInt()), CircleShape)) })
        }
        FilterChip(selected = selected == "ungrouped", onClick = { onSelect("ungrouped") }, label = { Text("未分组") })
    }
}

@Composable internal fun PindoGroupPicker(groups: List<TodoGroup>, selected: String?, empty: String,
    modifier: Modifier = Modifier, includeUngrouped: Boolean = false, onSelect: (String?) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box(modifier) {
        OutlinedButton(onClick = { expanded = true }, contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)) {
            groups.find { it.id == selected }?.let { Box(Modifier.size(9.dp).background(Color(it.color.toColorInt()), CircleShape)); Spacer(Modifier.width(7.dp)) }
            Text(if (selected == "ungrouped") "未分组" else groups.find { it.id == selected }?.name ?: empty,
                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 150.dp))
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
    collapsed: Set<String>, onDisclosure: (String) -> Unit, onEdit: (String) -> Unit,
    onAddChild: (String) -> Unit, onDelete: (Set<String>) -> Unit, store: AppStore,
    selected: Set<String>? = null, onSelect: (String) -> Unit = {}, onEnterSelection: ((String) -> Unit)? = null) {
    items(rows, key = { it.task.id }) { row ->
        PindoTaskRow(row, state, expanded = row.task.id !in collapsed, onDisclosure = { onDisclosure(row.task.id) },
            onEdit = { onEdit(row.task.id) }, onAddChild = { onAddChild(row.task.id) },
            onDelete = { onDelete(setOf(row.task.id)) }, onMove = { store.move(row.task.id, it) },
            onPhase = { store.advancePhase(row.task.id) }, selected = selected?.contains(row.task.id),
            onSelect = { onSelect(row.task.id) }, onEnterSelection = onEnterSelection?.let { callback -> { callback(row.task.id) } })
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable private fun PindoTaskRow(entry: TaskOutlineEntry, state: AppState, expanded: Boolean,
    onDisclosure: () -> Unit, onEdit: () -> Unit, onAddChild: () -> Unit, onDelete: () -> Unit,
    onMove: (Int) -> Unit, onPhase: () -> Unit, selected: Boolean?, onSelect: () -> Unit, onEnterSelection: (() -> Unit)?) {
    val task = entry.task
    val children = state.tasks.filter { it.parentID == task.id }
    val completedChildren = children.count { it.phase == "completed" }
    val stripe = state.groups.find { it.id == task.groupID }?.let { Color(it.color.toColorInt()) } ?: MaterialTheme.colorScheme.outlineVariant
    var menu by remember { mutableStateOf(false) }
    val editable = !state.readOnly && entry.matchesQuery
    val today = LocalDate.now()
    val date = if (task.phase == "completed" && task.day < today.minusDays(1))
        task.day.format(DateTimeFormatter.ofPattern("M月d日", Locale.SIMPLIFIED_CHINESE)) else relativeDay(task.day, today)
    val overdue = task.day < today && task.phase != "completed"
    Surface(shape = RoundedCornerShape(16.dp), color = when {
        selected == true -> MaterialTheme.colorScheme.primaryContainer
        !entry.matchesQuery -> MaterialTheme.colorScheme.surfaceContainerLow
        else -> MaterialTheme.colorScheme.surface
    }, modifier = Modifier.fillMaxWidth().padding(start = (entry.depth * 16).dp)
        .alpha(if (entry.matchesQuery) 1f else .7f)) {
        Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min)
            .combinedClickable(enabled = !state.readOnly, onClick = { if (selected != null) { if (entry.matchesQuery) onSelect() } else onEdit() },
                onLongClick = { if (selected == null && editable) menu = true }), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.width(5.dp).fillMaxHeight().background(stripe))
            if (children.isNotEmpty()) {
                IconButton(onClick = onDisclosure, modifier = Modifier.width(30.dp)) {
                    Icon(if (expanded) Icons.Outlined.ExpandMore else Icons.Outlined.ChevronRight,
                        contentDescription = if (expanded) "收起子项" else "展开子项", modifier = Modifier.size(20.dp))
                }
            } else Spacer(Modifier.width(30.dp))
            if (selected != null) Checkbox(checked = selected, onCheckedChange = { onSelect() }, enabled = editable, modifier = Modifier.size(40.dp))
            else PindoPhaseCircle(task.phase, editable, onPhase)
            Column(Modifier.weight(1f).padding(vertical = 13.dp, horizontal = 5.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Text(task.title, style = MaterialTheme.typography.titleMedium.copy(fontSize = 16.sp, lineHeight = 23.sp),
                    fontWeight = if (task.phase == "completed") FontWeight.Normal else FontWeight.Medium,
                    textDecoration = if (task.phase == "completed") TextDecoration.LineThrough else TextDecoration.None,
                    color = if (task.phase == "completed") MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (!entry.matchesQuery) Text("所在父项", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    else Text(date, style = MaterialTheme.typography.labelSmall,
                        color = if (overdue) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                    if (children.isNotEmpty()) {
                        Text("子项 " + completedChildren + "/" + children.size, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
                    }
                }
            }
            if (selected == null) {
                if (task.note.isNotBlank()) IconButton(onClick = onEdit, modifier = Modifier.width(32.dp)) {
                    Icon(Icons.AutoMirrored.Outlined.Notes, "打开备注", Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Box {
                    IconButton(onClick = { menu = true }, enabled = editable, modifier = Modifier.width(32.dp)) {
                        Icon(Icons.Outlined.MoreVert, "事项操作", Modifier.size(20.dp))
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(text = { Text("修改待办") }, leadingIcon = { Icon(Icons.Outlined.Edit, null) }, onClick = { menu = false; onEdit() })
                        DropdownMenuItem(text = { Text("打开备注") }, leadingIcon = { Icon(Icons.AutoMirrored.Outlined.Notes, null) }, onClick = { menu = false; onEdit() })
                        if (entry.depth < 2) DropdownMenuItem(text = { Text("添加子项") }, leadingIcon = { Icon(Icons.Outlined.Add, null) }, onClick = { menu = false; onAddChild() })
                        if (onEnterSelection != null) DropdownMenuItem(text = { Text("选择事项") }, leadingIcon = { Icon(Icons.Outlined.CheckBox, null) }, onClick = { menu = false; onEnterSelection() })
                        HorizontalDivider()
                        DropdownMenuItem(text = { Text("上移") }, leadingIcon = { Icon(Icons.Outlined.ArrowUpward, null) }, onClick = { menu = false; onMove(-1) })
                        DropdownMenuItem(text = { Text("下移") }, leadingIcon = { Icon(Icons.Outlined.ArrowDownward, null) }, onClick = { menu = false; onMove(1) })
                        DropdownMenuItem(text = { Text("删除待办", color = MaterialTheme.colorScheme.error) }, leadingIcon = { Icon(Icons.Outlined.DeleteOutline, null, tint = MaterialTheme.colorScheme.error) }, onClick = { menu = false; onDelete() })
                    }
                }
            } else Spacer(Modifier.width(10.dp))
        }
    }
}

@Composable private fun PindoPhaseCircle(phase: String, enabled: Boolean, onClick: () -> Unit) {
    val primary = MaterialTheme.colorScheme.primary
    val check = MaterialTheme.colorScheme.onPrimary
    val outline = if (phase == "pending") MaterialTheme.colorScheme.outline else primary
    IconButton(onClick = onClick, enabled = enabled, modifier = Modifier.size(40.dp)
        .semantics { contentDescription = when (phase) { "inProgress" -> "进行中，点击完成"; "completed" -> "已完成，点击恢复待办"; else -> "待办，点击开始" } }) {
        Canvas(Modifier.size(23.dp)) {
            val r = size.minDimension / 2 - 1.dp.toPx(); val cx = size.width / 2; val cy = size.height / 2
            if (phase == "completed") {
                drawCircle(primary, r)
                drawPath(Path().apply { moveTo(cx - r * .5f, cy); lineTo(cx - r * .1f, cy + r * .4f); lineTo(cx + r * .55f, cy - r * .4f) }, check, style = Stroke(1.8.dp.toPx()))
            } else {
                if (phase == "inProgress") drawPath(Path().apply {
                    moveTo(cx, cy - r); arcTo(Rect(cx - r, cy - r, cx + r, cy + r), -90f, 180f, false)
                    cubicTo(cx + r * .75f, cy + r, cx + r * .75f, cy, cx, cy)
                    cubicTo(cx - r * .75f, cy, cx - r * .75f, cy - r, cx, cy - r); close()
                }, primary)
                drawCircle(outline, r, style = Stroke(1.5.dp.toPx()))
            }
        }
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
