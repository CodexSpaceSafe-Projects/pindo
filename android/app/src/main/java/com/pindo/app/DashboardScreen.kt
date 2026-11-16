package com.pindo.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
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
@Composable internal fun DashboardScreen(store: AppStore, state: AppState, onEdit: (String) -> Unit,
    onAddChild: (String) -> Unit, onDelete: (Set<String>) -> Unit, onAdd: () -> Unit, onSyncSettings: () -> Unit) {
    val today = LocalDate.now()
    var scopeName by rememberSaveable { mutableStateOf(TaskScope.TODAY.name) }
    var groupID by rememberSaveable { mutableStateOf<String?>(null) }
    var showCompleted by rememberSaveable { mutableStateOf(false) }
    var searchOpen by rememberSaveable { mutableStateOf(false) }
    var search by rememberSaveable { mutableStateOf("") }
    var quickTitle by rememberSaveable { mutableStateOf("") }
    var collapsed by rememberSaveable { mutableStateOf(emptyList<String>()) }
    val scope = TaskScope.valueOf(scopeName)
    val phase = if (showCompleted) PhaseFilter.COMPLETED else PhaseFilter.UNFINISHED
    val query = TaskQuery(scope, today, phase, groupID, search, TaskSort.MANUAL)
    val matching = TodoQueries.matching(state.tasks, query)
    val rows = TodoQueries.outline(state.tasks, query, if (search.isBlank()) collapsed.toSet() else emptySet())
    val stats = TodoQueries.stats(state.tasks, today)
    val focus = LocalFocusManager.current

    fun submitQuick() {
        if (quickTitle.isBlank() || state.readOnly) return
        val targetGroup = when (groupID) { "ungrouped" -> null; null -> state.preferences.defaultGroupID; else -> groupID }
        if (store.addTask(quickTitle, "", today, targetGroup, null)) {
            quickTitle = ""; scopeName = TaskScope.TODAY.name; showCompleted = false
            search = ""; searchOpen = false; focus.clearFocus()
        }
    }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val compactControls = maxWidth < 360.dp || LocalDensity.current.fontScale > 1.3f
        LazyColumn(
            modifier = Modifier.fillMaxSize().testTag("dashboard"),
            contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 104.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            item(key = "dashboard-header") {
                PindoPageHeader("我的清单", today.format(DateTimeFormatter.ofPattern("M月d日 EEEE", Locale.SIMPLIFIED_CHINESE))) {
                    PindoSyncChip(state, onSyncSettings)
                }
            }
            if (state.error != null) item(key = "dashboard-error") { PindoErrorMessage(state.error, store::dismissError) }
            item(key = "dashboard-summary") {
                Column(Modifier.fillMaxWidth().padding(bottom = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    LinearProgressIndicator(
                        progress = { if (stats.todayTotal == 0) 0f else stats.todayCompleted.toFloat() / stats.todayTotal },
                        modifier = Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp))
                            .semantics { contentDescription = "今日进度，已完成 " + stats.todayCompleted + " / " + stats.todayTotal + " 项" },
                        color = MaterialTheme.colorScheme.primary,
                        trackColor = MaterialTheme.colorScheme.surfaceContainerHigh
                    )
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        DashboardStat("未完成", stats.unfinished.toString(), scope == TaskScope.ALL && !showCompleted, Modifier.weight(1f), compactControls) {
                            scopeName = TaskScope.ALL.name; showCompleted = false
                        }
                        DashboardStat("已逾期", stats.overdue.toString(), scope == TaskScope.OVERDUE && !showCompleted, Modifier.weight(1f), compactControls) {
                            scopeName = TaskScope.OVERDUE.name; showCompleted = false
                        }
                        DashboardStat("今日完成", stats.todayCompleted.toString() + "/" + stats.todayTotal, scope == TaskScope.TODAY && showCompleted, Modifier.weight(1f), compactControls) {
                            scopeName = TaskScope.TODAY.name; showCompleted = true
                        }
                    }
                }
            }
            item(key = "dashboard-quick-add") {
                OutlinedTextField(
                    value = quickTitle,
                    onValueChange = { quickTitle = it },
                    modifier = Modifier.fillMaxWidth().testTag("quick-add"),
                    visualTransformation = MixedScriptVisualTransformation,
                    placeholder = { Text("添加到今天", maxLines = 1, softWrap = false, overflow = TextOverflow.Ellipsis) },
                    singleLine = true,
                    shape = RoundedCornerShape(14.dp),
                    enabled = !state.readOnly,
                    leadingIcon = {
                        IconButton(onClick = onAdd, enabled = !state.readOnly,
                            modifier = Modifier.size(48.dp).testTag("add-task")) {
                            Icon(Icons.Outlined.Add, "添加事项", tint = if (state.readOnly)
                                MaterialTheme.colorScheme.onSurface.copy(alpha = .38f) else MaterialTheme.colorScheme.primary)
                        }
                    },
                    trailingIcon = {
                        IconButton(onClick = ::submitQuick, enabled = quickTitle.isNotBlank() && !state.readOnly,
                            modifier = Modifier.size(48.dp)) {
                            Icon(Icons.Outlined.ArrowUpward, "快速添加事项",
                                tint = if (quickTitle.isNotBlank() && !state.readOnly) MaterialTheme.colorScheme.primary
                                    else MaterialTheme.colorScheme.outline)
                        }
                    },
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { submitQuick() })
                )
            }
            item(key = "dashboard-scope") {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    if (compactControls) {
                        DashboardScopeMenu(scope, Modifier.weight(1f)) { scopeName = it.name }
                    } else {
                        SingleChoiceSegmentedButtonRow(Modifier.weight(1f)) {
                            listOf(TaskScope.TODAY to "今天", TaskScope.UPCOMING to "近 7 天", TaskScope.ALL to "全部").forEachIndexed { index, (value, label) ->
                                SegmentedButton(
                                    selected = scope == value,
                                    onClick = { scopeName = value.name },
                                    modifier = Modifier.heightIn(min = 48.dp),
                                    shape = SegmentedButtonDefaults.itemShape(index = index, count = 3),
                                    icon = {}
                                ) { Text(label) }
                            }
                        }
                    }
                    IconButton(onClick = { searchOpen = !searchOpen; if (!searchOpen) search = "" },
                        modifier = Modifier.size(48.dp)) {
                        Icon(if (searchOpen) Icons.Outlined.SearchOff else Icons.Outlined.Search,
                            if (searchOpen) "关闭搜索" else "搜索事项")
                    }
                }
            }
            if (searchOpen) item(key = "dashboard-search") {
                OutlinedTextField(
                    value = search,
                    onValueChange = { search = it },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    placeholder = { Text("搜索标题或备注") },
                    leadingIcon = { Icon(Icons.Outlined.Search, null) },
                    trailingIcon = {
                        if (search.isNotEmpty()) IconButton(onClick = { search = "" }, modifier = Modifier.size(48.dp)) {
                            Icon(Icons.Outlined.Close, "清空搜索")
                        }
                    },
                    shape = RoundedCornerShape(14.dp)
                )
            }
            item(key = "dashboard-groups") { PindoGroupChips(state.groups, groupID) { groupID = it } }
            item(key = "dashboard-list-heading") {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(if (scope == TaskScope.OVERDUE) "逾期待办" else if (showCompleted) "已完成" else "待办事项",
                            style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                        Text(matching.size.toString() + " 项", style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    FilterChip(
                        selected = showCompleted,
                        onClick = { showCompleted = !showCompleted },
                        label = { Text("已完成") },
                        leadingIcon = { Icon(Icons.Outlined.TaskAlt, null, Modifier.size(16.dp)) }
                    )
                }
            }
            if (rows.isEmpty()) item(key = "dashboard-empty") {
                PindoEmptyState(
                    if (search.isNotBlank()) "没有找到匹配的事项" else if (showCompleted) "还没有完成的事项" else "清单已经理清了",
                    if (search.isNotBlank()) "试试其他关键词，或切换分组。" else "从一件小事开始，安排接下来的时间。",
                    actionLabel = if (!state.readOnly && search.isBlank() && !showCompleted) "添加第一件事" else null,
                    onAction = onAdd
                )
            }
            pindoTaskItems(rows, state, collapsed.toSet(),
                onDisclosure = { id -> collapsed = if (id in collapsed) collapsed - id else collapsed + id },
                onEdit, onAddChild, onDelete, store)
        }
    }
}

