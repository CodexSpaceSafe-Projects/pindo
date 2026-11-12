package com.pindo.app

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate

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

    @Test fun cannotCompleteParentWithPendingChild() {
        val parent = task("parent"); val child = task("child", parent.getString("id"))
        assertThrows(IllegalArgumentException::class.java) {
            TodoRules.setPhase(JSONArray().put(parent).put(child), parent.getString("id"), "completed")
        }
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
