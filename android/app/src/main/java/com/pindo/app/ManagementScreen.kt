package com.pindo.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Sort
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import java.time.LocalDate

@OptIn(ExperimentalLayoutApi::class)
@Composable internal fun ManagementScreen(store: AppStore, state: AppState, onEdit: (String) -> Unit,
    onAddChild: (String) -> Unit, onDelete: (Set<String>) -> Unit) {
    var search by rememberSaveable { mutableStateOf("") }
    var groupID by rememberSaveable { mutableStateOf<String?>(null) }
    var phaseName by rememberSaveable { mutableStateOf(PhaseFilter.ALL.name) }
    var sortName by rememberSaveable { mutableStateOf(TaskSort.DATE.name) }
    var selectionMode by rememberSaveable { mutableStateOf(false) }
    var selectedIDs by rememberSaveable { mutableStateOf(emptyList<String>()) }
    var collapsed by rememberSaveable { mutableStateOf(emptyList<String>()) }
    var groupDialog by remember { mutableStateOf(false) }
    var targetGroup by rememberSaveable { mutableStateOf<String?>(null) }
    var dateDialog by remember { mutableStateOf(false) }
    val query = TaskQuery(TaskScope.ALL, LocalDate.now(), PhaseFilter.valueOf(phaseName), groupID, search, TaskSort.valueOf(sortName))
    val matching = TodoQueries.matching(state.tasks, query)
    val matchingIDs = matching.map { it.id }.toSet()
    val selected = selectedIDs.toSet().intersect(matchingIDs)
    val rows = TodoQueries.outline(state.tasks, query, if (search.isNotBlank() || selectionMode) emptySet() else collapsed.toSet())
    LaunchedEffect(search, groupID, phaseName, sortName) { selectedIDs = emptyList() }
    DisposableEffect(selectionMode) {
        val lease = if (selectionMode) store.beginEditing() else null
        onDispose { if (lease != null) store.endEditing(lease) }
    }
    BackHandler(enabled = selectionMode) { selectionMode = false; selectedIDs = emptyList() }
    fun perform(action: TodoBatchAction) {
        if (selected.isNotEmpty() && store.applyBatch(selected, action)) {
            selectedIDs = emptyList(); selectionMode = false
        }
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize().testTag("management"),
        contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 104.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        item(key = "management-header") {
            PindoPageHeader("管理事项", "跨日期查找，集中处理待办") {
                TextButton(
                    onClick = { selectionMode = !selectionMode; selectedIDs = emptyList() },
                    enabled = !state.readOnly,
                    modifier = Modifier.heightIn(min = 48.dp).testTag("batch-mode")
                ) {
                    Icon(if (selectionMode) Icons.Outlined.Close else Icons.Outlined.Checklist,
                        if (selectionMode) "退出批量操作" else "批量操作", Modifier.size(20.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(if (selectionMode) "取消" else "选择")
                }
            }
        }
        if (state.error != null) item(key = "management-error") { PindoErrorMessage(state.error, store::dismissError) }
        item(key = "management-search") {
            OutlinedTextField(
                value = search,
                onValueChange = { search = it },
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text("搜索标题或备注") },
                singleLine = true,
                leadingIcon = { Icon(Icons.Outlined.Search, null) },
                trailingIcon = {
                    if (search.isNotEmpty()) IconButton(onClick = { search = "" }, modifier = Modifier.size(48.dp)) {
                        Icon(Icons.Outlined.Close, "清空搜索")
                    }
                },
                shape = RoundedCornerShape(14.dp)
            )
        }
        item(key = "management-groups") { PindoGroupChips(state.groups, groupID) { groupID = it } }
        item(key = "management-filters") {
            FlowRow(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                PindoPhasePicker(PhaseFilter.valueOf(phaseName), { phaseName = it.name })
                PindoSortPicker(TaskSort.valueOf(sortName)) { sortName = it.name }
            }
        }
        if (selectionMode) item(key = "management-selection") {
            Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.primaryContainer) {
                Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    FlowRow(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                        itemVerticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("已选择 " + selected.size + " 项", style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onPrimaryContainer)
                        TextButton(
                            onClick = { selectedIDs = if (matchingIDs.isNotEmpty() && selected == matchingIDs) emptyList() else matchingIDs.toList() },
                            modifier = Modifier.heightIn(min = 48.dp),
                            enabled = matchingIDs.isNotEmpty()
                        ) {
                            Text(if (matchingIDs.isNotEmpty() && selected == matchingIDs) "取消全选" else "全选结果")
                        }
                    }
                    FlowRow(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        BatchButton("完成", Icons.Outlined.Done, selected.isNotEmpty(), emphasized = true) {
                            perform(TodoBatchAction.SetPhase("completed"))
                        }
                        BatchButton("未完成", Icons.Outlined.RadioButtonUnchecked, selected.isNotEmpty()) {
                            perform(TodoBatchAction.SetPhase("pending"))
                        }
                        BatchButton("分组", Icons.Outlined.FolderOpen, selected.isNotEmpty()) {
                            targetGroup = null; groupDialog = true
                        }
                        BatchButton("日期", Icons.Outlined.Event, selected.isNotEmpty()) { dateDialog = true }
                        BatchButton("删除", Icons.Outlined.DeleteOutline, selected.isNotEmpty(), destructive = true) { onDelete(selected) }
                    }
                    Text("全选仅包含筛选结果；删除父项会同时删除其子项。",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onPrimaryContainer)
                }
            }
        }
        item(key = "management-results-heading") {
            Row(Modifier.fillMaxWidth().padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("全部结果", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(matching.size.toString() + " 项", style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (rows.isEmpty()) item(key = "management-empty") {
            PindoEmptyState("没有符合条件的事项", "调整状态、分组或关键词，再试一次。", Icons.Outlined.FilterAltOff)
        }
        pindoTaskItems(
            rows = rows, state = state, collapsed = collapsed.toSet(),
            onDisclosure = { id -> collapsed = if (id in collapsed) collapsed - id else collapsed + id },
            onEdit = onEdit, onAddChild = onAddChild, onDelete = onDelete, store = store,
            selected = if (selectionMode) selected else null,
            onSelect = { id -> selectedIDs = if (id in selected) selectedIDs - id else selectedIDs + id },
            onEnterSelection = { id -> selectionMode = true; selectedIDs = listOf(id) }
        )
    }
    if (groupDialog) AlertDialog(
        onDismissRequest = { groupDialog = false },
        title = { Text("修改所选事项的分组") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("将 " + selected.size + " 项事项移到同一分组。")
                PindoGroupPicker(state.groups, targetGroup, "未分组") { targetGroup = it }
            }
        },
        confirmButton = {
            TextButton(onClick = { perform(TodoBatchAction.SetGroup(targetGroup)); groupDialog = false },
                enabled = selected.isNotEmpty()) { Text("应用分组") }
        },
        dismissButton = { TextButton(onClick = { groupDialog = false }) { Text("取消") } }
    )
    if (dateDialog) PindoDatePickerDialog(LocalDate.now(), { dateDialog = false }) { date ->
        perform(TodoBatchAction.SetDay(date)); dateDialog = false
    }
}

@Composable private fun BatchButton(label: String, icon: ImageVector, enabled: Boolean,
    emphasized: Boolean = false, destructive: Boolean = false, onClick: () -> Unit) {
    val content: @Composable RowScope.() -> Unit = {
        Icon(icon, contentDescription = null, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(label)
    }
    if (emphasized) {
        Button(onClick = onClick, enabled = enabled, modifier = Modifier.heightIn(min = 48.dp),
            contentPadding = PaddingValues(horizontal = 14.dp, vertical = 10.dp), content = content)
    } else {
        OutlinedButton(
            onClick = onClick, enabled = enabled, modifier = Modifier.heightIn(min = 48.dp),
            contentPadding = PaddingValues(horizontal = 14.dp, vertical = 10.dp),
            colors = ButtonDefaults.outlinedButtonColors(
                contentColor = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface
            ),
            content = content
        )
    }
}

@Composable internal fun PindoPhasePicker(selected: PhaseFilter, onSelect: (PhaseFilter) -> Unit, compact: Boolean = false) {
    var expanded by remember { mutableStateOf(false) }
    val labels = mapOf(PhaseFilter.ALL to "全部状态", PhaseFilter.UNFINISHED to "未完成", PhaseFilter.PENDING to "待开始",
        PhaseFilter.IN_PROGRESS to "进行中", PhaseFilter.COMPLETED to "已完成")
    Box {
        if (compact) TextButton(onClick = { expanded = true }, modifier = Modifier.heightIn(min = 48.dp)) {
            Text(labels.getValue(selected))
            Icon(Icons.Outlined.ExpandMore, null, Modifier.size(18.dp))
        } else OutlinedButton(
            onClick = { expanded = true }, modifier = Modifier.heightIn(min = 48.dp),
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 10.dp)
        ) {
            Icon(Icons.Outlined.FilterList, null, Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text(labels.getValue(selected))
            Icon(Icons.Outlined.ExpandMore, null, Modifier.size(18.dp))
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            PhaseFilter.entries.forEach { phase ->
                DropdownMenuItem(
                    text = { Text(labels.getValue(phase)) },
                    trailingIcon = { if (phase == selected) Icon(Icons.Outlined.Check, null) },
                    onClick = { expanded = false; onSelect(phase) }
                )
            }
        }
    }
}

@Composable private fun PindoSortPicker(selected: TaskSort, onSelect: (TaskSort) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val labels = mapOf(TaskSort.MANUAL to "手动顺序", TaskSort.DATE to "计划日期", TaskSort.UPDATED to "最近修改")
    Box {
        OutlinedButton(onClick = { expanded = true }, modifier = Modifier.heightIn(min = 48.dp),
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 10.dp)) {
            Icon(Icons.AutoMirrored.Outlined.Sort, null, Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text(labels.getValue(selected))
            Icon(Icons.Outlined.ExpandMore, null, Modifier.size(18.dp))
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            TaskSort.entries.forEach { sort ->
                DropdownMenuItem(
                    text = { Text(labels.getValue(sort)) },
                    trailingIcon = { if (sort == selected) Icon(Icons.Outlined.Check, null) },
                    onClick = { expanded = false; onSelect(sort) }
                )
            }
        }
    }
}
