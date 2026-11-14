package com.pindo.app

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
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
        val targetGroup = when (groupID) { "ungrouped" -> null; null -> state.preferences.defaultGroupID; else -> groupID }
        if (store.addTask(quickTitle, "", today, targetGroup, null)) {
            quickTitle = ""; scopeName = TaskScope.TODAY.name; showCompleted = false
            search = ""; searchOpen = false; focus.clearFocus()
        }
    }
    LazyColumn(Modifier.fillMaxSize().testTag("dashboard"), contentPadding = PaddingValues(start = 18.dp, end = 18.dp, top = 5.dp, bottom = 104.dp),
        verticalArrangement = Arrangement.spacedBy(11.dp)) {
        item {
            PindoPageHeader("我的清单", today.format(DateTimeFormatter.ofPattern("M月d日 EEEE", Locale.SIMPLIFIED_CHINESE))) {
                PindoSyncChip(state, onSyncSettings)
            }
        }
        item { PindoErrorMessage(state.error, store::dismissError) }
        item {
            Surface(shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.primaryContainer) {
                Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(15.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        Box(Modifier.size(64.dp), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(progress = { if (stats.todayTotal == 0) 0f else stats.todayCompleted.toFloat() / stats.todayTotal },
                                modifier = Modifier.fillMaxSize(), strokeWidth = 5.dp,
                                color = MaterialTheme.colorScheme.primary, trackColor = MaterialTheme.colorScheme.primary.copy(alpha = .12f))
                            Icon(Icons.Outlined.Check, null, Modifier.size(26.dp), tint = MaterialTheme.colorScheme.primary)
                        }
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text("今日进度", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
                                color = MaterialTheme.colorScheme.onPrimaryContainer)
                            Text("已完成 " + stats.todayCompleted + " / " + stats.todayTotal + " 项",
                                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onPrimaryContainer.copy(alpha = .8f))
                        }
                    }
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        DashboardStat("全部未完成", stats.unfinished.toString(), Modifier.weight(1f), Icons.Outlined.RadioButtonUnchecked) {
                            scopeName = TaskScope.ALL.name; showCompleted = false
                        }
                        DashboardStat("已逾期", stats.overdue.toString(), Modifier.weight(1f), Icons.Outlined.Schedule) {
                            scopeName = TaskScope.OVERDUE.name; showCompleted = false
                        }
                        DashboardStat("今日完成", stats.completedToday.toString(), Modifier.weight(1f), Icons.Outlined.TaskAlt) {
                            scopeName = TaskScope.TODAY.name; showCompleted = true
                        }
                    }
                }
            }
        }
        item {
            OutlinedTextField(quickTitle, { quickTitle = it }, modifier = Modifier.fillMaxWidth().testTag("quick-add"),
                visualTransformation = MixedScriptVisualTransformation,
                placeholder = { Text("快速添加到今天…") }, singleLine = true,
                shape = RoundedCornerShape(16.dp), enabled = !state.readOnly,
                leadingIcon = { Icon(Icons.Outlined.Add, null, tint = MaterialTheme.colorScheme.primary) },
                trailingIcon = {
                    IconButton(onClick = ::submitQuick, enabled = quickTitle.isNotBlank() && !state.readOnly) {
                        Icon(Icons.Outlined.ArrowUpward, "快速添加事项", tint = if (quickTitle.isNotBlank()) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline)
                    }
                }, keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { if (quickTitle.isNotBlank()) submitQuick() }))
        }
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SingleChoiceSegmentedButtonRow(Modifier.weight(1f)) {
                    listOf(TaskScope.TODAY to "今天", TaskScope.UPCOMING to "近 7 天", TaskScope.ALL to "全部").forEachIndexed { index, (value, label) ->
                        SegmentedButton(selected = scope == value, onClick = { scopeName = value.name },
                            shape = SegmentedButtonDefaults.itemShape(index = index, count = 3), icon = {}) { Text(label) }
                    }
                }
                IconButton(onClick = { searchOpen = !searchOpen; if (!searchOpen) search = "" }) {
                    Icon(if (searchOpen) Icons.Outlined.SearchOff else Icons.Outlined.Search, if (searchOpen) "关闭搜索" else "搜索事项")
                }
            }
        }
        item {
            AnimatedVisibility(searchOpen) {
                OutlinedTextField(search, { search = it }, modifier = Modifier.fillMaxWidth(), singleLine = true,
                    placeholder = { Text("搜索标题或备注") }, leadingIcon = { Icon(Icons.Outlined.Search, null) }, shape = RoundedCornerShape(14.dp))
            }
        }
        item { PindoGroupChips(state.groups, groupID) { groupID = it } }
        item {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(if (scope == TaskScope.OVERDUE) "逾期待办" else if (showCompleted) "已完成" else "待办事项",
                        style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(matching.size.toString() + " 项", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                FilterChip(selected = showCompleted, onClick = { showCompleted = !showCompleted }, label = { Text("已完成") },
                    leadingIcon = { Icon(Icons.Outlined.TaskAlt, null, Modifier.size(16.dp)) })
            }
        }
        if (rows.isEmpty()) item {
            PindoEmptyState(if (search.isNotBlank()) "没有找到匹配的事项" else if (showCompleted) "还没有完成的事项" else "清单已经理清了",
                if (search.isNotBlank()) "试试其他关键词，或切换分组。" else "从一件小事开始，安排接下来的时间。",
                actionLabel = if (!state.readOnly && search.isBlank() && !showCompleted) "添加第一件事" else null, onAction = onAdd)
        }
        pindoTaskItems(rows, state, collapsed.toSet(), onDisclosure = { id -> collapsed = if (id in collapsed) collapsed - id else collapsed + id },
            onEdit, onAddChild, onDelete, store)
    }
}

@Composable private fun DashboardStat(label: String, value: String, modifier: Modifier, icon: androidx.compose.ui.graphics.vector.ImageVector, onClick: () -> Unit) {
    Surface(onClick = onClick, modifier = modifier, shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surface.copy(alpha = .6f)) {
        Column(Modifier.padding(horizontal = 10.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                Icon(icon, null, Modifier.size(14.dp), tint = MaterialTheme.colorScheme.primary)
                Text(value, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            }
            Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
