package com.pindo.app.sync

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CancellationException

class SyncEngineTest {
    private val key = "01".repeat(32)
    private val crypto = SyncCrypto(key)
    private val channel = "test-channel"
    private val a = "00000000-0000-0000-0000-000000000001"
    private val taskID = "11111111-1111-1111-1111-111111111111"

    private fun task(title: String = "初始事项") = JSONObject().put("id", taskID).put("title", title).put("note", "备注")
        .put("phase", "pending").put("order", 0).put("createdAt", 1).put("updatedAt", 1)
        .put("startedAt", JSONObject.NULL).put("completedAt", JSONObject.NULL)
        .put("groupID", JSONObject.NULL).put("parentID", JSONObject.NULL)
        .put("plannedDay", JSONObject().put("year", 2026).put("month", 11).put("day", 14))
    private fun document(title: String? = "初始事项"): JSONObject {
        val tasks = JSONArray().also { if (title != null) it.put(task(title)) }
        val replica = SyncReplica.fresh(a, version = 2).apply { capture(tasks, JSONArray()) }
        return JSONObject().put("version", 1).put("tasks", tasks).put("groups", JSONArray()).put("syncReplica", replica.toJson())
            .put("syncChannel", channel).put("syncSession", SyncSession(channel).json())
    }
    private fun session(document: JSONObject) = SyncSession.fromDocument(document, channel, crypto)
    private fun changed(document: JSONObject, title: String): JSONObject {
        val next = JSONObject(document.toString())
        next.getJSONArray("tasks").getJSONObject(0).put("title", title).put("updatedAt", 2)
        val replica = SyncReplica.fromJson(next.getJSONObject("syncReplica"))
        replica.capture(next.getJSONArray("tasks"), next.getJSONArray("groups"))
        return next.put("syncReplica", replica.toJson())
    }

    @Test fun durableOutboxReusesCiphertextAfterRestartAndLostPutResponse() {
        val remote = MemoryTransport(crypto.vaultID)
        val engine = SyncEngine(crypto, channel, true, remote)
        val prepared = engine.prepare(document(), engine.fetch(session(document())))
        val restarted = JSONObject(prepared.toString())
        val pending = session(restarted).pendingObject!!
        remote.losePutResponse = true
        engine.publish(pending, emptySet())
        remote.losePutResponse = false
        engine.publish(session(JSONObject(restarted.toString())).pendingObject!!, remote.objects.keys)
        assertEquals(2, remote.uploaded.size)
        assertArrayEquals(remote.uploaded[0].second, remote.uploaded[1].second)
        assertArrayEquals(pending.data, remote.objects.getValue(pending.key))
        val acknowledged = engine.acknowledge(restarted, pending)
        assertNull(session(acknowledged).pendingObject)
        assertFalse(engine.needsUpload(acknowledged))
    }

    @Test fun anOldAcknowledgementCannotEraseANewerLocalEditOrPendingObject() {
        val remote = MemoryTransport(crypto.vaultID)
        val engine = SyncEngine(crypto, channel, true, remote)
        val prepared = engine.prepare(document(), engine.fetch(session(document())))
        val first = session(prepared).pendingObject!!
        val editedWhileUploading = changed(prepared, "上传期间的新修改")
        engine.publish(first, emptySet())
        val acknowledged = engine.acknowledge(editedWhileUploading, first)
        assertEquals("上传期间的新修改", acknowledged.getJSONArray("tasks").getJSONObject(0).getString("title"))
        assertTrue(engine.needsUpload(acknowledged))
        val newer = engine.prepare(acknowledged, engine.fetch(session(acknowledged)))
        val second = session(newer).pendingObject!!
        assertNotEquals(first.key, second.key)
        val late = engine.acknowledge(newer, first)
        assertEquals(second.key, session(late).pendingObject!!.key)
    }

    @Test fun missingAcknowledgedCloudObjectCreatesANewFullCheckpoint() {
        val remote = MemoryTransport(crypto.vaultID)
        val engine = SyncEngine(crypto, channel, true, remote)
        val prepared = engine.prepare(document(), engine.fetch(session(document())))
        val pending = session(prepared).pendingObject!!
        engine.publish(pending, emptySet())
        val acknowledged = engine.acknowledge(prepared, pending)
        remote.objects.clear()
        val joinedEngine = SyncEngine(crypto, channel, false, remote)
        val repaired = joinedEngine.prepare(acknowledged, joinedEngine.fetch(session(acknowledged)))
        val replacement = session(repaired).pendingObject!!
        assertEquals(pending.payloadDigest, replacement.payloadDigest)
        assertNotEquals(pending.key, replacement.key)
        assertEquals(1, repaired.getJSONArray("tasks").length())
    }

