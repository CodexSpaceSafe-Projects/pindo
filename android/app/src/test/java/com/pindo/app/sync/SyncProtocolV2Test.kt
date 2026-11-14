package com.pindo.app.sync

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.Random
import java.util.UUID

class SyncProtocolV2Test {
    private val a = "00000000-0000-4000-8000-000000000001"
    private val b = "00000000-0000-4000-8000-000000000002"
    private val c = "00000000-0000-4000-8000-000000000003"
    private val id = "10000000-0000-4000-8000-000000000001"
    private val childID = "10000000-0000-4000-8000-000000000002"
    private fun tasks(vararg values: JSONObject) = JSONArray().also { out -> values.forEach { out.put(it) } }
    private fun task(taskID: String = id, parent: String? = null): JSONObject = JSONObject()
        .put("id", taskID).put("title", "事项 $taskID").put("note", "初始备注")
        .put("phase", "pending").put("isProgressExplicit", false).put("order", 0)
        .put("createdAt", 1.0).put("updatedAt", 1.0).put("groupID", JSONObject.NULL)
        .put("parentID", parent ?: JSONObject.NULL).put("startedAt", JSONObject.NULL).put("completedAt", JSONObject.NULL)
        .put("plannedDay", JSONObject().put("year", 2026).put("month", 11).put("day", 14))
    private fun phase(task: JSONObject, value: String, at: Double, explicit: Boolean = value == "inProgress"): JSONObject = task
        .put("phase", value).put("updatedAt", at).put("isProgressExplicit", explicit)
        .put("startedAt", if (value == "inProgress") at else JSONObject.NULL)
        .put("completedAt", if (value == "completed") at else JSONObject.NULL)
    private fun fields(payload: JSONObject, taskID: String = id) = payload.getJSONObject("records").getJSONObject("task:$taskID").getJSONObject("fields")
    private fun editLegacy(payload: JSONObject, name: String, value: Any, counter: Long, actor: String = b): JSONObject {
        fields(payload).put(name, JSONObject().put("value", value).put("stamp", JSONObject().put("counter", counter).put("deviceID", actor)))
        payload.getJSONObject("seen").put(actor, counter)
        return payload
    }
    private fun merge(vararg heads: JSONObject): SyncReplica = SyncReplica.fresh(c, version = 2).apply { heads.forEach { merge(it) } }

    @Test fun upgradePreservesRawRegistersAndCommutesWithLegacyMerge() {
        val legacy = SyncReplica.fresh(a).apply { capture(tasks(task()), JSONArray()) }
        val first = editLegacy(legacy.payload, "phase", "completed", 2)
        editLegacy(first, "completedAt", 2.0, 2)
        val second = editLegacy(legacy.payload, "phase", "pending", 3)
        editLegacy(second, "completedAt", JSONObject.NULL, 3)
        val metadata = editLegacy(first, "completedAt", 4.0, 4)
        val oldMerged = SyncReplica.fresh(c).apply { merge(second); merge(metadata) }
        val upgradedMerged = oldMerged.upgraded()
        val separate = merge(SyncReplica.upgradedPayload(second), SyncReplica.upgradedPayload(metadata))
        assertEquals(upgradedMerged.payload.toMap(), separate.payload.toMap())
        assertEquals("pending", separate.projected().first.getJSONObject(0).getString("phase"))
        assertTrue(separate.projected().first.getJSONObject(0).isNull("completedAt"))
        val oldFields = fields(oldMerged.payload)
        val newFields = fields(upgradedMerged.payload)
        oldFields.keys().forEach { name -> assertEquals(oldFields.getJSONObject(name).toMap(), newFields.getJSONObject(name).toMap()) }
        assertTrue(newFields.getJSONObject("lifecycle").isNull("value"))
        assertEquals(1, oldMerged.payload.getInt("version"))
    }

