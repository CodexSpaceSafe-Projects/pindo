package com.pindo.app

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate

class BackupCodecTest {
    private val day = LocalDate.of(2026, 11, 12)
    private fun task(title: String, parent: String? = null): JSONObject = TodoRules.newTask(title, "完整备注", day, null, parent, 0)
    private fun document(): JSONObject = JSONObject().put("version", 1).put("tasks", JSONArray().put(task("任务"))).put("groups", JSONArray())

    @Test fun exportedBackupExcludesReplicaChannelCredentialsAndPreferences() {
        val document = document().put("syncReplica", JSONObject().put("deviceID", "NOT-EXPORTED"))
            .put("syncChannel", "NOT-EXPORTED").put("preferences", JSONObject().put("theme", "dark"))
            .put("secretKey", "TEST-SECRET-SHOULD-NOT-EXPORT").put("recoveryKey", "TEST-RECOVERY-SHOULD-NOT-EXPORT")
        document.getJSONArray("tasks").getJSONObject(0).put("secretKey", "NESTED-SECRET-SHOULD-NOT-EXPORT")
            .getJSONObject("plannedDay").put("secretKey", "NESTED-DATE-SECRET-SHOULD-NOT-EXPORT")
        val encoded = BackupCodec.encode(document)
        val result = JSONObject(encoded)
        assertEquals(setOf("version", "tasks", "groups"), result.keys().asSequence().toSet())
        assertFalse(encoded.contains("NOT-EXPORTED"))
        assertFalse(encoded.contains("TEST-SECRET"))
        assertFalse(encoded.contains("TEST-RECOVERY"))
        assertFalse(encoded.contains("NESTED-SECRET"))
        assertFalse(encoded.contains("NESTED-DATE-SECRET"))
        assertEquals("完整备注", result.getJSONArray("tasks").getJSONObject(0).getString("note"))
    }

    @Test fun importsMacExportWithoutAdoptingPlatformPreferencesOrReplicaIdentity() {
        val source = document()
        source.remove("version")
        source.put("schemaVersion", 1).put("preferences", JSONObject().put("launchAtLogin", true))
            .put("syncState", JSONObject().put("deviceID", "FOREIGN-DEVICE"))
        val imported = BackupCodec.decode(source.toString())
        assertEquals(1, imported.getInt("version"))
        assertEquals(setOf("version", "tasks", "groups"), imported.keys().asSequence().toSet())
        assertEquals("任务", imported.getJSONArray("tasks").getJSONObject(0).getString("title"))
    }

    @Test fun invalidVersionDuplicateIdentifiersAndMalformedUUIDAreRejected() {
        assertThrows(IllegalArgumentException::class.java) { BackupCodec.decode(document().put("version", 9).toString()) }
        val duplicate = document()
        duplicate.getJSONArray("tasks").put(JSONObject(duplicate.getJSONArray("tasks").getJSONObject(0).toString()))
        assertThrows(IllegalArgumentException::class.java) { BackupCodec.decode(duplicate.toString()) }
        val malformed = document()
        malformed.getJSONArray("tasks").getJSONObject(0).put("id", "1-1-1-1-1")
        assertThrows(IllegalArgumentException::class.java) { BackupCodec.decode(malformed.toString()) }
        for (invalidOrder in listOf<Any>("1", 1.5, Long.MAX_VALUE)) {
            val invalid = document()
            invalid.getJSONArray("tasks").getJSONObject(0).put("order", invalidOrder)
            assertThrows(IllegalArgumentException::class.java) { BackupCodec.decode(invalid.toString()) }
        }
        val duplicateNames = document().put("groups", JSONArray()
            .put(JSONObject().put("id", "00000000-0000-0000-0000-000000000001").put("name", "Café").put("colorHex", "#4477AA"))
            .put(JSONObject().put("id", "00000000-0000-0000-0000-000000000002").put("name", "Cafe\u0301").put("colorHex", "#228833")))
        assertThrows(IllegalArgumentException::class.java) { BackupCodec.decode(duplicateNames.toString()) }
    }

    @Test fun invalidHierarchyOrMissingGroupNeverBecomesAnAcceptedBackup() {
        val root = task("父项")
        val child = task("子项", root.getString("id"))
        val grand = task("孙项", child.getString("id"))
        val fourth = task("第四级", grand.getString("id"))
        val deep = document().put("tasks", JSONArray().put(root).put(child).put(grand).put(fourth))
        assertThrows(IllegalArgumentException::class.java) { BackupCodec.decode(deep.toString()) }
        val missingGroup = document()
        missingGroup.getJSONArray("tasks").getJSONObject(0).put("groupID", "00000000-0000-0000-0000-000000000010")
        assertThrows(IllegalArgumentException::class.java) { BackupCodec.decode(missingGroup.toString()) }
    }

    @Test fun oversizedValidJsonBackupIsRejectedBeforeImport() {
        val huge = document()
        huge.getJSONArray("tasks").getJSONObject(0).put("note", "x".repeat(10 * 1024 * 1024 + 1))
        assertThrows(IllegalArgumentException::class.java) { BackupCodec.decode(huge.toString()) }
    }
}
