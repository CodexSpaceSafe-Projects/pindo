package com.pindo.app.sync

import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.math.BigDecimal
import java.util.Base64
import java.util.concurrent.CancellationException

/** A synchronous, injectable transport. Run the engine on a serial worker. */
internal interface SyncTransport {
    fun listHeads(): List<SyncRemoteHead>
    fun listObjects(): List<SyncRemoteHead>
    fun download(key: String, expectedETag: String? = null): ByteArray
    fun upload(data: ByteArray, key: String)
    fun cancel()
}

internal data class PendingSyncObject(val key: String, val data: ByteArray, val payloadDigest: String) {
    fun json(): JSONObject = JSONObject().put("key", key).put("data", Base64.getEncoder().encodeToString(data)).put("payloadDigest", payloadDigest)
}

/** This metadata and the replica are always committed in the same data.json. */
internal data class SyncSession(
    val channelID: String,
    val acknowledgedObjects: Set<String> = emptySet(),
    val legacyETags: Map<String, String> = emptyMap(),
    val pendingObject: PendingSyncObject? = null,
    val acknowledgedPayloadDigest: String? = null,
    val acknowledgedObjectKey: String? = null,
    val joined: Boolean = false,
    val objectETags: Map<String, String> = emptyMap()
) {
    fun json(): JSONObject = JSONObject().put("version", 2).put("channelID", channelID)
        .put("acknowledgedObjects", JSONArray(acknowledgedObjects.sorted()))
        .put("legacyETags", JSONObject(legacyETags)).put("pendingObject", pendingObject?.json() ?: JSONObject.NULL)
        .put("acknowledgedPayloadDigest", acknowledgedPayloadDigest ?: JSONObject.NULL)
        .put("acknowledgedObjectKey", acknowledgedObjectKey ?: JSONObject.NULL).put("joined", joined)
        .put("objectETags", JSONObject(objectETags))

    companion object {
        fun fromDocument(document: JSONObject, channelID: String, crypto: SyncCrypto): SyncSession {
            val value = document.optJSONObject("syncSession") ?: return SyncSession(channelID)
            require(value.getInt("version") == 2 && value.getString("channelID") == channelID) { "同步状态与资料库不一致，请重新连接。" }
            val array = value.getJSONArray("acknowledgedObjects")
            require(array.length() <= 10_000) { "同步对象缓存超过安全上限。" }
            val keys = (0 until array.length()).map { array.getString(it) }.toSet()
            require(keys.size == array.length() && keys.all { isObjectKey(it, crypto.vaultID) }) { "本机同步对象缓存无效。" }
            val rawTags = value.getJSONObject("legacyETags")
            require(rawTags.length() <= 101)
            val tags = rawTags.keys().asSequence().associateWith { rawTags.getString(it) }
            require(tags.all { (key, tag) -> key.startsWith("pindo/v1/${crypto.vaultID}/heads/") && validSyncETag(tag) })
            // Older local sessions have no immutable-object versions. They must
            // read cached objects once rather than trusting an unversioned cache.
            val rawObjectTags = if (value.has("objectETags")) value.getJSONObject("objectETags") else JSONObject()
            require(rawObjectTags.length() <= 10_000) { "同步对象版本缓存超过安全上限。" }
            val objectTags = rawObjectTags.keys().asSequence().associateWith { rawObjectTags.getString(it) }
            require(objectTags.all { (key, tag) -> key in keys && isObjectKey(key, crypto.vaultID) && validSyncETag(tag) }) {
                "本机同步对象版本缓存无效。"
            }
            val pending = value.optJSONObject("pendingObject")?.let {
                val data = Base64.getDecoder().decode(it.getString("data"))
                val key = it.getString("key")
                val digest = it.getString("payloadDigest")
                SyncCrypto.validateObject(data, key, crypto.vaultID)
                require(digest.matches(Regex("[0-9a-f]{64}")))
                val payload = payload(crypto.openV2(data))
                require(payload.getInt("version") == 2 && digest == payloadDigest(payload)) { "本机待上传资料无效。" }
                PendingSyncObject(key, data, digest)
            }
            val acknowledgedDigest = value.nullableString("acknowledgedPayloadDigest")
            val acknowledgedKey = value.nullableString("acknowledgedObjectKey")
            require(acknowledgedDigest == null || acknowledgedDigest.matches(Regex("[0-9a-f]{64}")))
            require(acknowledgedKey == null || isObjectKey(acknowledgedKey, crypto.vaultID))
            require((acknowledgedDigest == null) == (acknowledgedKey == null))
            return SyncSession(channelID = channelID, acknowledgedObjects = keys, legacyETags = tags, pendingObject = pending,
                acknowledgedPayloadDigest = acknowledgedDigest, acknowledgedObjectKey = acknowledgedKey,
                joined = value.optBoolean("joined", acknowledgedKey != null || keys.isNotEmpty()), objectETags = objectTags)
        }
    }
}