    @Test fun realLifecycleSurvivesHigherLegacyTimeAndNullBottomStamps() {
        val legacy = SyncReplica.fresh(a).apply { capture(tasks(task()), JSONArray()) }
        val upgraded = legacy.upgraded()
        upgraded.rotateActor(c)
        upgraded.capture(tasks(phase(task(), "inProgress", 20.0)), JSONArray())
        val real = upgraded.payload
        val lateTime = editLegacy(legacy.payload, "completedAt", 900.0, 99)
        val combined = merge(real, lateTime)
        val visible = combined.projected().first.getJSONObject(0)
        assertEquals("inProgress", visible.getString("phase"))
        assertEquals(20.0, visible.getDouble("startedAt"), 0.0)
        assertTrue(visible.isNull("completedAt"))
        assertTrue(visible.getBoolean("isProgressExplicit"))
        val highBottom = SyncReplica.upgradedPayload(legacy.payload)
        fields(highBottom).getJSONObject("lifecycle").getJSONObject("stamp").put("counter", 100).put("deviceID", b)
        highBottom.getJSONObject("seen").put(b, 100)
        combined.merge(highBottom)
        assertEquals(visible.toMap(), combined.projected().first.getJSONObject(0).toMap())
        assertFalse(fields(combined.payload).getJSONObject("lifecycle").isNull("value"))
    }

    @Test fun newerLegacyPhaseWinsThenARealLifecycleMirrorsItWithoutTimeBasedResurrection() {
        val legacy = SyncReplica.fresh(a).apply { capture(tasks(task()), JSONArray()) }
        val upgraded = legacy.upgraded()
        upgraded.rotateActor(c)
        upgraded.capture(tasks(phase(task(), "inProgress", 2.0)), JSONArray())
        val oldReal = upgraded.payload
        val reopened = editLegacy(legacy.payload, "phase", "pending", 5)
        editLegacy(reopened, "startedAt", JSONObject.NULL, 5)
        val merged = merge(oldReal, reopened)
        assertEquals("pending", merged.projected().first.getJSONObject(0).getString("phase"))
        merged.merge(legacy.payload)
        assertEquals("pending", merged.projected().first.getJSONObject(0).getString("phase"))
        merged.rotateActor(c)
        merged.capture(tasks(phase(task(), "completed", 6.0)), JSONArray())
        val current = merged.payload
        val statusFields = fields(current)
        val lifecycleStamp = statusFields.getJSONObject("lifecycle").getJSONObject("stamp").toMap()
        for (name in listOf("phase", "startedAt", "completedAt")) assertEquals(lifecycleStamp, statusFields.getJSONObject(name).getJSONObject("stamp").toMap())
        val onlyTime = JSONObject(current.toString()).put("version", 1)
        fields(onlyTime).remove("lifecycle")
        editLegacy(onlyTime, "startedAt", 90.0, 90)
        merged.merge(onlyTime)
        val completed = merged.projected().first.getJSONObject(0)
        assertEquals("completed", completed.getString("phase"))
        assertEquals(6.0, completed.getDouble("completedAt"), 0.0)
        assertTrue(completed.isNull("startedAt"))
    }

    @Test fun explicitParentProgressSurvivesRemoteChildReopenAndDerivedProgressClears() {
        val base = SyncReplica.fresh(a, version = 2).apply {
            capture(tasks(task(), phase(task(childID, id), "inProgress", 2.0)), JSONArray())
        }
        val first = SyncReplica.fresh(b, version = 2).apply { merge(base.payload) }
        val second = SyncReplica.fresh(c, version = 2).apply { merge(base.payload) }
        val firstProjection = first.projected().first
        firstProjection.getJSONObject(0).put("isProgressExplicit", true)
        first.capture(firstProjection, JSONArray())
        val secondProjection = second.projected().first
        phase(secondProjection.getJSONObject(1), "pending", 3.0)
        second.capture(secondProjection, JSONArray())
        first.merge(second.payload)
        assertEquals("inProgress", first.projected().first.getJSONObject(0).getString("phase"))
        assertTrue(first.projected().first.getJSONObject(0).getBoolean("isProgressExplicit"))
        val derived = SyncReplica.fresh(b, version = 2).apply { merge(base.payload) }
        val projection = derived.projected().first
        phase(projection.getJSONObject(1), "pending", 3.0)
        derived.capture(projection, JSONArray())
        val parent = derived.projected().first.getJSONObject(0)
        assertEquals("pending", parent.getString("phase"))
        assertFalse(parent.getBoolean("isProgressExplicit"))
        assertTrue(parent.isNull("startedAt"))
        val removed = SyncReplica.fresh(c, version = 2).apply { merge(base.payload) }
        removed.capture(tasks(removed.projected().first.getJSONObject(0)), JSONArray())
        assertEquals("pending", removed.projected().first.getJSONObject(0).getString("phase"))
    }

