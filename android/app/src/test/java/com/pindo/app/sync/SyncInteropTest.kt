package com.pindo.app.sync

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

class SyncInteropTest {
    @Test fun actualSwiftPayloadProjectsIdenticallyAndEmitsKotlinRoundTrip() {
        val vectors = generateSequence(File(System.getProperty("user.dir")).canonicalFile) { it.parentFile }
            .map { File(it, "sync-vectors") }.first { it.isDirectory }
        val swiftPayload = JSONObject(File(vectors, "payload-v1.json").readText())
        val expected = JSONObject(File(vectors, "projected-v1.json").readText())
        val replica = SyncReplica.fresh("00000000-0000-0000-0000-000000000099")
        replica.merge(swiftPayload)
        val actual = replica.projected()
        // Swift omits nil Codable properties, Android persists explicit JSON nulls.
        assertEquals(semantic(expected.getJSONArray("tasks")), semantic(actual.first))
        assertEquals(semantic(expected.getJSONArray("groups")), semantic(actual.second))
        assertEquals(swiftPayload.toMap(), replica.payload.toMap())
        val restored = SyncReplica.fromJson(replica.toJson())
        assertEquals(replica.payload.toMap(), restored.payload.toMap())
        val output = File("build/test-vectors/payload-v1-kotlin.json")
        output.parentFile.mkdirs()
        output.writeText(replica.payload.toString(2))
    }

    private fun semantic(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is Number -> value.toDouble()
        is JSONObject -> value.keys().asSequence().filter { !value.isNull(it) }.associateWith { semantic(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { semantic(value.get(it)) }
        else -> value
    }
}
