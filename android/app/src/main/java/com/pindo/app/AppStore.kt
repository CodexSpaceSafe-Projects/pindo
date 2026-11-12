package com.pindo.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.pindo.app.sync.BitifulClient
import com.pindo.app.sync.BitifulConfiguration
import com.pindo.app.sync.BitifulCredentials
import com.pindo.app.sync.SyncCrypto
import com.pindo.app.sync.SyncReplica
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.util.UUID

data class AppState(val tasks: List<Todo> = emptyList(), val groups: List<TodoGroup> = emptyList(),
    val error: String? = null, val readOnly: Boolean = false, val syncing: Boolean = false,
    val syncEnabled: Boolean = false, val syncStatus: String = "仅保存在本机")

class AppStore(application: Application) : AndroidViewModel(application) {
    private val storage = DocumentStorage(application)
    private val secrets = SecretStorage(application)
    private var document = emptyDocument()
    private var cloud = CloudSettings()
    private val mutable = MutableStateFlow(AppState())
    val state: StateFlow<AppState> = mutable
    private var poll: Job? = null
    private var scheduledSync: Job? = null
    private var syncBusy = false
    private var syncAgain = false
    private var channelGeneration = 0
    private var failures = 0
    private val etags = mutableMapOf<String, String>()
    private var uploadedPayload: String? = null
    private var editing = false

    init {
        try {
            document = storage.read() ?: emptyDocument().also(storage::write)
            validateDocument(document)
            document.optJSONObject("syncReplica")?.let { SyncReplica.fromJson(it) }
            if (!state.value.readOnly) publish()
        } catch (_: Exception) {
            mutable.value = AppState(error = "无法读取本机资料，原文件已保留。请先备份应用数据，再检查或重新安装。", readOnly = true)
        }
        try {
            cloud = secrets.read() ?: CloudSettings()
            if (cloud.enabled && !state.value.readOnly && document.optString("syncChannel") != channelID(cloud)) {
                val next = JSONObject(document.toString())
                val replica = SyncReplica.fresh()
                replica.capture(next.getJSONArray("tasks"), next.getJSONArray("groups"))
                next.put("syncReplica", replica.toJson()).put("syncChannel", channelID(cloud))
                storage.write(next); document = next
            }
            if (!state.value.readOnly) publish()
        }
        catch (_: Exception) { error("无法解密本机保存的同步凭据。待办仍可离线使用，请重新配置同步。") }
    }

    fun settings(): CloudSettings = cloud.copy()
    fun dismissError() { if (!state.value.readOnly) mutable.value = state.value.copy(error = null) }
    fun generateRecoveryKey(): String = SyncCrypto.generateKey()

    fun saveSettings(value: CloudSettings): Boolean {
        if (state.value.readOnly) return false
        return try {
            val normalized = value.copy(endpoint = value.endpoint.trim().trimEnd('/'), bucket = value.bucket.trim(),
                region = value.region.trim(), accessKey = value.accessKey.trim(), secretKey = value.secretKey.trim(),
                recoveryKey = value.recoveryKey.filterNot(Char::isWhitespace).lowercase())
            if (normalized.enabled) {
                SyncCrypto(normalized.recoveryKey)
                BitifulClient(BitifulConfiguration(normalized.endpoint, normalized.bucket, normalized.region),
                    BitifulCredentials(normalized.accessKey, normalized.secretKey))
                require(normalized.accessKey.isNotBlank() && normalized.secretKey.isNotBlank()) { "请填写 Access Key 和 Secret Key。" }
            }
            val changedVault = normalized.recoveryKey != cloud.recoveryKey || normalized.bucket != cloud.bucket || normalized.endpoint != cloud.endpoint || normalized.region != cloud.region
            val next = JSONObject(document.toString())
            if (normalized.enabled && (changedVault || next.isNull("syncReplica"))) {
                val replica = SyncReplica.fresh()
                replica.capture(next.getJSONArray("tasks"), next.getJSONArray("groups"))
                next.put("syncReplica", replica.toJson())
            }
            if (normalized.enabled) next.put("syncChannel", channelID(normalized))
            // Credentials are encrypted first; a failed document write rolls them back.
            // The channel marker also repairs a process interruption between these two files.
            secrets.write(normalized)
            try { storage.write(next) }
            catch (failure: Exception) { runCatching { secrets.write(cloud) }; throw failure }
            document = next
            cloud = normalized
            channelGeneration++
            etags.clear(); uploadedPayload = null; failures = 0
            mutable.value = state.value.copy(error = null, syncStatus = if (cloud.enabled) "等待同步" else "仅保存在本机")
            publish()
            if (cloud.enabled) requestSync(immediate = true)
            true
        } catch (e: Exception) { error(e.message?.take(180) ?: "无法保存同步配置。"); false }
    }

