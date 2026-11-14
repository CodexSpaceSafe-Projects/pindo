package com.pindo.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.pindo.app.sync.BitifulClient
import com.pindo.app.sync.BitifulConfiguration
import com.pindo.app.sync.BitifulCredentials
import com.pindo.app.sync.SyncCrypto
import com.pindo.app.sync.SyncReplica
import com.pindo.app.sync.SyncEngine
import com.pindo.app.sync.SyncSession
import com.pindo.app.sync.SyncTransport
import com.pindo.app.sync.BitifulSyncTransport
import com.pindo.app.sync.SyncRemoteChangedException
import com.pindo.app.sync.VerifiedSyncConnection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
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
import java.text.Normalizer
import java.util.UUID
import java.io.File

data class AppState(val tasks: List<Todo> = emptyList(), val groups: List<TodoGroup> = emptyList(),
    val error: String? = null, val readOnly: Boolean = false, val syncing: Boolean = false,
    val syncEnabled: Boolean = false, val syncStatus: String = "仅保存在本机",
    val preferences: AppPreferences = AppPreferences(), val hasLocalBackup: Boolean = false,
    val lastSyncTime: String? = null, val validatingConnection: Boolean = false, val connectionRevision: Long = 0,
    val lifecycleRevision: Long = 0)

class AppStore(application: Application) : AndroidViewModel(application) {
    private val storage = DocumentStorage(application)
    private val secrets = SecretStorage(application)
    private val noteDraftFiles = AtomicNoteDraftFiles(File(application.noBackupFilesDir, "editor-note-drafts"))
    private val preferenceStorage = PreferenceStorage(application)
    private var preferences = runCatching { preferenceStorage.read() }.getOrDefault(AppPreferences())
    private var document = emptyDocument()
    private var cloud = CloudSettings()
    private var cloudDraft: CloudSettings? = null
    private val mutable = MutableStateFlow(AppState())
    val state: StateFlow<AppState> = mutable
    private var poll: Job? = null
    private var scheduledSync: Job? = null
    private var configurationJob: Job? = null
    private var configurationPreviousReady: Boolean? = null
    private var syncBusy = false
    private var syncAgain = false
    private var channelGeneration = 0
    private var failures = 0
    private var nextAutomaticSyncAt = 0L
    private val editingLeases = mutableSetOf<String>()
    private var foreground = false
    private var uiReady = false
    private var syncReady = false
    private var activeTransport: SyncTransport? = null
    private var documentRevision = 0L
    internal var transportFactory: (CloudSettings, SyncCrypto) -> SyncTransport = { settings, crypto ->
        BitifulSyncTransport(BitifulClient(BitifulConfiguration(settings.endpoint, settings.bucket, settings.region),
            BitifulCredentials(settings.accessKey, settings.secretKey)), crypto.vaultID)
    }

    init {
        try {
            document = storage.read() ?: emptyDocument().also(storage::write)
            validateDocument(document)
            // Rotate before any local edit, including while disconnected. Copied data files
            // must not let two installations write the same actor/counter pair offline.
            document.optJSONObject("syncReplica")?.let {
                val replica = SyncReplica.fromJson(it).upgraded()
                replica.rotateActor()
                replica.capture(document.getJSONArray("tasks"), document.getJSONArray("groups"))
                replica.merge(SyncReplica.fresh(version = 2).payload())
                val projected = replica.projected()
                val next = JSONObject(document.toString()).put("tasks", projected.first).put("groups", projected.second).put("syncReplica", replica.toJson())
                persist(next)
            }
            if (!state.value.readOnly) publish()
        } catch (_: Exception) {
            mutable.value = AppState(error = "无法读取本机资料，原文件已保留。请先备份应用数据，再检查或重新安装。", readOnly = true)
        }
        try {
            recoverConnection()
            if (!state.value.readOnly) publish()
        }
        catch (_: Exception) { syncReady = false; error("同步连接尚未安全恢复。待办仍可离线使用，请重新保存同步设置。") }
    }

