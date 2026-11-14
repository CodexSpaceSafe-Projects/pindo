package com.pindo.app.sync

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SyncProtocolTest {
    private val a = "00000000-0000-0000-0000-000000000001"
    private val b = "00000000-0000-0000-0000-000000000002"
    private val taskID = "11111111-1111-1111-1111-111111111111"
    private val secondID = "22222222-2222-2222-2222-222222222222"

    private fun task(id: String = taskID, title: String = "测试", note: String = "初始备注", parent: String? = null, phase: String = "pending"): JSONObject =
        JSONObject().put("id", id).put("title", title).put("note", note).put("phase", phase).put("order", 0)
            .put("createdAt", 1.0).put("updatedAt", 1.0).put("groupID", JSONObject.NULL)
            .put("parentID", parent ?: JSONObject.NULL).put("startedAt", JSONObject.NULL).put("completedAt", JSONObject.NULL)
            .put("plannedDay", JSONObject().put("year", 2026).put("month", 11).put("day", 12))

    private fun tasks(vararg values: JSONObject): JSONArray = JSONArray().also { out -> values.forEach { out.put(it) } }
    private fun seeded(): Pair<SyncReplica, SyncReplica> {
        val first = SyncReplica.fresh(a)
        first.capture(tasks(task()), JSONArray())
        val second = SyncReplica.fresh(b)
        second.merge(first.payload)
        return first to second
    }

    @Test fun independentFieldsSurviveOfflineEditsAndMergeOrder() {
        val (first, second) = seeded()
        first.capture(tasks(task(title = "电脑改标题")), JSONArray())
        second.capture(tasks(task(note = "手机改备注")), JSONArray())
        val firstHead = first.payload
        val secondHead = second.payload
        first.merge(secondHead)
        second.merge(firstHead)
        assertEquals(first.payload.toMap(), second.payload.toMap())
        assertEquals("电脑改标题", first.projected().first.getJSONObject(0).getString("title"))
        assertEquals("手机改备注", first.projected().first.getJSONObject(0).getString("note"))
        first.merge(secondHead)
        assertEquals(2L, first.clock)
    }

    @Test fun concurrentNotesArePreservedThenResolvedByEditingCombinedText() {
        val (first, second) = seeded()
        first.capture(tasks(task(note = "电脑写的")), JSONArray())
        second.capture(tasks(task(note = "手机写的")), JSONArray())
        first.merge(second.payload)
        val note = first.projected().first.getJSONObject(0).getString("note")
        assertEquals("手机写的\n\n[Sync conflict]\n\n电脑写的", note)
        first.capture(tasks(task(note = "合并后的备注")), JSONArray())
        second.merge(first.payload)
        assertEquals("合并后的备注", second.projected().first.getJSONObject(0).getString("note"))
        val variants = second.payload.getJSONObject("records").getJSONObject("task:$taskID").getJSONArray("notes")
        assertEquals(1, variants.length())
    }

    @Test fun deletionDoesNotResurrectAfterConcurrentEditAndRestoreIsExplicit() {
        val (first, second) = seeded()
        first.capture(JSONArray(), JSONArray())
        second.capture(tasks(task(title = "离线改名")), JSONArray())
        first.merge(second.payload)
        second.merge(first.payload)
        assertEquals(0, first.projected().first.length())
        assertEquals(0, second.projected().first.length())
        second.capture(tasks(task(title = "显式恢复")), JSONArray())
        first.merge(second.payload)
        assertEquals("显式恢复", first.projected().first.getJSONObject(0).getString("title"))
    }

    @Test fun metadataRoundTripDoesNotTreatRemoteProjectionAsLocalEdit() {
        val (first, second) = seeded()
        first.capture(tasks(task(title = "新标题")), JSONArray())
        second.merge(first.payload)
        val projection = second.projected()
        val restored = SyncReplica.fromJson(second.toJson())
        restored.capture(projection.first, projection.second)
        assertEquals(2L, restored.clock)
        assertEquals(second.payload.toMap(), restored.payload.toMap())
    }

    @Test fun cyclesAndDepthAreProjectedDeterministicallyWithoutDiscardingTasks() {
        val third = "33333333-3333-3333-3333-333333333333"
        val fourth = "44444444-4444-4444-4444-444444444444"
        val replica = SyncReplica.fresh(a)
        replica.capture(tasks(task(taskID), task(secondID), task(third), task(fourth)), JSONArray())
        val payload = replica.payload
        for ((id, parent) in mapOf(taskID to secondID, secondID to taskID, third to secondID, fourth to third)) {
            payload.getJSONObject("records").getJSONObject("task:$id").getJSONObject("fields").getJSONObject("parentID").put("value", parent)
        }
        val first = SyncReplica.fresh(a)
        first.merge(payload)
        val projected = first.projected().first
        assertEquals(4, projected.length())
        assertTrue(projected.getJSONObject(0).isNull("parentID"))
        // Four nodes still survive even though the deepest parent edge is detached.
        assertTrue(projected.getJSONObject(3).isNull("parentID"))
        val other = SyncReplica.fresh(b)
        other.merge(payload)
        assertEquals(projected.toList(), other.projected().first.toList())
    }

    @Test fun orphanIsPreservedAndParentCompletionIsDerivedBottomUp() {
        val replica = SyncReplica.fresh(a)
        replica.capture(tasks(task(taskID, phase = "pending"), task(secondID, parent = taskID, phase = "completed")), JSONArray())
        val projection = replica.projected().first
        assertEquals("completed", projection.getJSONObject(0).getString("phase"))
        assertEquals(1.0, projection.getJSONObject(0).getDouble("completedAt"), 0.0)
        val deletedParent = replica.payload
        deletedParent.getJSONObject("records").getJSONObject("task:$taskID").getJSONObject("fields").getJSONObject("\$alive").put("value", false)
        val other = SyncReplica.fresh(b)
        other.merge(deletedParent)
        assertEquals(1, other.projected().first.length())
        assertTrue(other.projected().first.getJSONObject(0).isNull("parentID"))
    }

    @Test fun invalidPayloadFailsWithoutChangingReplica() {
        val (first, _) = seeded()
        val prior = first.toJson().toMap()
        val invalid = first.payload
        invalid.getJSONObject("records").getJSONObject("task:$taskID").getJSONObject("fields").getJSONObject("title")
            .getJSONObject("stamp").put("counter", 99)
        assertThrows(IllegalArgumentException::class.java) { first.merge(invalid) }
        assertEquals(prior, first.toJson().toMap())
    }

    @Test fun partialCompletionStartsParentDuringSync() {
        val replica = SyncReplica.fresh(a)
        val pendingID = "33333333-3333-3333-3333-333333333333"
        replica.capture(tasks(task(taskID), task(secondID, parent = taskID, phase = "completed"),
            task(pendingID, parent = taskID)), JSONArray())
        val other = SyncReplica.fresh(b)
        other.merge(replica.payload)
        val parent = other.projected().first.getJSONObject(0)
        assertEquals("inProgress", parent.getString("phase"))
        assertEquals(1.0, parent.getDouble("startedAt"), 0.0)
    }

    @Test fun capturingUnchangedDocumentDoesNotConsumeRequestsOrCounters() {
        val (first, _) = seeded()
        first.capture(tasks(task()), JSONArray())
        assertEquals(1L, first.clock)
    }

    @Test fun malformedTombstonesAndCoercedScalarTypesAreRejected() {
        val (first, _) = seeded()
        for (field in listOf("title", "createdAt", "order")) {
            val payload = first.payload
            val fields = payload.getJSONObject("records").getJSONObject("task:$taskID").getJSONObject("fields")
            fields.getJSONObject("\$alive").put("value", false)
            fields.getJSONObject(field).put("value", when (field) { "title" -> true; "createdAt" -> "1.0"; else -> 1.5 })
            assertThrows(IllegalArgumentException::class.java) { SyncReplica.validatedPayload(payload) }
        }
        val incomplete = first.payload
        incomplete.getJSONObject("records").getJSONObject("task:$taskID").getJSONObject("fields").remove("title")
        assertThrows(IllegalArgumentException::class.java) { SyncReplica.validatedPayload(incomplete) }
        val excessiveCounter = first.payload
        excessiveCounter.getJSONObject("seen").put(a, 9_007_199_254_740_992L)
        assertThrows(IllegalArgumentException::class.java) { SyncReplica.validatedPayload(excessiveCounter) }
    }

    @Test fun canonicalUnicodeComparisonMatchesSwiftWithoutRewritingText() {
        val (first, second) = seeded()
        first.capture(tasks(task(note = "Café")), JSONArray())
        second.capture(tasks(task(note = "Cafe\u0301")), JSONArray())
        first.merge(second.payload)
        assertEquals("Cafe\u0301", first.projected().first.getJSONObject(0).getString("note"))
        val counter = first.clock
        first.capture(tasks(task(note = "Café")), JSONArray())
        assertEquals(counter, first.clock)

        val groupA = JSONObject().put("id", taskID).put("name", "Café").put("colorHex", "#228833")
        val groupB = JSONObject().put("id", secondID).put("name", "Cafe\u0301").put("colorHex", "#228833")
        val ga = SyncReplica.fresh(a).apply { capture(JSONArray(), tasks(groupA)) }
        val gb = SyncReplica.fresh(b).apply { capture(JSONArray(), tasks(groupB)) }
        ga.merge(gb.payload)
        val groups = ga.projected().second
        assertEquals("Café [$taskID]", groups.getJSONObject(0).getString("name"))
        assertEquals("Cafe\u0301 [$secondID]", groups.getJSONObject(1).getString("name"))
    }
}