    fun addTask(title: String, note: String, day: LocalDate, groupID: String?, parentID: String?): Boolean = mutate { next ->
        val tasks = next.getJSONArray("tasks")
        TodoRules.validateParent(tasks.objects().map(Todo::from), null, parentID)
        tasks.put(TodoRules.newTask(title, note, day, groupID, parentID, tasks.objects().maxOfOrNull { it.getInt("order") }?.plus(1) ?: 0))
        next.put("tasks", TodoRules.reconcile(tasks))
    }

    fun editTask(id: String, title: String, note: String, day: LocalDate, groupID: String?, parentID: String?): Boolean = mutate { next ->
        require(title.isNotBlank()) { "请填写事项内容。" }
        val tasks = next.getJSONArray("tasks")
        TodoRules.validateParent(tasks.objects().map(Todo::from), id, parentID)
        val task = tasks.objects().firstOrNull { it.getString("id").equals(id, true) } ?: kotlin.error("找不到这条待办。")
        task.put("title", title.trim()).put("note", note).put("plannedDay", TodoRules.dayJSON(day))
            .put("groupID", groupID ?: JSONObject.NULL).put("parentID", parentID ?: JSONObject.NULL).put("updatedAt", swiftNow())
        next.put("tasks", TodoRules.reconcile(tasks))
    }

    fun advancePhase(id: String) = mutate { next ->
        val task = next.getJSONArray("tasks").objects().map(Todo::from).first { it.id == id }
        val phase = when (task.phase) { "pending" -> "inProgress"; "inProgress" -> "completed"; else -> "pending" }
        next.put("tasks", TodoRules.setPhase(next.getJSONArray("tasks"), id, phase))
    }

    fun deleteTask(id: String) = mutate { next ->
        val tasks = next.getJSONArray("tasks").objects()
        val removed = TodoRules.descendants(tasks.map(Todo::from), id)
        next.put("tasks", TodoRules.reconcile(tasks.filter { it.getString("id").lowercase() !in removed }.jsonArray()))
    }

    fun move(id: String, offset: Int) = mutate { next ->
        val items = next.getJSONArray("tasks").objects()
        val task = items.map(Todo::from).first { it.id == id }
        val siblings = items.map(Todo::from).filter { it.parentID == task.parentID && (it.phase == "completed") == (task.phase == "completed") }
            .sortedWith(compareBy<Todo> { it.order }.thenBy { it.id })
        val index = siblings.indexOfFirst { it.id == id }
        if (index + offset in siblings.indices) {
            val ordered = siblings.toMutableList().apply { add(index + offset, removeAt(index)) }
            ordered.forEachIndexed { order, item -> items.first { it.getString("id").equals(item.id, true) }.put("order", order) }
        }
    }

    fun addGroup(name: String, color: String): Boolean = mutate { next ->
        require(name.isNotBlank()) { "请填写分组名称。" }
        require(next.getJSONArray("groups").objects().none { it.getString("name") == name.trim() }) { "分组名称已存在。" }
        require(color.matches(Regex("#[0-9a-fA-F]{6}"))) { "分组颜色无效。" }
        next.getJSONArray("groups").put(JSONObject().put("id", UUID.randomUUID().toString()).put("name", name.trim()).put("colorHex", color))
    }

    fun deleteGroup(id: String) = mutate { next ->
        next.put("groups", next.getJSONArray("groups").objects().filter { !it.getString("id").equals(id, true) }.jsonArray())
        next.getJSONArray("tasks").objects().filter { it.optionalID("groupID") == id }.forEach { it.put("groupID", JSONObject.NULL) }
    }

    fun startForeground() {
        if (poll != null) return
        poll = viewModelScope.launch {
            requestSync(immediate = true)
            while (true) {
                delay(30_000L * (1L shl failures.coerceAtMost(4)))
                requestSync(immediate = true)
            }
        }
    }
    fun stopForeground() { poll?.cancel(); poll = null }
    fun setEditing(value: Boolean) {
        editing = value
        if (!value && cloud.enabled) requestSync(immediate = true)
    }

    fun requestSync(immediate: Boolean = false) {
        if (!cloud.enabled || state.value.readOnly || editing) return
        if (syncBusy) { syncAgain = true; return }
        scheduledSync?.cancel()
        scheduledSync = viewModelScope.launch { if (!immediate) delay(1_000); synchronize() }
    }