    fun settings(): CloudSettings = cloud.copy()
    fun settingsDraft(): CloudSettings = cloudDraft ?: cloud.copy()
    fun stageSettingsDraft(value: CloudSettings) { cloudDraft = value }
    fun dismissError() { if (!state.value.readOnly) mutable.value = state.value.copy(error = null) }
    fun generateRecoveryKey(): String = SyncCrypto.generateKey()
    internal fun noteDraftHandle(): NoteDraftHandle = NoteDraftHandle(noteDraftFiles)
    fun cancelSettingsValidation() { if (state.value.validatingConnection) cancelSynchronization() }

    fun saveSettings(value: CloudSettings): Boolean {
        if (state.value.readOnly) return false
        return try {
            val normalized = normalizeSettings(value)
            if (!normalized.enabled) return commitSettings(normalized)
            require(networkUiReady()) { "请先结束编辑，并在应用前台验证同步连接。" }
            cancelSynchronization()
            val previousReady = syncReady
            syncReady = false; configurationPreviousReady = previousReady
            val generation = channelGeneration
            val crypto = SyncCrypto(normalized.recoveryKey)
            val transport = transportFactory(normalized, crypto)
            activeTransport = transport
            mutable.value = state.value.copy(error = null, validatingConnection = true, syncStatus = "正在验证同步连接…")
            configurationJob = viewModelScope.launch {
                try {
                    val proof = withContext(Dispatchers.IO) {
                        // One bounded validated batch is enough to prove the supplied
                        // key/bucket names an existing vault; no state is rebound yet.
                        SyncEngine(crypto, channelID(normalized), normalized.createVault, transport, batchBytes = 1).probe()
                    }
                    if (generation != channelGeneration || !networkUiReady()) return@launch
                    configurationJob = null; configurationPreviousReady = null; activeTransport = null
                    commitSettings(normalized, proof)
                } catch (_: CancellationException) {
                    // Epoch cancellation restores the previous connection in cancelSynchronization().
                } catch (failure: Exception) {
                    if (generation == channelGeneration) {
                        syncReady = previousReady
                        configurationPreviousReady = null; configurationJob = null; activeTransport = null
                        mutable.value = state.value.copy(validatingConnection = false,
                            error = "连接验证失败，原资料库与离线历史未更改。${safeError(failure)}", syncStatus = "连接验证失败")
                    }
                }
            }
            true // Accepted for read-only validation; the UI waits for connectionRevision before leaving.
        } catch (failure: Exception) { error(failure.message?.take(180) ?: "无法验证同步配置。"); false }
    }

    private fun normalizeSettings(value: CloudSettings): CloudSettings {
        val normalized = value.copy(endpoint = value.endpoint.trim().trimEnd('/'), bucket = value.bucket.trim(),
            region = value.region.trim(), accessKey = value.accessKey.trim(), secretKey = value.secretKey.trim(),
            recoveryKey = value.recoveryKey.filterNot(Char::isWhitespace).lowercase())
        if (normalized.enabled) {
            SyncCrypto(normalized.recoveryKey)
            BitifulClient(BitifulConfiguration(normalized.endpoint, normalized.bucket, normalized.region), BitifulCredentials(normalized.accessKey, normalized.secretKey))
        }
        return normalized
    }

