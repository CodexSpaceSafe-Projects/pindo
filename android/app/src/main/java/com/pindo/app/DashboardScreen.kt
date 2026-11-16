package com.pindo.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun DashboardScreen(store: AppStore, state: AppState, onEdit: (String, Boolean) -> Unit,
    onAddChild: (String) -> Unit, onDelete: (Set<String>) -> Unit, onAdd: () -> Unit, onSyncSettings: () -> Unit,
    onCaptureContextChange: (LocalDate, String?) -> Unit = { _, _ -> }) {
    val today = LocalDate.now()
    var groupID by rememberSaveable { mutableStateOf<String?>(null) }
    var showCompleted by rememberSaveable { mutableStateOf(false) }
    var searchOpen by rememberSaveable { mutableStateOf(false) }
    var filtersOpen by rememberSaveable { mutableStateOf(false) }
    var search by rememberSaveable { mutableStateOf("") }
    var collapsed by rememberSaveable { mutableStateOf(emptyList<String>()) }
    val query = TaskQuery(TaskScope.TODAY, today, if (showCompleted) PhaseFilter.COMPLETED else PhaseFilter.UNFINISHED, groupID, search)
    val matching = TodoQueries.matching(state.tasks, query)
    val activeCollapsed = if (search.isBlank()) collapsed.toSet() else emptySet()
    val rows = TodoQueries.outline(state.tasks, query, activeCollapsed)
    SideEffect { onCaptureContextChange(today, if (groupID == "ungrouped") null else groupID ?: state.preferences.defaultGroupID) }
    val filtered = groupID != null || showCompleted
    val todayTasks = state.tasks.filter { it.day == today }
    val completed = todayTasks.count { it.phase == "completed" }
    val overdue = matching.count { it.day < today }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(start = 24.dp, end = 12.dp, top = 12.dp, bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(today.format(DateTimeFormatter.ofPattern("M月d日 · EEEE", Locale.SIMPLIFIED_CHINESE)),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("今天", style = MaterialTheme.typography.headlineLarge, modifier = Modifier.padding(top = 4.dp))
            }
            IconButton(onClick = { searchOpen = !searchOpen; if (!searchOpen) search = "" }) {
                Icon(if (searchOpen) Icons.Outlined.SearchOff else Icons.Outlined.Search, if (searchOpen) "关闭搜索" else "搜索事项")
            }
            if (state.readOnly || state.syncStatus.contains("失败")) PindoSyncChip(state, onSyncSettings)
            else IconButton(onClick = onSyncSettings, modifier = Modifier.testTag("open-settings")) {
                Icon(Icons.Outlined.Settings, "设置", tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (searchOpen) OutlinedTextField(search, { search = it }, modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 8.dp),
            placeholder = { Text("搜索标题或备注") }, singleLine = true, shape = MaterialTheme.shapes.medium,
            trailingIcon = { if (search.isNotBlank()) IconButton(onClick = { search = "" }) { Icon(Icons.Outlined.Close, "清空搜索") } })
        Row(Modifier.fillMaxWidth().padding(start = 24.dp, end = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(if (showCompleted) "已完成 ${matching.size} 项" else "${matching.size} 项待办" + if (overdue > 0) " · $overdue 项逾期" else "",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis)
            TextButton(onClick = { filtersOpen = true }, modifier = Modifier.heightIn(min = 48.dp)) {
                Icon(Icons.Outlined.Tune, "筛选事项", Modifier.size(18.dp)); Spacer(Modifier.width(4.dp))
                Text(if (filtered) "已筛选" else "筛选", style = MaterialTheme.typography.labelMedium)
            }
        }
        if (!showCompleted && todayTasks.isNotEmpty()) LinearProgressIndicator(progress = { completed.toFloat() / todayTasks.size },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 12.dp).height(2.dp),
            color = MaterialTheme.colorScheme.primary, trackColor = MaterialTheme.colorScheme.outlineVariant,
            drawStopIndicator = {})
        LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("dashboard"), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 104.dp)) {
            if (state.error != null) item { PindoErrorMessage(state.error, store::dismissError) }
            if (rows.isEmpty()) item {
                PindoEmptyState(if (search.isNotBlank() || filtered) "没有匹配的事项" else "给今天留一点空间",
                    if (search.isNotBlank() || filtered) "调整筛选，或试试其他关键词。" else "记下一件想做的事，从容地开始。",
                    actionLabel = if (!state.readOnly && search.isBlank() && !filtered) "记一件事" else null, onAction = onAdd)
            }
            pindoTaskItems(rows, state, activeCollapsed, onDisclosure = { id -> collapsed = if (id in collapsed) collapsed - id else collapsed + id },
                onEdit, onAddChild, onDelete, store)
        }
    }
    if (filtersOpen) ModalBottomSheet(onDismissRequest = { filtersOpen = false }, containerColor = MaterialTheme.colorScheme.surface) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("今天的视图", style = MaterialTheme.typography.titleLarge)
            PindoGroupPicker(state.groups, groupID, "全部分组", includeUngrouped = true) { groupID = it }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("查看已完成", Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                Switch(showCompleted, onCheckedChange = { showCompleted = it })
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                TextButton(onClick = { groupID = null; showCompleted = false }, modifier = Modifier.heightIn(min = 48.dp)) { Text("重置") }
                Button(onClick = { filtersOpen = false }, modifier = Modifier.weight(1f).heightIn(min = 48.dp)) { Text("显示结果") }
            }
        }
    }
}
