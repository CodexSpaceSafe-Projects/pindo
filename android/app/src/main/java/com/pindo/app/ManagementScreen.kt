package com.pindo.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Sort
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import java.time.LocalDate

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable internal fun ManagementScreen(store: AppStore, state: AppState, onEdit: (String, Boolean) -> Unit,
    onAddChild: (String) -> Unit, onDelete: (Set<String>) -> Unit, onSettings: () -> Unit = {},
    onSelectionModeChange: (Boolean) -> Unit = {},
    onCaptureContextChange: (LocalDate, String?) -> Unit = { _, _ -> }) {
    val focusManager = LocalFocusManager.current
    var search by rememberSaveable { mutableStateOf("") }
    var searchOpen by rememberSaveable { mutableStateOf(false) }
    var filtersOpen by rememberSaveable { mutableStateOf(false) }
    var scopeName by rememberSaveable { mutableStateOf(TaskScope.ALL.name) }
    var groupID by rememberSaveable { mutableStateOf<String?>(null) }
    var phaseName by rememberSaveable { mutableStateOf(PhaseFilter.ALL.name) }
    var sortName by rememberSaveable { mutableStateOf(TaskSort.DATE.name) }
    var selectionMode by rememberSaveable { mutableStateOf(false) }
    var selectedIDs by rememberSaveable { mutableStateOf(emptyList<String>()) }
    var collapsed by rememberSaveable { mutableStateOf(emptyList<String>()) }
    var groupDialog by remember { mutableStateOf(false) }
    var targetGroup by rememberSaveable { mutableStateOf<String?>(null) }
    var dateDialog by remember { mutableStateOf(false) }
    val query = TaskQuery(TaskScope.valueOf(scopeName), LocalDate.now(), PhaseFilter.valueOf(phaseName), groupID, search, TaskSort.valueOf(sortName))
    SideEffect { onCaptureContextChange(if (TaskScope.valueOf(scopeName) == TaskScope.UPCOMING) LocalDate.now().plusDays(1) else LocalDate.now(),
        if (groupID == "ungrouped") null else groupID ?: state.preferences.defaultGroupID) }
    val matching = TodoQueries.matching(state.tasks, query)
    val matchingIDs = matching.map { it.id }.toSet()
    val selected = selectedIDs.toSet().intersect(matchingIDs)
    val activeCollapsed = if (search.isNotBlank() || selectionMode) emptySet() else collapsed.toSet()
    val rows = TodoQueries.outline(state.tasks, query, activeCollapsed)
    val filtered = scopeName != TaskScope.ALL.name || groupID != null || PhaseFilter.valueOf(phaseName) != PhaseFilter.ALL || TaskSort.valueOf(sortName) != TaskSort.DATE
    LaunchedEffect(search, scopeName, groupID, phaseName, sortName) { selectedIDs = emptyList() }
    LaunchedEffect(state.tasks, selectionMode) {
        if (selectionMode && selectedIDs.isNotEmpty() && selectedIDs.none { id -> state.tasks.any { it.id == id } }) {
            selectionMode = false; selectedIDs = emptyList()
        }
    }
    DisposableEffect(selectionMode) {
        val lease = if (selectionMode) store.beginEditing() else null
        onSelectionModeChange(selectionMode)
        onDispose {
            if (lease != null) store.endEditing(lease)
            onSelectionModeChange(false)
        }
    }
    BackHandler(enabled = selectionMode || searchOpen) {
        if (selectionMode) { selectionMode = false; selectedIDs = emptyList() }
        else { searchOpen = false; search = "" }
    }
    fun perform(action: TodoBatchAction) {
        if (selected.isNotEmpty() && store.applyBatch(selected, action)) {
            selectedIDs = emptyList(); selectionMode = false
        }
    }

    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(start = 24.dp, end = 12.dp, top = 20.dp, bottom = 12.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("清单", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.SemiBold)
                Text(if (search.isBlank() && !filtered) "跨日期查看，按分组整理" else "找到 " + matching.size + " 条事项",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp))
            }
            IconButton(onClick = { searchOpen = !searchOpen; if (!searchOpen) search = "" }) {
                Icon(if (searchOpen) Icons.Outlined.SearchOff else Icons.Outlined.Search, if (searchOpen) "关闭搜索" else "搜索事项")
            }
            IconButton(onClick = { focusManager.clearFocus(); onSettings() }, modifier = Modifier.testTag("open-settings")) { Icon(Icons.Outlined.Settings, "设置") }
        }
        if (searchOpen) OutlinedTextField(search, { search = it }, modifier = Modifier.fillMaxWidth()
            .padding(horizontal = 20.dp).padding(bottom = 8.dp).testTag("management-search"),
            placeholder = { Text("搜索标题或备注") }, singleLine = true, shape = RoundedCornerShape(16.dp),
            leadingIcon = { Icon(Icons.Outlined.Search, null) },
            trailingIcon = { if (search.isNotBlank()) IconButton(onClick = { search = "" }) { Icon(Icons.Outlined.Close, "清空搜索") } })
        Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 12.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = { focusManager.clearFocus(); filtersOpen = true }, modifier = Modifier.heightIn(min = 48.dp).testTag("list-filters"),
                contentPadding = PaddingValues(horizontal = 8.dp)) {
                Icon(Icons.Outlined.Tune, null, Modifier.size(18.dp))
                Text(if (filtered) "已筛选" else "筛选与排序", Modifier.padding(start = 6.dp))
                if (filtered) Icon(Icons.Outlined.Circle, null, Modifier.padding(start = 5.dp).size(5.dp))
            }
            Spacer(Modifier.weight(1f))
            Text(matching.size.toString() + " 条", style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            TextButton(onClick = { focusManager.clearFocus(); selectionMode = !selectionMode; selectedIDs = emptyList() }, enabled = selectionMode || !state.readOnly,
                modifier = Modifier.heightIn(min = 48.dp).testTag("batch-mode")) {
                Icon(if (selectionMode) Icons.Outlined.Close else Icons.Outlined.Checklist, null, Modifier.size(18.dp))
                Text(if (selectionMode) "取消" else "选择", Modifier.padding(start = 6.dp))
            }
        }
        if (filtered) Row(Modifier.fillMaxWidth().padding(horizontal = 24.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(listOfNotNull(if (scopeName != TaskScope.ALL.name) scopeLabel(TaskScope.valueOf(scopeName)) else null, groupID?.let { id -> state.groups.find { it.id == id }?.name ?: "未分组" },
                if (phaseName != PhaseFilter.ALL.name) phaseLabel(PhaseFilter.valueOf(phaseName)) else null,
                if (sortName != TaskSort.DATE.name) sortLabel(TaskSort.valueOf(sortName)) else null).joinToString(" · "),
                Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary,
                maxLines = 2, overflow = TextOverflow.Ellipsis)
            TextButton(onClick = { scopeName = TaskScope.ALL.name; groupID = null; phaseName = PhaseFilter.ALL.name; sortName = TaskSort.DATE.name }) { Text("清除") }
        }
        LazyColumn(modifier = Modifier.weight(1f).fillMaxWidth().testTag("management"),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = if (selectionMode) 16.dp else 96.dp)) {
            if (state.error != null) item(key = "management-error") { PindoErrorMessage(state.error, store::dismissError) }
            if (rows.isEmpty()) item(key = "management-empty") {
                PindoEmptyState(if (search.isNotBlank() || filtered) "没有找到相关事项" else "还没有事项",
                    if (search.isNotBlank() || filtered) "换个关键词，或调整筛选条件。" else "点右下角添加第一件事。",
                    Icons.Outlined.Checklist)
            }
            pindoTaskItems(rows, state, activeCollapsed,
                onDisclosure = { id -> collapsed = if (id in collapsed) collapsed - id else collapsed + id },
                onEdit = onEdit, onAddChild = onAddChild, onDelete = onDelete, store = store,
                selected = if (selectionMode) selected else null,
                onSelect = { id -> selectedIDs = if (id in selected) selectedIDs - id else selectedIDs + id },
                onEnterSelection = { id -> selectionMode = true; selectedIDs = listOf(id) })
        }
        if (selectionMode) Surface(color = MaterialTheme.colorScheme.surfaceContainerLow, tonalElevation = 1.dp) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(top = 4.dp, bottom = 12.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("已选择 " + selected.size + " 项", Modifier.weight(1f), style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold)
                    TextButton(onClick = { selectedIDs = if (matchingIDs.isNotEmpty() && selected == matchingIDs) emptyList() else matchingIDs.toList() },
                        enabled = matchingIDs.isNotEmpty()) { Text(if (matchingIDs.isNotEmpty() && selected == matchingIDs) "取消全选" else "全选结果") }
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    BatchAction("完成", Icons.Outlined.Done, selected.isNotEmpty() && !state.readOnly, Modifier.weight(1f), emphasized = true) {
                        perform(TodoBatchAction.SetPhase("completed"))
                    }
                    BatchAction("分组", Icons.Outlined.FolderOpen, selected.isNotEmpty() && !state.readOnly, Modifier.weight(1f)) {
                        targetGroup = null; groupDialog = true
                    }
                    BatchAction("日期", Icons.Outlined.Event, selected.isNotEmpty() && !state.readOnly, Modifier.weight(1f)) { dateDialog = true }
                    var more by remember { mutableStateOf(false) }
                    Box(Modifier.weight(1f)) {
                        BatchAction("更多", Icons.Outlined.MoreHoriz, selected.isNotEmpty() && !state.readOnly, Modifier.fillMaxWidth()) { more = true }
                        DropdownMenu(more, onDismissRequest = { more = false }) {
                            DropdownMenuItem(text = { Text("未完成") }, leadingIcon = { Icon(Icons.Outlined.RadioButtonUnchecked, null) },
                                onClick = { more = false; perform(TodoBatchAction.SetPhase("pending")) })
                            DropdownMenuItem(text = { Text("删除", color = MaterialTheme.colorScheme.error) },
                                leadingIcon = { Icon(Icons.Outlined.DeleteOutline, null, tint = MaterialTheme.colorScheme.error) },
                                onClick = { more = false; onDelete(selected) })
                        }
                    }
                }
            }
        }
    }
    if (filtersOpen) ModalBottomSheet(onDismissRequest = { filtersOpen = false }) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("筛选清单", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            PindoScopePicker(TaskScope.valueOf(scopeName)) { scopeName = it.name }
            Text("分组", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            PindoGroupPicker(state.groups, groupID, "全部分组", includeUngrouped = true) { groupID = it }
            Text("状态与顺序", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                PindoPhasePicker(PhaseFilter.valueOf(phaseName), { phaseName = it.name })
                PindoSortPicker(TaskSort.valueOf(sortName)) { sortName = it.name }
            }
            Button(onClick = { filtersOpen = false }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("显示结果") }
        }
    }
    if (groupDialog) AlertDialog(onDismissRequest = { groupDialog = false }, title = { Text("修改所选事项的分组") },
        text = { Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("将 " + selected.size + " 项事项移到同一分组。")
            PindoGroupPicker(state.groups, targetGroup, "未分组") { targetGroup = it }
        } },
        confirmButton = { TextButton(onClick = { perform(TodoBatchAction.SetGroup(targetGroup)); groupDialog = false },
            enabled = selected.isNotEmpty() && !state.readOnly) { Text("应用分组") } },
        dismissButton = { TextButton(onClick = { groupDialog = false }) { Text("取消") } })
    if (dateDialog) PindoDatePickerDialog(LocalDate.now(), { dateDialog = false }) { date ->
        perform(TodoBatchAction.SetDay(date)); dateDialog = false
    }
}

