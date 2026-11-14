package com.pindo.app

import com.pindo.app.sync.SyncReplica
import com.pindo.app.sync.SyncSession
import com.pindo.app.sync.SyncCrypto
import org.json.JSONObject

/** Credential journal. The data-file transaction marker decides the single active configuration. */
internal data class SettingsJournal(val active: CloudSettings = CloudSettings(), val pending: CloudSettings? = null, val transactionID: String? = null) {
    fun resolve(documentTransaction: String?): CloudSettings = if (pending != null && transactionID == documentTransaction) pending else active
    fun json(): JSONObject = JSONObject().put("schemaVersion", 2).put("active", active.json())
        .put("pending", pending?.json() ?: JSONObject.NULL).put("transactionID", transactionID ?: JSONObject.NULL)
    companion object {
        fun from(value: JSONObject): SettingsJournal {
            // Existing encrypted v1 plaintext consisted of CloudSettings itself.
            if (!value.has("schemaVersion")) return SettingsJournal(CloudSettings.from(value))
            require(value.getInt("schemaVersion") == 2) { "不支持此同步配置版本。" }
            val pending = value.optJSONObject("pending")?.let(CloudSettings::from)
            val transaction = if (value.isNull("transactionID")) null else value.getString("transactionID")
            require((pending == null) == (transaction == null) && (transaction == null || transaction.isNotBlank())) { "同步配置事务无效。" }
            return SettingsJournal(CloudSettings.from(value.getJSONObject("active")), pending, transaction)
        }
    }
}

internal object SyncChannelIdentity {
    fun channelID(settings: CloudSettings): String = hash("PindoSync/v2\n${settings.bucket.lowercase()}\n${SyncCrypto(settings.recoveryKey).vaultID}")
    fun legacyChannelID(settings: CloudSettings): String = hash("${settings.endpoint}|${settings.bucket}|${settings.region}|${SyncCrypto(settings.recoveryKey).vaultID}")

    fun recoverBinding(document: JSONObject, settings: CloudSettings): JSONObject {
        val next = adoptLegacy(document, settings)
        val bound = next.optString("syncChannel")
        require(bound.isNotBlank() || next.optJSONObject("syncSession") == null) { "本机同步资料库绑定缺失，已停止自动连接。请重新保存设置。" }
        require(bound.isBlank() || bound == channelID(settings)) { "同步配置与本机资料库绑定不一致。请显式重新连接，未上传本机资料。" }
        return next
    }

    fun adoptLegacy(source: JSONObject, settings: CloudSettings): JSONObject {
        val current = channelID(settings); val legacy = legacyChannelID(settings)
        val next = JSONObject(source.toString())
        fun migrate(value: JSONObject) {
            value.optJSONObject("syncSession")?.let { session ->
                if (session.optString("channelID") == legacy) session.put("channelID", current)
            }
        }
        if (next.optString("syncChannel") == legacy) { next.put("syncChannel", current); migrate(next) }
        next.optJSONObject("syncChannels")?.let { archives ->
            if (archives.has(legacy) && !archives.has(current)) {
                val archived = archives.getJSONObject(legacy); migrate(archived)
                archives.put(current, archived); archives.remove(legacy)
            }
        }
        return next
    }

    private fun hash(value: String): String = java.security.MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
}

/** Archives are local only. Switching back restores that channel, including its tombstones/outbox. */
internal object SyncConnectionBinding {
    const val TRANSACTION = "syncConnectionTransaction"
    private val archiveFields = listOf("tasks", "groups", "syncReplica", "syncSession")

    fun prepare(document: JSONObject, targetChannel: String?, transactionID: String, maximumArchiveBytes: Int = 64 * 1024 * 1024, preserveUnboundReplica: Boolean = false): JSONObject {
        val next = JSONObject(document.toString()).put(TRANSACTION, transactionID)
        if (targetChannel == null) return next // Disconnect preserves all causal history.
        val oldChannel = document.optString("syncChannel").takeIf { it.isNotBlank() }
        val archives = document.optJSONObject("syncChannels")?.let { JSONObject(it.toString()) } ?: JSONObject()
        require(archives.length() <= 8) { "本机保存的同步资料库超过安全上限。" }
        if (oldChannel != targetChannel) {
            if (oldChannel != null) archives.put(oldChannel, snapshot(document))
            val restored = archives.optJSONObject(targetChannel)
            if (restored != null) {
                require(restored.keys().asSequence().toSet().all { it in archiveFields }) { "本机资料库归档无效。" }
                archiveFields.forEach { field -> if (restored.has(field)) next.put(field, restored.get(field)) else next.remove(field) }
                archives.remove(targetChannel)
            } else if (oldChannel == null && preserveUnboundReplica && next.optJSONObject("syncReplica") != null) {
                // A proven existing vault may be the source of a disconnected v1 replica.
                // Keep its tombstones instead of reseeding the visible projection.
                next.put("syncSession", SyncSession(targetChannel).json())
            } else {
                // An unknown channel starts by merging the visible local tasks, never old channel stamps.
                next.put("syncReplica", SyncReplica.fresh(version = 2).apply {
                    capture(next.getJSONArray("tasks"), next.getJSONArray("groups"))
                }.toJson())
                next.put("syncSession", SyncSession(targetChannel).json())
            }
        }
        require(archives.length() + 1 <= 8) { "本机最多保存 8 个同步资料库；为保护离线历史，未自动删除旧库。" }
        require(archives.toString().toByteArray(Charsets.UTF_8).size <= maximumArchiveBytes) { "本机资料库归档超过 64 MiB，已保留原资料库并取消切换。" }
        next.put("syncChannels", archives).put("syncChannel", targetChannel)
        val replica = next.optJSONObject("syncReplica")?.let { SyncReplica.fromJson(it).upgraded() } ?: SyncReplica.fresh(version = 2)
        replica.rotateActor()
        replica.capture(next.getJSONArray("tasks"), next.getJSONArray("groups"))
        replica.merge(SyncReplica.fresh(version = 2).payload())
        val projected = replica.projected()
        next.put("tasks", projected.first).put("groups", projected.second).put("syncReplica", replica.toJson())
        if (next.optJSONObject("syncSession") == null) next.put("syncSession", SyncSession(targetChannel).json())
        return next
    }

    private fun snapshot(document: JSONObject): JSONObject = JSONObject().also { result ->
        archiveFields.forEach { field -> if (document.has(field)) result.put(field, document.get(field)) }
    }
}
