package com.pindo.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.time.LocalDate

private enum class MainTab(val title: String, val icon: ImageVector) {
    TASKS("清单", Icons.Outlined.Checklist), CALENDAR("日历", Icons.Outlined.CalendarMonth),
    MANAGE("管理", Icons.Outlined.Tune), SETTINGS("设置", Icons.Outlined.Settings)
}

@Composable fun PindoScreen(store: AppStore) {
    val state by store.state.collectAsStateWithLifecycle()
    var selectedTab by rememberSaveable { mutableStateOf(MainTab.TASKS.name) }
    val tab = MainTab.valueOf(selectedTab)
    var selectedDay by rememberSaveable { mutableStateOf(LocalDate.now().toString()) }
    var editorOpen by rememberSaveable { mutableStateOf(false) }
    var editorWriting by rememberSaveable { mutableStateOf(false) }
    var editorTaskID by rememberSaveable { mutableStateOf<String?>(null) }
    var editorParentID by rememberSaveable { mutableStateOf<String?>(null) }
    var editorDay by rememberSaveable { mutableStateOf(LocalDate.now().toString()) }
    var deletingIDs by rememberSaveable { mutableStateOf<List<String>?>(null) }
    val holder = rememberSaveableStateHolder()
    fun edit(taskID: String?, parentID: String?, day: LocalDate, writing: Boolean = false) {
        editorWriting = writing
        editorTaskID = taskID; editorParentID = parentID; editorDay = day.toString(); editorOpen = true
    }
    BackHandler(enabled = tab != MainTab.TASKS && !editorOpen && deletingIDs == null) { selectedTab = MainTab.TASKS.name }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val useRail = maxWidth >= 600.dp && maxHeight >= 480.dp
        val fabEndPadding = if (useRail) ((maxWidth - 80.dp - 840.dp) / 2).coerceAtLeast(0.dp) else 0.dp
        Scaffold(
            modifier = Modifier.imePadding(),
            containerColor = MaterialTheme.colorScheme.background,
            bottomBar = {
                if (!useRail) Column(Modifier.testTag("navigation-bar")) {
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    Row(Modifier.fillMaxWidth().navigationBarsPadding().selectableGroup()) {
                        MainTab.entries.forEach { item ->
                            val color = if (item == tab) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                            Column(Modifier.weight(1f).heightIn(min = 56.dp)
                                .selectable(selected = item == tab, role = Role.Tab, onClick = { selectedTab = item.name })
                                .semantics(mergeDescendants = true) {}
                                .padding(horizontal = 4.dp, vertical = 6.dp), horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterVertically)) {
                                Icon(item.icon, null, Modifier.size(22.dp), tint = color)
                                Text(item.title, style = MaterialTheme.typography.labelSmall, color = color,
                                    fontWeight = if (item == tab) FontWeight.Bold else FontWeight.Normal)
                            }
                        }
                    }
                }
            },
            floatingActionButton = {
                if (!state.readOnly && (tab == MainTab.CALENDAR || tab == MainTab.MANAGE)) {
                    FloatingActionButton(onClick = {
                        edit(null, null, if (tab == MainTab.CALENDAR) LocalDate.parse(selectedDay) else LocalDate.now())
                    }, modifier = Modifier.padding(end = fabEndPadding).testTag("add-task"),
                        containerColor = MaterialTheme.colorScheme.primary, contentColor = MaterialTheme.colorScheme.onPrimary) {
                        Icon(Icons.Outlined.Add, contentDescription = "添加事项")
                    }
                }
            }
        ) { padding ->
            Row(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding)) {
                if (useRail) NavigationRail(
                    modifier = Modifier.fillMaxHeight().verticalScroll(rememberScrollState()).testTag("navigation-rail"),
                    containerColor = MaterialTheme.colorScheme.background,
                    windowInsets = WindowInsets(0, 0, 0, 0),
                    header = { Text("Pindo", style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(vertical = 20.dp)) }
                ) {
                    MainTab.entries.forEach { item ->
                        NavigationRailItem(selected = item == tab, onClick = { selectedTab = item.name },
                            icon = { Icon(item.icon, contentDescription = null) }, label = { Text(item.title) })
                        Spacer(Modifier.height(12.dp))
                    }
                }
                Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.TopCenter) {
                    Box(Modifier.widthIn(max = 840.dp).fillMaxSize()) {
                        holder.SaveableStateProvider(selectedTab) {
                            when (tab) {
                                MainTab.TASKS -> DashboardScreen(store, state,
                                    onEdit = { id, writing -> edit(id, null, LocalDate.now(), writing) }, onAddChild = { id -> edit(null, id, state.tasks.find { it.id == id }?.day ?: LocalDate.now()) },
                                    onDelete = { deletingIDs = it.toList() }, onAdd = { edit(null, null, LocalDate.now()) },
                                    onSyncSettings = { selectedTab = MainTab.SETTINGS.name })
                                MainTab.CALENDAR -> CalendarScreen(store, state, LocalDate.parse(selectedDay),
                                    onDaySelected = { selectedDay = it.toString() }, onEdit = { id, writing -> edit(id, null, LocalDate.parse(selectedDay), writing) },
                                    onAddChild = { id -> edit(null, id, state.tasks.find { it.id == id }?.day ?: LocalDate.parse(selectedDay)) },
                                    onDelete = { deletingIDs = it.toList() }, onAdd = { edit(null, null, LocalDate.parse(selectedDay)) })
                                MainTab.MANAGE -> ManagementScreen(store, state, onEdit = { id, writing -> edit(id, null, LocalDate.now(), writing) },
                                    onAddChild = { id -> edit(null, id, state.tasks.find { it.id == id }?.day ?: LocalDate.now()) },
                                    onDelete = { deletingIDs = it.toList() })
                                MainTab.SETTINGS -> AppSettingsScreen(store, state) { selectedTab = MainTab.TASKS.name }
                            }
                        }
                    }
                }
            }
        }
    }
    if (editorOpen) {
        TaskEditorSheet(store = store, state = state, taskID = editorTaskID, parentID = editorParentID,
            initialDay = LocalDate.parse(editorDay), initiallyEditing = editorWriting, onDismiss = { editorOpen = false })
    }
    deletingIDs?.let { ids ->
        val existing = ids.toSet().intersect(state.tasks.map { it.id }.toSet())
        val count = store.deletionCount(existing)
        AlertDialog(onDismissRequest = { deletingIDs = null }, title = { Text("删除 " + count + " 条事项？") },
            text = { Text("所选事项、全部子项及备注将一并删除，此操作会同步到其他设备。") },
            confirmButton = { TextButton(enabled = !state.readOnly && count > 0, onClick = {
                if (store.applyBatch(existing, TodoBatchAction.Delete)) deletingIDs = null
            }, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text("删除事项") } },
            dismissButton = { TextButton(onClick = { deletingIDs = null }) { Text("取消") } })
    }
    // Compose invokes SideEffects after all restored DisposableEffects have
    // registered their editing leases. onStart alone must never start a pull.
    SideEffect { store.markUiReady() }
}