@Composable private fun BatchAction(label: String, icon: ImageVector, enabled: Boolean, modifier: Modifier,
    emphasized: Boolean = false, onClick: () -> Unit) {
    Surface(onClick = onClick, enabled = enabled, modifier = modifier.heightIn(min = 64.dp),
        shape = RoundedCornerShape(14.dp),
        color = if (emphasized && enabled) MaterialTheme.colorScheme.primaryContainer else Color.Transparent,
        contentColor = if (!enabled) MaterialTheme.colorScheme.onSurface.copy(alpha = .38f)
            else if (emphasized) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurface) {
        Column(Modifier.padding(horizontal = 4.dp, vertical = 8.dp), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Icon(icon, null, Modifier.size(21.dp))
            Text(label, style = MaterialTheme.typography.labelMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

private fun phaseLabel(phase: PhaseFilter): String = when (phase) {
    PhaseFilter.ALL -> "全部状态"; PhaseFilter.UNFINISHED -> "未完成"; PhaseFilter.PENDING -> "待开始"
    PhaseFilter.IN_PROGRESS -> "进行中"; PhaseFilter.COMPLETED -> "已完成"
}
private fun sortLabel(sort: TaskSort): String = when (sort) {
    TaskSort.MANUAL -> "手动顺序"; TaskSort.DATE -> "计划日期"; TaskSort.UPDATED -> "最近修改"
}

@Composable internal fun PindoPhasePicker(selected: PhaseFilter, onSelect: (PhaseFilter) -> Unit, compact: Boolean = false) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        if (compact) TextButton(onClick = { expanded = true }, modifier = Modifier.heightIn(min = 48.dp)) {
            Text(phaseLabel(selected))
            Icon(Icons.Outlined.ExpandMore, null, Modifier.size(18.dp))
        } else OutlinedButton(onClick = { expanded = true }, modifier = Modifier.heightIn(min = 48.dp),
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 10.dp)) {
            Icon(Icons.Outlined.FilterList, null, Modifier.size(18.dp))
            Text(phaseLabel(selected), Modifier.padding(horizontal = 6.dp))
            Icon(Icons.Outlined.ExpandMore, null, Modifier.size(18.dp))
        }
        DropdownMenu(expanded, onDismissRequest = { expanded = false }) {
            PhaseFilter.entries.forEach { phase -> DropdownMenuItem(text = { Text(phaseLabel(phase)) },
                trailingIcon = { if (phase == selected) Icon(Icons.Outlined.Check, null) },
                onClick = { expanded = false; onSelect(phase) }) }
        }
    }
}

@Composable private fun PindoSortPicker(selected: TaskSort, onSelect: (TaskSort) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        OutlinedButton(onClick = { expanded = true }, modifier = Modifier.heightIn(min = 48.dp),
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 10.dp)) {
            Icon(Icons.AutoMirrored.Outlined.Sort, null, Modifier.size(18.dp))
            Text(sortLabel(selected), Modifier.padding(horizontal = 6.dp))
            Icon(Icons.Outlined.ExpandMore, null, Modifier.size(18.dp))
        }
        DropdownMenu(expanded, onDismissRequest = { expanded = false }) {
            TaskSort.entries.forEach { sort -> DropdownMenuItem(text = { Text(sortLabel(sort)) },
                trailingIcon = { if (sort == selected) Icon(Icons.Outlined.Check, null) },
                onClick = { expanded = false; onSelect(sort) }) }
        }
    }
}

private fun scopeLabel(scope: TaskScope): String = when (scope) {
    TaskScope.TODAY -> "今天"; TaskScope.UPCOMING -> "近 7 天"; TaskScope.OVERDUE -> "逾期待办"; else -> "全部日期"
}

@Composable private fun PindoScopePicker(selected: TaskScope, onSelect: (TaskScope) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        OutlinedButton(onClick = { expanded = true }, modifier = Modifier.heightIn(min = 48.dp).testTag("scope-filter")) {
            Icon(Icons.Outlined.DateRange, null, Modifier.size(18.dp))
            Text(scopeLabel(selected), Modifier.padding(horizontal = 6.dp))
            Icon(Icons.Outlined.ExpandMore, null, Modifier.size(18.dp))
        }
        DropdownMenu(expanded, onDismissRequest = { expanded = false }) {
            listOf(TaskScope.ALL,TaskScope.TODAY,TaskScope.UPCOMING,TaskScope.OVERDUE).forEach { scope ->
                DropdownMenuItem(text = { Text(scopeLabel(scope)) },
                    trailingIcon = { if (scope == selected) Icon(Icons.Outlined.Check, null) },
                    onClick = { expanded = false; onSelect(scope) })
            }
        }
    }
}
