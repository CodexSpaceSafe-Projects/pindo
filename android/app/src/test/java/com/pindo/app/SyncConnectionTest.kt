package com.pindo.app

import com.pindo.app.sync.SyncReplica
import com.pindo.app.sync.SyncSession
import com.pindo.app.sync.toMap
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SyncConnectionTest {
    private val actor = "00000000-0000-0000-0000-000000000001"
    private val id = "11111111-1111-1111-1111-111111111111"
    private fun task(title: String = "资料库 A") = JSONObject().put("id", id).put("title", title).put("note", "备注")
        .put("phase", "pending").put("order", 0).put("createdAt", 1).put("updatedAt", 1)
        .put("startedAt", JSONObject.NULL).put("completedAt", JSONObject.NULL)
        .put("groupID", JSONObject.NULL).put("parentID", JSONObject.NULL)
        .put("plannedDay", JSONObject().put("year", 2026).put("month", 11).put("day", 14))
    private fun document(): JSONObject {
        val tasks = JSONArray().put(task())
        val replica = SyncReplica.fresh(actor, version = 2).apply { capture(tasks, JSONArray()) }
        return JSONObject().put("version", 1).put("tasks", tasks).put("groups", JSONArray()).put("syncReplica", replica.toJson())
            .put("syncChannel", "A").put("syncSession", SyncSession("A").json())
    }

    @Test fun settingsJournalResolvesEverySideOfTheDocumentCommitBoundary() {
        val a = CloudSettings(enabled = true, bucket = "bucket-a", recoveryKey = "01".repeat(32))
        val b = a.copy(bucket = "bucket-b")
        val prepared = SettingsJournal(a, b, "transaction-b")
        val recovered = SettingsJournal.from(JSONObject(prepared.json().toString()))
        assertEquals(a, recovered.resolve(null))
        assertEquals(a, recovered.resolve("older-transaction"))
        assertEquals(b, recovered.resolve("transaction-b"))
        assertEquals(b, SettingsJournal.from(SettingsJournal(b).json()).resolve("transaction-b"))
        val legacy = SettingsJournal.from(a.json())
        assertEquals(a, legacy.active)
        assertFalse(legacy.active.createVault)
    }

    @Test fun disconnectAndReconnectRetainOfflineChangesAndDeletionTombstones() {
        val local = document()
        val oldCloud = SyncReplica.fromJson(local.getJSONObject("syncReplica")).payload()
        var disconnected = SyncConnectionBinding.prepare(local, null, "disconnect")
        val replica = SyncReplica.fromJson(disconnected.getJSONObject("syncReplica"))
        replica.capture(JSONArray(), JSONArray())
        disconnected.put("tasks", JSONArray()).put("syncReplica", replica.toJson())
        val connected = SyncConnectionBinding.prepare(disconnected, "A", "reconnect")
        val restored = SyncReplica.fromJson(connected.getJSONObject("syncReplica"))
        restored.merge(oldCloud)
        assertEquals(0, restored.projected().first.length())
        assertTrue(restored.clock > 1)
        assertFalse(restored.payload().getJSONObject("records").getJSONObject("task:$id").getJSONObject("fields").getJSONObject("\$alive").getBoolean("value"))
    }

    @Test fun switchingBackRestoresThatChannelsReplicaAndVisibleDataWithoutImportingTheOtherChannel() {
        val a = document()
        val aPayload = SyncReplica.fromJson(a.getJSONObject("syncReplica")).payload().toMap()
        var b = SyncConnectionBinding.prepare(a, "B", "switch-b")
        b.getJSONArray("tasks").getJSONObject(0).put("title", "仅资料库 B 的修改")
        val bReplica = SyncReplica.fromJson(b.getJSONObject("syncReplica"))
        bReplica.capture(b.getJSONArray("tasks"), b.getJSONArray("groups"))
        b.put("syncReplica", bReplica.toJson())
        val returned = SyncConnectionBinding.prepare(b, "A", "switch-a")
        assertEquals("资料库 A", returned.getJSONArray("tasks").getJSONObject(0).getString("title"))
        assertEquals(aPayload, SyncReplica.fromJson(returned.getJSONObject("syncReplica")).payload().toMap())
        assertEquals("仅资料库 B 的修改", returned.getJSONObject("syncChannels").getJSONObject("B").getJSONArray("tasks").getJSONObject(0).getString("title"))
        assertFalse(returned.getJSONObject("syncChannels").has("A"))
        assertEquals(setOf("tasks", "groups", "syncReplica", "syncSession"), returned.getJSONObject("syncChannels").getJSONObject("B").keys().asSequence().toSet())
    }

    @Test fun capacityAndArchiveByteFailuresNeverMutateTheActiveChannel() {
        var local = document()
        for (index in 2..8) local = SyncConnectionBinding.prepare(local, "channel-$index", "transaction-$index")
        val before = local.toString()
        assertThrows(IllegalArgumentException::class.java) { SyncConnectionBinding.prepare(local, "ninth-channel", "transaction-9") }
        assertEquals(before, local.toString())
        val first = document(); val initial = first.toString()
        assertThrows(IllegalArgumentException::class.java) { SyncConnectionBinding.prepare(first, "B", "small-limit", maximumArchiveBytes = 20) }
        assertEquals(initial, first.toString())
    }

    @Test fun routeChangesKeepLogicalIdentityAndLegacyMigrationKeepsHistory() {
        val settings = CloudSettings(enabled = true, bucket = "bucket-a", recoveryKey = "01".repeat(32))
        val routed = settings.copy(endpoint = "https://legacy-route.example", region = "cn-other-1")
        assertEquals(SyncChannelIdentity.channelID(settings), SyncChannelIdentity.channelID(routed))
        val legacy = document().put("syncChannel", SyncChannelIdentity.legacyChannelID(settings))
            .put("syncSession", SyncSession(SyncChannelIdentity.legacyChannelID(settings)).json())
        val before = SyncReplica.fromJson(legacy.getJSONObject("syncReplica")).payload().toMap()
        val migrated = SyncChannelIdentity.recoverBinding(legacy, settings)
        assertEquals(SyncChannelIdentity.channelID(settings), migrated.getString("syncChannel"))
        assertEquals(before, SyncReplica.fromJson(migrated.getJSONObject("syncReplica")).payload().toMap())
        assertEquals(SyncChannelIdentity.channelID(settings), migrated.getJSONObject("syncSession").getString("channelID"))
    }

    @Test fun startupWithAnUnrelatedActiveConfigurationFailsClosedWithoutFresheningTheReplica() {
        val a = CloudSettings(enabled = true, bucket = "bucket-a", recoveryKey = "01".repeat(32))
        val b = a.copy(bucket = "bucket-b")
        val local = document().put("syncChannel", SyncChannelIdentity.channelID(a))
        val original = local.toString()
        assertThrows(IllegalArgumentException::class.java) { SyncChannelIdentity.recoverBinding(local, b) }
        assertEquals(original, local.toString())
    }

    @Test fun aVerifiedJoinAdoptsUnboundLegacyTombstonesInsteadOfFresheningVisibleTasks() {
        val source = document()
        val replica = SyncReplica.fromJson(source.getJSONObject("syncReplica"))
        val originalCloud = replica.payload()
        replica.capture(JSONArray(), JSONArray())
        source.put("tasks", JSONArray()).put("syncReplica", replica.toJson())
        source.remove("syncChannel"); source.remove("syncSession")
        val joined = SyncConnectionBinding.prepare(source, "A", "verified-join", preserveUnboundReplica = true)
        val restored = SyncReplica.fromJson(joined.getJSONObject("syncReplica"))
        restored.merge(originalCloud)
        assertEquals(0, restored.projected().first.length())
        assertTrue(restored.clock > 1)
        assertEquals("A", joined.getString("syncChannel"))
    }
}