    @Test fun corruptDownloadDoesNotApplyAnyPartOfTheCurrentBatch() {
        val remote = MemoryTransport(crypto.vaultID)
        remote.addObject(SyncReplica.fromJson(document("远端一").getJSONObject("syncReplica")).payload())
        remote.addObject(SyncReplica.fromJson(changed(document(), "远端二").getJSONObject("syncReplica")).payload())
        remote.corruptDownload = remote.objects.keys.sorted().last()
        val local = document(null); val original = local.toString()
        val engine = SyncEngine(crypto, channel, false, remote)
        assertThrows(Exception::class.java) { engine.fetch(session(local)) }
        assertEquals(original, local.toString())
        assertEquals(0, remote.uploaded.size)
    }

    @Test fun boundedBatchesResumeFromAtomicallyCommittedKnownObjectsBeforeUploading() {
        val remote = MemoryTransport(crypto.vaultID)
        for (index in 1..3) {
            val replica = SyncReplica.fresh("00000000-0000-0000-0000-00000000000$index", version = 2)
            val value = task("事项$index").put("id", "11111111-1111-1111-1111-11111111111$index")
            replica.capture(JSONArray().put(value), JSONArray())
            remote.addObject(replica.payload())
        }
        val engine = SyncEngine(crypto, channel, false, remote, batchBytes = 1)
        var local = document(null)
        for (index in 1..3) {
            val batch = engine.fetch(session(local))
            assertEquals(index == 3, batch.complete)
            assertTrue(batch.downloadedBytes > 0)
            local = JSONObject(engine.prepare(local, batch).toString()) // Simulate a restart between every batch.
            assertEquals(index, session(local).acknowledgedObjects.size)
            if (index < 3) assertNull(session(local).pendingObject)
        }
        assertEquals(3, local.getJSONArray("tasks").length())
        assertNotNull(session(local).pendingObject)
        assertEquals(0, remote.uploaded.size)
    }

    @Test fun emptyJoinAndReservedLegacyWriterNeverCreateCloudObjects() {
        val remote = MemoryTransport(crypto.vaultID)
        val engine = SyncEngine(crypto, channel, false, remote)
        assertThrows(IllegalArgumentException::class.java) { engine.fetch(session(document())) }
        val legacy = SyncReplica.fresh(a).apply { capture(JSONArray().put(task()), JSONArray()) }
        remote.heads[SyncCrypto.migrationMarkerKey(crypto.vaultID)] = crypto.seal(legacy.payload().toString().toByteArray())
        assertThrows(IllegalStateException::class.java) { engine.fetch(session(document())) }
        assertTrue(remote.uploaded.isEmpty())
    }

    @Test fun markerIsAVerifiedV2CheckpointAndLateV1HeadsStillMerge() {
        val remote = MemoryTransport(crypto.vaultID)
        val legacy = SyncReplica.fresh(a).apply { capture(JSONArray().put(task()), JSONArray()) }
        val legacyKey = "pindo/v1/${crypto.vaultID}/heads/$a.json"
        remote.heads[legacyKey] = crypto.seal(legacy.payload().toString().toByteArray())
        val engine = SyncEngine(crypto, channel, false, remote)
        var local = engine.prepare(document(null), engine.fetch(session(document(null))))
        val pending = session(local).pendingObject!!
        engine.publish(pending, remote.objects.keys)
        local = engine.acknowledge(local, pending)
        engine.ensureMigrationMarker(pending.data)
        assertEquals(2, JSONObject(crypto.openV2(remote.heads.getValue(SyncCrypto.migrationMarkerKey(crypto.vaultID))).toString(Charsets.UTF_8)).getInt("version"))
        legacy.capture(JSONArray().put(task("迟到的旧版修改")), JSONArray())
        remote.heads[legacyKey] = crypto.seal(legacy.payload().toString().toByteArray())
        local = engine.prepare(local, engine.fetch(session(local)))
        assertEquals("迟到的旧版修改", local.getJSONArray("tasks").getJSONObject(0).getString("title"))
    }

    @Test fun cancellationAndGetCorruptionLeaveTheDurableOutboxUnacknowledged() {
        val remote = MemoryTransport(crypto.vaultID)
        val engine = SyncEngine(crypto, channel, true, remote)
        val local = engine.prepare(document(), engine.fetch(session(document())))
        val pending = session(local).pendingObject!!
        remote.cancelPut = true
        assertThrows(CancellationException::class.java) { engine.publish(pending, emptySet()) }
        remote.cancelPut = false; remote.corruptDownload = pending.key
        assertThrows(Exception::class.java) { engine.publish(pending, emptySet()) }
        assertEquals(pending.key, session(local).pendingObject!!.key)
    }