    @Test fun actorRotationRetainsHistoryButSeparatesFutureCloneOperations() {
        val original = SyncReplica.fresh(a, version = 2).apply { capture(tasks(task()), JSONArray()) }
        val first = SyncReplica.fromJson(original.toJson()).apply { rotateActor(b) }
        val second = SyncReplica.fromJson(original.toJson()).apply { rotateActor(c) }
        first.capture(tasks(task().put("title", "电脑标题")), JSONArray())
        second.capture(tasks(task().put("note", "手机备注")), JSONArray())
        val merged = merge(first.payload, second.payload)
        val visible = merged.projected().first.getJSONObject(0)
        assertEquals("电脑标题", visible.getString("title")); assertEquals("手机备注", visible.getString("note"))
        assertEquals(a, fields(merged.payload).getJSONObject("createdAt").getJSONObject("stamp").getString("deviceID"))
        assertEquals(b, fields(merged.payload).getJSONObject("title").getJSONObject("stamp").getString("deviceID"))
        assertEquals(c, merged.payload.getJSONObject("records").getJSONObject("task:$id").getJSONArray("notes").getJSONObject(0).getJSONObject("stamp").getString("deviceID"))
        assertEquals(a, original.deviceID)
        assertThrows(IllegalArgumentException::class.java) { first.rotateActor(a) }
    }

    @Test fun invalidLifecycleAndContradictoryRealOperationsFailWithoutMutation() {
        val replica = SyncReplica.fresh(a, version = 2).apply { capture(tasks(task()), JSONArray()) }
        val before = replica.toJson().toMap()
        for (invalid in listOf(
            JSONObject().put("phase", "pending").put("startedAt", 2.0).put("completedAt", JSONObject.NULL).put("isProgressExplicit", false),
            JSONObject().put("phase", "inProgress").put("startedAt", JSONObject.NULL).put("completedAt", JSONObject.NULL).put("isProgressExplicit", true),
            JSONObject().put("phase", "completed").put("startedAt", JSONObject.NULL).put("completedAt", 2.0).put("isProgressExplicit", true)
        )) {
            val payload = replica.payload
            fields(payload).getJSONObject("lifecycle").put("value", invalid)
            assertThrows(IllegalArgumentException::class.java) { replica.merge(payload) }
            assertEquals(before, replica.toJson().toMap())
        }
        val contradictory = replica.payload
        fields(contradictory).getJSONObject("lifecycle").getJSONObject("value").put("phase", "completed").put("completedAt", 2.0)
        assertThrows(IllegalArgumentException::class.java) { replica.merge(contradictory) }
        assertEquals(before, replica.toJson().toMap())
    }

