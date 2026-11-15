package com.pindo.app.sync

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class SyncInteropTest {
    @Test fun sharedCurrentPayloadMatchesSwiftProjectionAndRoundTrips() {
        val vectors = generateSequence(File(System.getProperty("user.dir")).canonicalFile) { it.parentFile }
            .map { File(it, "sync-vectors") }.first { it.isDirectory }
        val payload = JSONObject(File(vectors, "payload.json").readText())
        val expected = JSONObject(File(vectors, "projected.json").readText())
        val replica = SyncReplica.fresh("00000000-0000-4000-8000-000000000103").apply { merge(payload) }
        assertEquals(payload.toMap(), replica.payload.toMap())
        val actual = replica.projected()
        assertEquals(semantic(expected.getJSONArray("tasks")), semantic(actual.first))
        assertEquals(semantic(expected.getJSONArray("groups")), semantic(actual.second))
        val restored = SyncReplica.fromJson(replica.toJson())
        assertEquals(replica.payload.toMap(), restored.payload.toMap())
        val clock = restored.clock
        restored.capture(actual.first, actual.second)
        assertEquals(clock, restored.clock)
        assertThrows(IllegalArgumentException::class.java) { replica.merge(JSONObject(payload.toString()).put("version", 1)) }
    }

    private fun semantic(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is Number -> value.toDouble()
        is JSONObject -> value.keys().asSequence().filter { !value.isNull(it) }.associateWith { semantic(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { semantic(value.get(it)) }
        else -> value
    }
}