internal data class RemoteSyncBatch(
    val payload: JSONObject?, val session: SyncSession, val listedObjects: Set<String>,
    val complete: Boolean, val markerPresent: Boolean, val downloadedBytes: Long
)

internal data class VerifiedSyncConnection(val channelID: String, val createVault: Boolean)

/**
 * Immutable cloud objects + an exact-byte durable outbox. No method mutates its
 * input document; the owner validates its current revision before committing.
 */
internal class SyncEngine(
    private val crypto: SyncCrypto,
    private val channelID: String,
    private val createVault: Boolean,
    private val transport: SyncTransport,
    private val batchBytes: Long = 64L * 1024 * 1024
) {
    /** Read-only connection validation. No binding, local persistence, PUT or marker write. */
    fun probe(): VerifiedSyncConnection {
        fetch(SyncSession(channelID))
        return VerifiedSyncConnection(channelID, createVault)
    }

    fun fetch(session: SyncSession): RemoteSyncBatch {
        require(session.channelID == channelID)
        val heads = transport.listHeads()
        val objects = transport.listObjects()
        val listed = objects.map { it.key }.toSet()
        require(listed.size == objects.size && listed.size <= 10_000 && listed.all { isObjectKey(it, crypto.vaultID) } &&
            objects.all { validSyncETag(it.etag) }) { "同步对象列表无效。" }
        val aggregate = SyncReplica.fresh(version = 2)
        var hasPayload = false
        var bytes = 0L
        var complete = true
        var joined = session.joined
        var markerPresent = false
        val known = session.acknowledgedObjects.intersect(listed).toMutableSet()
        val objectTags = session.objectETags.filterKeys { it in known }.toMutableMap()
        val tags = session.legacyETags.filterKeys { key -> heads.any { it.key == key } }.toMutableMap()
        val marker = SyncCrypto.migrationMarkerKey(crypto.vaultID)

        fun merge(data: ByteArray, version: Int) {
            val value = payload(data)
            require(value.getInt("version") == version) { "同步资料来自不支持的协议版本。" }
            aggregate.merge(value); hasPayload = true; joined = true
        }
        for (head in heads.sortedBy { if (it.key == marker) "" else it.key }) {
            if (head.key == marker) markerPresent = true
            if (tags[head.key] == head.etag) { joined = true; continue }
            if (bytes >= batchBytes) { complete = false; break }
            val data = transport.download(head.key, head.etag); bytes += data.size
            if (head.key == marker) {
                try { merge(crypto.openV2(data), 2) }
                catch (failure: CancellationException) { throw failure }
                catch (failure: Exception) { throw IllegalStateException("升级保留路径被旧设备占用或升级标记损坏，已停止迁移。", failure) }
            } else merge(crypto.open(data), 1)
            tags[head.key] = head.etag
        }
        if (complete) for (head in objects.sortedBy { it.key }) {
            if (head.key in known && objectTags[head.key] == head.etag) { joined = true; continue }
            if (bytes >= batchBytes) { complete = false; break }
            val data = transport.download(head.key); bytes += data.size
            SyncCrypto.validateObject(data, head.key, crypto.vaultID)
            merge(crypto.openV2(data), 2)
            known.add(head.key)
            objectTags[head.key] = head.etag
        }
        // Joining a typo/incorrect-key namespace never silently creates a vault.
        require(createVault || joined || !complete) { "没有找到可解密的同步资料。加入设备请检查存储桶和恢复密钥；创建新资料库请使用生成新密钥。" }
        val next = session.copy(acknowledgedObjects = known, legacyETags = tags, objectETags = objectTags, joined = joined || createVault)
        return RemoteSyncBatch(if (hasPayload) aggregate.payload() else null, next, listed, complete, markerPresent, bytes)
    }

    fun prepare(document: JSONObject, batch: RemoteSyncBatch): JSONObject {
        val next = JSONObject(document.toString())
        val replica = next.optJSONObject("syncReplica")?.let { SyncReplica.fromJson(it).upgraded() } ?: SyncReplica.fresh(version = 2)
        replica.capture(next.getJSONArray("tasks"), next.getJSONArray("groups"))
        // Even an empty remote batch advances the baseline to the canonical
        // projection, so hierarchy repair is never recaptured as a user edit.
        replica.merge(batch.payload ?: SyncReplica.fresh(version = 2).payload())
        val projection = replica.projected()
        next.put("tasks", projection.first).put("groups", projection.second).put("syncReplica", replica.toJson())
        // Preserve a pending object installed after the network snapshot, if any.
        val current = SyncSession.fromDocument(document, channelID, crypto)
        var session = batch.session.copy(pendingObject = current.pendingObject,
            acknowledgedObjectKey = current.acknowledgedObjectKey, acknowledgedPayloadDigest = current.acknowledgedPayloadDigest)
        if (batch.complete && session.pendingObject == null) {
            val value = replica.payload()
            val digest = payloadDigest(value)
            val missing = session.acknowledgedObjectKey == null || session.acknowledgedObjectKey !in batch.listedObjects
            if (missing || session.acknowledgedPayloadDigest != digest) {
                val data = crypto.sealV2(canonical(value).toByteArray(Charsets.UTF_8))
                session = session.copy(pendingObject = PendingSyncObject(SyncCrypto.objectKey(crypto.vaultID, data), data, digest))
            }
        }
        next.put("syncSession", session.json())
        return next
    }

    /** PUT retries always reuse the persisted bytes. A lost PUT response is checked with GET. */
    fun publish(pending: PendingSyncObject, listedObjects: Set<String>) {
        SyncCrypto.validateObject(pending.data, pending.key, crypto.vaultID)
        require(listedObjects.size < 10_000 || pending.key in listedObjects) { "同步对象已达到上限，待上传资料已保留在本机。" }
        try { transport.upload(pending.data, pending.key) }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) {
            try { verify(pending); return }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { throw failure }
        }
        verify(pending)
    }

    private fun verify(pending: PendingSyncObject) {
        val stored = transport.download(pending.key)
        SyncCrypto.validateObject(stored, pending.key, crypto.vaultID)
        require(stored.contentEquals(pending.data)) { "云端尚未确认待上传资料，本机发件箱已保留。" }
    }

    fun acknowledge(document: JSONObject, sent: PendingSyncObject): JSONObject {
        val session = SyncSession.fromDocument(document, channelID, crypto)
        val pending = session.pendingObject
        if (pending == null || pending.key != sent.key || !pending.data.contentEquals(sent.data)) return JSONObject(document.toString())
        val next = JSONObject(document.toString())
        next.put("syncSession", session.copy(pendingObject = null,
            acknowledgedObjects = session.acknowledgedObjects + sent.key,
            acknowledgedObjectKey = sent.key, acknowledgedPayloadDigest = sent.payloadDigest,
            objectETags = session.objectETags - sent.key, joined = true).json())
        return next
    }

    /** Publish the v1 stop marker only after a v2 checkpoint is durably verified. */
    fun ensureMigrationMarker(checkpoint: ByteArray): Boolean {
        val value = payload(crypto.openV2(checkpoint))
        require(value.getInt("version") == 2)
        val key = SyncCrypto.migrationMarkerKey(crypto.vaultID)
        // A pre-existing reserved v1 writer must never be overwritten.
        val existing = transport.listHeads().firstOrNull { it.key == key }
        if (existing != null) {
            val marker = payload(crypto.openV2(transport.download(key, existing.etag)))
            require(marker.getInt("version") == 2) { "升级保留路径被旧设备占用，已停止迁移。" }
            return true // Another writer published a checkpoint after our scan; import it next.
        }
        try { transport.upload(checkpoint, key) }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) {
            try {
                val confirmed = transport.download(key)
                require(payload(crypto.openV2(confirmed)).getInt("version") == 2)
                return !confirmed.contentEquals(checkpoint)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { throw failure }
        }
        val confirmed = transport.download(key)
        require(payload(crypto.openV2(confirmed)).getInt("version") == 2) { "云端升级标记未能验证。" }
        return !confirmed.contentEquals(checkpoint)
    }

    fun downloadCheckpoint(key: String): ByteArray = transport.download(key).also {
        SyncCrypto.validateObject(it, key, crypto.vaultID)
        require(payload(crypto.openV2(it)).getInt("version") == 2)
    }

    fun needsUpload(document: JSONObject): Boolean {
        val session = SyncSession.fromDocument(document, channelID, crypto)
        val replica = SyncReplica.fromJson(document.getJSONObject("syncReplica"))
        return session.pendingObject != null || payloadDigest(replica.payload()) != session.acknowledgedPayloadDigest
    }
}

