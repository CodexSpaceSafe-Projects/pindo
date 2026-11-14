package com.pindo.app

import com.pindo.app.sync.toMap

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.math.BigDecimal

class TodoRulesTest {
    private val day = LocalDate.of(2026, 11, 12)
    private fun task(title: String, parent: String? = null): JSONObject = TodoRules.newTask(title, "", day, null, parent, 0)

    @Test fun lastChildCompletesParentAndReopeningChildReopensParent() {
        val parent = task("parent")
        val child = task("child", parent.getString("id"))
        val all = JSONArray().put(parent).put(child)
        val complete = TodoRules.setPhase(all, child.getString("id"), "completed")
        assertTrue(complete.objects().all { it.getString("phase") == "completed" })
        val reopened = TodoRules.setPhase(complete, child.getString("id"), "pending")
        assertTrue(reopened.objects().all { it.getString("phase") == "pending" })
    }

    @Test fun completingParentCompletesItsEntireBranchLikeMacOS() {
        val parent = task("parent"); val child = task("child", parent.getString("id"))
        val grandchild = task("grandchild", child.getString("id"))
        val original = JSONArray().put(parent).put(child).put(grandchild)
        val complete = TodoRules.setPhase(original, parent.getString("id"), "completed")
        assertTrue(complete.objects().all { it.getString("phase") == "completed" && !it.isNull("completedAt") })
        assertTrue(original.objects().all { it.getString("phase") == "pending" && it.isNull("completedAt") })
        val reopened = TodoRules.setPhase(complete, parent.getString("id"), "pending")
        assertTrue(reopened.objects().all { it.getString("phase") == "pending" && it.isNull("startedAt") && it.isNull("completedAt") })
    }

    @Test fun explicitParentStartSurvivesChildStartAndReopen() {
        val parent = task("parent"); val child = task("child", parent.getString("id"))
        val initial = JSONArray().put(parent).put(child)
        val startedParent = TodoRules.setPhase(initial, parent.getString("id"), "inProgress")
        val parentStart = startedParent.getJSONObject(0).getDouble("startedAt")
        assertEquals(true, Todo.from(startedParent.getJSONObject(0)).isProgressExplicit)
        assertEquals("pending", startedParent.getJSONObject(1).getString("phase"))
        val startedChild = TodoRules.setPhase(startedParent, child.getString("id"), "inProgress")
        val reopened = TodoRules.setPhase(startedChild, child.getString("id"), "pending")
        assertEquals("inProgress", reopened.getJSONObject(0).getString("phase"))
        assertTrue(reopened.getJSONObject(0).getBoolean("isProgressExplicit"))
        assertEquals(parentStart, reopened.getJSONObject(0).getDouble("startedAt"), 0.0)
        assertEquals("pending", reopened.getJSONObject(1).getString("phase"))
    }

    @Test fun derivedParentStartIsRemovedWhenChildReopens() {
        val parent = task("parent"); val child = task("child", parent.getString("id"))
        val started = TodoRules.setPhase(JSONArray().put(parent).put(child), child.getString("id"), "inProgress")
        assertEquals("inProgress", started.getJSONObject(0).getString("phase"))
        assertFalse(started.getJSONObject(0).getBoolean("isProgressExplicit"))
        val reopened = TodoRules.setPhase(started, child.getString("id"), "pending")
        assertTrue(reopened.objects().all { it.getString("phase") == "pending" && it.isNull("startedAt") && it.isNull("completedAt") })
    }

    @Test fun legacyInProgressParentWithOnlyPendingChildrenKeepsItsOwnStart() {
        val parent = task("parent").put("phase", "inProgress").put("startedAt", 1.0)
        val child = task("child", parent.getString("id"))
        assertNull(Todo.from(parent).isProgressExplicit)
        val started = TodoRules.setPhase(JSONArray().put(parent).put(child), child.getString("id"), "inProgress")
        val reopened = TodoRules.setPhase(started, child.getString("id"), "pending")
        assertEquals("inProgress", reopened.getJSONObject(0).getString("phase"))
        assertTrue(reopened.getJSONObject(0).getBoolean("isProgressExplicit"))
        assertEquals(1.0, reopened.getJSONObject(0).getDouble("startedAt"), 0.0)
    }