    private fun commitSettings(value: CloudSettings, proof: VerifiedSyncConnection? = null): Boolean {
        if (state.value.readOnly) return false
        val transaction = UUID.randomUUID().toString()
        cancelSynchronization()
        syncReady = false
        return try {
            val normalized = value.copy(endpoint = value.endpoint.trim().trimEnd('/'), bucket = value.bucket.trim(),
                region = value.region.trim(), accessKey = value.accessKey.trim(), secretKey = value.secretKey.trim(),
                recoveryKey = value.recoveryKey.filterNot(Char::isWhitespace).lowercase())
            if (normalized.enabled) {
                require(proof != null && proof.channelID == channelID(normalized) && proof.createVault == normalized.createVault) { "同步连接尚未验证，未更改本机资料库。" }
                SyncCrypto(normalized.recoveryKey)
                BitifulClient(BitifulConfiguration(normalized.endpoint, normalized.bucket, normalized.region),
                    BitifulCredentials(normalized.accessKey, normalized.secretKey))
                require(normalized.accessKey.isNotBlank() && normalized.secretKey.isNotBlank()) { "请填写 Access Key 和 Secret Key。" }
            }
            val activeSource = if (cloud.recoveryKey.isNotBlank() && cloud.bucket.isNotBlank()) {
                // Disabled connection drafts may be incomplete. They must never
                // prevent clearing credentials or explicitly repairing a binding.
                runCatching { adoptLegacyChannel(document, cloud) }.getOrDefault(document)
            } else document
            val source = if (normalized.enabled) adoptLegacyChannel(activeSource, normalized) else activeSource
            val next = SyncConnectionBinding.prepare(source, if (normalized.enabled) channelID(normalized) else null, transaction,
                preserveUnboundReplica = normalized.enabled && !normalized.createVault)
            validateDocument(next)
            if (normalized.enabled) SyncSession.fromDocument(next, channelID(normalized), SyncCrypto(normalized.recoveryKey))
            // Pending credentials are durable before the one atomic data-file commit.
            // Recovery selects pending iff its transaction marker reached data.json.
            secrets.writeJournal(SettingsJournal(cloud, normalized, transaction))
            persist(next)
            secrets.writeJournal(SettingsJournal(normalized))
            cloud = normalized
            cloudDraft = null
            syncReady = true; failures = 0; nextAutomaticSyncAt = 0L
            mutable.value = state.value.copy(error = null, validatingConnection = false, connectionRevision = state.value.connectionRevision + 1,
                syncStatus = if (cloud.enabled) "等待同步" else "仅保存在本机")
            publish()
            if (cloud.enabled) requestSync(immediate = true)
            true
        } catch (e: Exception) {
            // A write may have committed before reporting an error. Resolve by the
            // durable marker rather than guessing or best-effort credential rollback.
            var readBackValid = false
            val recovered = runCatching {
                val saved = storage.read() ?: throw IllegalStateException("本机资料无法读取。")
                validateDocument(saved)
                document = saved; documentRevision++; readBackValid = true
                recoverConnection()
            }.isSuccess
            if (readBackValid) publish()
            else mutable.value = state.value.copy(readOnly = true)
            if (recovered && document.optString(SyncConnectionBinding.TRANSACTION) == transaction) {
                cloudDraft = null
                mutable.value = state.value.copy(validatingConnection = false, connectionRevision = state.value.connectionRevision + 1)
                if (cloud.enabled) requestSync(immediate = true)
                true
            } else {
                if (!recovered) syncReady = false
                error(if (!readBackValid) "无法确认配置事务后的本机资料，已停止修改和同步。原文件与凭据事务已保留。"
                    else e.message?.take(180) ?: "无法保存同步配置。原资料与离线历史已保留。")
                false
            }
        }
    }

    fun addTask(title: String, note: String, day: LocalDate, groupID: String?, parentID: String?): Boolean = mutate { next ->
        val tasks = next.getJSONArray("tasks")
        TodoRules.validateParent(tasks.objects().map(Todo::from), null, parentID)
        val maximumOrder = tasks.objects().maxOfOrNull { it.getLong("order") } ?: -1L
        require(maximumOrder < 9_007_199_254_740_991L) { "事项排序已达到安全上限，请先整理排序。" }
        tasks.put(TodoRules.newTask(title, note, day, groupID, parentID, maximumOrder + 1))
        next.put("tasks", TodoRules.reconcile(tasks))
    }

    fun editTask(id: String, title: String, note: String, day: LocalDate, groupID: String?, parentID: String?, phase: String? = null, baseline: Todo? = null, baselineNoteDigest: String? = null): Boolean = mutate { next ->
        require(title.isNotBlank()) { "请填写事项内容。" }
        val tasks = if (baseline == null || parentID != baseline.parentID) TodoRules.moveTask(next.getJSONArray("tasks"), id, parentID) else next.getJSONArray("tasks")
        val task = tasks.objects().firstOrNull { it.getString("id").equals(id, true) } ?: kotlin.error("找不到这条待办。")
        if (baseline == null || title != baseline.title) task.put("title", title.trim())
        val noteChanged = if (baselineNoteDigest != null) taskNoteDigest(note) != baselineNoteDigest else baseline == null || note != baseline.note
        if (noteChanged) task.put("note", note)
        if (baseline == null || day != baseline.day) task.put("plannedDay", TodoRules.dayJSON(day))
        if (baseline == null || groupID != baseline.groupID) task.put("groupID", groupID ?: JSONObject.NULL)
        task.put("updatedAt", swiftNow())
        next.put("tasks", if (phase == null || (baseline != null && phase == baseline.phase)) tasks else TodoRules.setPhase(tasks, id, phase))
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
        require(next.getJSONArray("groups").objects().none { canonicalGroupName(it.getString("name")) == canonicalGroupName(name.trim()) }) { "分组名称已存在。" }
        require(color.matches(Regex("#[0-9a-fA-F]{6}"))) { "分组颜色无效。" }
        next.getJSONArray("groups").put(JSONObject().put("id", UUID.randomUUID().toString()).put("name", name.trim()).put("colorHex", color))
    }

