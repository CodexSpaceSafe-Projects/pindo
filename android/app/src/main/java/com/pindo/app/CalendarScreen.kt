package com.pindo.app

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable internal fun CalendarScreen(store: AppStore, state: AppState, selectedDay: LocalDate,
    onDaySelected: (LocalDate) -> Unit, onEdit: (String, Boolean) -> Unit, onAddChild: (String) -> Unit,
    onDelete: (Set<String>) -> Unit, onAdd: () -> Unit, onSettings: () -> Unit = {},
    onCaptureContextChange: (LocalDate, String?) -> Unit = { _, _ -> }) {
    val today = LocalDate.now()
    var monthText by rememberSaveable { mutableStateOf(selectedDay.withDayOfMonth(1).toString()) }
    var groupID by rememberSaveable { mutableStateOf<String?>(null) }
    var phaseName by rememberSaveable { mutableStateOf(PhaseFilter.ALL.name) }
    var collapsed by rememberSaveable(selectedDay.toString()) { mutableStateOf(emptyList<String>()) }
    var monthExpanded by rememberSaveable { mutableStateOf(false) }
    var filtersOpen by rememberSaveable { mutableStateOf(false) }
    SideEffect { onCaptureContextChange(selectedDay, if (groupID == "ungrouped") null else groupID ?: state.preferences.defaultGroupID) }
    val month = YearMonth.from(LocalDate.parse(monthText))
    val weekStart = selectedDay.minusDays(selectedDay.dayOfWeek.value.toLong() - 1)
    val countMonths = if (monthExpanded) listOf(month.minusMonths(1), month, month.plusMonths(1)) else listOf(YearMonth.from(weekStart), YearMonth.from(weekStart.plusDays(6))).distinct()
    val counts = countMonths.flatMap { TodoQueries.calendarCounts(state.tasks, it, groupID).entries }.associate { it.key to it.value }
    val query = TaskQuery(TaskScope.DAY, selectedDay, PhaseFilter.valueOf(phaseName), groupID, "", TaskSort.MANUAL)
    val rows = TodoQueries.outline(state.tasks, query, collapsed.toSet())
    val matching = TodoQueries.matching(state.tasks, query)
    val filtered = groupID != null || phaseName != PhaseFilter.ALL.name
    LaunchedEffect(selectedDay) { monthText = selectedDay.withDayOfMonth(1).toString() }

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val calendarInset = if (maxWidth < 360.dp) 0.dp else 16.dp
        LazyColumn(modifier = Modifier.fillMaxSize().testTag("calendar"),
            contentPadding = PaddingValues(bottom = 104.dp)) {
            item(key = "calendar-header") {
                Row(Modifier.fillMaxWidth().padding(start = 24.dp, end = 12.dp, top = 20.dp, bottom = 16.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("日历", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.SemiBold)
                        Text(today.format(DateTimeFormatter.ofPattern("yyyy年M月d日 EEEE", Locale.SIMPLIFIED_CHINESE)), Modifier.padding(top = 4.dp), style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    TextButton(onClick = { monthText = today.withDayOfMonth(1).toString(); onDaySelected(today) },
                        modifier = Modifier.heightIn(min = 48.dp)) { Text("今天") }
                    IconButton(onClick = onSettings, modifier = Modifier.testTag("open-settings")) { Icon(Icons.Outlined.Settings, "设置") }
                }
            }
            if (state.error != null) item(key = "calendar-error") {
                Box(Modifier.padding(horizontal = 20.dp)) { PindoErrorMessage(state.error, store::dismissError) }
            }
            item(key = "calendar-date-picker") {
                Column(Modifier.fillMaxWidth().padding(horizontal = calendarInset)
                    .background(MaterialTheme.colorScheme.surfaceContainerLow, RoundedCornerShape(20.dp))
                    .padding(horizontal = 8.dp, vertical = 8.dp)) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        TextButton(onClick = { monthText = selectedDay.withDayOfMonth(1).toString(); monthExpanded = !monthExpanded },
                            modifier = Modifier.weight(1f).heightIn(min = 48.dp)
                                .semantics { contentDescription = if (monthExpanded) "收起月历" else "展开月历" },
                            contentPadding = PaddingValues(horizontal = 12.dp)) {
                            Text(month.format(DateTimeFormatter.ofPattern("yyyy 年 M 月", Locale.SIMPLIFIED_CHINESE)),
                                Modifier.weight(1f), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold,
                                color = MaterialTheme.colorScheme.onSurface, textAlign = TextAlign.Start)
                            Icon(if (monthExpanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,
                                null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        IconButton(onClick = {
                            if (monthExpanded) monthText = month.minusMonths(1).atDay(1).toString()
                            else onDaySelected(selectedDay.minusWeeks(1))
                        }, enabled = if (monthExpanded) month > YearMonth.of(1, 1) else selectedDay.minusWeeks(1).year >= 1) {
                            Icon(Icons.Outlined.ChevronLeft, if (monthExpanded) "上个月" else "上一周")
                        }
                        IconButton(onClick = {
                            if (monthExpanded) monthText = month.plusMonths(1).atDay(1).toString()
                            else onDaySelected(selectedDay.plusWeeks(1))
                        }, enabled = if (monthExpanded) month < YearMonth.of(9999, 12) else selectedDay.plusWeeks(1).year <= 9999) {
                            Icon(Icons.Outlined.ChevronRight, if (monthExpanded) "下个月" else "下一周")
                        }
                    }
                    CalendarMonthGrid(month, selectedDay, today, counts, onDaySelected, if (monthExpanded) null else weekStart)
                }
            }
            item(key = "calendar-results-heading") {
                Row(Modifier.fillMaxWidth().padding(start = 24.dp, end = 12.dp, top = 20.dp, bottom = 8.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(selectedDay.format(DateTimeFormatter.ofPattern("M月d日 EEEE", Locale.SIMPLIFIED_CHINESE)),
                            modifier = Modifier.semantics { heading() }, style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold)
                        Text(if (matching.isEmpty()) "暂时没有安排" else matching.count { it.phase != "completed" }.toString() +
                            " 条待办 · " + matching.count { it.phase == "completed" } + " 条已完成",
                            Modifier.padding(top = 4.dp), style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    IconButton(onClick = { filtersOpen = true }, modifier = Modifier.testTag("calendar-filters")) {
                        Icon(if (filtered) Icons.Outlined.FilterAlt else Icons.Outlined.Tune, "筛选日历事项",
                            tint = if (filtered) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            if (filtered) item(key = "calendar-active-filters") {
                Row(Modifier.fillMaxWidth().padding(horizontal = 24.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(listOfNotNull(groupID?.let { id -> state.groups.find { it.id == id }?.name ?: "未分组" },
                        if (phaseName != PhaseFilter.ALL.name) when (PhaseFilter.valueOf(phaseName)) {
                            PhaseFilter.UNFINISHED -> "未完成"; PhaseFilter.PENDING -> "待开始"
                            PhaseFilter.IN_PROGRESS -> "进行中"; PhaseFilter.COMPLETED -> "已完成"; else -> null
                        } else null).joinToString(" · "), Modifier.weight(1f),
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
                    TextButton(onClick = { groupID = null; phaseName = PhaseFilter.ALL.name }) { Text("清除") }
                }
            }
            if (rows.isEmpty()) item(key = "calendar-empty") {
                Box(Modifier.padding(horizontal = 20.dp)) {
                    PindoEmptyState(if (filtered) "没有符合筛选的事项" else "这一天还没有安排",
                        if (filtered) "调整筛选条件，再看看。" else "添加事项，为这一天留出时间。", Icons.Outlined.EventAvailable,
                        actionLabel = if (!state.readOnly && !filtered) "添加这一天的事项" else null, onAction = onAdd)
                }
            }
            pindoTaskItems(rows, state, collapsed.toSet(),
                onDisclosure = { id -> collapsed = if (id in collapsed) collapsed - id else collapsed + id },
                onEdit = onEdit, onAddChild = onAddChild, onDelete = onDelete, store = store, horizontalPadding = 16.dp)
        }
    }
    if (filtersOpen) ModalBottomSheet(onDismissRequest = { filtersOpen = false }) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("筛选日历事项", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            PindoGroupPicker(state.groups, groupID, "全部分组", includeUngrouped = true) { groupID = it }
            PindoPhasePicker(PhaseFilter.valueOf(phaseName), { phaseName = it.name })
            Button(onClick = { filtersOpen = false }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text("显示结果") }
        }
    }
}

@Composable private fun CalendarMonthGrid(month: YearMonth, selectedDay: LocalDate, today: LocalDate,
    counts: Map<LocalDate, DayTaskCounts>, onDaySelected: (LocalDate) -> Unit, weekStart: LocalDate?) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        // Seven real 48 dp targets cannot fit in a narrow 320 dp window. Keep
        // their size and scroll the aligned grid instead of overlapping them.
        val viewportWidth = maxWidth
        val calendarWidth = maxOf(viewportWidth, 336.dp)
        val scroll = rememberScrollState()
        val density = androidx.compose.ui.platform.LocalDensity.current
        LaunchedEffect(selectedDay, viewportWidth) {
            if (viewportWidth < calendarWidth) {
                val index = selectedDay.dayOfWeek.value - 1
                val target = with(density) { ((calendarWidth / 7) * index - viewportWidth / 2 + calendarWidth / 14).toPx().toInt() }
                scroll.scrollTo(target.coerceAtLeast(0))
            }
        }
        Column {
            Column(Modifier.horizontalScroll(scroll).width(calendarWidth)) {
                Row(Modifier.fillMaxWidth().padding(top = 2.dp, bottom = 6.dp)) {
                    listOf("一", "二", "三", "四", "五", "六", "日").forEach { label ->
                        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.labelSmall,
                            textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                val first = weekStart ?: month.atDay(1)
                val offset = if (weekStart == null) first.dayOfWeek.value - 1 else 0
                val weeks = if (weekStart == null) (offset + month.lengthOfMonth() + 6) / 7 else 1
                val start = first.minusDays(offset.toLong())
                repeat(weeks) { week ->
                    Row(Modifier.fillMaxWidth().padding(bottom = 3.dp)) {
                        repeat(7) { weekday ->
                            val date = start.plusDays((week * 7 + weekday).toLong())
                            val dayCounts = counts[date]
                            CalendarDay(date, if (weekStart == null) month else YearMonth.from(date), today, date == selectedDay,
                                dayCounts?.unfinished ?: 0, dayCounts?.completed ?: 0, Modifier.weight(1f)) { onDaySelected(date) }
                        }
                    }
                }
            }
            if (viewportWidth < calendarWidth) Text("左右滑动查看整周", Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable private fun CalendarDay(date: LocalDate, month: YearMonth, today: LocalDate, selected: Boolean,
    unfinished: Int, completed: Int, modifier: Modifier, onSelect: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    val textColor = when {
        selected -> colors.onPrimary
        YearMonth.from(date) != month -> colors.onSurfaceVariant.copy(alpha = .55f)
        date == today -> colors.primary
        else -> colors.onSurface
    }
    Surface(onClick = onSelect, enabled = date.year in 1..9999,
        modifier = modifier.heightIn(min = 56.dp).testTag("calendar-day-" + date).semantics {
            this.selected = selected
            contentDescription = date.format(DateTimeFormatter.ofPattern("yyyy年M月d日", Locale.SIMPLIFIED_CHINESE)) +
                "，未完成 " + unfinished + " 项，已完成 " + completed + " 项"
        }, shape = RoundedCornerShape(14.dp), color = if (selected) colors.primary else Color.Transparent,
        border = if (date == today && !selected) BorderStroke(1.dp, colors.primary.copy(alpha = .5f)) else null) {
        Column(Modifier.fillMaxWidth().padding(vertical = 7.dp), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(date.dayOfMonth.toString(), style = MaterialTheme.typography.bodyLarge,
                fontWeight = if (date == today || selected) FontWeight.SemiBold else FontWeight.Normal, color = textColor)
            Box(Modifier.size(4.dp).background(
                if (unfinished + completed == 0) Color.Transparent else if (selected) colors.onPrimary
                else if (unfinished > 0) colors.primary else colors.onSurfaceVariant, CircleShape))
        }
    }
}
