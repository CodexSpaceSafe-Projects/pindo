package com.pindo.app

import com.pindo.app.sync.SyncReplica
import com.pindo.app.sync.toMap
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

    @Test fun invalidPhaseIsAtomicAndDoesNotPartiallyUpdateOtherSelectedTasks() {
        val parent = task("父项")
        val child = task("未完成子项", parent.getString("id"))
        val other = task("其他事项")
        val tasks = JSONArray().put(parent).put(child).put(other)
        val before = tasks.toString()
        assertThrows(IllegalArgumentException::class.java) {
            TodoRules.batch(tasks, setOf(parent.getString("id"), other.getString("id")), TodoBatchAction.SetPhase("invalid"))
        }
        assertEquals(before, tasks.toString())
    }

    @Test fun reopeningParentReopensChildrenWhileStartingParentOnlyStartsTheParent() {
        val parent = task("父项")
        val child = task("子项", parent.getString("id"))
        val done = TodoRules.batch(JSONArray().put(parent).put(child),
            setOf(parent.getString("id"), child.getString("id")), TodoBatchAction.SetPhase("completed"))
        for (phase in listOf("pending", "inProgress")) {
            val changed = TodoRules.batch(done, setOf(parent.getString("id")), TodoBatchAction.SetPhase(phase))
            assertEquals(phase, changed.getJSONObject(0).getString("phase"))
            assertEquals(if (phase == "pending") "pending" else "completed", changed.getJSONObject(1).getString("phase"))
            assertTrue(changed.getJSONObject(0).isNull("completedAt"))
            if (phase == "inProgress") assertTrue(changed.getJSONObject(0).getBoolean("isProgressExplicit"))
        }
        assertTrue(done.objects().all { it.getString("phase") == "completed" })
    }

    @Test fun reparentingPendingTaskUnderCompletedParentReopensParentEvenWhenTargetPhaseIsUnchanged() {
        val parent = task("已完成父项").put("phase", "completed").put("completedAt", 1.0)
        val child = task("待移动")
        val original = JSONArray().put(parent).put(child)
        val moved = TodoRules.moveTask(original, child.getString("id"), parent.getString("id"))
        val result = TodoRules.setPhase(moved, child.getString("id"), "pending")
        assertEquals("pending", result.getJSONObject(0).getString("phase"))
        assertEquals(parent.getString("id"), result.getJSONObject(1).getString("parentID"))
        validateDocument(emptyDocument().put("tasks", result))
        assertEquals("completed", original.getJSONObject(0).getString("phase"))
        assertTrue(original.getJSONObject(1).isNull("parentID"))
    }

    @Test fun movingLastUnfinishedChildAwayCompletesOldAncestorsWithUnchangedTargetPhase() {
        val grand = task("祖父项")
        val oldParent = task("旧父项", grand.getString("id"))
        val finished = task("已完成子项", oldParent.getString("id")).put("phase", "completed").put("completedAt", 1.0)
        val moving = task("未完成子项", oldParent.getString("id"))
        val original = JSONArray().put(grand).put(oldParent).put(finished).put(moving)
        val moved = TodoRules.moveTask(original, moving.getString("id"), null)
        val result = TodoRules.setPhase(moved, moving.getString("id"), "pending")
        assertEquals("completed", result.getJSONObject(0).getString("phase"))
        assertEquals("completed", result.getJSONObject(1).getString("phase"))
        assertTrue(result.getJSONObject(3).isNull("parentID"))
        assertEquals("pending", result.getJSONObject(3).getString("phase"))
        validateDocument(emptyDocument().put("tasks", result))
        assertEquals("pending", original.getJSONObject(1).getString("phase"))
    }

    @Test fun reparentingRootAppendsItsSubtreeAfterExistingChildren() {
        val moving = task("先创建的根项").put("order", 0L).put("updatedAt", 1.0)
        val parent = task("目标父项").put("order", 1L).put("updatedAt", 2.0)
        val existing = task("已有子项", parent.getString("id")).put("order", 2L).put("updatedAt", 3.0)
        val descendant = task("跟随移动的子项", moving.getString("id")).put("order", 3L).put("updatedAt", 4.0)
        val original = JSONArray().put(moving).put(parent).put(existing).put(descendant)
        val before = original.toString()
        val moved = TodoRules.moveTask(original, moving.getString("id"), parent.getString("id"))
        val children = moved.objects().map(Todo::from).filter { it.parentID == parent.getString("id") }.sortedBy { it.order }

        assertEquals(listOf(existing.getString("id"), moving.getString("id")), children.map { it.id })
        assertEquals(listOf(0L, 1L), children.map { it.order })
        assertEquals(3.0, moved.getJSONObject(2).getDouble("updatedAt"), 0.0)
        assertEquals(parent.toMap(), moved.getJSONObject(1).toMap())
        assertEquals(descendant.toMap(), moved.getJSONObject(3).toMap())
        assertTrue(moved.getJSONObject(0).getDouble("updatedAt") > 1.0)
        assertEquals(before, original.toString())
        validateDocument(emptyDocument().put("tasks", moved))
    }

    @Test fun reparentingBetweenFamiliesAppendsAndReconcilesBothAncestorChains() {
        val grandparent = task("旧祖父项")
        val oldParent = task("旧父项", grandparent.getString("id"))
        val finished = task("旧父项的已完成子项", oldParent.getString("id"))
        val moving = task("移动的未完成子项", oldParent.getString("id")).put("order", -MAX_TASK_ORDER)
        val newParent = task("新父项")
        val existing = task("新父项的已有子项", newParent.getString("id")).put("order", MAX_TASK_ORDER)
        var original = JSONArray().put(grandparent).put(oldParent).put(finished).put(moving).put(newParent).put(existing)
        original = TodoRules.setPhase(original, finished.getString("id"), "completed")
        original = TodoRules.setPhase(original, newParent.getString("id"), "completed")
        val before = original.toString()
        val moved = TodoRules.moveTask(original, moving.getString("id"), newParent.getString("id"))

        assertEquals("completed", moved.getJSONObject(0).getString("phase"))
        assertEquals("completed", moved.getJSONObject(1).getString("phase"))
        assertEquals("inProgress", moved.getJSONObject(4).getString("phase"))
        assertFalse(moved.getJSONObject(4).getBoolean("isProgressExplicit"))
        assertEquals(0L, moved.getJSONObject(5).getLong("order"))
        assertEquals(1L, moved.getJSONObject(3).getLong("order"))
        assertEquals(original.getJSONObject(5).getDouble("updatedAt"), moved.getJSONObject(5).getDouble("updatedAt"), 0.0)
        assertEquals(original.getJSONObject(2).toMap(), moved.getJSONObject(2).toMap())
        assertEquals(before, original.toString())
        validateDocument(emptyDocument().put("tasks", moved))
    }

    @Test fun movingChildToRootAppendsAfterEqualAndMaximumOrderSiblings() {
        val parent = task("旧父项").put("order", MAX_TASK_ORDER).put("updatedAt", 3.0)
        val later = task("较晚创建的根项").put("order", 0L).put("createdAt", 2.0).put("updatedAt", 2.0)
            .put("id", "11111111-1111-4111-8111-111111111111")
        val earlier = task("较早创建的根项").put("order", 0L).put("createdAt", 1.0).put("updatedAt", 1.0)
            .put("id", "22222222-2222-4222-8222-222222222222")
        val moving = task("移到根层", parent.getString("id")).put("order", -MAX_TASK_ORDER).put("updatedAt", 4.0)
        val original = JSONArray().put(parent).put(later).put(earlier).put(moving)
        val before = original.toString()
        val moved = TodoRules.moveTask(original, moving.getString("id"), null)
        val roots = moved.objects().map(Todo::from).filter { it.parentID == null }.sortedBy { it.order }

        assertEquals(listOf(earlier, later, parent, moving).map { it.getString("id") }, roots.map { it.id })
        assertEquals(listOf(0L, 1L, 2L, 3L), roots.map { it.order })
        for (index in 0..2) {
            val unchanged = original.getJSONObject(index).toMap().toMutableMap().apply { remove("order") }
            val actual = moved.getJSONObject(index).toMap().toMutableMap().apply { remove("order") }
            assertEquals(unchanged, actual)
        }
        assertTrue(moved.getJSONObject(3).getDouble("updatedAt") > 4.0)
        assertEquals(before, original.toString())
        assertEquals(moved.objects().map { it.toMap() },
            TodoRules.moveTask(moved, moving.getString("id"), null).objects().map { it.toMap() })
        validateDocument(emptyDocument().put("tasks", moved))
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

    @Test fun deletingUnrelatedBranchPreservesExplicitlyReopenedBranch() {
        val grandparent = task("祖父项")
        val parent = task("父项", grandparent.getString("id"))
        val child = task("子项", parent.getString("id"))
        val other = task("另一棵树")
        val otherChild = task("另一棵树的子项", other.getString("id"))
        val completed = TodoRules.setPhase(JSONArray().put(grandparent).put(parent).put(child).put(other).put(otherChild),
            grandparent.getString("id"), "completed")
        val reopened = TodoRules.setPhase(completed, parent.getString("id"), "inProgress")
        val before = reopened.toString()
        val remaining = TodoRules.batch(reopened, setOf(other.getString("id"), otherChild.getString("id")), TodoBatchAction.Delete)

        assertEquals(3, remaining.length())
        for (index in 0..2) {
            assertEquals(reopened.getJSONObject(index).toMap(), remaining.getJSONObject(index).toMap())
        }
        assertEquals("inProgress", remaining.getJSONObject(1).getString("phase"))
        assertTrue(remaining.getJSONObject(1).getBoolean("isProgressExplicit"))
        assertEquals(before, reopened.toString())
        validateDocument(emptyDocument().put("tasks", remaining))
    }

    @Test fun deletingLastUnfinishedGrandchildCompletesEverySurvivingAncestor() {
        val grandparent = task("祖父项")
        val parent = task("父项", grandparent.getString("id"))
        val finished = task("已完成孙项", parent.getString("id"))
        val unfinished = task("未完成孙项", parent.getString("id"))
        val active = TodoRules.setPhase(JSONArray().put(grandparent).put(parent).put(finished).put(unfinished),
            finished.getString("id"), "completed")
        assertEquals("inProgress", active.getJSONObject(0).getString("phase"))
        assertEquals("inProgress", active.getJSONObject(1).getString("phase"))
        val remaining = TodoRules.batch(active, setOf(unfinished.getString("id")), TodoBatchAction.Delete)

        assertEquals(3, remaining.length())
        assertTrue(remaining.objects().all { it.getString("phase") == "completed" && !it.isNull("completedAt") })
        assertEquals(active.getJSONObject(2).toMap(), remaining.getJSONObject(2).toMap())
        assertEquals("inProgress", active.getJSONObject(0).getString("phase"))
        validateDocument(emptyDocument().put("tasks", remaining))
    }

    @Test fun movingOrDeletingTheLastChildOnlyClearsDerivedParentProgress() {
        for (explicit in listOf(false, true)) {
            val parent = task("parent")
            val child = task("child", parent.getString("id"))
            var started = JSONArray().put(parent).put(child)
            if (explicit) started = TodoRules.setPhase(started, parent.getString("id"), "inProgress")
            started = TodoRules.setPhase(started, child.getString("id"), "inProgress")
            val moved = TodoRules.moveTask(started, child.getString("id"), null)
            assertEquals(if (explicit) "inProgress" else "pending", moved.getJSONObject(0).getString("phase"))
            assertEquals("inProgress", moved.getJSONObject(1).getString("phase"))
            val deleted = TodoRules.batch(started, setOf(child.getString("id")), TodoBatchAction.Delete)
            assertEquals(1, deleted.length())
            assertEquals(if (explicit) "inProgress" else "pending", deleted.getJSONObject(0).getString("phase"))
            if (!explicit) {
                assertTrue(moved.getJSONObject(0).isNull("startedAt"))
                assertTrue(deleted.getJSONObject(0).isNull("startedAt"))
            }
        }
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