    fun deleteGroup(id: String) = mutate { next ->
        next.put("groups", next.getJSONArray("groups").objects().filter { !it.getString("id").equals(id, true) }.jsonArray())
        next.getJSONArray("tasks").objects().filter { it.optionalID("groupID") == id }.forEach { it.put("groupID", JSONObject.NULL) }
    }

    fun updateGroup(id: String, name: String, color: String): Boolean = mutate { next ->
        val normalized = name.trim()
        require(normalized.isNotBlank()) { "请填写分组名称。" }
        require(color.matches(Regex("#[0-9a-fA-F]{6}"))) { "分组颜色无效。" }
        val groups = next.getJSONArray("groups").objects()
        require(groups.none { !it.getString("id").equals(id, true) && canonicalGroupName(it.getString("name")) == canonicalGroupName(normalized) }) { "分组名称已存在。" }
        val group = groups.find { it.getString("id").equals(id, true) } ?: kotlin.error("找不到这个分组。")
        group.put("name", normalized).put("colorHex", color)
    }

    fun setTheme(theme: String): Boolean = savePreferences(preferences.copy(theme = theme))

    fun setDefaultGroup(groupID: String?): Boolean {
        if (groupID != null && state.value.groups.none { it.id.equals(groupID, true) }) {
            error("找不到这个分组。"); return false
        }
        return savePreferences(preferences.copy(defaultGroupID = groupID?.lowercase()))
    }

    private fun savePreferences(value: AppPreferences): Boolean = try {
        preferenceStorage.write(value); preferences = value; publish(); true
    } catch (failure: Exception) { error(failure.message ?: "设置未能保存，请重试。"); false }

    fun applyBatch(ids: Set<String>, action: TodoBatchAction): Boolean = mutate { next ->
        next.put("tasks", TodoRules.batch(next.getJSONArray("tasks"), ids, action))
    }
    fun batchPhase(ids: Set<String>, phase: String): Boolean = applyBatch(ids, TodoBatchAction.SetPhase(phase))
    fun batchGroup(ids: Set<String>, groupID: String?): Boolean = applyBatch(ids, TodoBatchAction.SetGroup(groupID))
    fun batchDay(ids: Set<String>, day: LocalDate): Boolean = applyBatch(ids, TodoBatchAction.SetDay(day))
    fun batchDelete(ids: Set<String>): Boolean = applyBatch(ids, TodoBatchAction.Delete)
    fun deletionCount(ids: Set<String>): Int = TodoRules.deletionIDs(state.value.tasks, ids).size

    fun exportData(): String {
        check(!state.value.readOnly) { "本机资料暂不可读取，原文件已保留。" }
        return BackupCodec.encode(document)
    }

    fun importData(text: String): Boolean = try {
        val replacement = BackupCodec.decode(text)
        mutate { next ->
            // One atomic replacement protects the previous visible data together
            // with the imported document and this installation's sync replica.
            val protection = BackupCodec.sanitized(next)
            next.put("tasks", replacement.getJSONArray("tasks")).put("groups", replacement.getJSONArray("groups"))
                .put("previousDocument", protection)
        }
    } catch (failure: Exception) { error(failure.message?.take(180) ?: "无法导入，原资料已保留。"); false }

