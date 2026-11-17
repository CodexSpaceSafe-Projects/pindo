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
        val completedSibling = task("已完成兄弟", phase = "completed", parent = root.id)
        val tasks = listOf(root, child, sibling, completedSibling)
        val query = TaskQuery(scope = TaskScope.ALL, day = today, search = "FIND-ME")
        assertEquals(listOf(child.id), TodoQueries.matching(tasks, query).map { it.id })
        val rows = TodoQueries.outline(tasks, query, emptySet())
        assertEquals(listOf(root.id, child.id), rows.map { it.task.id })
        assertEquals(listOf(0, 1), rows.map { it.depth })
        assertEquals(listOf(false, true), rows.map { it.matchesQuery })
        assertEquals(listOf(root.id), TodoQueries.outline(tasks, query, setOf(root.id)).map { it.task.id })
        assertFalse(rows.any { it.task.id == sibling.id })
        assertFalse(rows.any { it.task.id == completedSibling.id })
        assertTrue(rows.none { it.isCompletionContext })
    }

    @Test fun unfinishedOutlineKeepsCompletedChildrenVisibleWithoutMakingThemMatchingResults() {
        val root = task("未完成项目", phase = "inProgress", order = 0)
        val completed = task("已做完的一步", phase = "completed", parent = root.id, order = 1)
        val pending = task("下一步", parent = root.id, order = 2)
        val tasks = listOf(root, completed, pending)
        val query = TaskQuery(scope = TaskScope.ALL, day = today)
        val rows = TodoQueries.outline(tasks, query)
        assertEquals(listOf(root.id, completed.id, pending.id), rows.map { it.task.id })
        assertEquals(listOf(true, false, true), rows.map { it.matchesQuery })
        assertEquals(listOf(false, true, false), rows.map { it.isCompletionContext })
        assertEquals(setOf(root.id, pending.id), TodoQueries.matching(tasks, query).map { it.id }.toSet())
        assertEquals("completed", rows.single { it.isCompletionContext }.task.phase)
    }

    @Test fun completionContextIncludesMultipleLevelsAndRespectsEveryCollapsedParent() {
        val root = task("项目", phase = "inProgress", order = 0)
        val completed = task("已完成阶段", phase = "completed", parent = root.id, order = 1)
        val completedGrandchild = task("已完成步骤", phase = "completed", parent = completed.id, order = 2)
        val pending = task("后续阶段", parent = root.id, order = 3)
        val tasks = listOf(completedGrandchild, pending, completed, root)
        val query = TaskQuery(scope = TaskScope.ALL, day = today)
        val rows = TodoQueries.outline(tasks, query)
        assertEquals(listOf(root.id, completed.id, completedGrandchild.id, pending.id), rows.map { it.task.id })
        assertEquals(listOf(0, 1, 2, 1), rows.map { it.depth })
        assertEquals(setOf(completed.id, completedGrandchild.id), rows.filter { it.isCompletionContext }.map { it.task.id }.toSet())
        assertEquals(listOf(root.id, completed.id, pending.id),
            TodoQueries.outline(tasks, query, setOf(completed.id)).map { it.task.id })
        assertEquals(listOf(root.id), TodoQueries.outline(tasks, query, setOf(root.id)).map { it.task.id })
    }

    @Test fun ancestorContextAndCompletedContextRemainDistinctUnderAGroupFilter() {
        val root = task("跨分组项目", phase = "inProgress", order = 0)
        val completed = task("已完成工作步骤", phase = "completed", parent = root.id, group = work, order = 1)
        val pending = task("未完成工作步骤", parent = root.id, group = work, order = 2)
        val rows = TodoQueries.outline(listOf(root, completed, pending), TaskQuery(scope = TaskScope.ALL, day = today, groupID = work))
        assertEquals(listOf(root.id, completed.id, pending.id), rows.map { it.task.id })
        assertEquals(listOf(false, false, true), rows.map { it.matchesQuery })
        assertEquals(listOf(false, true, false), rows.map { it.isCompletionContext })
    }

    @Test fun fullyCompletedRootTreesRemainHiddenInTheUnfinishedView() {
        val doneRoot = task("已完成项目", phase = "completed")
        val doneChild = task("已完成子项", phase = "completed", parent = doneRoot.id)
        val query = TaskQuery(scope = TaskScope.ALL, day = today)
        assertTrue(TodoQueries.outline(listOf(doneRoot, doneChild), query).isEmpty())
        val activeRoot = task("另一个未完成项目")
        assertEquals(listOf(activeRoot.id), TodoQueries.outline(listOf(doneRoot, doneChild, activeRoot), query).map { it.task.id })
    }

    @Test fun explicitPhaseFiltersNeverAddCompletedDescendantsAsUnfinishedContext() {
        val pendingRoot = task("待办项目", order = 0)
        val pendingDone = task("待办项目已完成一步", phase = "completed", parent = pendingRoot.id, order = 1)
        val activeRoot = task("进行中项目", phase = "inProgress", order = 2)
        val activeDone = task("进行中项目已完成一步", phase = "completed", parent = activeRoot.id, order = 3)
        val tasks = listOf(pendingRoot, pendingDone, activeRoot, activeDone)
        val query = TaskQuery(scope = TaskScope.ALL, day = today)
        assertEquals(listOf(pendingRoot.id), TodoQueries.outline(tasks, query.copy(phase = PhaseFilter.PENDING)).map { it.task.id })
        assertEquals(listOf(activeRoot.id), TodoQueries.outline(tasks, query.copy(phase = PhaseFilter.IN_PROGRESS)).map { it.task.id })
        val completed = TodoQueries.outline(tasks, query.copy(phase = PhaseFilter.COMPLETED))
        assertEquals(setOf(pendingDone.id, activeDone.id), completed.filter { it.matchesQuery }.map { it.task.id }.toSet())
        assertTrue(completed.none { it.isCompletionContext })
        val all = TodoQueries.outline(tasks, query.copy(phase = PhaseFilter.ALL))
        assertEquals(4, all.size)
        assertTrue(all.all { it.matchesQuery && !it.isCompletionContext })
    }

    @Test fun completedContextRespectsSelectedGroupDayAndExcludedBranches() {
        val root = task("项目", phase = "inProgress", group = work, order = 0)
        val included = task("当天完成", phase = "completed", parent = root.id, group = work, order = 1)
        val otherDay = task("昨天完成", today.minusDays(1), "completed", parent = root.id, group = work, order = 2)
        val otherGroup = task("其他分组完成", phase = "completed", parent = root.id, order = 3)
        val excludedBranch = task("不越过分组筛选", phase = "completed", parent = otherGroup.id, group = work, order = 4)
        val tasks = listOf(root, included, otherDay, otherGroup, excludedBranch)
        val rows = TodoQueries.outline(tasks, TaskQuery(scope = TaskScope.DAY, day = today, groupID = work))
        assertEquals(listOf(root.id, included.id), rows.map { it.task.id })
        assertTrue(rows.last().isCompletionContext)
        val ungrouped = TodoQueries.outline(tasks, TaskQuery(scope = TaskScope.DAY, day = today, groupID = "ungrouped"))
        assertTrue(ungrouped.isEmpty())
    }

    @Test fun todayAndOverdueKeepDueCompletedChildrenOnlyUnderVisibleActiveParents() {
        val root = task("逾期项目", today.minusDays(2), "inProgress", order = 0)
        val past = task("过去完成", today.minusDays(1), "completed", parent = root.id, order = 1)
        val sameDay = task("当天完成", today, "completed", parent = root.id, order = 2)
        val future = task("未来完成", today.plusDays(1), "completed", parent = root.id, order = 3)
        val doneRoot = task("已完成逾期根项", today.minusDays(2), "completed", order = 4)
        val tasks = listOf(root, past, sameDay, future, doneRoot)
        val todayQuery = TaskQuery(day = today)
        assertEquals(listOf(root.id), TodoQueries.matching(tasks, todayQuery).map { it.id })
        assertEquals(listOf(root.id, past.id, sameDay.id), TodoQueries.outline(tasks, todayQuery).map { it.task.id })
        assertEquals(listOf(root.id, past.id),
            TodoQueries.outline(tasks, todayQuery.copy(scope = TaskScope.OVERDUE)).map { it.task.id })
    }

    @Test fun upcomingCompletionContextStillUsesTheSevenDayWindow() {
        val root = task("近期项目", today.plusDays(1), order = 0)
        val included = task("近期已完成子项", today.plusDays(7), "completed", parent = root.id, order = 1)
        val past = task("过去已完成子项", today.minusDays(1), "completed", parent = root.id, order = 2)
        val later = task("窗口外已完成子项", today.plusDays(8), "completed", parent = root.id, order = 3)
        val rows = TodoQueries.outline(listOf(root, included, past, later), TaskQuery(scope = TaskScope.UPCOMING, day = today))
        assertEquals(listOf(root.id, included.id), rows.map { it.task.id })
        assertFalse(rows.last().matchesQuery)
        assertTrue(rows.last().isCompletionContext)
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
