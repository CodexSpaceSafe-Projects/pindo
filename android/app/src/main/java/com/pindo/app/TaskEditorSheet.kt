package com.pindo.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.Saver
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.graphics.toColorInt
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable internal fun TaskEditorSheet(store: AppStore, state: AppState, taskID: String?, parentID: String?, initialDay: LocalDate, initiallyEditing: Boolean = false, initialTitle: String = "", initialGroupID: String? = state.preferences.defaultGroupID, onDismiss: () -> Unit) {
    val currentTask = state.tasks.find { it.id == taskID }
    val baselineText by rememberSaveable(taskID, parentID) { mutableStateOf(currentTask?.let { TaskEditBaseline.capture(it).encoded() }) }
    val baseline = remember(baselineText) { baselineText?.let(TaskEditBaseline::decode) }
    val task = currentTask
    val initialParent = state.tasks.find { it.id == parentID }
    val originalTitle = baseline?.title ?: initialTitle
    val originalNote = task?.note ?: ""
    val originalDay = baseline?.day ?: initialParent?.day ?: initialDay
    val originalGroup = when { baseline != null -> baseline.groupID; initialParent != null -> initialParent.groupID; else -> initialGroupID }
    val originalParent = if (baseline != null) baseline.parentID else parentID
    var draftWarning by remember { mutableStateOf<String?>(null) }
    val noteDraft = remember(taskID, parentID) { store.noteDraftHandle() }
    val noteSaver = remember(noteDraft, originalNote) {
        Saver<TextFieldValue, String>(
            save = { value -> noteDraft.save(NoteDraft(value.text, value.selection.start, value.selection.end)).also { draftWarning = noteDraft.error } },
            restore = { token ->
                val restored = noteDraft.restore(token)
                draftWarning = noteDraft.error
                restored?.let { TextFieldValue(it.text, TextRange(it.selectionStart, it.selectionEnd)) } ?: TextFieldValue(originalNote)
            }
        )
    }
    var title by rememberSaveable(taskID, parentID) { mutableStateOf(originalTitle) }
    var note by rememberSaveable(taskID, parentID, stateSaver = noteSaver) { mutableStateOf(TextFieldValue(originalNote)) }
    var day by rememberSaveable(taskID, parentID) { mutableStateOf(originalDay.toString()) }
    var group by rememberSaveable(taskID, parentID) { mutableStateOf(originalGroup) }
    var parent by rememberSaveable(taskID, parentID) { mutableStateOf(originalParent) }
    var phase by rememberSaveable(taskID, parentID) { mutableStateOf(baseline?.phase ?: "pending") }
    var preview by rememberSaveable(taskID, parentID) { mutableStateOf(taskID != null && !initiallyEditing) }
    var propertiesOpen by rememberSaveable { mutableStateOf(false) }
    val titleFocus = remember { FocusRequester() }
    val noteFocus = remember { FocusRequester() }
    var formattingMenu by remember { mutableStateOf(false) }
    var datePicker by remember { mutableStateOf(false) }
    var parentPicker by remember { mutableStateOf(false) }
    var groupPicker by remember { mutableStateOf(false) }
    var discard by remember { mutableStateOf(false) }
    var validation by remember { mutableStateOf<String?>(null) }
    val noteChanged = remember(note.text, baseline?.noteDigest) { baseline?.let { taskNoteDigest(note.text) != it.noteDigest } ?: (note.text != originalNote) }
    val dirty = (taskID == null && (title.isNotBlank() || note.text.isNotBlank())) || title != originalTitle || noteChanged || day != originalDay.toString() || group != originalGroup || parent != originalParent || phase != (baseline?.phase ?: "pending")
    fun closeDraft() {
        if (noteDraft.clear()) { draftWarning = null; onDismiss() }
        else draftWarning = noteDraft.error
    }
    val requestClose = { if (dirty) discard = true else closeDraft() }
    DisposableEffect(Unit) { val lease = store.beginEditing(); onDispose { store.endEditing(lease) } }
    fun save() {
        if (title.isBlank()) { validation = "先写下这件事的标题。"; return }
        val parsed = runCatching { LocalDate.parse(day) }.getOrNull()
        if (parsed == null) { validation = "请选择有效日期。"; return }
        val saved = if (taskID == null) store.addTask(title, note.text, parsed, group, parent)
            else store.editTask(taskID, title, note.text, parsed, group, parent, phase,
                baseline = baseline?.task(taskID), baselineNoteDigest = baseline?.noteDigest)
        if (saved) closeDraft()
    }
    Dialog(onDismissRequest = requestClose, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        val keyboard = LocalSoftwareKeyboardController.current
        fun openProperties() { keyboard?.hide(); formattingMenu = false; propertiesOpen = true }
        fun read() { keyboard?.hide(); formattingMenu = false; preview = true }
        fun formatNote(prefix: String, suffix: String) {
            note = surroundNote(note, prefix, suffix)
            noteFocus.requestFocus()
            keyboard?.show()
        }
        BackHandler(onBack = requestClose)
        Surface(Modifier.fillMaxSize().testTag("task-editor"), color = MaterialTheme.colorScheme.background) {
            Scaffold(modifier = Modifier.imePadding(), containerColor = MaterialTheme.colorScheme.background,
                topBar = {
                    Column {
                        TopAppBar(
                            title = {
                                Text(if (preview) "事项" else if (taskID == null) "新事项" else "写事项",
                                    style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Medium)
                            },
                            navigationIcon = {
                                IconButton(onClick = requestClose, modifier = Modifier.size(48.dp)) {
                                    Icon(Icons.Outlined.Close, "关闭编辑")
                                }
                            },
                            actions = {
                                if (!preview) TextButton(onClick = ::read, modifier = Modifier.heightIn(min = 48.dp)) {
                                    Icon(Icons.Outlined.Visibility, null, Modifier.size(18.dp))
                                    Spacer(Modifier.width(6.dp))
                                    Text("预览")
                                }
                            },
                            colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background))
                        listOfNotNull(draftWarning, validation ?: state.error).distinct().forEach { text ->
                            Text(text, Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 8.dp),
                                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error)
                        }
                    }
                },
                bottomBar = {
                    Surface(color = MaterialTheme.colorScheme.surface, tonalElevation = 0.dp) {
                        Column(Modifier.navigationBarsPadding()) {
                            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = .65f))
                            BoxWithConstraints(Modifier.fillMaxWidth()) {
                                val compactActions = maxWidth < 360.dp || LocalDensity.current.fontScale > 1.3f
                                Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    if (preview) {
                                        FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween,
                                            verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                            TextButton(onClick = ::openProperties, enabled = !state.readOnly,
                                                modifier = Modifier.heightIn(min = 48.dp).semantics { contentDescription = "安排事项" }) {
                                                Icon(Icons.Outlined.Tune, null, Modifier.size(20.dp))
                                                Spacer(Modifier.width(8.dp))
                                                Text("安排")
                                            }
                                            if (dirty) OutlinedButton(onClick = { preview = false },
                                                modifier = Modifier.heightIn(min = 48.dp), enabled = !state.readOnly) { Text("继续编辑") }
                                            else Button(onClick = { preview = false }, modifier = Modifier.heightIn(min = 48.dp),
                                                enabled = !state.readOnly, contentPadding = PaddingValues(horizontal = 24.dp)) {
                                                Icon(Icons.Outlined.Edit, null, Modifier.size(18.dp))
                                                Spacer(Modifier.width(8.dp))
                                                Text("编辑")
                                            }
                                            if (dirty) Button(onClick = ::save,
                                                modifier = (if (compactActions) Modifier.fillMaxWidth() else Modifier).heightIn(min = 48.dp),
                                                enabled = !state.readOnly && title.isNotBlank()) { Text("保存") }
                                        }
                                    } else {
                                        Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()),
                                            verticalAlignment = Alignment.CenterVertically) {
                                            TextButton(onClick = { formatNote("**", "**") }, enabled = !state.readOnly,
                                                modifier = Modifier.heightIn(min = 48.dp), contentPadding = PaddingValues(horizontal = 10.dp)) {
                                                Text("加粗", fontWeight = FontWeight.Bold)
                                            }
                                            if (!compactActions) IconButton(onClick = { formatNote("\n- [ ] ", "") }, enabled = !state.readOnly,
                                                modifier = Modifier.size(48.dp)) { Icon(Icons.Outlined.Checklist, "插入清单", Modifier.size(21.dp)) }
                                            Box {
                                                IconButton(onClick = { formattingMenu = true }, enabled = !state.readOnly,
                                                    modifier = Modifier.size(48.dp)) { Icon(Icons.Outlined.MoreHoriz, "更多格式", Modifier.size(21.dp)) }
                                                DropdownMenu(expanded = formattingMenu, onDismissRequest = { formattingMenu = false }) {
                                                    if (compactActions) DropdownMenuItem(text = { Text("清单") }, onClick = {
                                                        formattingMenu = false; formatNote("\n- [ ] ", "")
                                                    })
                                                    listOf("斜体" to "*", "代码" to "`").forEach { (label, token) ->
                                                        DropdownMenuItem(text = { Text(label) }, onClick = {
                                                            formattingMenu = false; formatNote(token, token)
                                                        })
                                                    }
                                                    DropdownMenuItem(text = { Text("标题") }, onClick = {
                                                        formattingMenu = false; formatNote("\n## ", "")
                                                    })
                                                }
                                            }
                                        }
                                        IconButton(onClick = ::openProperties, modifier = Modifier.size(48.dp), enabled = !state.readOnly) {
                                            Icon(Icons.Outlined.Tune, "安排事项", Modifier.size(21.dp))
                                        }
                                        Button(onClick = ::save, modifier = Modifier.heightIn(min = 48.dp),
                                            enabled = !state.readOnly && title.isNotBlank(), contentPadding = PaddingValues(horizontal = 20.dp)) {
                                            Text("保存", fontWeight = FontWeight.SemiBold)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            ) { padding ->
                Box(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding), contentAlignment = Alignment.TopCenter) {
                    Column(Modifier.widthIn(max = 680.dp).fillMaxSize().verticalScroll(rememberScrollState())
                        .padding(horizontal = 24.dp).padding(top = 16.dp, bottom = 40.dp),
                        verticalArrangement = Arrangement.spacedBy(20.dp)) {
                        state.tasks.find { it.id == parent }?.let { parentTask ->
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                Icon(Icons.Outlined.SubdirectoryArrowRight, null, Modifier.size(16.dp),
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                Text(spacedText(parentTask.title), style = MaterialTheme.typography.labelMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                        }
                        if (preview) {
                            SelectionContainer {
                                Text(spacedText(title.ifBlank { "未命名事项" }),
                                    style = MaterialTheme.typography.headlineMedium.copy(fontSize = 28.sp, lineHeight = 38.sp),
                                    fontWeight = FontWeight.SemiBold, modifier = Modifier.testTag("task-reader-title").semantics { heading() })
                            }
                        } else {
                            BasicTextField(title, { title = it; validation = null }, enabled = !state.readOnly,
                                textStyle = MaterialTheme.typography.headlineMedium.copy(fontSize = 26.sp, lineHeight = 36.sp,
                                    fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface),
                                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary), visualTransformation = MixedScriptVisualTransformation,
                                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("task-title")
                                    .initialInputFocus(titleFocus, !state.readOnly && taskID == null && initialTitle.isBlank())
                                    .semantics { contentDescription = "事项标题" },
                                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
                                decorationBox = { input -> Box {
                                    if (title.isEmpty()) Text("事项标题", style = MaterialTheme.typography.headlineMedium.copy(fontSize = 26.sp, lineHeight = 36.sp),
                                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = .65f))
                                    input()
                                } })
                        }
                        EditorMetadata(day = LocalDate.parse(day), group = state.groups.find { it.id == group }, phase = phase)
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = .65f))
                        if (preview) {
                            if (note.text.isBlank()) Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text("留一点细节，让这件事更清楚。", style = MaterialTheme.typography.bodyLarge,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Text("可以记录步骤、清单或想法。", style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            else MarkdownPreview(note.text, Modifier.fillMaxWidth().testTag("task-reader"))
                        } else BasicTextField(note, { note = it }, enabled = !state.readOnly,
                            textStyle = MaterialTheme.typography.bodyLarge.copy(fontSize = 17.sp, lineHeight = 29.sp,
                                color = MaterialTheme.colorScheme.onSurface),
                            cursorBrush = SolidColor(MaterialTheme.colorScheme.primary), visualTransformation = MixedScriptVisualTransformation,
                            modifier = Modifier.fillMaxWidth().heightIn(min = 180.dp).testTag("task-note")
                                .initialInputFocus(noteFocus, !state.readOnly && (taskID != null || initialTitle.isNotBlank()))
                                .semantics { contentDescription = "事项备注，支持 Markdown" },
                            decorationBox = { input -> Box {
                                if (note.text.isEmpty()) Text("写下细节、清单或想法…",
                                    style = MaterialTheme.typography.bodyLarge.copy(fontSize = 17.sp, lineHeight = 29.sp),
                                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = .7f))
                                input()
                            } })
                    }
                }
            }
        }
        if (propertiesOpen) ModalBottomSheet(onDismissRequest = { propertiesOpen = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = MaterialTheme.colorScheme.surface) {
            Column(Modifier.fillMaxWidth().heightIn(max = 620.dp).verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                Text("安排事项", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                if (taskID != null) {
                    EditorSection("事项状态", Icons.Outlined.CheckCircleOutline) {
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            listOf("pending" to "待办", "inProgress" to "进行中", "completed" to "已完成").forEach { (value, label) ->
                                FilterChip(selected = phase == value, onClick = { phase = value },
                                    label = { Text(label) }, modifier = Modifier.heightIn(min = 48.dp),
                                    leadingIcon = if (phase == value) ({ Icon(Icons.Outlined.Check, null, Modifier.size(18.dp)) }) else null)
                            }
                        }
                        if (state.tasks.any { it.parentID == taskID && it.phase != "completed" }) {
                            Text("子项全部完成后，父项才能标记完成。", color = MaterialTheme.colorScheme.onSurfaceVariant,
                                style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
                EditorSection("计划日期", Icons.Outlined.Event) {
                    Text(LocalDate.parse(day).format(DateTimeFormatter.ofPattern("M 月 d 日 · EEEE")),
                        style = MaterialTheme.typography.bodyLarge)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        listOf(LocalDate.now() to "今天", LocalDate.now().plusDays(1) to "明天", LocalDate.now().plusDays(7) to "一周后").forEach { (date, label) ->
                            FilterChip(selected = day == date.toString(), onClick = { day = date.toString() },
                                label = { Text(label) }, modifier = Modifier.heightIn(min = 48.dp))
                        }
                        AssistChip(onClick = { datePicker = true }, label = { Text("选择日期") },
                            modifier = Modifier.heightIn(min = 48.dp),
                            leadingIcon = { Icon(Icons.Outlined.CalendarMonth, null, Modifier.size(18.dp)) })
                    }
                }
                Column {
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    EditorChoiceRow("所属分组", state.groups.find { it.id == group }?.name ?: "未分组", Icons.Outlined.FolderOpen) { groupPicker = true }
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    EditorChoiceRow("父事项", state.tasks.find { it.id == parent }?.title ?: "作为主待办", Icons.Outlined.SubdirectoryArrowRight) { parentPicker = true }
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                }
                Button(onClick = { propertiesOpen = false }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("完成") }
            }
        }
        if (datePicker) {
            val pickerState = rememberDatePickerState(initialSelectedDateMillis = LocalDate.parse(day).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli())
            DatePickerDialog(onDismissRequest = { datePicker = false }, confirmButton = { TextButton(onClick = {
                pickerState.selectedDateMillis?.let { day = Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate().toString() }
                datePicker = false
            }, modifier = Modifier.heightIn(min = 48.dp)) { Text("确定") } }, dismissButton = { TextButton(onClick = { datePicker = false }, modifier = Modifier.heightIn(min = 48.dp)) { Text("取消") } }) { DatePicker(pickerState) }
        }
        if (groupPicker) GroupPicker(state.groups, group, onChoose = { group = it; groupPicker = false }, onDismiss = { groupPicker = false })
        if (parentPicker) ParentPicker(state.tasks, taskID, parent, onChoose = { parent = it; parentPicker = false }, onDismiss = { parentPicker = false })
        if (discard) AlertDialog(onDismissRequest = { discard = false }, title = { Text("放弃未保存的修改？") }, text = { Text("当前填写的内容还没有保存。") },
            confirmButton = { TextButton(onClick = { discard = false; closeDraft() }, modifier = Modifier.heightIn(min = 48.dp)) { Text("放弃修改") } }, dismissButton = { TextButton(onClick = { discard = false }, modifier = Modifier.heightIn(min = 48.dp)) { Text("继续编辑") } })
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable private fun EditorMetadata(day: LocalDate, group: TodoGroup?, phase: String) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(Icons.Outlined.Event, null, Modifier.size(15.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(relativeDay(day), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        group?.let {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(Modifier.size(6.dp).background(Color(it.color.toColorInt()), CircleShape))
                Text(it.name, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 180.dp))
            }
        }
        Text(when (phase) { "completed" -> "已完成"; "inProgress" -> "进行中"; else -> "待办" },
            style = MaterialTheme.typography.labelMedium,
            color = if (phase == "inProgress") MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable private fun EditorSection(title: String, icon: ImageVector, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, Modifier.size(22.dp), tint = MaterialTheme.colorScheme.primary)
            Text(title, Modifier.padding(start = 10.dp), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        }
        content()
    }
}

@Composable private fun EditorChoiceRow(label: String, value: String, icon: ImageVector, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 64.dp).clickable(role = Role.Button, onClick = onClick).padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(24.dp), tint = MaterialTheme.colorScheme.primary)
        Column(Modifier.weight(1f).padding(horizontal = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(spacedText(value), style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Icon(Icons.Outlined.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable private fun GroupPicker(groups: List<TodoGroup>, selected: String?, onChoose: (String?) -> Unit, onDismiss: () -> Unit) {
    AlertDialog(onDismissRequest = onDismiss, title = { Text("选择分组") }, text = {
        LazyColumn(Modifier.fillMaxWidth().heightIn(max = 360.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            items(listOf<TodoGroup?>(null) + groups, key = { it?.id ?: "ungrouped" }) { group ->
                val chosen = selected == group?.id
                ListItem(
                    headlineContent = { Text(spacedText(group?.name ?: "未分组"), maxLines = 2, overflow = TextOverflow.Ellipsis) },
                    leadingContent = {
                        if (group == null) Icon(Icons.Outlined.FolderOpen, null)
                        else Box(Modifier.size(14.dp).background(Color(group.color.toColorInt()), CircleShape))
                    },
                    trailingContent = { RadioButton(selected = chosen, onClick = null) },
                    colors = ListItemDefaults.colors(containerColor = if (chosen) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surface),
                    modifier = Modifier.fillMaxWidth().heightIn(min = 64.dp)
                        .selectable(selected = chosen, role = Role.RadioButton, onClick = { onChoose(group?.id) })
                )
            }
            if (groups.isEmpty()) item {
                Text("可以稍后在设置中建立工作、生活等分组。", Modifier.padding(top = 16.dp),
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }, confirmButton = { TextButton(onClick = onDismiss, modifier = Modifier.heightIn(min = 48.dp)) { Text("取消") } })
}

@Composable private fun ParentPicker(tasks: List<Todo>, editingID: String?, selected: String?, onChoose: (String?) -> Unit, onDismiss: () -> Unit) {
    var search by rememberSaveable { mutableStateOf("") }
    val candidates = tasks.filter { candidate ->
        candidate.title.contains(search, true) && runCatching { TodoRules.validateParent(tasks, editingID, candidate.id) }.isSuccess
    }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("选择父事项") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedTextField(search, { search = it }, placeholder = { Text("搜索事项") }, leadingIcon = { Icon(Icons.Outlined.Search, null) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            LazyColumn(Modifier.heightIn(max = 360.dp)) {
                item { ListItem(headlineContent = { Text("作为主待办") }, leadingContent = { Icon(Icons.Outlined.FolderOpen, null) }, trailingContent = { if (selected == null) Icon(Icons.Outlined.Check, null, tint = MaterialTheme.colorScheme.primary) }, modifier = Modifier.heightIn(min = 64.dp).selectable(selected = selected == null, role = Role.RadioButton) { onChoose(null) }) }
                items(candidates, key = { it.id }) { candidate ->
                    ListItem(headlineContent = { Text(spacedText(candidate.title), maxLines = 2, overflow = TextOverflow.Ellipsis) }, supportingContent = { Text(if (candidate.parentID == null) "主待办" else "子待办") }, trailingContent = { if (candidate.id == selected) Icon(Icons.Outlined.Check, null, tint = MaterialTheme.colorScheme.primary) }, modifier = Modifier.heightIn(min = 64.dp).selectable(selected = candidate.id == selected, role = Role.RadioButton) { onChoose(candidate.id) })
                }
                if (candidates.isEmpty()) item { Text("没有可用的父事项", Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
        }
    }, confirmButton = { TextButton(onClick = onDismiss, modifier = Modifier.heightIn(min = 48.dp)) { Text("取消") } })
}

private fun surroundNote(value: TextFieldValue, prefix: String, suffix: String): TextFieldValue {
    val start = value.selection.min
    val end = value.selection.max
    val text = value.text.substring(0, start) + prefix + value.text.substring(start, end) + suffix + value.text.substring(end)
    return TextFieldValue(text, TextRange(start + prefix.length, end + prefix.length))
}
