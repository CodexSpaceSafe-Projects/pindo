package com.pindo.app.sync

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

class SyncInteropV2Test {
    @Test fun sharedMigrationAndOfflineLifecycleTraceMatchBothWireAndProjection() {
        val vectors = generateSequence(File(System.getProperty("user.dir")).canonicalFile) { it.parentFile }
            .map { File(it, "sync-vectors") }.first { it.isDirectory }
        val legacy = JSONObject(File(vectors, "payload-v1.json").readText())
        val expectedUpgrade = JSONObject(File(vectors, "payload-v2-upgraded.json").readText())
        assertEquals(expectedUpgrade.toMap(), SyncReplica.upgradedPayload(legacy).toMap())
        val a = SyncReplica.fresh("00000000-0000-4000-8000-000000000101", version = 2).apply { merge(legacy) }
        val b = SyncReplica.fresh("00000000-0000-4000-8000-000000000102", version = 2).apply { merge(legacy) }
        val pa = a.projected()
        pa.first.getJSONObject(0).put("isProgressExplicit", true).put("updatedAt", 50.0)
            .put("title", "显式进行中 / Explicit parent").put("note", "Mac 离线备注\n保留中文 👩‍💻")
        a.capture(pa.first, pa.second)
        val pb = b.projected()
        pb.first.getJSONObject(0).put("note", "Android 离线备注\n另一个版本 ✅").put("updatedAt", 55.0)
        pb.first.getJSONObject(1).put("phase", "pending").put("isProgressExplicit", false)
            .put("startedAt", JSONObject.NULL).put("completedAt", JSONObject.NULL).put("updatedAt", 55.0)
        b.capture(pb.first, pb.second)
        val replica = SyncReplica.fresh("00000000-0000-4000-8000-000000000103", version = 2).apply { merge(b.payload); merge(a.payload) }
        val expectedPayload = JSONObject(File(vectors, "payload-v2.json").readText())
        val expectedProjection = JSONObject(File(vectors, "projected-v2.json").readText())
        assertEquals(expectedPayload.toMap(), replica.payload.toMap())
        val actual = replica.projected()
        assertEquals(semantic(expectedProjection.getJSONArray("tasks")), semantic(actual.first))
        assertEquals(semantic(expectedProjection.getJSONArray("groups")), semantic(actual.second))
        val restored = SyncReplica.fromJson(replica.toJson())
        assertEquals(replica.payload.toMap(), restored.payload.toMap())
        val output = File("build/test-vectors/payload-v2-kotlin.json")
        output.parentFile.mkdirs()
        output.writeText(restored.payload.toString(2))
    }

    private fun semantic(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is Number -> value.toDouble()
        is JSONObject -> value.keys().asSequence().filter { !value.isNull(it) }.associateWith { semantic(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { semantic(value.get(it)) }
        else -> value
    }
}
