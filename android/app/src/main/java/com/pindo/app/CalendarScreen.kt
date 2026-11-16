package com.pindo.app

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
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
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import java.time.LocalDate
import java.time.YearMonth
import java.time.format.DateTimeFormatter
import java.util.Locale

@OptIn(ExperimentalLayoutApi::class)
@Composable internal fun CalendarScreen(store: AppStore, state: AppState, selectedDay: LocalDate,
    onDaySelected: (LocalDate) -> Unit, onEdit: (String, Boolean) -> Unit, onAddChild: (String) -> Unit,
    onDelete: (Set<String>) -> Unit, onAdd: () -> Unit) {
    val today = LocalDate.now()
    var monthText by rememberSaveable { mutableStateOf(selectedDay.withDayOfMonth(1).toString()) }
    var groupID by rememberSaveable { mutableStateOf<String?>(null) }
    var phaseName by rememberSaveable { mutableStateOf(PhaseFilter.ALL.name) }
    var collapsed by rememberSaveable { mutableStateOf(emptyList<String>()) }
    var monthExpanded by rememberSaveable { mutableStateOf(false) }
    val month = YearMonth.from(LocalDate.parse(monthText))
    val weekStart = selectedDay.minusDays(selectedDay.dayOfWeek.value.toLong() - 1)
    val countMonths = if (monthExpanded) listOf(month) else listOf(YearMonth.from(weekStart), YearMonth.from(weekStart.plusDays(6))).distinct()
    val counts = countMonths.flatMap { TodoQueries.calendarCounts(state.tasks, it, groupID).entries }.associate { it.key to it.value }
    val query = TaskQuery(TaskScope.DAY, selectedDay, PhaseFilter.valueOf(phaseName), groupID, "", TaskSort.MANUAL)
    val rows = TodoQueries.outline(state.tasks, query, collapsed.toSet())
    val matching = TodoQueries.matching(state.tasks, query)
    LaunchedEffect(selectedDay) { monthText = selectedDay.withDayOfMonth(1).toString() }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val compact = maxWidth < 400.dp
        val calendarInset = if (compact) 4.dp else 20.dp
        val calendarInnerInset = if (compact) 4.dp else 10.dp
        LazyColumn(
            modifier = Modifier.fillMaxSize().testTag("calendar"),
            contentPadding = PaddingValues(top = 4.dp, bottom = 104.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            item {
                Box(Modifier.padding(horizontal = 20.dp)) {
                    PindoPageHeader("日历", "今天 · " + today.format(DateTimeFormatter.ofPattern("M月d日 EEEE", Locale.SIMPLIFIED_CHINESE))) {
                        TextButton(
                            onClick = { monthText = today.withDayOfMonth(1).toString(); onDaySelected(today) },
                            modifier = Modifier.heightIn(min = 48.dp)
                        ) { Text("今天") }
                    }
                }
            }
            if (state.error != null) item {
                Box(Modifier.padding(horizontal = 20.dp)) { PindoErrorMessage(state.error, store::dismissError) }
            }
            item {
                Surface(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = calendarInset),
                    shape = RoundedCornerShape(20.dp),
                    color = MaterialTheme.colorScheme.surface,
                    border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant)
                ) {
                    Column(Modifier.fillMaxWidth().padding(horizontal = calendarInnerInset, vertical = 8.dp)) {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            IconButton(
                                onClick = { if (monthExpanded) monthText = month.minusMonths(1).atDay(1).toString() else onDaySelected(selectedDay.minusWeeks(1)) },
                                enabled = if (monthExpanded) month > YearMonth.of(1, 1) else selectedDay.minusWeeks(1).year >= 1, modifier = Modifier.size(48.dp)
                            ) { Icon(Icons.Outlined.ChevronLeft, if (monthExpanded) "上个月" else "上一周") }
                            TextButton(onClick = { monthText = selectedDay.withDayOfMonth(1).toString(); monthExpanded = !monthExpanded },
                                modifier = Modifier.weight(1f).semantics { contentDescription = if (monthExpanded) "收起月历" else "展开月历" }) {
                                Text(month.format(DateTimeFormatter.ofPattern("yyyy年M月", Locale.SIMPLIFIED_CHINESE)),
                                    style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                                Icon(if (monthExpanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null, Modifier.size(18.dp))
                            }
                            IconButton(
                                onClick = { if (monthExpanded) monthText = month.plusMonths(1).atDay(1).toString() else onDaySelected(selectedDay.plusWeeks(1)) },
                                enabled = if (monthExpanded) month < YearMonth.of(9999, 12) else selectedDay.plusWeeks(1).year <= 9999, modifier = Modifier.size(48.dp)
                            ) { Icon(Icons.Outlined.ChevronRight, if (monthExpanded) "下个月" else "下一周") }
                        }
                        CalendarMonthGrid(month, selectedDay, today, counts, onDaySelected, if (monthExpanded) null else weekStart)
                        FlowRow(
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 6.dp, vertical = 8.dp),
                            horizontalArrangement = Arrangement.spacedBy(16.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            CalendarLegend("未完成数量", MaterialTheme.colorScheme.tertiary, completed = false)
                            CalendarLegend("已完成数量", MaterialTheme.colorScheme.primary, completed = true)
                        }
                    }
                }
            }
            item {
                Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(top = 4.dp), verticalAlignment = Alignment.Top,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(
                            selectedDay.format(DateTimeFormatter.ofPattern("M月d日 EEEE", Locale.SIMPLIFIED_CHINESE)),
                            modifier = Modifier.semantics { heading() },
                            style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold
                        )
                        Text(matching.size.toString() + " 项事项", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    PindoPhasePicker(PhaseFilter.valueOf(phaseName), { phaseName = it.name }, compact = true)
                }
            }
            item { Box(Modifier.padding(horizontal = 20.dp)) { PindoGroupChips(state.groups, groupID) { groupID = it } } }
            if (rows.isEmpty()) item {
                Box(Modifier.padding(horizontal = 20.dp)) {
                    PindoEmptyState("这一天还没有安排", "选择日期，提前为下一步留出时间。", Icons.Outlined.EventAvailable,
                        actionLabel = if (!state.readOnly) "添加这一天的事项" else null, onAction = onAdd)
                }
            }
            pindoTaskItems(rows = rows, state = state, collapsed = collapsed.toSet(),
                onDisclosure = { id -> collapsed = if (id in collapsed) collapsed - id else collapsed + id },
                onEdit = onEdit, onAddChild = onAddChild, onDelete = onDelete, store = store, horizontalPadding = 20.dp)
        }
    }
}

