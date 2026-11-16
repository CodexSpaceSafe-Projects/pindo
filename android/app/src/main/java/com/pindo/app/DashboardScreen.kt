package com.pindo.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun DashboardScreen(store: AppStore, state: AppState, onEdit: (String, Boolean) -> Unit,
    onAddChild: (String) -> Unit, onDelete: (Set<String>) -> Unit, onAdd: () -> Unit, onSyncSettings: () -> Unit) {
    val today = LocalDate.now()
    var scopeName by rememberSaveable { mutableStateOf(TaskScope.TODAY.name) }
    var groupID by rememberSaveable { mutableStateOf<String?>(null) }
    var showCompleted by rememberSaveable { mutableStateOf(false) }
    var searchOpen by rememberSaveable { mutableStateOf(false) }
    var filtersOpen by rememberSaveable { mutableStateOf(false) }
    var search by rememberSaveable { mutableStateOf("") }
    var quickTitle by rememberSaveable { mutableStateOf("") }
    var collapsed by rememberSaveable { mutableStateOf(emptyList<String>()) }
    val scope = TaskScope.valueOf(scopeName)
    val query = TaskQuery(scope, today, if (showCompleted) PhaseFilter.COMPLETED else PhaseFilter.UNFINISHED,
        groupID, search, TaskSort.MANUAL)
    val matching = TodoQueries.matching(state.tasks, query)
    val rows = TodoQueries.outline(state.tasks, query, if (search.isBlank()) collapsed.toSet() else emptySet())
    val filtered = groupID != null || showCompleted
    fun submitQuick() {
        if (quickTitle.isBlank() || state.readOnly) return
        val targetGroup = when (groupID) { "ungrouped" -> null; null -> state.preferences.defaultGroupID; else -> groupID }
        if (store.addTask(quickTitle, "", today, targetGroup, null)) {
            quickTitle = ""; scopeName = TaskScope.TODAY.name; showCompleted = false
            search = ""; searchOpen = false
        }
    }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                DashboardScopeMenu(scope) { scopeName = it.name }
                Text(today.format(DateTimeFormatter.ofPattern("M月d日 EEEE", Locale.SIMPLIFIED_CHINESE)) + " · ${matching.size} 项",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (state.readOnly || state.syncStatus.contains("失败")) IconButton(onClick = onSyncSettings) {
                Icon(Icons.Outlined.ErrorOutline, if (state.readOnly) "存储异常" else "同步失败", tint = MaterialTheme.colorScheme.error)
            }
            IconButton(onClick = { searchOpen = !searchOpen; if (!searchOpen) search = "" }) {
                Icon(if (searchOpen) Icons.Outlined.SearchOff else Icons.Outlined.Search,
                    if (searchOpen) "关闭搜索" else "搜索事项")
            }
            IconButton(onClick = { filtersOpen = true }) {
                Icon(if (filtered) Icons.Outlined.FilterAlt else Icons.Outlined.Tune, "筛选事项",
                    tint = if (filtered) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (searchOpen) OutlinedTextField(search, { search = it },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            label = { Text("搜索标题或备注") }, singleLine = true,
            trailingIcon = { if (search.isNotBlank()) IconButton(onClick = { search = "" }) { Icon(Icons.Outlined.Close, "清空搜索") } })
        if (filtered) Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(listOfNotNull(groupID?.let { id -> state.groups.find { it.id == id }?.name ?: "未分组" },
                if (showCompleted) "已完成" else null).joinToString(" · "), Modifier.weight(1f),
                style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            TextButton(onClick = { groupID = null; showCompleted = false }) { Text("清除筛选") }
        }
        LazyColumn(Modifier.weight(1f).fillMaxWidth().testTag("dashboard"),
            contentPadding = PaddingValues(start = 12.dp, end = 12.dp, bottom = 12.dp)) {
            if (state.error != null) item { PindoErrorMessage(state.error, store::dismissError) }
            if (rows.isEmpty()) item {
                PindoEmptyState(if (search.isNotBlank() || filtered) "没有匹配的事项" else "今天想做些什么？",
                    if (search.isNotBlank() || filtered) "调整筛选，或试试其他关键词。" else "在下方写下一件事，或点 + 补充细节。",
                    actionLabel = if (!state.readOnly && search.isBlank() && !filtered) "写一件事" else null, onAction = onAdd)
            }
            pindoTaskItems(rows, state, collapsed.toSet(),
                onDisclosure = { id -> collapsed = if (id in collapsed) collapsed - id else collapsed + id },
                onEdit, onAddChild, onDelete, store)
        }
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onAdd, enabled = !state.readOnly, modifier = Modifier.size(48.dp).testTag("add-task")) {
                Icon(Icons.Outlined.Add, "添加事项")
            }
            BasicTextField(quickTitle, { quickTitle = it }, enabled = !state.readOnly, singleLine = true,
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary), visualTransformation = MixedScriptVisualTransformation,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { submitQuick() }),
                modifier = Modifier.weight(1f).heightIn(min = 48.dp).testTag("quick-add").semantics { contentDescription = "添加事项标题" },
                decorationBox = { input -> Box(contentAlignment = Alignment.CenterStart) {
                    if (quickTitle.isEmpty()) Text("添加事项…", style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                    input()
                } })
            IconButton(onClick = ::submitQuick, enabled = quickTitle.isNotBlank() && !state.readOnly, modifier = Modifier.size(48.dp)) {
                Icon(Icons.Outlined.ArrowUpward, "快速添加事项")
            }
        }
    }
    if (filtersOpen) ModalBottomSheet(onDismissRequest = { filtersOpen = false }) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("筛选事项", style = MaterialTheme.typography.titleLarge)
            PindoGroupPicker(state.groups, groupID, "全部分组", includeUngrouped = true) { groupID = it }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("查看已完成", Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                Switch(showCompleted, onCheckedChange = { showCompleted = it })
            }
            Button(onClick = { filtersOpen = false }, modifier = Modifier.fillMaxWidth()) { Text("完成") }
        }
    }
}

@Composable private fun DashboardScopeMenu(selected: TaskScope, onSelect: (TaskScope) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val choices = listOf(TaskScope.TODAY to "今天", TaskScope.UPCOMING to "近 7 天", TaskScope.ALL to "全部事项", TaskScope.OVERDUE to "逾期待办")
    Box {
        TextButton(onClick = { expanded = true }, contentPadding = PaddingValues(0.dp), modifier = Modifier.heightIn(min = 48.dp).testTag("scope-filter")) {
            Text(choices.first { it.first == selected }.second, style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
            Icon(Icons.Outlined.ExpandMore, null, Modifier.padding(start = 4.dp).size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        DropdownMenu(expanded, onDismissRequest = { expanded = false }) {
            choices.forEach { (scope, label) -> DropdownMenuItem(text = { Text(label) },
                trailingIcon = { if (scope == selected) Icon(Icons.Outlined.Check, null) }, onClick = { expanded = false; onSelect(scope) }) }
        }
    }
}