    fun restoreBackup(): Boolean = try {
        val backup = document.optJSONObject("previousDocument") ?: kotlin.error("当前没有导入前的保护备份。")
        // The external file cap does not apply to an already protected local
        // document. Large local notes must remain recoverable after a small import.
        val replacement = BackupCodec.sanitized(backup)
        mutate { next ->
            val protection = BackupCodec.sanitized(next)
            next.put("tasks", replacement.getJSONArray("tasks")).put("groups", replacement.getJSONArray("groups"))
                .put("previousDocument", protection)
        }
    } catch (failure: Exception) { error(failure.message?.take(180) ?: "无法恢复，原资料已保留。"); false }

    fun startForeground() {
        if (poll != null) return
        foreground = true
        uiReady = false
        mutable.value = state.value.copy(lifecycleRevision = state.value.lifecycleRevision + 1)
        poll = viewModelScope.launch {
            while (true) {
                val base = 30_000L * (1L shl failures.coerceAtMost(4))
                delay(base + kotlin.random.Random.nextLong(0, maxOf(1, base / 5)))
                requestSync(immediate = true)
            }
        }
    }
    fun markUiReady() {
        if (!foreground || uiReady) return
        uiReady = true
        requestSync(immediate = true)
    }
    internal fun networkUiReady(): Boolean = foreground && uiReady && editingLeases.isEmpty()
    fun stopForeground() { foreground = false; uiReady = false; poll?.cancel(); poll = null; cancelSynchronization() }
    fun beginEditing(): String = UUID.randomUUID().toString().also {
        if (editingLeases.isEmpty()) cancelSynchronization()
        editingLeases.add(it)
    }
    fun endEditing(token: String) {
        if (editingLeases.remove(token) && editingLeases.isEmpty() && cloud.enabled) requestSync(immediate = true)
    }

    fun requestSync(immediate: Boolean = false) {
        if (!maySynchronize()) return
        if (syncBusy) { syncAgain = true; return }
        scheduledSync?.cancel()
        scheduledSync = viewModelScope.launch {
            if (!immediate) delay(maxOf(1_000L, nextAutomaticSyncAt - monotonicMilliseconds()))
            synchronize()
        }
    }

    private suspend fun synchronize() {
        if (syncBusy || !maySynchronize()) return
        syncBusy = true; syncAgain = false
        mutable.value = state.value.copy(syncing = true, syncStatus = "正在同步…")
        val generation = channelGeneration
        val settings = cloud.copy()
        var continueImmediately = false
        try {
            val crypto = SyncCrypto(settings.recoveryKey)
            val transport = transportFactory(settings, crypto)
            activeTransport = transport
            val channel = channelID(settings)
            require(document.optString("syncChannel") == channel) { "同步资料库绑定不一致，已停止网络同步。请重新保存设置。" }
            val budget = minOf(64L * 1024 * 1024, maxOf(SyncCrypto.MAX_ENVELOPE_BYTES.toLong(), Runtime.getRuntime().maxMemory() / 8))
            val engine = SyncEngine(crypto, channel, settings.createVault, transport, batchBytes = budget)
            val session = SyncSession.fromDocument(document, channel, crypto)
            val batch = withContext(Dispatchers.IO) { engine.fetch(session) }
            if (!mayApply(generation)) return
            // Expensive merge/projection runs off the UI thread. If a local edit
            // committed during that work, rebase onto its new revision.
            while (true) {
                val revision = documentRevision
                val snapshot = JSONObject(document.toString())
                val next = withContext(Dispatchers.IO) { engine.prepare(snapshot, batch).also(::validateDocument) }
                if (!mayApply(generation)) return
                if (revision != documentRevision) continue
                persist(next); publish()
                break
            }
            if (!batch.complete) {
                failures = 0; nextAutomaticSyncAt = 0L
                mutable.value = state.value.copy(error = null, syncStatus = "已保存一批远端更改，继续下载…")
                syncAgain = true; continueImmediately = true
                return
            }
            var current = SyncSession.fromDocument(document, channel, crypto)
            val pending = current.pendingObject
            var checkpoint: ByteArray? = null
            var needsRescan = false
            if (pending != null) {
                // The exact encrypted object already reached data.json before PUT.
                withContext(Dispatchers.IO) { engine.publish(pending, batch.listedObjects) }
                if (!mayApply(generation)) return
                val next = engine.acknowledge(document, pending)
                persist(next); publish()
                checkpoint = pending.data
                current = SyncSession.fromDocument(document, channel, crypto)
            }
            if (!batch.markerPresent) {
                val data = checkpoint ?: current.acknowledgedObjectKey?.let { key ->
                    withContext(Dispatchers.IO) { engine.downloadCheckpoint(key) }
                } ?: throw IllegalStateException("尚未确认 v2 检查点，未建立升级标记。")
                if (!mayApply(generation)) return
                needsRescan = withContext(Dispatchers.IO) { engine.ensureMigrationMarker(data) }
                if (!mayApply(generation)) return
            }
            if (mayApply(generation)) {
                failures = 0; nextAutomaticSyncAt = 0L
                val time = LocalTime.now().format(DateTimeFormatter.ofPattern("HH:mm:ss"))
                val dirty = engine.needsUpload(document)
                if (dirty || needsRescan) { syncAgain = true; continueImmediately = true }
                val status = when { dirty -> "本机更改已保存，继续上传…"; needsRescan -> "发现新的远端检查点，继续同步…"; else -> "已同步 · $time" }
                mutable.value = state.value.copy(error = null, syncStatus = status, lastSyncTime = if (dirty || needsRescan) state.value.lastSyncTime else time)
            }
        } catch (_: CancellationException) {
            // Cancelling a foreground epoch is not a failed synchronization.
        } catch (_: SyncRemoteChangedException) {
            if (generation == channelGeneration) {
                nextAutomaticSyncAt = monotonicMilliseconds() + 1_000L
                syncAgain = true
                mutable.value = state.value.copy(syncStatus = "远端正在更新，重新读取…")
            }
        } catch (e: Exception) {
            if (generation == channelGeneration) {
                failures = (failures + 1).coerceAtMost(4)
                val delay = 30_000L * (1L shl failures)
                nextAutomaticSyncAt = monotonicMilliseconds() + delay + kotlin.random.Random.nextLong(0, maxOf(1, delay / 5))
                // Never display server response bodies or credentials. Transport messages are bounded/sanitized.
                mutable.value = state.value.copy(error = "同步失败，本机修改已保留。${safeError(e)}", syncStatus = "同步失败，可手动重试")
            }
        } finally {
            if (generation == channelGeneration) {
                syncBusy = false; activeTransport = null
                mutable.value = state.value.copy(syncing = false)
                if (syncAgain && maySynchronize()) { syncAgain = false; requestSync(immediate = continueImmediately) }
            }
        }
    }