    @Test fun preparingWithoutRemoteChangesMakesDerivedParentStateTheNewBaseline() {
        val childID = "22222222-2222-2222-2222-222222222222"
        val tasks = JSONArray().put(task()).put(task("已完成子项").put("id", childID).put("parentID", taskID)
            .put("phase", "completed").put("completedAt", 2))
        val replica = SyncReplica.fresh(a, version = 2).apply { capture(tasks, JSONArray()) }
        val local = document(null).put("tasks", tasks).put("syncReplica", replica.toJson())
        val engine = SyncEngine(crypto, channel, true, MemoryTransport(crypto.vaultID))
        val prepared = engine.prepare(local, engine.fetch(session(local)))
        assertEquals("completed", prepared.getJSONArray("tasks").getJSONObject(0).getString("phase"))
        val restored = SyncReplica.fromJson(prepared.getJSONObject("syncReplica"))
        val clock = restored.clock
        restored.capture(prepared.getJSONArray("tasks"), prepared.getJSONArray("groups"))
        assertEquals(clock, restored.clock)
        val second = engine.prepare(prepared, engine.fetch(session(prepared)))
        assertEquals(clock, SyncReplica.fromJson(second.getJSONObject("syncReplica")).clock)
        assertEquals(session(prepared).pendingObject!!.key, session(second).pendingObject!!.key)
    }

    @Test fun collisionSuffixRepairWithoutARemoteBatchDoesNotBecomeANewRename() {
        val groupA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        val groupB = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        fun group(id: String) = JSONObject().put("id", id).put("name", "同名分组").put("colorHex", "#4477AA")
        val first = SyncReplica.fresh(a, version = 2).apply { capture(JSONArray(), JSONArray().put(group(groupA))) }
        val other = SyncReplica.fresh("00000000-0000-0000-0000-000000000002", version = 2).apply { capture(JSONArray(), JSONArray().put(group(groupB))) }
        first.merge(other.payload())
        val groups = first.projected().second
        groups.getJSONObject(0).put("name", "修改一个分组名")
        first.capture(JSONArray(), groups)
        val local = document(null).put("groups", groups).put("syncReplica", first.toJson())
        val engine = SyncEngine(crypto, channel, true, MemoryTransport(crypto.vaultID))
        val prepared = engine.prepare(local, engine.fetch(session(local)))
        assertEquals("同名分组", prepared.getJSONArray("groups").getJSONObject(1).getString("name"))
        val restored = SyncReplica.fromJson(prepared.getJSONObject("syncReplica"))
        val clock = restored.clock
        restored.capture(prepared.getJSONArray("tasks"), prepared.getJSONArray("groups"))
        assertEquals(clock, restored.clock)
    }

    @Test fun readOnlyConnectionProbeCannotAuthorizeBindingAnEmptyJoin() {
        val remote = MemoryTransport(crypto.vaultID)
        val join = SyncEngine(crypto, channel, false, remote, batchBytes = 1)
        var bindings = 0
        assertThrows(IllegalArgumentException::class.java) {
            join.probe()
            bindings++
        }
        assertEquals(0, bindings)
        assertTrue(remote.uploaded.isEmpty())
        remote.addObject(SyncReplica.fromJson(document().getJSONObject("syncReplica")).payload())
        val proof = join.probe()
        assertEquals(channel, proof.channelID)
        assertFalse(proof.createVault)
        assertTrue(remote.uploaded.isEmpty())
        val create = SyncEngine(crypto, "new-channel", true, MemoryTransport(crypto.vaultID))
        assertTrue(create.probe().createVault)
    }

    @Test fun changedImmutableObjectVersionsAreReverifiedWithoutAdvancingTheCacheOnCorruption() {
        val remote = MemoryTransport(crypto.vaultID)
        remote.addObject(SyncReplica.fromJson(document().getJSONObject("syncReplica")).payload())
        val objectKey = remote.objects.keys.single()
        val engine = SyncEngine(crypto, channel, false, remote)
        val local = engine.prepare(document(null), engine.fetch(session(document(null))))
        val cached = session(local)
        val original = local.toString()
        val oldETag = cached.objectETags.getValue(objectKey)
        assertEquals(setOf(objectKey), cached.acknowledgedObjects)
        remote.downloaded.clear()
        remote.objects[objectKey] = remote.objects.getValue(objectKey).copyOf().also {
            it[it.lastIndex] = (it.last().toInt() xor 1).toByte()
        }
        assertNotEquals(oldETag, remote.listObjects().single().etag)
        assertThrows(IllegalArgumentException::class.java) { engine.fetch(cached) }
        assertEquals(listOf(objectKey), remote.downloaded)
        assertEquals(original, local.toString())
        assertEquals(oldETag, session(local).objectETags[objectKey])
        assertTrue(remote.uploaded.isEmpty())
    }

