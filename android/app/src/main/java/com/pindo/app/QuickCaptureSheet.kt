package com.pindo.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material.icons.automirrored.outlined.Subject
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import java.time.LocalDate
import java.time.ZoneOffset

/** A single, keyboard-safe capture surface shared by every task view. Draft
 * fields live in the root's saved state so dismissing this panel loses no text. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable internal fun QuickCaptureSheet(
    store: AppStore,
    state: AppState,
    title: String,
    onTitle: (String) -> Unit,
    day: LocalDate,
    onDay: (LocalDate) -> Unit,
    groupID: String?,
    onGroup: (String?) -> Unit,
    onDismiss: () -> Unit,
    onDetails: () -> Unit
) {
    val focus = remember { FocusRequester() }
    var datePicker by rememberSaveable { mutableStateOf(false) }
    var added by rememberSaveable { mutableStateOf(0) }
    var addedTo by rememberSaveable { mutableStateOf("") }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surface,
        modifier = Modifier.testTag("quick-capture"),
        dragHandle = { BottomSheetDefaults.DragHandle() }
    ) {
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val compact = maxWidth < 360.dp || maxHeight < 480.dp || LocalDensity.current.fontScale > 1.3f
            val keyboard = LocalSoftwareKeyboardController.current
            fun submit() {
                if (title.isBlank() || state.readOnly) return
                if (store.addTask(title, "", day, groupID, null)) {
                    added++;
                    addedTo = relativeDay(day) + (state.groups.find { it.id == groupID }?.let { " · " + it.name } ?: "")
                    onTitle("");
                    focus.requestFocus();
                    keyboard?.show()
                }
            }

            Column(
                Modifier.fillMaxWidth().imePadding().padding(horizontal = 24.dp).padding(bottom = 20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("记一件事", Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
                    TextButton(
                        onClick = onDismiss,
                        modifier = Modifier.heightIn(min = 48.dp).semantics { contentDescription = "关闭快速添加" }
                    ) { Text("收起") }
                }
                Column(
                    Modifier.fillMaxWidth().weight(1f, fill = false).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(16.dp)
                ) {
                    OutlinedTextField(
                        value = title,
                        onValueChange = onTitle,
                        modifier = Modifier.fillMaxWidth()
                            .initialInputFocus(focus, !state.readOnly) { keyboard?.show() }
                            .testTag("quick-add")
                            .semantics { contentDescription = "添加事项标题" },
                        enabled = !state.readOnly,
                        placeholder = { Text("有什么想做的？") },
                        minLines = 1,
                        maxLines = 3,
                        textStyle = MaterialTheme.typography.bodyLarge,
                        visualTransformation = MixedScriptVisualTransformation,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { submit() }),
                        shape = MaterialTheme.shapes.medium
                    )
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        if (!compact) listOf(LocalDate.now() to "今天", LocalDate.now().plusDays(1) to "明天").forEach { (date, label) ->
                            FilterChip(
                                selected = day == date,
                                onClick = { onDay(date) },
                                label = { Text(label) },
                                modifier = Modifier.heightIn(min = 48.dp)
                            )
                        }
                        AssistChip(
                            onClick = { datePicker = true },
                            label = {
                                Text(if (!compact && (day == LocalDate.now() || day == LocalDate.now().plusDays(1))) "选择日期" else relativeDay(day))
                            },
                            modifier = Modifier.heightIn(min = 48.dp),
                            leadingIcon = { Icon(Icons.Outlined.CalendarMonth, null, Modifier.size(18.dp)) }
                        )
                        PindoGroupPicker(
                            state.groups,
                            groupID,
                            "未分组",
                            modifier = if (compact) Modifier.widthIn(max = 156.dp) else Modifier
                        ) { onGroup(it) }
                    }
                    if (added > 0) Text(
                        "已添加 $added 项 · $addedTo",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.testTag("capture-feedback")
                    )
                    state.error?.let {
                        Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
                    }
                }
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    if (compact) IconButton(
                        onClick = onDetails,
                        modifier = Modifier.size(48.dp),
                        enabled = !state.readOnly
                    ) {
                        Icon(Icons.AutoMirrored.Outlined.Subject, "详细编辑")
                    } else TextButton(
                        onClick = onDetails,
                        modifier = Modifier.heightIn(min = 48.dp),
                        enabled = !state.readOnly
                    ) {
                        Icon(Icons.AutoMirrored.Outlined.Subject, null, Modifier.size(18.dp));
                        Spacer(Modifier.width(6.dp));
                        Text("详细编辑")
                    }
                    Button(
                        onClick = ::submit,
                        enabled = title.isNotBlank() && !state.readOnly,
                        modifier = Modifier.weight(1f).heightIn(min = 52.dp).semantics { contentDescription = "快速添加事项" },
                        shape = MaterialTheme.shapes.medium
                    ) {
                        Icon(Icons.Outlined.Add, null, Modifier.size(20.dp));
                        Spacer(Modifier.width(6.dp));
                        Text("添加并继续")
                    }
                }
            }
        }
    }
    if (datePicker) {
        val picker = rememberDatePickerState(initialSelectedDateMillis = day.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli())
        DatePickerDialog(
            onDismissRequest = { datePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    picker.selectedDateMillis?.let { onDay(java.time.Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate()) };
                    datePicker = false
                }) { Text("确定") }
            },
            dismissButton = { TextButton(onClick = { datePicker = false }) { Text("取消") } }
        ) { DatePicker(state = picker) }
    }
}