    private suspend fun synchronize() {
        if (syncBusy || !cloud.enabled || state.value.readOnly || editing) return
        syncBusy = true; syncAgain = false
        mutable.value = state.value.copy(syncing = true, syncStatus = "正在同步…")
        val generation = channelGeneration
        val settings = cloud.copy()
        try {
            val crypto = SyncCrypto(settings.recoveryKey)
            val client = BitifulClient(BitifulConfiguration(settings.endpoint, settings.bucket, settings.region), BitifulCredentials(settings.accessKey, settings.secretKey))
            val knownETags = etags.toMap()
            val changes = withContext(Dispatchers.IO) {
                client.listHeads(crypto.vaultID).filter { knownETags[it.key] != it.etag }.map { head ->
                    Triple(head.key, head.etag, JSONObject(crypto.open(client.download(head.key)).toString(Charsets.UTF_8)))
                }
            }
            if (generation != channelGeneration || editing) return
            val next = JSONObject(document.toString())
            val replica = next.optJSONObject("syncReplica")?.let(SyncReplica::fromJson) ?: SyncReplica.fresh()
            replica.capture(next.getJSONArray("tasks"), next.getJSONArray("groups"))
            for ((_, _, payload) in changes) replica.merge(payload)
            val projected = replica.projected()
            next.put("tasks", projected.first).put("groups", projected.second).put("syncReplica", replica.toJson())
            validateDocument(next)
            storage.write(next) // Document and its merge baseline commit together, before uploading.
            document = next
            changes.forEach { (key, etag, _) -> etags[key] = etag }
            publish()
            val payload = replica.payload().toString()
            if (payload != uploadedPayload) {
                val ownKey = BitifulClient.headKey(crypto.vaultID, replica.deviceID)
                withContext(Dispatchers.IO) { client.upload(crypto.seal(payload.toByteArray()), ownKey) }
                if (generation == channelGeneration) uploadedPayload = payload
            }
            if (generation == channelGeneration) {
                failures = 0
                mutable.value = state.value.copy(error = null, syncStatus = "已同步 · ${LocalTime.now().format(DateTimeFormatter.ofPattern("HH:mm:ss"))}")
            }
        } catch (e: Exception) {
            failures = (failures + 1).coerceAtMost(4)
            if (generation == channelGeneration) {
                // Never display server response bodies or credentials. Transport messages are bounded/sanitized.
                mutable.value = state.value.copy(error = "同步失败，本机修改已保留。${safeError(e)}", syncStatus = "同步失败，可手动重试")
            }
        } finally {
            syncBusy = false
            mutable.value = state.value.copy(syncing = false)
            if (syncAgain && cloud.enabled) { syncAgain = false; requestSync() }
        }
    }

    private fun safeError(error: Exception): String = when (error) {
        is java.net.UnknownHostException -> "无法连接服务器。"
        is java.net.SocketTimeoutException -> "连接超时。"
        else -> "请检查配置、网络和恢复密钥。"
    }

    private fun mutate(change: (JSONObject) -> Unit): Boolean {
        if (state.value.readOnly) return false
        return try {
            val next = JSONObject(document.toString())
            change(next)
            validateDocument(next)
            next.optJSONObject("syncReplica")?.let { raw ->
                val replica = SyncReplica.fromJson(raw)
                replica.capture(next.getJSONArray("tasks"), next.getJSONArray("groups"))
                next.put("syncReplica", replica.toJson())
            }
            storage.write(next)
            document = next
            publish(); requestSync()
            true
        } catch (e: Exception) { error(e.message?.take(180) ?: "无法保存，本机原资料已保留。"); false }
    }

    private fun publish() {
        mutable.value = state.value.copy(tasks = document.getJSONArray("tasks").objects().map(Todo::from),
            groups = document.getJSONArray("groups").objects().map(TodoGroup::from), syncEnabled = cloud.enabled)
    }
    private fun error(message: String) { mutable.value = state.value.copy(error = message) }
    private fun channelID(settings: CloudSettings): String = java.security.MessageDigest.getInstance("SHA-256")
        .digest("${settings.endpoint}|${settings.bucket}|${settings.region}|${SyncCrypto(settings.recoveryKey).vaultID}".toByteArray())
        .joinToString("") { "%02x".format(it) }
}

internal fun validateDocument(value: JSONObject) {
    require(value.getInt("version") == 1) { "资料来自不支持的版本。" }
    val tasks = value.getJSONArray("tasks").objects().map(Todo::from)
    val groups = value.getJSONArray("groups").objects().map(TodoGroup::from)
    require(tasks.size <= 10_000 && groups.size <= 1_000) { "资料数量超过当前版本限制。" }
    require(tasks.map { it.id }.toSet().size == tasks.size && groups.map { it.id }.toSet().size == groups.size) { "资料中存在重复标识。" }
    tasks.forEach { UUID.fromString(it.id) }; groups.forEach { UUID.fromString(it.id) }
    require(groups.all { it.name.isNotBlank() && it.color.matches(Regex("#[0-9a-fA-F]{6}")) }) { "分组资料无效。" }
    require(groups.map { it.name }.toSet().size == groups.size) { "分组名称重复。" }
    val groupIDs = groups.map { it.id }.toSet()
    for (task in tasks) {
        require(task.title.isNotBlank() && task.phase in listOf("pending", "inProgress", "completed")) { "待办资料无效。" }
        require(task.groupID == null || task.groupID in groupIDs) { "待办引用不存在的分组。" }
        TodoRules.validateParent(tasks, task.id, task.parentID)
        if (task.phase == "completed") require(tasks.filter { it.parentID == task.id }.all { it.phase == "completed" }) { "父项仍有未完成子项。" }
    }
}