    private fun maySynchronize(): Boolean = networkUiReady() && syncReady && cloud.enabled && !state.value.readOnly
    private fun monotonicMilliseconds(): Long = System.nanoTime() / 1_000_000L
    private fun mayApply(generation: Int): Boolean = generation == channelGeneration && maySynchronize()
    private fun cancelSynchronization() {
        channelGeneration++
        configurationJob?.cancel(); configurationJob = null
        configurationPreviousReady?.let { syncReady = it }; configurationPreviousReady = null
        activeTransport?.cancel(); activeTransport = null
        scheduledSync?.cancel(); scheduledSync = null
        syncBusy = false; syncAgain = false
        mutable.value = state.value.copy(syncing = false, validatingConnection = false)
    }

    override fun onCleared() {
        foreground = false; uiReady = false; poll?.cancel(); cancelSynchronization()
        super.onCleared()
    }

    private fun safeError(error: Exception): String = when (error) {
        is java.net.UnknownHostException -> "无法连接服务器。"
        is java.net.SocketTimeoutException -> "连接超时。"
        is IllegalArgumentException, is IllegalStateException -> error.message?.take(180) ?: "请检查配置、网络和恢复密钥。"
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
            persist(next)
            mutable.value = state.value.copy(error = if (syncReady || !cloud.enabled) null else state.value.error,
                syncStatus = if (cloud.enabled && syncReady) "本机已保存，等待同步" else state.value.syncStatus)
            publish(); requestSync()
            true
        } catch (e: Exception) { error(e.message?.take(180) ?: "无法保存，本机原资料已保留。"); false }
    }

    private fun publish() {
        // A deleted or imported-away default group must not survive as a dangling preference.
        val visibleGroups = document.getJSONArray("groups").objects().map(TodoGroup::from)
        if (preferences.defaultGroupID != null && visibleGroups.none { it.id == preferences.defaultGroupID }) {
            preferences = preferences.copy(defaultGroupID = null)
            runCatching { preferenceStorage.write(preferences) }
        }
        mutable.value = state.value.copy(tasks = document.getJSONArray("tasks").objects().map(Todo::from),
            groups = visibleGroups, syncEnabled = cloud.enabled, preferences = preferences,
            hasLocalBackup = document.optJSONObject("previousDocument") != null)
    }
    private fun error(message: String) { mutable.value = state.value.copy(error = message) }
    private fun persist(next: JSONObject) { storage.write(next); document = next; documentRevision++ }

    private fun recoverConnection() {
        // An unreadable primary file cannot decide a pending credential transaction.
        if (state.value.readOnly) { syncReady = false; return }
        val journal = secrets.readJournal() ?: SettingsJournal()
        val marker = document.optString(SyncConnectionBinding.TRANSACTION).takeIf { it.isNotBlank() }
        val recovered = journal.resolve(marker)
        cloud = recovered
        if (journal.pending != null) secrets.writeJournal(SettingsJournal(recovered))
        if (recovered.enabled) {
            val crypto = SyncCrypto(recovered.recoveryKey)
            BitifulClient(BitifulConfiguration(recovered.endpoint, recovered.bucket, recovered.region), BitifulCredentials(recovered.accessKey, recovered.secretKey))
            var next = SyncChannelIdentity.recoverBinding(document, recovered)
            val bound = next.optString("syncChannel")
            if (bound.isBlank()) {
                next = JSONObject(next.toString()).put("syncChannel", channelID(recovered))
                if (next.optJSONObject("syncReplica") == null) {
                    val replica = SyncReplica.fresh(version = 2).apply {
                        capture(next.getJSONArray("tasks"), next.getJSONArray("groups"))
                        merge(SyncReplica.fresh(version = 2).payload())
                    }
                    val projected = replica.projected()
                    next.put("tasks", projected.first).put("groups", projected.second).put("syncReplica", replica.toJson())
                }
                next.put("syncSession", SyncSession(channelID(recovered)).json())
            } else require(bound == channelID(recovered)) { "同步配置与本机资料库绑定不一致。请显式重新连接，未上传本机资料。" }
            SyncSession.fromDocument(next, channelID(recovered), crypto)
            if (next.toString() != document.toString()) persist(next)
        }
        syncReady = true
    }

    private fun adoptLegacyChannel(source: JSONObject, settings: CloudSettings): JSONObject = SyncChannelIdentity.adoptLegacy(source, settings)
    private fun channelID(settings: CloudSettings): String = SyncChannelIdentity.channelID(settings)
}

