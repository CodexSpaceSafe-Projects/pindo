package com.pindo.app

import java.time.LocalDate
import java.time.YearMonth

enum class TaskScope { TODAY, UPCOMING, ALL, OVERDUE, DAY }
enum class PhaseFilter { UNFINISHED, ALL, PENDING, IN_PROGRESS, COMPLETED }
enum class TaskSort { MANUAL, DATE, UPDATED }

data class TaskQuery(
    val scope: TaskScope = TaskScope.TODAY,
    val day: LocalDate = LocalDate.now(),
    val phase: PhaseFilter = PhaseFilter.UNFINISHED,
    val groupID: String? = null,
    val search: String = "",
    val sort: TaskSort = TaskSort.MANUAL
)

data class TaskOutlineEntry(val task: Todo, val depth: Int, val matchesQuery: Boolean, val isCompletionContext: Boolean = false)
data class DayTaskCounts(val unfinished: Int, val completed: Int)
data class TaskStats(val unfinished: Int, val overdue: Int, val completedToday: Int, val todayTotal: Int, val todayCompleted: Int)

object TodoQueries {
    fun matching(tasks: List<Todo>, query: TaskQuery): List<Todo> = tasks.filter { task ->
        val phaseMatches = when (query.phase) {
            PhaseFilter.ALL -> true
            PhaseFilter.UNFINISHED -> task.phase != "completed"
            PhaseFilter.PENDING -> task.phase == "pending"
            PhaseFilter.IN_PROGRESS -> task.phase == "inProgress"
            PhaseFilter.COMPLETED -> task.phase == "completed"
        }
        matchesScope(task, query) && phaseMatches && matchesGroup(task, query.groupID) &&
            (query.search.isBlank() || task.title.contains(query.search.trim(), true) || task.note.contains(query.search.trim(), true))
    }.sortedWith(comparator(query.sort))

    /** Ancestors and completed descendants provide context, never implicit bulk selection. */
    fun outline(tasks: List<Todo>, query: TaskQuery, collapsed: Set<String> = emptySet()): List<TaskOutlineEntry> {
        val matching = matching(tasks, query).map { it.id }.toSet()
        val visible = matching.toMutableSet()
        val byID = tasks.associateBy { it.id }
        for (id in matching) {
            var parent = byID[id]?.parentID
            val visited = mutableSetOf(id)
            while (parent != null && visited.add(parent)) {
                val item = byID[parent] ?: break
                visible.add(item.id)
                parent = item.parentID
            }
        }
        val completionContext = mutableSetOf<String>()
        if (query.phase == PhaseFilter.UNFINISHED && query.search.isBlank()) {
            val byParent = tasks.groupBy { it.parentID }
            val parents = ArrayDeque(visible.filter { byID[it]?.phase != "completed" })
            val visited = mutableSetOf<String>()
            while (parents.isNotEmpty()) {
                val parent = parents.removeFirst()
                if (!visited.add(parent)) continue
                for (child in byParent[parent].orEmpty()) {
                    // Due completed children can remain below active work even
                    // though TODAY/OVERDUE never match completed past roots.
                    val inScope = when (query.scope) {
                        TaskScope.TODAY -> child.day <= query.day
                        TaskScope.OVERDUE -> child.day < query.day
                        else -> matchesScope(child, query)
                    }
                    if (child.phase != "completed" || !inScope || !matchesGroup(child, query.groupID)) continue
                    visible.add(child.id)
                    completionContext.add(child.id)
                    parents.addLast(child.id)
                }
            }
        }
        val children = tasks.filter { it.id in visible }.groupBy { it.parentID?.takeIf(visible::contains) }
        val rows = mutableListOf<TaskOutlineEntry>()
        fun append(parent: String?, depth: Int, ancestors: Set<String>) {
            if (depth >= 3) return
            for (task in children[parent].orEmpty().sortedWith(comparator(query.sort))) {
                if (task.id in ancestors) continue
                rows.add(TaskOutlineEntry(task, depth, task.id in matching, task.id in completionContext))
                if (task.id !in collapsed) append(task.id, depth + 1, ancestors + task.id)
            }
        }
        append(null, 0, emptySet())
        return rows
    }

    fun calendarCounts(tasks: List<Todo>, month: YearMonth, groupID: String? = null): Map<LocalDate, DayTaskCounts> =
        tasks.filter { YearMonth.from(it.day) == month && matchesGroup(it, groupID) }.groupBy { it.day }
            .mapValues { (_, entries) -> DayTaskCounts(entries.count { it.phase != "completed" }, entries.count { it.phase == "completed" }) }

    fun stats(tasks: List<Todo>, today: LocalDate = LocalDate.now()): TaskStats {
        val datedToday = tasks.filter { it.day == today }
        return TaskStats(tasks.count { it.phase != "completed" },
            tasks.count { it.phase != "completed" && it.day < today },
            datedToday.count { it.phase == "completed" }, datedToday.size, datedToday.count { it.phase == "completed" })
    }

    private fun matchesScope(task: Todo, query: TaskQuery): Boolean = when (query.scope) {
        TaskScope.ALL -> true
        TaskScope.DAY -> task.day == query.day
        TaskScope.TODAY -> task.day == query.day || task.phase != "completed" && (task.day < query.day || task.phase == "inProgress")
        TaskScope.UPCOMING -> task.day > query.day && task.day <= query.day.plusDays(7)
        TaskScope.OVERDUE -> task.phase != "completed" && task.day < query.day
    }

    private fun matchesGroup(task: Todo, groupID: String?): Boolean = when (groupID) {
        null -> true
        "ungrouped" -> task.groupID == null
        else -> task.groupID.equals(groupID, true)
    }

    internal fun comparator(sort: TaskSort): Comparator<Todo> = when (sort) {
        TaskSort.MANUAL -> compareBy<Todo> { it.order }.thenBy { it.json.optDouble("createdAt", 0.0) }.thenBy { it.id }
        TaskSort.DATE -> compareBy<Todo> { it.day }.thenBy { it.order }.thenBy { it.id }
        TaskSort.UPDATED -> compareByDescending<Todo> { it.json.optDouble("updatedAt", 0.0) }.thenBy { it.id }
    }
}
