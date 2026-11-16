package com.pindo.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.time.LocalDate

private enum class MainTab(val title: String, val icon: ImageVector) {
    TASKS("今天", Icons.Outlined.WbSunny), CALENDAR("日历", Icons.Outlined.CalendarMonth), MANAGE("清单", Icons.Outlined.Checklist)
}

@Composable fun PindoScreen(store: AppStore) {
    val state by store.state.collectAsStateWithLifecycle()
    var selectedTab by rememberSaveable { mutableStateOf(MainTab.TASKS.name) }
    val tab = MainTab.entries.firstOrNull { it.name == selectedTab } ?: MainTab.TASKS
    var settingsOpen by rememberSaveable { mutableStateOf(false) }
    var selectedDay by rememberSaveable { mutableStateOf(LocalDate.now().toString()) }
    var editorOpen by rememberSaveable { mutableStateOf(false) }
    var editorWriting by rememberSaveable { mutableStateOf(false) }
    var editorTaskID by rememberSaveable { mutableStateOf<String?>(null) }
    var editorParentID by rememberSaveable { mutableStateOf<String?>(null) }
    var editorDay by rememberSaveable { mutableStateOf(LocalDate.now().toString()) }
    var editorTitle by rememberSaveable { mutableStateOf("") }
    var editorGroup by rememberSaveable { mutableStateOf<String?>(null) }
    var deletingIDs by rememberSaveable { mutableStateOf<List<String>?>(null) }
    var captureOpen by rememberSaveable { mutableStateOf(false) }
    var captureTitle by rememberSaveable { mutableStateOf("") }
    var captureDay by rememberSaveable { mutableStateOf(LocalDate.now().toString()) }
    var captureGroup by rememberSaveable { mutableStateOf<String?>(state.preferences.defaultGroupID) }
    var selecting by remember { mutableStateOf(false) }
    var viewCaptureDay by remember { mutableStateOf(LocalDate.now()) }
    var viewCaptureGroup by remember { mutableStateOf(state.preferences.defaultGroupID) }
    val holder = rememberSaveableStateHolder()
    fun edit(taskID: String?, parentID: String?, day: LocalDate, writing: Boolean = false,
             title: String = "", group: String? = state.preferences.defaultGroupID) {
        editorWriting = writing; editorTaskID = taskID; editorParentID = parentID
        editorDay = day.toString(); editorTitle = title; editorGroup = group; editorOpen = true
    }
    fun capture() {
        if (captureTitle.isBlank()) {
            captureDay = viewCaptureDay.toString()
            captureGroup = viewCaptureGroup?.takeIf { group -> state.groups.any { it.id == group } }
        }
        captureOpen = true
    }
    // Commit after restored editor DisposableEffects have registered their
    // leases; entering settings must not bypass the same network gate.
    SideEffect { store.markUiReady() }
    BackHandler(enabled = settingsOpen) { settingsOpen = false }
    if (settingsOpen) {
        AppSettingsScreen(store, state) { settingsOpen = false }
        return
    }
    BackHandler(enabled = tab != MainTab.TASKS && !editorOpen && !captureOpen && deletingIDs == null) {
        selectedTab = MainTab.TASKS.name
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val useRail = maxWidth >= 600.dp && maxHeight >= 480.dp
        val imeVisible = WindowInsets.ime.getBottom(LocalDensity.current) > 0
        val fabEnd = if (useRail) ((maxWidth - 88.dp - 840.dp) / 2).coerceAtLeast(0.dp) else 0.dp
        Scaffold(containerColor = MaterialTheme.colorScheme.background,
            modifier = Modifier.imePadding(),
            bottomBar = {
                if (!useRail && !imeVisible && !captureOpen) {
                    NavigationBar(modifier = Modifier.testTag("navigation-bar"), containerColor = MaterialTheme.colorScheme.surface,
                        tonalElevation = 0.dp) {
                        MainTab.entries.forEach { item ->
                            NavigationBarItem(selected = item == tab, onClick = { selectedTab = item.name },
                                icon = { Icon(item.icon, null, Modifier.size(23.dp)) }, label = { Text(item.title) },
                                colors = NavigationBarItemDefaults.colors(indicatorColor = MaterialTheme.colorScheme.primaryContainer,
                                    selectedIconColor = MaterialTheme.colorScheme.primary, selectedTextColor = MaterialTheme.colorScheme.primary))
                        }
                    }
                }
            }, floatingActionButton = {
                if (!state.readOnly && !selecting && !imeVisible && !captureOpen) {
                    if (maxWidth < 360.dp || LocalDensity.current.fontScale > 1.3f) FloatingActionButton(onClick = ::capture,
                        modifier = Modifier.padding(end = fabEnd).testTag("add-task"), shape = MaterialTheme.shapes.large,
                        containerColor = MaterialTheme.colorScheme.primary, contentColor = MaterialTheme.colorScheme.onPrimary) {
                        Icon(Icons.Outlined.Add, "添加事项")
                    } else ExtendedFloatingActionButton(onClick = ::capture,
                        modifier = Modifier.padding(end = fabEnd).testTag("add-task"),
                        icon = { Icon(Icons.Outlined.Add, "添加事项") }, text = { Text(if (captureTitle.isBlank()) "记一件事" else "继续草稿") },
                        shape = MaterialTheme.shapes.large, containerColor = MaterialTheme.colorScheme.primary,
                        contentColor = MaterialTheme.colorScheme.onPrimary)
                }
            }) { padding ->
            Row(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding)) {
                if (useRail) {
                    NavigationRail(modifier = Modifier.fillMaxHeight().width(88.dp).verticalScroll(rememberScrollState()).testTag("navigation-rail"),
                        containerColor = MaterialTheme.colorScheme.background, windowInsets = WindowInsets(0, 0, 0, 0),
                        header = {
                            Text("P", modifier = Modifier.padding(top = 12.dp, bottom = 28.dp),
                                style = MaterialTheme.typography.headlineMedium, color = MaterialTheme.colorScheme.primary)
                        }) {
                        MainTab.entries.forEach { item ->
                            NavigationRailItem(selected = item == tab, onClick = { selectedTab = item.name },
                                icon = { Icon(item.icon, null) }, label = { Text(item.title) })
                            Spacer(Modifier.height(16.dp))
                        }
                        Spacer(Modifier.weight(1f))
                        IconButton(onClick = { settingsOpen = true }, modifier = Modifier.size(48.dp)) { Icon(Icons.Outlined.Settings, "设置") }
                        Spacer(Modifier.height(16.dp))
                    }
                }
                Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.TopCenter) {
                    Box(Modifier.widthIn(max = 840.dp).fillMaxSize()) {
                        holder.SaveableStateProvider(selectedTab) {
                            when (tab) {
                                MainTab.TASKS -> DashboardScreen(store, state,
                                    onEdit = { id, writing -> edit(id, null, LocalDate.now(), writing) },
                                    onAddChild = { id -> edit(null, id, state.tasks.find { it.id == id }?.day ?: LocalDate.now()) },
                                    onDelete = { deletingIDs = it.toList() }, onAdd = ::capture,
                                    onSyncSettings = { settingsOpen = true },
                                    onCaptureContextChange = { day, group -> viewCaptureDay = day; viewCaptureGroup = group })
                                MainTab.CALENDAR -> CalendarScreen(store, state, LocalDate.parse(selectedDay),
                                    onDaySelected = { selectedDay = it.toString() },
                                    onEdit = { id, writing -> edit(id, null, LocalDate.parse(selectedDay), writing) },
                                    onAddChild = { id -> edit(null, id, state.tasks.find { it.id == id }?.day ?: LocalDate.parse(selectedDay)) },
                                    onDelete = { deletingIDs = it.toList() }, onAdd = ::capture, onSettings = { settingsOpen = true },
                                    onCaptureContextChange = { day, group -> viewCaptureDay = day; viewCaptureGroup = group })
                                MainTab.MANAGE -> ManagementScreen(store, state,
                                    onEdit = { id, writing -> edit(id, null, LocalDate.now(), writing) },
                                    onAddChild = { id -> edit(null, id, state.tasks.find { it.id == id }?.day ?: LocalDate.now()) },
                                    onDelete = { deletingIDs = it.toList() }, onSettings = { settingsOpen = true },
                                    onSelectionModeChange = { selecting = it },
                                    onCaptureContextChange = { day, group -> viewCaptureDay = day; viewCaptureGroup = group })
                            }
                        }
                    }
                }
            }
        }
    }
    if (captureOpen) QuickCaptureSheet(store, state, captureTitle, { captureTitle = it }, LocalDate.parse(captureDay),
        { captureDay = it.toString() }, captureGroup, { captureGroup = it }, onDismiss = { captureOpen = false },
        onDetails = {
            edit(null, null, LocalDate.parse(captureDay), true, captureTitle, captureGroup)
            captureOpen = false; captureTitle = ""
        })
    if (editorOpen) TaskEditorSheet(store = store, state = state, taskID = editorTaskID, parentID = editorParentID,
        initialDay = LocalDate.parse(editorDay), initiallyEditing = editorWriting, initialTitle = editorTitle,
        initialGroupID = editorGroup, onDismiss = { editorOpen = false })
    deletingIDs?.let { ids ->
        val existing = ids.toSet().intersect(state.tasks.map { it.id }.toSet())
        val count = store.deletionCount(existing)
        AlertDialog(onDismissRequest = { deletingIDs = null }, title = { Text("删除 $count 条事项？") },
            text = { Text("所选事项、全部子项及备注将一并删除，此操作会同步到其他设备。") },
            confirmButton = { TextButton(enabled = !state.readOnly && count > 0, onClick = {
                if (store.applyBatch(existing, TodoBatchAction.Delete)) deletingIDs = null
            }, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text("删除事项") } },
            dismissButton = { TextButton(onClick = { deletingIDs = null }) { Text("取消") } })
    }
}