internal fun validateDocument(value: JSONObject) {
    val version = value.get("version")
    require(version is Number && version.toDouble() == 1.0) { "资料来自不支持的版本。" }
    val tasks = value.getJSONArray("tasks").objects().map(Todo::from)
    val groups = value.getJSONArray("groups").objects().map(TodoGroup::from)
    require(tasks.size <= 10_000 && groups.size <= 1_000) { "资料数量超过当前版本限制。" }
    require(tasks.map { it.id }.toSet().size == tasks.size && groups.map { it.id }.toSet().size == groups.size) { "资料中存在重复标识。" }
    tasks.forEach { UUID.fromString(it.id) }; groups.forEach { UUID.fromString(it.id) }
    require(groups.all { it.name.isNotBlank() && it.color.matches(Regex("#[0-9a-fA-F]{6}")) }) { "分组资料无效。" }
    require(groups.map { canonicalGroupName(it.name) }.toSet().size == groups.size) { "分组名称重复。" }
    val groupIDs = groups.map { it.id }.toSet()
    for (task in tasks) {
        require(task.title.isNotBlank() && task.phase in listOf("pending", "inProgress", "completed")) { "待办资料无效。" }
        require(task.groupID == null || task.groupID in groupIDs) { "待办引用不存在的分组。" }
        TodoRules.validateParent(tasks, task.id, task.parentID)
        if (task.phase == "completed") require(tasks.filter { it.parentID == task.id }.all { it.phase == "completed" }) { "父项仍有未完成子项。" }
    }
}

internal fun canonicalGroupName(value: String): String = Normalizer.normalize(value, Normalizer.Form.NFC)
