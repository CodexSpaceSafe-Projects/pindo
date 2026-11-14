package com.pindo.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import com.pindo.app.sync.SyncReplica
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.text.Normalizer
import java.util.UUID
import java.io.File

data class AppState(val tasks: List<Todo> = emptyList(), val groups: List<TodoGroup> = emptyList(),
    val error: String? = null, val readOnly: Boolean = false, val syncing: Boolean = false,
    val syncEnabled: Boolean = false, val syncStatus: String = "仅保存在本机",
    val preferences: AppPreferences = AppPreferences(), val hasLocalBackup: Boolean = false,
    val lifecycleRevision: Long = 0)

class AppStore(application: Application) : AndroidViewModel(application) {
    private val storage = DocumentStorage(application)
    private val noteDraftFiles = AtomicNoteDraftFiles(File(application.noBackupFilesDir, "editor-note-drafts"))
    private val preferenceStorage = PreferenceStorage(application)
    private var preferences = runCatching { preferenceStorage.read() }.getOrDefault(AppPreferences())
    private var document = emptyDocument()
    private val mutable = MutableStateFlow(AppState())
    val state: StateFlow<AppState> = mutable
    private val editingLeases = mutableSetOf<String>()
    private var foreground = false
    private var uiReady = false

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
    }

    fun dismissError() { if (!state.value.readOnly) mutable.value = state.value.copy(error = null) }
    internal fun noteDraftHandle(): NoteDraftHandle = NoteDraftHandle(noteDraftFiles)

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
        foreground = true; uiReady = false
        mutable.value = state.value.copy(lifecycleRevision = state.value.lifecycleRevision + 1)
    }
    fun markUiReady() { if (foreground) uiReady = true }
    internal fun networkUiReady(): Boolean = foreground && uiReady && editingLeases.isEmpty()
    fun stopForeground() { foreground = false; uiReady = false }
    fun beginEditing(): String = UUID.randomUUID().toString().also(editingLeases::add)
    fun endEditing(token: String) { editingLeases.remove(token) }

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
            mutable.value = state.value.copy(error = null)
            publish()
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
            groups = visibleGroups, syncEnabled = false, preferences = preferences,
            hasLocalBackup = document.optJSONObject("previousDocument") != null)
    }
    private fun error(message: String) { mutable.value = state.value.copy(error = message) }
    private fun persist(next: JSONObject) { storage.write(next); document = next }
}