    @Test fun olderCachesWithoutObjectVersionsAreRevalidatedAndDeletedVersionsArePruned() {
        val remote = MemoryTransport(crypto.vaultID)
        remote.addObject(SyncReplica.fromJson(document().getJSONObject("syncReplica")).payload())
        val objectKey = remote.objects.keys.single()
        val engine = SyncEngine(crypto, channel, false, remote)
        val local = engine.prepare(document(null), engine.fetch(session(document(null))))
        local.getJSONObject("syncSession").remove("objectETags")
        val legacyCache = session(local)
        assertEquals(setOf(objectKey), legacyCache.acknowledgedObjects)
        assertTrue(legacyCache.objectETags.isEmpty())
        remote.downloaded.clear()
        val refreshed = engine.fetch(legacyCache)
        assertEquals(listOf(objectKey), remote.downloaded)
        assertEquals(remote.listObjects().single().etag, refreshed.session.objectETags[objectKey])
        val persisted = engine.prepare(local, refreshed)
        assertEquals(refreshed.session.objectETags, session(JSONObject(persisted.toString())).objectETags)
        remote.objects.clear()
        val pruned = engine.fetch(session(persisted))
        assertTrue(pruned.session.acknowledgedObjects.isEmpty())
        assertTrue(pruned.session.objectETags.isEmpty())
    }

    @Test fun acknowledgementsDoNotInventAnUnobservedObjectVersion() {
        val remote = MemoryTransport(crypto.vaultID)
        val engine = SyncEngine(crypto, channel, true, remote)
        val prepared = engine.prepare(document(), engine.fetch(session(document())))
        val pending = session(prepared).pendingObject!!
        engine.publish(pending, emptySet())
        val acknowledged = engine.acknowledge(prepared, pending)
        assertNull(session(acknowledged).objectETags[pending.key])
        remote.downloaded.clear()
        val verified = engine.fetch(session(acknowledged))
        assertEquals(listOf(pending.key), remote.downloaded)
        assertEquals(remote.listObjects().single().etag, verified.session.objectETags[pending.key])
    }

    @Test fun malformedLocalObjectVersionMetadataFailsClosed() {
        val remote = MemoryTransport(crypto.vaultID)
        remote.addObject(SyncReplica.fromJson(document().getJSONObject("syncReplica")).payload())
        val engine = SyncEngine(crypto, channel, false, remote)
        val local = engine.prepare(document(null), engine.fetch(session(document(null))))
        val objectKey = remote.objects.keys.single()
        for (map in listOf(
            JSONObject().put("pindo/v2/${"a".repeat(32)}/objects/${"b".repeat(64)}.json", "etag"),
            JSONObject().put(objectKey, ""), JSONObject().put(objectKey, "etag\r\nInjected: value")
        )) {
            val corrupted = JSONObject(local.toString())
            corrupted.getJSONObject("syncSession").put("objectETags", map)
            assertThrows(IllegalArgumentException::class.java) { session(corrupted) }
        }
    }

    private class MemoryTransport(private val vault: String) : SyncTransport {
        val objects = linkedMapOf<String, ByteArray>()
        val heads = linkedMapOf<String, ByteArray>()
        val uploaded = mutableListOf<Pair<String, ByteArray>>()
        val downloaded = mutableListOf<String>()
        var losePutResponse = false
        var cancelPut = false
        var corruptDownload: String? = null
        fun addObject(payload: JSONObject) {
            val data = SyncCrypto("01".repeat(32)).sealV2(payload.toString().toByteArray())
            objects[SyncCrypto.objectKey(vault, data)] = data
        }
        override fun listHeads() = heads.map { SyncRemoteHead(it.key, digest(it.value)) }
        override fun listObjects() = objects.map { SyncRemoteHead(it.key, digest(it.value)) }
        override fun download(key: String, expectedETag: String?): ByteArray {
            downloaded.add(key)
            val data = objects[key] ?: heads[key] ?: error("not found")
            if (expectedETag != null) require(expectedETag == digest(data))
            return if (key == corruptDownload) data.copyOf().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() } else data.copyOf()
        }
        override fun upload(data: ByteArray, key: String) {
            if (cancelPut) throw CancellationException("cancelled")
            uploaded.add(key to data.copyOf())
            if (key.startsWith("pindo/v2/")) objects[key] = data.copyOf() else heads[key] = data.copyOf()
            if (losePutResponse) error("response lost")
        }
        override fun cancel() { cancelPut = true }
        private fun digest(data: ByteArray) = SyncCrypto.hex(java.security.MessageDigest.getInstance("SHA-256").digest(data))
    }
}