    @Test fun directCompletionDoesNotReuseAnOldRoundStartTimestamp() {
        val pending = task("pending").put("startedAt", 1.0)
        val complete = TodoRules.setPhase(JSONArray().put(pending), pending.getString("id"), "completed").getJSONObject(0)
        assertTrue(complete.isNull("startedAt"))
        assertFalse(complete.isNull("completedAt"))
        assertTrue(complete.isNull("isProgressExplicit"))
    }

    @Test fun largeCrossPlatformOrderRemainsLongThroughModelAndStateChanges() {
        val value = TodoRules.newTask("large order", "", day, null, null, 4_294_967_296L)
        assertEquals(4_294_967_296L, Todo.from(value).order)
        val complete = TodoRules.setPhase(JSONArray().put(value), value.getString("id"), "completed").getJSONObject(0)
        assertEquals(4_294_967_296L, Todo.from(complete).order)
        assertEquals(MAX_TASK_ORDER, Todo.from(value.put("order", MAX_TASK_ORDER)).order)
        assertEquals(-MAX_TASK_ORDER, Todo.from(value.put("order", -MAX_TASK_ORDER)).order)
        val middle = Todo.from(task("middle"))
        val large = Todo.from(TodoRules.newTask("large", "", day, null, null, 4_294_967_296L))
        val small = Todo.from(TodoRules.newTask("small", "", day, null, null, -4_294_967_296L))
        assertEquals(listOf(small.id, middle.id, large.id), TodoQueries.matching(listOf(large, middle, small),
            TaskQuery(scope = TaskScope.ALL, phase = PhaseFilter.ALL)).map { it.id })
    }

    @Test fun nonIntegralAndOutOfRangeOrdersAreRejectedInsteadOfTruncated() {
        for (order in listOf<Any>("4294967296", 1.5, BigDecimal("1.0000000000000000001"),
                                 MAX_TASK_ORDER + 1, Long.MAX_VALUE, Long.MIN_VALUE)) {
            val value = task("invalid").put("order", order)
            assertThrows(IllegalArgumentException::class.java) { Todo.from(value) }
        }
        assertThrows(IllegalArgumentException::class.java) { TodoRules.newTask("invalid", "", day, null, null, Long.MAX_VALUE) }
    }

    @Test fun modelDoesNotCoerceStringProgressSourcesToBoolean() {
        assertThrows(IllegalArgumentException::class.java) { Todo.from(task("invalid").put("isProgressExplicit", "true")) }
        assertNull(Todo.from(task("legacy").put("isProgressExplicit", JSONObject.NULL)).isProgressExplicit)
    }

    @Test fun modelRejectsCoercedStringsAndFractionalOrOutOfRangeCalendarDates() {
        for (field in listOf("id", "title", "note", "phase", "parentID", "groupID")) {
            assertThrows(IllegalArgumentException::class.java) { Todo.from(task("invalid").put(field, 1)) }
        }
        for ((field, value) in listOf("year" to "2026", "year" to 0, "year" to 10000,
                                     "year" to 4_294_967_296L, "month" to 11.5,
                                     "day" to BigDecimal("12.000000000000000001"))) {
            val invalid = task("invalid")
            invalid.getJSONObject("plannedDay").put(field, value)
            assertThrows(IllegalArgumentException::class.java) { Todo.from(invalid) }
        }
        val withoutNote = task("legacy").also { it.remove("note") }
        assertEquals("", Todo.from(withoutNote).note)
        assertThrows(IllegalArgumentException::class.java) { Todo.from(task("invalid").put("note", JSONObject.NULL)) }
        val group = JSONObject().put("id", "00000000-0000-0000-0000-000000000010").put("name", "group").put("colorHex", "#4477AA")
        for (field in listOf("id", "name", "colorHex")) {
            assertThrows(IllegalArgumentException::class.java) { TodoGroup.from(JSONObject(group.toString()).put(field, 1)) }
        }
        for (date in listOf(LocalDate.of(1, 1, 1), LocalDate.of(9999, 12, 31))) {
            assertEquals(date, Todo.from(TodoRules.newTask("boundary", "", date, null, null, 0L)).day)
        }
    }

    @Test fun partialCompletionStartsParent() {
        val parent = task("父项")
        val child = task("完成的子项", parent.getString("id"))
        val sibling = task("未开始的子项", parent.getString("id"))
        val result = TodoRules.setPhase(JSONArray().put(parent).put(child).put(sibling), child.getString("id"), "completed")
        assertEquals("inProgress", result.getJSONObject(0).getString("phase"))
        assertFalse(result.getJSONObject(0).isNull("startedAt"))
        assertFalse(result.getJSONObject(0).getBoolean("isProgressExplicit"))
    }