private fun JSONObject.nullableString(key: String): String? = if (isNull(key)) null else getString(key)
private fun isObjectKey(key: String, vaultID: String): Boolean = key.matches(Regex("pindo/v2/$vaultID/objects/[0-9a-f]{64}\\.json"))
private fun validSyncETag(value: String): Boolean = value.isNotBlank() && value.toByteArray(Charsets.UTF_8).size <= 1024 &&
    value.none { it.code < 32 || it.code == 127 }
private fun payload(bytes: ByteArray): JSONObject {
    val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes)).toString()
    return SyncReplica.validatedPayload(JSONObject(text))
}
internal fun payloadDigest(value: JSONObject): String = SyncCrypto.hex(MessageDigest.getInstance("SHA-256").digest(canonical(value).toByteArray(Charsets.UTF_8)))
private fun canonical(value: Any?): String = when (value) {
    null, JSONObject.NULL -> "null"
    is JSONObject -> value.keys().asSequence().toList().sorted().joinToString(",", "{", "}") { JSONObject.quote(it) + ":" + canonical(value.get(it)) }
    is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.get(it)) }
    is String -> JSONObject.quote(value)
    is Number -> BigDecimal(value.toString()).stripTrailingZeros().toPlainString()
    is Boolean -> value.toString()
    else -> error("不支持的同步数值。")
}