@Composable private fun DashboardStat(label: String, value: String, selected: Boolean, modifier: Modifier,
    compact: Boolean, onClick: () -> Unit) {
    val valueColor = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface
    TextButton(
        onClick = onClick,
        modifier = modifier.heightIn(min = 48.dp),
        contentPadding = PaddingValues(horizontal = 6.dp, vertical = if (compact) 4.dp else 8.dp),
        colors = ButtonDefaults.textButtonColors(
            contentColor = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
        )
    ) {
        if (compact) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(value, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = valueColor)
                Text(label, style = MaterialTheme.typography.labelMedium,
                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal)
            }
        } else {
            Text(label, Modifier.weight(1f), style = MaterialTheme.typography.labelMedium,
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal)
            Spacer(Modifier.width(6.dp))
            Text(value, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = valueColor)
        }
    }
}

@Composable private fun DashboardScopeMenu(selected: TaskScope, modifier: Modifier, onSelect: (TaskScope) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val choices = listOf(TaskScope.TODAY to "今天", TaskScope.UPCOMING to "近 7 天", TaskScope.ALL to "全部")
    val selectedLabel = if (selected == TaskScope.OVERDUE) "逾期待办" else choices.first { it.first == selected }.second
    Box(modifier) {
        OutlinedButton(onClick = { expanded = true }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("scope-filter"),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 10.dp)) {
            Text(selectedLabel, Modifier.weight(1f))
            Spacer(Modifier.width(8.dp))
            Icon(Icons.Outlined.ExpandMore, null, Modifier.size(20.dp))
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            choices.forEach { (scope, label) ->
                DropdownMenuItem(text = { Text(label) },
                    trailingIcon = { if (scope == selected) Icon(Icons.Outlined.Check, null) },
                    onClick = { expanded = false; onSelect(scope) })
            }
        }
    }
}