    @Test fun everyChildPhaseCombinationReconcilesParentProgress() {
        for (first in listOf("pending", "inProgress", "completed")) {
            for (second in listOf("pending", "inProgress", "completed")) {
                val parent = task("父项")
                val child = task("子项", parent.getString("id"))
                val sibling = task("另一子项", parent.getString("id"))
                var result = JSONArray().put(parent).put(child).put(sibling)
                result = TodoRules.setPhase(result, child.getString("id"), first)
                result = TodoRules.setPhase(result, sibling.getString("id"), second)
                val expected = when {
                    first == "completed" && second == "completed" -> "completed"
                    first != "pending" || second != "pending" -> "inProgress"
                    else -> "pending"
                }
                assertEquals("$first, $second", expected, result.getJSONObject(0).getString("phase"))
                assertEquals(expected == "completed", !result.getJSONObject(0).isNull("completedAt"))
                validateDocument(emptyDocument().put("tasks", result))
            }
        }
    }

    @Test fun completingActiveChildPreservesParentStartAndResettingAllChildrenClearsDerivedProgress() {
        val parent = task("父项")
        val child = task("子项", parent.getString("id"))
        val grandchild = task("孙项", child.getString("id"))
        val sibling = task("另一子项", parent.getString("id"))
        val started = TodoRules.setPhase(JSONArray().put(parent).put(child).put(grandchild).put(sibling), grandchild.getString("id"), "inProgress")
        val result = TodoRules.setPhase(started, grandchild.getString("id"), "completed")
        assertEquals(started.getJSONObject(0).toMap(), result.getJSONObject(0).toMap())
        assertEquals("completed", result.getJSONObject(1).getString("phase"))
        val reopened = TodoRules.setPhase(result, grandchild.getString("id"), "pending")
        assertTrue(reopened.objects().all { it.getString("phase") == "pending" && it.isNull("startedAt") && it.isNull("completedAt") })
    }

    @Test fun unchangedIntermediateProgressStillRepairsStaleAncestors() {
        val parent = task("父项")
        val child = task("子项", parent.getString("id"))
        val grandchild = task("孙项", child.getString("id"))
        val original = TodoRules.setPhase(JSONArray().put(parent).put(child).put(grandchild), grandchild.getString("id"), "inProgress")
        original.getJSONObject(0).put("phase", "pending").remove("startedAt")
        original.getJSONObject(0).remove("isProgressExplicit")
        val result = TodoRules.setPhase(original, grandchild.getString("id"), "inProgress")
        assertEquals("inProgress", result.getJSONObject(0).getString("phase"))
        assertEquals(original.getJSONObject(1).toMap(), result.getJSONObject(1).toMap())
    }

    @Test fun preventsFourthLevelAndCyclesIncludingMovingWholeSubtree() {
        val root = task("root"); val child = task("child", root.getString("id")); val grand = task("grand", child.getString("id"))
        val parsed = listOf(root, child, grand).map(Todo::from)
        assertThrows(IllegalArgumentException::class.java) { TodoRules.validateParent(parsed, null, grand.getString("id")) }
        assertThrows(IllegalArgumentException::class.java) { TodoRules.validateParent(parsed, root.getString("id"), child.getString("id")) }
        TodoRules.validateParent(parsed, grand.getString("id"), root.getString("id"))
    }

    @Test fun deletingBranchFindsAllDescendants() {
        val root = task("root"); val child = task("child", root.getString("id")); val grand = task("grand", child.getString("id")); val other = task("other")
        assertEquals(setOf(root, child, grand).map { it.getString("id") }.toSet(),
            TodoRules.descendants(listOf(root, child, grand, other).map(Todo::from), root.getString("id")))
    }

    @Test fun validatesDocumentBeforeReplacingPersistedData() {
        val root = task("root")
        val document = emptyDocument().put("tasks", JSONArray().put(root))
        validateDocument(document)
        document.getJSONArray("tasks").put(JSONObject(root.toString()))
        assertThrows(IllegalArgumentException::class.java) { validateDocument(document) }
    }

    @Test fun datesRemainCalendarDatesAndSwiftReferenceEpochIsExplicit() {
        val value = task("date")
        assertEquals(day, Todo.from(value).day)
        assertEquals(System.currentTimeMillis() / 1000.0, value.getDouble("createdAt") + 978307200.0, 1.0)
    }
}