@Composable private fun CalendarMonthGrid(month: YearMonth, selectedDay: LocalDate, today: LocalDate,
    counts: Map<LocalDate, DayTaskCounts>, onDaySelected: (LocalDate) -> Unit, weekStart: LocalDate? = null) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val overflows = maxWidth < 336.dp
        val calendarWidth = maxOf(maxWidth, 336.dp)
        val scroll = rememberScrollState()
        Column(Modifier.fillMaxWidth()) {
            Column(Modifier.horizontalScroll(scroll).width(calendarWidth)) {
                Row(Modifier.fillMaxWidth().padding(bottom = 4.dp)) {
                    listOf("一", "二", "三", "四", "五", "六", "日").forEach { label ->
                        Text(label, Modifier.weight(1f).padding(vertical = 6.dp),
                            style = MaterialTheme.typography.labelMedium, textAlign = TextAlign.Center,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                val first = weekStart ?: month.atDay(1)
                val offset = if (weekStart != null) 0 else first.dayOfWeek.value - 1
                val weeks = if (weekStart != null) 1 else (offset + month.lengthOfMonth() + 6) / 7
                val start = first.minusDays(offset.toLong())
                repeat(weeks) { week ->
                    Row(Modifier.fillMaxWidth().padding(bottom = 2.dp)) {
                        repeat(7) { weekday ->
                            val date = start.plusDays((week * 7 + weekday).toLong())
                            val dayCounts = counts[date]
                            CalendarDay(
                                date = date, month = if (weekStart != null) YearMonth.from(date) else month, today = today, selected = date == selectedDay,
                                unfinished = dayCounts?.unfinished ?: 0, completed = dayCounts?.completed ?: 0,
                                modifier = Modifier.weight(1f), onSelect = { onDaySelected(date) }
                            )
                        }
                    }
                }
            }
            if (overflows) Text("左右滑动查看整周", modifier = Modifier.padding(horizontal = 6.dp, vertical = 4.dp),
                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable private fun CalendarDay(date: LocalDate, month: YearMonth, today: LocalDate, selected: Boolean,
    unfinished: Int, completed: Int, modifier: Modifier, onSelect: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    val textColor = when {
        selected -> colors.onPrimary
        YearMonth.from(date) != month -> colors.onSurfaceVariant
        date == today -> colors.primary
        else -> colors.onSurface
    }
    Surface(
        onClick = onSelect, enabled = date.year in 1..9999,
        modifier = modifier.heightIn(min = 48.dp).testTag("calendar-day-" + date).semantics {
            this.selected = selected
            contentDescription = date.format(DateTimeFormatter.ofPattern("yyyy年M月d日", Locale.SIMPLIFIED_CHINESE)) +
                "，未完成 " + unfinished + " 项，已完成 " + completed + " 项"
        },
        shape = RoundedCornerShape(12.dp), color = if (selected) colors.primary else Color.Transparent,
        border = if (date == today && !selected) BorderStroke(1.dp, colors.primary) else null
    ) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 2.dp, vertical = 4.dp),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(date.dayOfMonth.toString(), style = MaterialTheme.typography.bodyMedium,
                fontWeight = if (date == today || selected) FontWeight.SemiBold else FontWeight.Normal, color = textColor)
            if (unfinished > 0 || completed > 0) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(5.dp, Alignment.CenterHorizontally),
                    verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    if (unfinished > 0) Text(unfinished.toString(), style = MaterialTheme.typography.labelSmall,
                        color = if (selected) colors.onPrimary else colors.tertiary)
                    if (completed > 0) Text("✓" + completed, style = MaterialTheme.typography.labelSmall,
                        color = if (selected) colors.onPrimary else colors.primary)
                }
            }
        }
    }
}

@Composable private fun CalendarLegend(label: String, color: Color, completed: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(if (completed) Icons.Outlined.Check else Icons.Outlined.RadioButtonUnchecked,
            contentDescription = null, tint = color, modifier = Modifier.size(14.dp))
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
