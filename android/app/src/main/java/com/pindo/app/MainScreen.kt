package com.pindo.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
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
import androidx.compose.ui.graphics.vector.ImageVector
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
    var editorTaskID by rememberSaveable { mutableStateOf<String?>(null) }
    var editorParentID by rememberSaveable { mutableStateOf<String?>(null) }
    var editorDay by rememberSaveable { mutableStateOf(LocalDate.now().toString()) }
    var deletingIDs by rememberSaveable { mutableStateOf<List<String>?>(null) }
    val holder = rememberSaveableStateHolder()
    fun edit(taskID: String?, parentID: String?, day: LocalDate) {
        editorTaskID = taskID; editorParentID = parentID; editorDay = day.toString(); editorOpen = true
    }
    BackHandler(enabled = tab != MainTab.TASKS && !editorOpen && deletingIDs == null) { selectedTab = MainTab.TASKS.name }
    Scaffold(
        bottomBar = {
            NavigationBar(containerColor = MaterialTheme.colorScheme.surface, tonalElevation = 0.dp) {
                MainTab.entries.forEach { item ->
                    NavigationBarItem(selected = item == tab, onClick = { selectedTab = item.name },
                        icon = { Icon(item.icon, contentDescription = null) }, label = { Text(item.title) },
                        colors = NavigationBarItemDefaults.colors(indicatorColor = MaterialTheme.colorScheme.primaryContainer))
                }
            }
        },
        floatingActionButton = {
            if (!state.readOnly && tab != MainTab.SETTINGS) {
                ExtendedFloatingActionButton(onClick = {
                    edit(null, null, if (tab == MainTab.CALENDAR) LocalDate.parse(selectedDay) else LocalDate.now())
                }, icon = { Icon(Icons.Outlined.Add, contentDescription = null) }, text = { Text("添加事项") },
                    containerColor = MaterialTheme.colorScheme.primary, contentColor = MaterialTheme.colorScheme.onPrimary)
            }
        }
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            holder.SaveableStateProvider(selectedTab) {
                when (tab) {
                    MainTab.TASKS -> DashboardScreen(store, state,
                        onEdit = { edit(it, null, LocalDate.now()) }, onAddChild = { id -> edit(null, id, state.tasks.find { it.id == id }?.day ?: LocalDate.now()) },
                        onDelete = { deletingIDs = it.toList() }, onAdd = { edit(null, null, LocalDate.now()) },
                        onSyncSettings = { selectedTab = MainTab.SETTINGS.name })
                    MainTab.CALENDAR -> CalendarScreen(store, state, LocalDate.parse(selectedDay),
                        onDaySelected = { selectedDay = it.toString() }, onEdit = { edit(it, null, LocalDate.parse(selectedDay)) },
                        onAddChild = { id -> edit(null, id, state.tasks.find { it.id == id }?.day ?: LocalDate.parse(selectedDay)) },
                        onDelete = { deletingIDs = it.toList() }, onAdd = { edit(null, null, LocalDate.parse(selectedDay)) })
                    MainTab.MANAGE -> ManagementScreen(store, state, onEdit = { edit(it, null, LocalDate.now()) },
                        onAddChild = { id -> edit(null, id, state.tasks.find { it.id == id }?.day ?: LocalDate.now()) },
                        onDelete = { deletingIDs = it.toList() })
                    MainTab.SETTINGS -> AppSettingsScreen(store, state) { selectedTab = MainTab.TASKS.name }
                }
            }
        }
    }
    if (editorOpen) {
        TaskEditorSheet(store = store, state = state, taskID = editorTaskID, parentID = editorParentID,
            initialDay = LocalDate.parse(editorDay), onDismiss = { editorOpen = false })
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
