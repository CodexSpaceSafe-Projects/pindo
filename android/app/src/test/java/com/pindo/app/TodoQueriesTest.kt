package com.pindo.app

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.time.YearMonth

class TodoQueriesTest {
    private val today = LocalDate.of(2026, 11, 12)
    private val work = "00000000-0000-0000-0000-000000000010"

    private fun task(title: String, day: LocalDate = today, phase: String = "pending", parent: String? = null,
                     group: String? = null, note: String = "", order: Int = 0, updated: Double = 1.0): Todo {
        val value = TodoRules.newTask(title, note, day, group, parent, order)
            .put("phase", phase).put("updatedAt", updated)
        if (phase == "completed") value.put("completedAt", updated)
        return Todo.from(value)
    }

    @Test fun todayIncludesOverdueAndOngoingButNotUnstartedFutureTasks() {
        val due = task("今天")
        val late = task("昨天", today.minusDays(1))
        val ongoing = task("持续进行", today.plusDays(10), "inProgress")
        val future = task("明天", today.plusDays(1))
        val done = task("已完成", today, "completed")
        val result = TodoQueries.matching(listOf(due, late, ongoing, future, done), TaskQuery(day = today))
        assertEquals(setOf(due.id, late.id, ongoing.id), result.map { it.id }.toSet())
    }

    @Test fun upcomingUsesSevenDayWindowAndOverdueNeverIncludesCompletedTasks() {
        val yesterday = task("逾期", today.minusDays(1))
        val doneYesterday = task("过去完成", today.minusDays(1), "completed")
        val now = task("今天", today)
        val first = task("第一天", today.plusDays(1))
        val seventh = task("第七天", today.plusDays(7))
        val eighth = task("第八天", today.plusDays(8))
        val tasks = listOf(yesterday, doneYesterday, now, first, seventh, eighth)
        val upcoming = TodoQueries.matching(tasks, TaskQuery(scope = TaskScope.UPCOMING, day = today, phase = PhaseFilter.ALL))
        assertEquals(setOf(first.id, seventh.id), upcoming.map { it.id }.toSet())
        val overdue = TodoQueries.matching(tasks, TaskQuery(scope = TaskScope.OVERDUE, day = today, phase = PhaseFilter.ALL))
        assertEquals(listOf(yesterday.id), overdue.map { it.id })
        assertEquals(listOf(now.id), TodoQueries.matching(tasks,
            TaskQuery(scope = TaskScope.DAY, day = today, phase = PhaseFilter.ALL)).map { it.id })
    }

    @Test fun searchIncludesAncestorsAsContextWithoutSelectingOrShowingUnrelatedChildren() {
        val root = task("项目")
        val child = task("目标任务", parent = root.id, note = "find-me")
        val sibling = task("无关子项", parent = root.id)
        val tasks = listOf(root, child, sibling)
        val query = TaskQuery(scope = TaskScope.ALL, day = today, search = "FIND-ME")
        assertEquals(listOf(child.id), TodoQueries.matching(tasks, query).map { it.id })
        val rows = TodoQueries.outline(tasks, query, emptySet())
        assertEquals(listOf(root.id, child.id), rows.map { it.task.id })
        assertEquals(listOf(0, 1), rows.map { it.depth })
        assertEquals(listOf(false, true), rows.map { it.matchesQuery })
        assertEquals(listOf(root.id), TodoQueries.outline(tasks, query, setOf(root.id)).map { it.task.id })
        assertFalse(rows.any { it.task.id == sibling.id })
    }

    @Test fun groupAndPhaseFiltersCombineAndDateOrUpdatedSortingIsStable() {
        val late = task("稍晚", today.plusDays(2), group = work, updated = 3.0)
        val early = task("较早", today, group = work, updated = 1.0)
        val active = task("进行中", today, "inProgress", group = work, updated = 2.0)
        val ungrouped = task("未分组", today)
        val tasks = listOf(late, early, active, ungrouped)
        val query = TaskQuery(scope = TaskScope.ALL, day = today, groupID = work, sort = TaskSort.DATE)
        assertEquals(late.id, TodoQueries.matching(tasks, query).last().id)
        assertEquals(listOf(late.id, active.id, early.id),
            TodoQueries.matching(tasks, query.copy(sort = TaskSort.UPDATED)).map { it.id })
        assertEquals(listOf(active.id), TodoQueries.matching(tasks, query.copy(phase = PhaseFilter.IN_PROGRESS)).map { it.id })
        assertEquals(listOf(ungrouped.id), TodoQueries.matching(tasks, query.copy(groupID = "ungrouped")).map { it.id })
    }

    @Test fun calendarCountsLeapDayAndCountsOnlyRequestedGroupAndMonth() {
        val leap = LocalDate.of(2028, 2, 29)
        val tasks = listOf(task("待办", leap, group = work), task("完成", leap, "completed", group = work),
            task("其他分组", leap), task("下个月", leap.plusDays(1), group = work))
        val counts = TodoQueries.calendarCounts(tasks, YearMonth.of(2028, 2), work)
        assertEquals(1, counts.getValue(leap).unfinished)
        assertEquals(1, counts.getValue(leap).completed)
        assertFalse(counts.containsKey(leap.plusDays(1)))
    }

    @Test fun statisticsReflectTaskStatesAndPlannedDates() {
        val tasks = listOf(task("今日待办"), task("进行中", phase = "inProgress"),
            task("逾期", today.minusDays(1)), task("今日完成", phase = "completed"),
            task("昨日完成", today.minusDays(1), "completed"))
        val stats = TodoQueries.stats(tasks, today)
        assertEquals(3, stats.unfinished)
        assertEquals(1, stats.overdue)
        assertEquals(1, stats.completedToday)
        assertEquals(3, stats.todayTotal)
        assertEquals(1, stats.todayCompleted)
    }
}
