package com.pindo.app

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import java.time.LocalDate
import java.time.YearMonth
import java.time.format.DateTimeFormatter
import java.util.Locale

@OptIn(ExperimentalLayoutApi::class)
@Composable internal fun CalendarScreen(store: AppStore, state: AppState, selectedDay: LocalDate,
    onDaySelected: (LocalDate) -> Unit, onEdit: (String) -> Unit, onAddChild: (String) -> Unit,
    onDelete: (Set<String>) -> Unit, onAdd: () -> Unit) {
    var monthText by rememberSaveable { mutableStateOf(selectedDay.withDayOfMonth(1).toString()) }
    var groupID by rememberSaveable { mutableStateOf<String?>(null) }
    var phaseName by rememberSaveable { mutableStateOf(PhaseFilter.ALL.name) }
    var collapsed by rememberSaveable { mutableStateOf(emptyList<String>()) }
    val month = YearMonth.from(LocalDate.parse(monthText))
    val counts = TodoQueries.calendarCounts(state.tasks, month, groupID)
    val query = TaskQuery(TaskScope.DAY, selectedDay, PhaseFilter.valueOf(phaseName), groupID, "", TaskSort.MANUAL)
    val rows = TodoQueries.outline(state.tasks, query, collapsed.toSet())
    val matching = TodoQueries.matching(state.tasks, query)
    LaunchedEffect(selectedDay) { monthText = selectedDay.withDayOfMonth(1).toString() }
    LazyColumn(Modifier.fillMaxSize().testTag("calendar"), contentPadding = PaddingValues(start = 18.dp, end = 18.dp, top = 5.dp, bottom = 104.dp),
        verticalArrangement = Arrangement.spacedBy(13.dp)) {
        item { PindoPageHeader("日历", "把时间留给重要的事") {
            TextButton(onClick = { monthText = LocalDate.now().withDayOfMonth(1).toString(); onDaySelected(LocalDate.now()) }) { Text("今天") }
        } }
        item { PindoErrorMessage(state.error, store::dismissError) }
        item {
            Surface(color = MaterialTheme.colorScheme.surface, shape = RoundedCornerShape(24.dp)) {
                Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        IconButton(onClick = { monthText = month.minusMonths(1).atDay(1).toString() }) { Icon(Icons.Outlined.ChevronLeft, "上个月") }
                        Text(month.format(DateTimeFormatter.ofPattern("yyyy年M月", Locale.SIMPLIFIED_CHINESE)), Modifier.weight(1f),
                            style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                        IconButton(onClick = { monthText = month.plusMonths(1).atDay(1).toString() }) { Icon(Icons.Outlined.ChevronRight, "下个月") }
                    }
                    Row(Modifier.fillMaxWidth()) {
                        listOf("一", "二", "三", "四", "五", "六", "日").forEach { label ->
                            Text(label, Modifier.weight(1f).padding(vertical = 5.dp), style = MaterialTheme.typography.labelMedium,
                                textAlign = androidx.compose.ui.text.style.TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    val first = month.atDay(1)
                    val offset = first.dayOfWeek.value - 1
                    val cells = ((offset + month.lengthOfMonth() + 6) / 7) * 7
                    val start = first.minusDays(offset.toLong())
                    (0 until cells / 7).forEach { week ->
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                            (0..6).forEach { weekday ->
                                val date = start.plusDays((week * 7 + weekday).toLong())
                                val dayCounts = counts[date]
                                val selected = date == selectedDay
                                val today = date == LocalDate.now()
                                Surface(onClick = { onDaySelected(date) }, modifier = Modifier.weight(1f).heightIn(min = 56.dp)
                                    .testTag("calendar-day-" + date)
                                    .semantics { contentDescription = date.format(DateTimeFormatter.ofPattern("yyyy年M月d日", Locale.SIMPLIFIED_CHINESE)) +
                                        "，未完成 " + (dayCounts?.unfinished ?: 0) + " 项，已完成 " + (dayCounts?.completed ?: 0) + " 项" },
                                    shape = RoundedCornerShape(12.dp),
                                    color = if (selected) MaterialTheme.colorScheme.primary else Color.Transparent,
                                    border = if (today && !selected) BorderStroke(1.dp, MaterialTheme.colorScheme.primary) else null) {
                                    Column(Modifier.fillMaxWidth().padding(top = 7.dp, bottom = 5.dp), horizontalAlignment = Alignment.CenterHorizontally,
                                        verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                        val textColor = if (selected) MaterialTheme.colorScheme.onPrimary
                                            else if (YearMonth.from(date) != month) MaterialTheme.colorScheme.outline else MaterialTheme.colorScheme.onSurface
                                        Text(date.dayOfMonth.toString(), style = MaterialTheme.typography.bodyMedium,
                                            fontWeight = if (today || selected) FontWeight.Bold else FontWeight.Normal, color = textColor)
                                        FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally),
                                            verticalArrangement = Arrangement.spacedBy(1.dp)) {
                                            if ((dayCounts?.unfinished ?: 0) > 0) Text(dayCounts!!.unfinished.toString(), style = MaterialTheme.typography.labelSmall,
                                                color = if (selected) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.tertiary,
                                                fontWeight = FontWeight.Medium)
                                            if ((dayCounts?.completed ?: 0) > 0) Row(verticalAlignment = Alignment.CenterVertically,
                                                horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                                                val completedColor = if (selected) MaterialTheme.colorScheme.onPrimary.copy(alpha = .85f) else MaterialTheme.colorScheme.primary
                                                Box(Modifier.size(3.dp).background(completedColor, CircleShape))
                                                Text(dayCounts!!.completed.toString(), style = MaterialTheme.typography.labelSmall,
                                                    color = completedColor, fontWeight = FontWeight.Medium)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Row(Modifier.fillMaxWidth().padding(top = 6.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(5.dp).background(MaterialTheme.colorScheme.tertiary, CircleShape)); Spacer(Modifier.width(5.dp))
                        Text("未完成数量", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Spacer(Modifier.width(14.dp)); Box(Modifier.size(5.dp).background(MaterialTheme.colorScheme.primary, CircleShape)); Spacer(Modifier.width(5.dp))
                        Text("已完成数量", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
        item { PindoGroupChips(state.groups, groupID) { groupID = it } }
        item {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(selectedDay.format(DateTimeFormatter.ofPattern("M月d日 EEEE", Locale.SIMPLIFIED_CHINESE)), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(matching.size.toString() + " 项事项", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                PindoPhasePicker(PhaseFilter.valueOf(phaseName), { phaseName = it.name }, compact = true)
            }
        }
        if (rows.isEmpty()) item { PindoEmptyState("这一天还没有安排", "选择日期，提前为下一步留出时间。", Icons.Outlined.EventAvailable,
            actionLabel = if (!state.readOnly) "添加这一天的事项" else null, onAction = onAdd) }
        pindoTaskItems(rows = rows, state = state, collapsed = collapsed.toSet(),
            onDisclosure = { id -> collapsed = if (id in collapsed) collapsed - id else collapsed + id },
            onEdit = onEdit, onAddChild = onAddChild, onDelete = onDelete, store = store)
    }
}
