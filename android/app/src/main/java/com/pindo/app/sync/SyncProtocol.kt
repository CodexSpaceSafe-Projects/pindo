package com.pindo.app.sync

import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.text.Normalizer
import java.math.BigDecimal
import java.util.UUID

/**
 * A per-field Lamport replica. Persist this object and its projected task/group arrays
 * in one atomic local file. Never save a merged replica before saving its projection.
 * Cloud heads contain payload() only: preferences, account keys and baselines stay local.
 * Date numbers use Swift's reference epoch: seconds since 2001-01-01T00:00:00Z.
 */
class SyncReplica private constructor(
    deviceID: String,
    var clock: Long,
    private var state: JSONObject,
    private var baselineTasks: JSONArray,
    private var baselineGroups: JSONArray
) {
    var deviceID: String = deviceID
        private set
    val payload: JSONObject get() = copy(state)
    fun payload(): JSONObject = payload

    /** A new process/connection actor never rewrites historical operation identities. */
    fun rotateActor(deviceID: String = UUID.randomUUID().toString()) {
        val actor = uuid(deviceID)
        require(actor == this.deviceID || !state.getJSONObject("seen").has(actor)) { "同步设备标识已被使用。" }
        this.deviceID = actor
    }

    /** Upgrade without rewriting old operation identities or legacy field values. */
    fun upgraded(): SyncReplica {
        val upgraded = upgradedPayload(state)
        return SyncReplica(deviceID, clock, upgraded,
            array(indexed(baselineTasks, true, 2).values), copy(baselineGroups))
    }

    fun capture(tasks: JSONArray, groups: JSONArray) {
        val version = state.getInt("version")
        val currentTasks = indexed(tasks, true, version)
        val currentGroups = indexed(groups, false)
        validateDocument(currentTasks, currentGroups)
        val oldTasks = indexed(baselineTasks, true, version)
        val oldGroups = indexed(baselineGroups, false)
        // JSONObject equality is identity equality; compare normalized JSON values instead.
        if (mapsEqual(currentTasks, oldTasks) && mapsEqual(currentGroups, oldGroups)) return
        val next = maxOf(clock, maxSeen(state.getJSONObject("seen"))) + 1
        require(next in 1..MAX_COUNTER) { "同步计数器无效。" }
        val stamp = Stamp(next, deviceID)
        val beforeSeen = copy(state.getJSONObject("seen"))
        val records = state.getJSONObject("records")
        fun captureType(prefix: String, current: Map<String, JSONObject>, old: Map<String, JSONObject>, task: Boolean) {
            for (id in (current.keys + old.keys).sorted()) {
                val currentValue = current[id]
                val oldValue = old[id]
                if (jsonEqual(currentValue, oldValue)) continue
                val key = "$prefix:$id"
                val record = records.optJSONObject(key) ?: JSONObject().put("fields", JSONObject()).put("notes", JSONArray())
                val fields = record.getJSONObject("fields")
                if (currentValue == null) {
                    fields.put(ALIVE, register(false, stamp))
                } else {
                    if (oldValue == null) fields.put(ALIVE, register(true, stamp))
                    val names = if (task) taskFields(version) else GROUP_FIELDS
                    val lifecycleChanged = task && version == 2 && (oldValue == null || LIFECYCLE_FIELDS.any {
                        !jsonEqual(currentValue.opt(it), oldValue.opt(it))
                    })
                    for (name in names) {
                        if (name == LIFECYCLE) continue
                        val value = currentValue.opt(name) ?: JSONObject.NULL
                        val old = oldValue?.opt(name) ?: JSONObject.NULL
                        if (oldValue == null || !jsonEqual(value, old) || (lifecycleChanged && name in LIFECYCLE_FIELDS)) fields.put(name, register(value, stamp))
                    }
                    if (lifecycleChanged) fields.put(LIFECYCLE, register(lifecycleValue(currentValue), stamp))
                    if (task && (oldValue == null || currentValue.getString("note") != oldValue.getString("note"))) {
                        val notes = record.getJSONArray("notes")
                        notes.put(JSONObject().put("value", currentValue.getString("note")).put("stamp", stamp.json()).put("seen", copy(beforeSeen)))
                        record.put("notes", mergedNotes(notes))
                    }
                }
                records.put(key, record)
            }
        }
        captureType("task", currentTasks, oldTasks, true)
        captureType("group", currentGroups, oldGroups, false)
        state.getJSONObject("seen").put(deviceID, next)
        clock = next
        baselineTasks = array(currentTasks.values)
        baselineGroups = array(currentGroups.values)
    }

    /** The caller must capture committed local edits first, then persist projection+replica atomically. */
    fun merge(payload: JSONObject) {
        var remote = validatedPayload(payload)
        val version = maxOf(state.getInt("version"), remote.getInt("version"))
        val combined = if (version == 2) upgradedPayload(state) else copy(state)
        if (version == 2) remote = upgradedPayload(remote)
        val seen = combined.getJSONObject("seen")
        remote.getJSONObject("seen").keys().forEach { id -> seen.put(id, maxOf(seen.optLong(id, 0), remote.getJSONObject("seen").getLong(id))) }
        val records = combined.getJSONObject("records")
        remote.getJSONObject("records").keys().forEach { key ->
            val incoming = remote.getJSONObject("records").getJSONObject(key)
            val existing = records.optJSONObject(key)
            if (existing == null) records.put(key, copy(incoming)) else {
                val fields = existing.getJSONObject("fields")
                incoming.getJSONObject("fields").keys().forEach fieldLoop@ { name ->
                    val value = incoming.getJSONObject("fields").getJSONObject(name)
                    val old = fields.optJSONObject(name)
                    if (name == LIFECYCLE && old != null) {
                        val oldBottom = old.isNull("value")
                        val incomingBottom = value.isNull("value")
                        if (!oldBottom && incomingBottom) return@fieldLoop
                        if (oldBottom && !incomingBottom) {
                            fields.put(name, copy(value))
                            return@fieldLoop
                        }
                    }
                    if (old == null || Stamp.parse(value.getJSONObject("stamp")) > Stamp.parse(old.getJSONObject("stamp"))) fields.put(name, copy(value))
                    else if (Stamp.parse(value.getJSONObject("stamp")) == Stamp.parse(old.getJSONObject("stamp"))) {
                        require(jsonEqual(value.get("value"), old.get("value"))) { "同步字段版本冲突。" }
                    }
                }
                val notes = copy(existing.getJSONArray("notes"))
                val more = incoming.getJSONArray("notes")
                for (index in 0 until more.length()) notes.put(copy(more.getJSONObject(index)))
                existing.put("notes", mergedNotes(notes))
            }
        }
        // Validate/materialize before committing even the in-memory candidate.
        val projected = project(validatedPayload(combined))
        state = combined
        clock = maxOf(clock, maxSeen(seen))
        baselineTasks = projected.first
        baselineGroups = projected.second
    }

    fun projected(): Pair<JSONArray, JSONArray> = project(state)

    fun toJson(): JSONObject = JSONObject().put("payload", copy(state)).put("deviceID", deviceID).put("clock", clock)
        .put("baselineTasks", copy(baselineTasks)).put("baselineGroups", copy(baselineGroups))

    companion object {
        private const val ALIVE = "\$alive"
        private const val LIFECYCLE = "lifecycle"
        private const val MAX_COUNTER = 9_007_199_254_740_991L
        private const val NOTE_SEPARATOR = "\n\n[Sync conflict]\n\n"
        private val TASK_FIELDS = listOf("title", "plannedDay", "groupID", "parentID", "phase", "order", "createdAt", "updatedAt", "startedAt", "completedAt")
        private val LIFECYCLE_FIELDS = listOf("phase", "startedAt", "completedAt", "isProgressExplicit")
        private fun taskFields(version: Int): List<String> = if (version == 2) TASK_FIELDS + LIFECYCLE else TASK_FIELDS
        private val GROUP_FIELDS = listOf("name", "colorHex")
        private val OPTIONAL_FIELDS = setOf("groupID", "parentID", "startedAt", "completedAt")
        private val UUID_PATTERN = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

        fun fresh(deviceID: String = UUID.randomUUID().toString(), version: Int = 1): SyncReplica {
            require(version == 1 || version == 2) { "不支持此同步资料版本。" }
            val id = uuid(deviceID)
            return SyncReplica(id, 0, JSONObject().put("version", version).put("seen", JSONObject()).put("records", JSONObject()), JSONArray(), JSONArray())
        }

        fun fromJson(value: JSONObject): SyncReplica {
            val storedID = value.getString("deviceID")
            val id = uuid(storedID)
            require(id == storedID) { "本机同步标识无效。" }
            val payload = validatedPayload(value.getJSONObject("payload"))
            val clock = long(value.get("clock"))
            require(clock == maxSeen(payload.getJSONObject("seen")) && clock in 0..MAX_COUNTER) { "本机同步计数器无效。" }
            val tasks = array(indexed(value.getJSONArray("baselineTasks"), true, payload.getInt("version")).values)
            val groups = array(indexed(value.getJSONArray("baselineGroups"), false).values)
            validateDocument(indexed(tasks, true), indexed(groups, false))
            return SyncReplica(id, clock, payload, tasks, groups)
        }

        fun upgradedPayload(value: JSONObject): JSONObject {
            val payload = validatedPayload(value)
            if (payload.getInt("version") == 2) return payload
            payload.put("version", 2)
            val records = payload.getJSONObject("records")
            records.keys().forEach { key ->
                if (key.startsWith("task:")) {
                    val fields = records.getJSONObject(key).getJSONObject("fields")
                    fields.put(LIFECYCLE, register(JSONObject.NULL, Stamp.parse(fields.getJSONObject("phase").getJSONObject("stamp"))))
                }
            }
            return validatedPayload(payload)
        }

        internal fun applyingV3(base:JSONObject,batch:JSONObject):JSONObject {
            require(batch.getInt("version")==3)
            val operations=batch.getJSONArray("operations");require(operations.length()<=20_000)
            if(batch.getString("type")=="baseline") {
                require(operations.length()==0)
                return fresh(version=2).apply { merge(upgradedPayload(base));merge(upgradedPayload(batch.getJSONObject("payload"))) }.payload
            }
            require(batch.getString("type")=="batch"&&!batch.has("payload"))
            val next=upgradedPayload(base);val records=next.getJSONObject("records");val seen=next.getJSONObject("seen")
            for(i in 0 until operations.length()) {
                val op=operations.getJSONObject(i);val key=op.getString("recordKey");val parts=key.split(':')
                require(parts.size==2&&parts[0] in setOf("task","group")&&uuid(parts[1])==parts[1])
                val allowed=(if(parts[0]=="task")taskFields(2) else GROUP_FIELDS).toSet()+ALIVE
                val fields=op.getJSONObject("fields");val names=fields.keys().asSequence().toSet();val notes=op.getJSONArray("notes");val kind=op.getString("kind")
                require(names.all { it in allowed } && (names.isNotEmpty()||notes.length()>0) && (parts[0]=="task"||notes.length()==0))
                when(kind) {
                    "patch" -> require(ALIVE !in names)
                    "delete" -> require(names==setOf(ALIVE)&&fields.getJSONObject(ALIVE).get("value")==false&&notes.length()==0)
                    "create","restore" -> require(names==allowed&&fields.getJSONObject(ALIVE).get("value")==true)
                    else -> error("Invalid operation")
                }
                if(!records.has(key)&&kind!in setOf("create","restore"))throw MissingV3Create(key)
                val record=records.optJSONObject(key)?:JSONObject().put("fields",JSONObject()).put("notes",JSONArray())
                val target=record.getJSONObject("fields")
                for(name in fields.keys()) {
                    val incoming=fields.getJSONObject(name);val stamp=Stamp.parse(incoming.getJSONObject("stamp"));val old=target.optJSONObject(name)
                    seen.put(stamp.deviceID,maxOf(seen.optLong(stamp.deviceID),stamp.counter))
                    if(name==LIFECYCLE&&old!=null) {
                        if(!old.isNull("value")&&incoming.isNull("value"))continue
                        if(old.isNull("value")&&!incoming.isNull("value")){target.put(name,copy(incoming));continue}
                    }
                    if(old==null||Stamp.parse(old.getJSONObject("stamp"))<stamp)target.put(name,copy(incoming))
                    else if(Stamp.parse(old.getJSONObject("stamp"))==stamp)require(jsonEqual(old.get("value"),incoming.get("value")))
                }
                val combined=copy(record.getJSONArray("notes"))
                for(j in 0 until notes.length()) {
                    val note=notes.getJSONObject(j);val stamp=Stamp.parse(note.getJSONObject("stamp"));val context=note.getJSONObject("seen")
                    validateSeen(context);require(context.keys().asSequence().all { context.getLong(it)<stamp.counter })
                    seen.put(stamp.deviceID,maxOf(seen.optLong(stamp.deviceID),stamp.counter))
                    for(actor in context.keys())seen.put(actor,maxOf(seen.optLong(actor),context.getLong(actor)))
                    combined.put(copy(note))
                }
                record.put("notes",mergedNotes(combined));records.put(key,record)
            }
            return validatedPayload(next)
        }

        fun validatedPayload(value: JSONObject): JSONObject {
            val rawVersion = long(value.get("version"))
            require(rawVersion == 1L || rawVersion == 2L) { "不支持此同步资料版本。" }
            val version = rawVersion.toInt()
            val payload = copy(value)
            val seen = payload.getJSONObject("seen")
            validateSeen(seen)
            val records = payload.getJSONObject("records")
            require(records.length() <= 200_000) { "同步资料过大。" }
            var liveTasks = 0
            var liveGroups = 0
            records.keys().forEach { key ->
                val parts = key.split(':')
                require(parts.size == 2 && parts[0] in setOf("task", "group") && uuid(parts[1]) == parts[1]) { "同步资料标识无效。" }
                val task = parts[0] == "task"
                val record = records.getJSONObject(key)
                val fields = record.getJSONObject("fields")
                val allowed = (if (task) taskFields(version) else GROUP_FIELDS).toSet() + ALIVE
                require(fields.keys().asSequence().toSet() == allowed) { "同步资料缺少字段。" }
                fields.keys().forEach { name ->
                    require(name in allowed) { "同步资料字段无效。" }
                    val register = fields.getJSONObject(name)
                    val stamp = Stamp.parse(register.getJSONObject("stamp"))
                    require(seen.optLong(stamp.deviceID, 0) >= stamp.counter) { "同步资料版本无效。" }
                    val fieldValue = register.get("value")
                    if (name == ALIVE) require(fieldValue is Boolean)
                    if (name == LIFECYCLE && fieldValue != JSONObject.NULL) {
                        require(fieldValue is JSONObject) { "同步事项状态字段无效。" }
                        validateLifecycle(fieldValue)
                    }
                    if (name in setOf("parentID", "groupID") && fieldValue != JSONObject.NULL) require(uuid(fieldValue as String) == fieldValue)
                }
                if (fields.getJSONObject(ALIVE).getBoolean("value")) {
                    if (task) liveTasks++ else liveGroups++
                    require(liveTasks <= 10_000 && liveGroups <= 1_000) { "同步资料过大。" }
                }
                val notes = record.getJSONArray("notes")
                require(notes.length() <= 10_000 && (if (task) notes.length() > 0 else notes.length() == 0))
                val noteStamps = mutableSetOf<Stamp>()
                for (index in 0 until notes.length()) {
                    val note = notes.getJSONObject(index)
                    require(note.get("value") is String)
                    val stamp = Stamp.parse(note.getJSONObject("stamp"))
                    require(noteStamps.add(stamp)) { "同步资料中存在重复备注版本。" }
                    require(seen.optLong(stamp.deviceID, 0) >= stamp.counter)
                    val context = note.getJSONObject("seen")
                    validateSeen(context)
                    context.keys().forEach { device -> require(seen.optLong(device, 0) >= context.getLong(device) && context.getLong(device) < stamp.counter) }
                }
                record.put("notes", mergedNotes(notes))
                val raw = JSONObject().put("id", parts[1])
                for (name in if (task) TASK_FIELDS else GROUP_FIELDS) {
                    raw.put(name, fields.getJSONObject(name).get("value"))
                }
                if (task) raw.put("note", projectedNote(record.getJSONArray("notes")))
                normalized(raw, task)
                if (task && version == 2) {
                    val lifecycle = fields.getJSONObject(LIFECYCLE)
                    if (!lifecycle.isNull("value")) {
                        val stamp = Stamp.parse(lifecycle.getJSONObject("stamp"))
                        val status = lifecycle.getJSONObject("value")
                        for (name in listOf("phase", "startedAt", "completedAt")) {
                            val legacy = fields.getJSONObject(name)
                            if (Stamp.parse(legacy.getJSONObject("stamp")) == stamp) {
                                require(jsonEqual(legacy.get("value"), status.get(name))) { "同步事项状态版本冲突。" }
                            }
                        }
                    }
                }
            }
            return payload
        }

        private fun project(payload: JSONObject): Pair<JSONArray, JSONArray> {
            val version = payload.getInt("version")
            val tasks = mutableMapOf<String, JSONObject>()
            val groups = mutableMapOf<String, JSONObject>()
            val records = payload.getJSONObject("records")
            records.keys().asSequence().sorted().forEach { key ->
                val record = records.getJSONObject(key)
                val fields = record.getJSONObject("fields")
                if (!fields.getJSONObject(ALIVE).getBoolean("value")) return@forEach
                val id = key.substringAfter(':')
                val task = key.startsWith("task:")
                val value = JSONObject().put("id", id)
                for (name in if (task) TASK_FIELDS else GROUP_FIELDS) value.put(name, fields.getJSONObject(name).get("value"))
                if (task && version == 2) {
                    val lifecycle = fields.getJSONObject(LIFECYCLE)
                    if (!lifecycle.isNull("value") && Stamp.parse(fields.getJSONObject("phase").getJSONObject("stamp")) <= Stamp.parse(lifecycle.getJSONObject("stamp"))) {
                        val state = lifecycle.getJSONObject("value")
                        for (name in LIFECYCLE_FIELDS) value.put(name, state.get(name))
                    }
                }
                if (task) value.put("note", projectedNote(record.getJSONArray("notes")))
                (if (task) tasks else groups)[id] = normalized(value, task, version)
            }
            val nameCounts = groups.values.groupingBy { nfc(it.getString("name")) }.eachCount()
            val emitted = mutableSetOf<String>()
            for ((id, group) in groups.toSortedMap()) {
                val base = group.getString("name")
                var name = if ((nameCounts[nfc(base)] ?: 0) > 1) "$base [$id]" else base
                while (!emitted.add(nfc(name))) name += " [$id]"
                group.put("name", name)
            }
            for ((id, task) in tasks) {
                val group = optionalUUID(task, "groupID")
                if (group != null && !groups.containsKey(group)) task.put("groupID", JSONObject.NULL)
                val parent = optionalUUID(task, "parentID")
                if (parent == id || (parent != null && !tasks.containsKey(parent))) task.put("parentID", JSONObject.NULL)
            }
            for (id in tasks.keys.sorted()) {
                val visited = mutableSetOf<String>()
                var current: String? = id
                while (current != null) {
                    if (!visited.add(current) || visited.size > 3) {
                        tasks.getValue(id).put("parentID", JSONObject.NULL)
                        break
                    }
                    current = optionalUUID(tasks.getValue(current), "parentID")
                }
            }
            fun depth(id: String): Int {
                var current = optionalUUID(tasks.getValue(id), "parentID")
                var count = 0
                while (current != null) { count++; current = optionalUUID(tasks.getValue(current), "parentID") }
                return count
            }
            val children = tasks.values.filter { optionalUUID(it, "parentID") != null }.groupBy { optionalUUID(it, "parentID")!! }
            for (id in tasks.keys.sortedWith(compareByDescending<String> { depth(it) }.thenBy { it })) {
                val task = tasks.getValue(id)
                val childTasks = children[id]
                if (childTasks == null) {
                    if (version == 2 && task.getString("phase") == "inProgress" && !task.getBoolean("isProgressExplicit")) {
                        task.put("phase", "pending")
                        normalizeLifecycle(task)
                    }
                    continue
                }
                val previous = task.getString("phase")
                val phase = when {
                    childTasks.all { it.getString("phase") == "completed" } -> "completed"
                    version == 2 && previous == "inProgress" && task.getBoolean("isProgressExplicit") -> "inProgress"
                    childTasks.any { it.getString("phase") != "pending" } -> "inProgress"
                    version == 2 -> "pending"
                    previous == "completed" -> "pending"
                    else -> previous
                }
                if (phase != previous) {
                    val date = (childTasks.map { it.getDouble("updatedAt") } + task.getDouble("updatedAt")).maxOrNull()!!
                    task.put("phase", phase).put("updatedAt", date).put("completedAt", if (phase == "completed") date else JSONObject.NULL)
                    if (phase == "inProgress" && task.isNull("startedAt")) task.put("startedAt", date)
                }
                if (version == 2) {
                    task.put("isProgressExplicit", phase == "inProgress" && previous == "inProgress" && task.getBoolean("isProgressExplicit"))
                    normalizeLifecycle(task)
                }
            }
            val sortedTasks = tasks.values.sortedWith(compareBy<JSONObject> { it.getLong("order") }.thenBy { it.getDouble("createdAt") }.thenBy { it.getString("id") })
            return array(sortedTasks) to array(groups.toSortedMap().values)
        }

        private fun indexed(values: JSONArray, task: Boolean, version: Int = 1): Map<String, JSONObject> {
            val result = linkedMapOf<String, JSONObject>()
            require(values.length() <= if (task) 10_000 else 1_000) { "同步资料过大。" }
            for (index in 0 until values.length()) {
                val value = normalized(values.getJSONObject(index), task, version)
                require(result.put(value.getString("id"), value) == null) { "资料中存在重复标识。" }
            }
            return result
        }

        private fun validateDocument(tasks: Map<String, JSONObject>, groups: Map<String, JSONObject>) {
            require(groups.values.map { nfc(it.getString("name")) }.toSet().size == groups.size) { "分组名称重复。" }
            for ((id, task) in tasks) {
                val group = optionalUUID(task, "groupID")
                require(group == null || groups.containsKey(group)) { "事项分组不存在。" }
                val visited = mutableSetOf<String>()
                var current: String? = id
                while (current != null) {
                    require(visited.add(current) && visited.size <= 3 && tasks.containsKey(current)) { "事项层级无效。" }
                    current = optionalUUID(tasks.getValue(current), "parentID")
                }
                if (task.getString("phase") == "completed") {
                    require(tasks.values.none { optionalUUID(it, "parentID") == id && it.getString("phase") != "completed" }) { "请先完成所有子项。" }
                }
            }
        }

        private fun normalized(value: JSONObject, task: Boolean, version: Int = 1): JSONObject {
            val result = JSONObject().put("id", uuid(value.getString("id")))
            if (!task) {
                require(value.get("name") is String && value.get("colorHex") is String)
                require(value.getString("name").trim().isNotEmpty())
                require(value.getString("colorHex").matches(Regex("#[0-9a-fA-F]{6}")))
                return result.put("name", value.getString("name")).put("colorHex", value.getString("colorHex"))
            }
            require(value.get("title") is String && value.get("note") is String && value.get("phase") is String)
            require(value.getString("title").trim().isNotEmpty()) { "请填写事项内容。" }
            require(value.getString("phase") in setOf("pending", "inProgress", "completed"))
            val day = value.getJSONObject("plannedDay")
            for (component in listOf("year", "month", "day")) require(long(day.get(component)) in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong())
            require(long(day.get("year")) in 1..9999)
            LocalDate.of(long(day.get("year")).toInt(), long(day.get("month")).toInt(), long(day.get("day")).toInt())
            require(value.get("createdAt") is Number && value.get("updatedAt") is Number && value.getDouble("createdAt").isFinite() && value.getDouble("updatedAt").isFinite())
            require(long(value.get("order")) in -MAX_COUNTER..MAX_COUNTER) { "同步事项顺序无效。" }
            for (name in TASK_FIELDS) {
                val field = value.opt(name) ?: JSONObject.NULL
                require(field != JSONObject.NULL || name in OPTIONAL_FIELDS)
                when (name) {
                    "groupID", "parentID" -> result.put(name, if (field == JSONObject.NULL) JSONObject.NULL else uuid(field as String))
                    "startedAt", "completedAt" -> {
                        require(field == JSONObject.NULL || (field is Number && field.toDouble().isFinite()))
                        result.put(name, field)
                    }
                    "plannedDay" -> result.put(name, JSONObject().put("year", day.getInt("year")).put("month", day.getInt("month")).put("day", day.getInt("day")))
                    else -> result.put(name, field)
                }
            }
            result.put("note", value.getString("note"))
            if (version == 2) {
                val explicit = value.opt("isProgressExplicit")
                require(explicit == null || explicit == JSONObject.NULL || explicit is Boolean)
                result.put("isProgressExplicit", if (explicit is Boolean) explicit else value.getString("phase") == "inProgress")
                normalizeLifecycle(result)
            }
            return result
        }

        private fun lifecycleValue(task: JSONObject): JSONObject = JSONObject().also { state ->
            LIFECYCLE_FIELDS.forEach { name -> state.put(name, task.get(name)) }
        }

        private fun normalizeLifecycle(task: JSONObject) {
            when (task.getString("phase")) {
                "pending" -> task.put("startedAt", JSONObject.NULL).put("completedAt", JSONObject.NULL).put("isProgressExplicit", false)
                "inProgress" -> {
                    if (task.isNull("startedAt")) task.put("startedAt", task.get("updatedAt"))
                    task.put("completedAt", JSONObject.NULL)
                }
                "completed" -> {
                    if (task.isNull("completedAt")) task.put("completedAt", task.get("updatedAt"))
                    task.put("isProgressExplicit", false)
                }
            }
        }

        private fun validateLifecycle(value: JSONObject) {
            require(value.keys().asSequence().toSet() == LIFECYCLE_FIELDS.toSet()) { "同步事项状态字段无效。" }
            require(value.get("phase") is String && value.getString("phase") in setOf("pending", "inProgress", "completed"))
            require(value.get("isProgressExplicit") is Boolean)
            for (name in listOf("startedAt", "completedAt")) {
                val date = value.get(name)
                require(date == JSONObject.NULL || (date is Number && date.toDouble().isFinite()))
            }
            when (value.getString("phase")) {
                "pending" -> require(value.isNull("startedAt") && value.isNull("completedAt") && !value.getBoolean("isProgressExplicit"))
                "inProgress" -> require(!value.isNull("startedAt") && value.isNull("completedAt"))
                "completed" -> require(!value.isNull("completedAt") && !value.getBoolean("isProgressExplicit"))
            }
        }

        private fun mergedNotes(notes: JSONArray): JSONArray {
            val unique = mutableMapOf<Stamp, JSONObject>()
            for (index in 0 until notes.length()) {
                val note = notes.getJSONObject(index)
                val stamp = Stamp.parse(note.getJSONObject("stamp"))
                val prior = unique.putIfAbsent(stamp, note)
                require(prior == null || jsonEqual(prior, note)) { "同步备注版本冲突。" }
            }
            val surviving = unique.filter { (stamp, _) -> unique.none { (other, note) -> other != stamp && note.getJSONObject("seen").optLong(stamp.deviceID, 0) >= stamp.counter } }
            require(unique.isEmpty() || surviving.isNotEmpty()) { "同步备注版本无效。" }
            return array(surviving.toSortedMap(compareByDescending<Stamp> { it }).values)
        }

        private fun projectedNote(notes: JSONArray): String {
            val entries = (0 until notes.length()).map { notes.getJSONObject(it) }.sortedByDescending { Stamp.parse(it.getJSONObject("stamp")) }
            return entries.map { it.getString("value") }.distinctBy(::nfc).joinToString(NOTE_SEPARATOR)
        }

        private fun register(value: Any, stamp: Stamp) = JSONObject().put("value", value).put("stamp", stamp.json())
        private fun validateSeen(seen: JSONObject) {
            require(seen.length() <= 10_000)
            seen.keys().forEach { id -> require(uuid(id) == id && long(seen.get(id)) in 0..MAX_COUNTER) }
        }
        private fun maxSeen(seen: JSONObject): Long = seen.keys().asSequence().map { seen.getLong(it) }.maxOrNull() ?: 0
        private fun uuid(value: String): String = value.lowercase().also { require(it.matches(UUID_PATTERN)) { "同步标识无效。" } }
        private fun optionalUUID(value: JSONObject, key: String): String? = if (!value.has(key) || value.isNull(key)) null else uuid(value.getString(key))
        private fun long(value: Any): Long {
            require(value is Number && value.toDouble().isFinite()) { "同步计数值无效。" }
            return try { BigDecimal(value.toString()).longValueExact() }
            catch (error: ArithmeticException) { throw IllegalArgumentException("同步计数值无效。", error) }
        }
        private fun mapsEqual(a: Map<String, JSONObject>, b: Map<String, JSONObject>): Boolean = a.keys == b.keys && a.all { (key, value) -> jsonEqual(value, b[key]) }
        private fun copy(value: JSONObject) = copyV3(value) as JSONObject
        private fun copy(value: JSONArray) = copyV3(value) as JSONArray
        private fun array(values: Collection<JSONObject>): JSONArray = JSONArray().also { out -> values.forEach { out.put(copy(it)) } }
        private fun jsonEqual(a: Any?, b: Any?): Boolean = when {
            a == null || b == null -> a == b
            a is Number && b is Number -> a.toDouble() == b.toDouble()
            a is String && b is String -> nfc(a) == nfc(b)
            a is JSONObject && b is JSONObject -> a.keys().asSequence().toSet() == b.keys().asSequence().toSet() && a.keys().asSequence().all { jsonEqual(a.get(it), b.get(it)) }
            a is JSONArray && b is JSONArray -> a.length() == b.length() && (0 until a.length()).all { jsonEqual(a.get(it), b.get(it)) }
            else -> a == b
        }
        private fun nfc(value: String): String = Normalizer.normalize(value, Normalizer.Form.NFC)
    }

    private data class Stamp(val counter: Long, val deviceID: String) : Comparable<Stamp> {
        override fun compareTo(other: Stamp): Int = compareValuesBy(this, other, { it.counter }, { it.deviceID })
        fun json(): JSONObject = JSONObject().put("counter", counter).put("deviceID", deviceID)
        companion object {
            fun parse(value: JSONObject): Stamp {
                val counter = long(value.get("counter"))
                val device = value.getString("deviceID")
                require(counter in 1..MAX_COUNTER && uuid(device) == device) { "同步版本无效。" }
                return Stamp(counter, device)
            }
        }
    }
}
