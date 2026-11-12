package com.pindo.app

import com.pindo.app.sync.SyncReplica
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate

class TodoBatchTest {
    private val day = LocalDate.of(2026, 11, 12)
    private fun task(title: String, parent: String? = null): JSONObject = TodoRules.newTask(title, "备注", day, null, parent, 0)

    @Test fun completingParentAndItsChildrenTogetherDoesNotDependOnSelectionOrder() {
        val parent = task("父项")
        val child = task("子项", parent.getString("id"))
        val tasks = JSONArray().put(parent).put(child)
        val done = TodoRules.batch(tasks, linkedSetOf(parent.getString("id"), child.getString("id")), TodoBatchAction.SetPhase("completed"))
        assertTrue(done.objects().all { it.getString("phase") == "completed" })
        assertTrue(tasks.objects().all { it.getString("phase") == "pending" })
        val reopened = TodoRules.batch(done, setOf(child.getString("id")), TodoBatchAction.SetPhase("pending"))
        assertTrue(reopened.objects().all { it.getString("phase") == "pending" })
    }

    @Test fun invalidCompletionIsAtomicAndDoesNotPartiallyUpdateOtherSelectedTasks() {
        val parent = task("父项")
        val child = task("未完成子项", parent.getString("id"))
        val other = task("其他事项")
        val tasks = JSONArray().put(parent).put(child).put(other)
        val before = tasks.toString()
        assertThrows(IllegalArgumentException::class.java) {
            TodoRules.batch(tasks, setOf(parent.getString("id"), other.getString("id")), TodoBatchAction.SetPhase("completed"))
        }
        assertEquals(before, tasks.toString())
    }

    @Test fun explicitlyReopeningParentDoesNotReopenCompletedChildrenOrImmediatelyCompleteItAgain() {
        val parent = task("父项")
        val child = task("子项", parent.getString("id"))
        val done = TodoRules.batch(JSONArray().put(parent).put(child),
            setOf(parent.getString("id"), child.getString("id")), TodoBatchAction.SetPhase("completed"))
        for (phase in listOf("pending", "inProgress")) {
            val changed = TodoRules.batch(done, setOf(parent.getString("id")), TodoBatchAction.SetPhase(phase))
            assertEquals(phase, changed.getJSONObject(0).getString("phase"))
            assertEquals("completed", changed.getJSONObject(1).getString("phase"))
            assertTrue(changed.getJSONObject(0).isNull("completedAt"))
        }
        assertTrue(done.objects().all { it.getString("phase") == "completed" })
    }

    @Test fun deleteExpandsSelectedBranchesAndDeduplicatesParentAndChildSelection() {
        val parent = task("父项")
        val child = task("子项", parent.getString("id"))
        val grandchild = task("孙项", child.getString("id"))
        val other = task("保留")
        val tasks = JSONArray().put(parent).put(child).put(grandchild).put(other)
        val ids = setOf(parent.getString("id"), child.getString("id"))
        assertEquals(3, TodoRules.deletionIDs(tasks.objects().map(Todo::from), ids).size)
        val remaining = TodoRules.batch(tasks, ids, TodoBatchAction.Delete)
        assertEquals(listOf(other.getString("id")), remaining.objects().map { it.getString("id") })
        assertEquals(4, tasks.length())
    }

    @Test fun groupAndDateChangesOnlyAffectSelectedTasksAndPreserveHierarchyAndNotes() {
        val parent = task("父项")
        val child = task("子项", parent.getString("id"))
        val tasks = JSONArray().put(parent).put(child)
        val group = "00000000-0000-0000-0000-000000000010"
        val grouped = TodoRules.batch(tasks, setOf(child.getString("id")), TodoBatchAction.SetGroup(group))
        val moved = TodoRules.batch(grouped, setOf(child.getString("id")), TodoBatchAction.SetDay(day.plusDays(3)))
        val parsed = moved.objects().map(Todo::from)
        assertNull(parsed[0].groupID)
        assertEquals(day, parsed[0].day)
        assertEquals(group, parsed[1].groupID)
        assertEquals(day.plusDays(3), parsed[1].day)
        assertEquals(parsed[0].id, parsed[1].parentID)
        assertEquals("备注", parsed[1].note)
    }

    @Test fun branchDeletionProducesSyncTombstonesForEveryRemovedDescendant() {
        val parent = task("父项")
        val child = task("子项", parent.getString("id"))
        val tasks = JSONArray().put(parent).put(child)
        val replica = SyncReplica.fresh()
        replica.capture(tasks, JSONArray())
        replica.capture(TodoRules.batch(tasks, setOf(parent.getString("id")), TodoBatchAction.Delete), JSONArray())
        val records = replica.payload().getJSONObject("records")
        for (item in listOf(parent, child)) {
            assertFalse(records.getJSONObject("task:${item.getString("id")}").getJSONObject("fields")
                .getJSONObject("\$alive").getBoolean("value"))
        }
    }
}