    @Test fun wireNumberDateAndCollectionLimitsMatchSwift() {
        val replica = SyncReplica.fresh(a, version = 2)
        replica.capture(tasks(task().put("order", 4_294_967_296L)), JSONArray())
        assertEquals(4_294_967_296L, replica.projected().first.getJSONObject(0).getLong("order"))
        for (invalid in listOf(9_007_199_254_740_992L, -9_007_199_254_740_992L,
            java.math.BigDecimal("4294967296.00000001"), 1.5, "2")) {
            val candidate = replica.payload
            fields(candidate).getJSONObject("order").put("value", invalid)
            assertThrows(IllegalArgumentException::class.java) { SyncReplica.validatedPayload(candidate) }
        }
        val future = replica.payload
        fields(future).getJSONObject("plannedDay").getJSONObject("value").put("year", 10_000)
        assertThrows(IllegalArgumentException::class.java) { SyncReplica.validatedPayload(future) }
        val groups = JSONArray()
        repeat(1001) { index -> groups.put(JSONObject().put("id", UUID.nameUUIDFromBytes("group-$index".toByteArray()).toString())
            .put("name", "Group $index").put("colorHex", "#228833")) }
        assertThrows(IllegalArgumentException::class.java) { replica.capture(JSONArray(), groups) }
    }

    @Test fun seededThreeDevicePartitionsReorderingDuplicatesAndRestoresConverge() {
        val random = Random(0x50494e444fL)
        val initial = SyncReplica.fresh(a, version = 2).apply { capture(tasks(task()), JSONArray()) }
        val replicas = listOf(a, b, c).map { actor -> SyncReplica.fresh(actor, version = 2).apply { merge(initial.payload) } }
        val snapshots = mutableListOf(initial.payload)
        val deleted = mutableListOf<JSONObject>()
        repeat(240) { step ->
            val replica = replicas[random.nextInt(replicas.size)]
            val projection = replica.projected().first
            val action = random.nextInt(8)
            when (action) {
                0 -> projection.put(task(UUID.nameUUIDFromBytes("operation-$step".toByteArray()).toString()))
                1 -> if (projection.length() > 0) projection.getJSONObject(random.nextInt(projection.length())).put("title", "标题 $step 中文✅")
                2 -> if (projection.length() > 0) projection.getJSONObject(random.nextInt(projection.length())).put("note", "备注 $step\n👩‍💻")
                3 -> if (projection.length() > 0) phase(projection.getJSONObject(random.nextInt(projection.length())), listOf("pending", "inProgress", "completed")[random.nextInt(3)], step + 10.0)
                4 -> if (projection.length() > 0) deleted.add(JSONObject(projection.remove(random.nextInt(projection.length())).toString()))
                5 -> if (deleted.isNotEmpty()) {
                    val restored = JSONObject(deleted[random.nextInt(deleted.size)].toString())
                    if ((0 until projection.length()).none { projection.getJSONObject(it).getString("id") == restored.getString("id") }) projection.put(restored)
                }
                6 -> replica.merge(snapshots[random.nextInt(snapshots.size)])
                7 -> replica.merge(replicas[random.nextInt(replicas.size)].payload)
            }
            if (action < 6) replica.capture(projection, JSONArray())
            snapshots.add(replica.payload)
        }
        val finalHeads = replicas.map { it.payload }
        val orders = listOf(listOf(0, 1, 2), listOf(0, 2, 1), listOf(1, 0, 2), listOf(1, 2, 0), listOf(2, 0, 1), listOf(2, 1, 0))
        val expected = merge(*finalHeads.toTypedArray())
        for (order in orders) {
            val candidate = merge(*order.map { finalHeads[it] }.toTypedArray())
            snapshots.shuffled(kotlin.random.Random(order.first())).take(30).forEach { candidate.merge(it) }
            finalHeads.forEach { candidate.merge(it); candidate.merge(it) }
            assertEquals(expected.payload.toMap(), candidate.payload.toMap())
            assertEquals(expected.projected().first.toList(), candidate.projected().first.toList())
            val clock = candidate.clock
            val projection = candidate.projected()
            candidate.capture(projection.first, projection.second)
            assertEquals(clock, candidate.clock)
            assertEquals(candidate.payload.toMap(), SyncReplica.fromJson(candidate.toJson()).payload.toMap())
        }
    }
}
