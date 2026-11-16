package com.pindo.app

import android.os.SystemClock
import com.pindo.app.sync.*
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64
import java.util.UUID

/** Device names are public metadata and share the server's Unicode limits. */
internal fun normalizedDeviceName(value: String): String {
    var index = 0
    while (index < value.length) {
        val character = value[index]
        require(character.code !in 0..31 && character.code !in 127..159)
        if (Character.isHighSurrogate(character)) {
            require(index + 1 < value.length && Character.isLowSurrogate(value[index + 1]))
            index += 2
        } else {
            require(!Character.isLowSurrogate(character))
            index++
        }
    }
    val name = value.trim { it.isWhitespace() || Character.isSpaceChar(it) || it == '\uFEFF' }
    require(name.isNotEmpty() && name.codePointCount(0, name.length) <= 80 && name.toByteArray(Charsets.UTF_8).size <= 256)
    return name
}

internal class SyncCoordinator(
    private val store: V3Store,
    private val secrets: V3JournalStorage,
    private val scope: CoroutineScope,
    private val ready: () -> Boolean,
    private val applied: () -> Unit,
    private val status: (Boolean, Boolean, String) -> Unit,
    private val transportFactory: (String) -> V3Transport = { V3HTTP(it) },
    initialDeviceName: String = "Android",
    private val persistDeviceName: (String) -> Unit = {}
) {
    private var journal = JSONObject().put("version", 3).put("enabled", false).put("archived", JSONObject())
    private var generation = UUID.randomUUID()
    private var job: Job? = null
    private var timer: Job? = null
    private var debounce: Job? = null
    private var failures = 0
    private var retryAt = 0L
    private var lastFailure: String? = null

    var deviceName: String = runCatching { normalizedDeviceName(initialDeviceName) }.getOrDefault("Android")
        private set
    var invitation: String? = null
        private set
    var devices: JSONArray = JSONArray()
        private set
    val active get() = journal.optJSONObject("active")?.let(V3Connection::from)
    val enabled get() = journal.optBoolean("enabled") && active != null
    val pending get() = journal.optJSONObject("pending") != null

    init {
        try {
            secrets.readJournal()?.let { require(it.getInt("version") == 3); journal = it }
            journal.optJSONObject("pending")?.let {
                val c = V3Connection.from(it.getJSONObject("connection"))
                if (store.binding()?.transactionID == c.transactionID) {
                    val promoted = (copyV3(journal) as JSONObject).put("active", c.json()).put("enabled", true)
                    promoted.remove("pending")
                    save(promoted)
                }
            }
            idle()
        } catch (_: Exception) {
            lastFailure = "同步失败：无法读取同步凭据；本机资料已保留。"
            status(false, false, lastFailure!!)
        }
    }

    private fun save(value: JSONObject = journal) {
        secrets.writeJournal(value)
        journal = value
    }

    private fun check(g: UUID) {
        if (generation != g || !ready()) throw CancellationException()
    }

    private fun idle() {
        val message = lastFailure ?: when {
            pending && journal.optBoolean("enabled") && !ready() -> "连接尚未完成，等待编辑结束并返回前台后继续连接。"
            pending && journal.optBoolean("enabled") -> "连接尚未完成，请继续连接。"
            active != null && !journal.optBoolean("enabled") -> "同步已暂停，本机修改会继续保存。"
            enabled && !ready() -> "等待编辑结束或返回前台后同步。"
            enabled -> "等待同步"
            else -> "仅保存在本机"
        }
        status(enabled, false, message)
    }

    fun pause() {
        generation = UUID.randomUUID()
        job?.cancel(); job = null
        debounce?.cancel(); debounce = null
        idle()
    }

    // A Compose recomposition is not a new foreground transition.
    fun foreground() {
        if (timer?.isActive == true) return
        val ticker = scope.launch(start = CoroutineStart.LAZY) {
            while (isActive) {
                delay(30_000)
                automaticWork()
            }
        }
        timer = ticker
        ticker.start()
        automaticWork()
    }

    fun background() {
        pause()
        timer?.cancel(); timer = null
    }

    fun changed() {
        debounce?.cancel()
        debounce = scope.launch {
            delay(1000)
            automaticWork()
        }
    }

    private fun automaticWork() {
        if (!ready() || SystemClock.elapsedRealtime() < retryAt) return
        if (pending && journal.optBoolean("enabled")) resume() else sync(false)
    }

    private fun failure(e: Exception) {
        if (e is CancellationException) { idle(); return }
        failures = (failures + 1).coerceAtMost(6)
        retryAt = SystemClock.elapsedRealtime() + (15_000L shl failures)
        lastFailure = if (e is InvalidInvitation) "同步失败：配对信息格式无效，请粘贴完整配对信息。" else when ((e as? V3Failure)?.code) {
            "authentication_required" -> "同步失败：设备授权已失效；本机资料和离线修改已保留。"
            "device_delete_forbidden" -> "不能删除正在使用的这台设备。请在另一台已连接设备上操作。"
            "pairing_invalid" -> "同步失败：配对信息已过期或已使用，请重新生成。"
            "bootstrap_closed" -> "同步失败：服务已初始化，请使用已连接设备生成配对信息。"
            "quota_unavailable" -> "同步失败：超出资源预算，将稍后重试。"
            "corrupt_data" -> "同步失败：云端资料校验失败，请核对恢复密钥。"
            else -> "同步失败：本机资料和待上传内容已保留。"
        }
        status(enabled, false, lastFailure!!)
    }

    private fun launch(message: String = "正在同步…", action: suspend (UUID) -> Unit): Boolean {
        if (job?.isActive == true) return false
        if (!ready()) { status(enabled, false, lastFailure ?: if (pending) "连接尚未完成，等待应用就绪后继续连接。" else "等待当前编辑结束并返回应用前台后重试。"); return false }
        val g = generation
        lastFailure = null
        status(enabled, true, message)
        // Main.immediate can finish without suspension (invalid JSON, URL, etc.).
        // Install the job before it starts so finally can always clear that job.
        val operation = scope.launch(start = CoroutineStart.LAZY) {
            try { action(g) }
            catch (e: Exception) { if (generation == g) failure(e) }
            finally { if (generation == g) job = null }
        }
        job = operation
        operation.start()
        return true
    }

    private fun stage(c: V3Connection, operation: String, extra: JSONObject = JSONObject()) {
        val next = copyV3(journal) as JSONObject
        val archived = next.getJSONObject("archived")
        active?.let { archived.put(it.binding.channel, it.json()) }
        require(archived.length() <= 8)
        next.put("pending", extra.put("connection", c.json()).put("operation", operation)).put("enabled", true)
        save(next)
    }

    fun create(endpoint: String, secret: String): Boolean = launch("正在连接同步库…") { g ->
        val http = transportFactory(endpoint)
        val health = http.request("GET", "/health")
        check(g)
        require(health.getBoolean("clientSyncAvailable") && health.getInt("version") == 3)
        val c = V3Connection(endpoint, health.getString("serviceID"), UUID.randomUUID().toString(),
            UUID.randomUUID().toString(), UUID.randomUUID().toString(), v3Token(), SyncCrypto.generateKey())
        val id = UUID.randomUUID().toString()
        val probe = SyncCrypto(c.recoveryKey).sealV3("PindoSync/v3/key-check".toByteArray(),
            SyncV3EnvelopeContext(SyncV3Identity(c.serviceID, c.vaultID), c.epoch, "checkpoint", id))
        stage(c, "create", JSONObject().put("bootstrapSecret", secret).put("keyCheck", JSONObject()
            .put("id", id).put("epoch", c.epoch).put("ciphertext", Base64.getEncoder().encodeToString(probe))))
        commit(g)
        changed()
    }

    private class InvalidInvitation : Exception()

    fun join(text: String): Boolean = launch("正在连接同步库…") { g ->
        val validated = try {
            val invite = JSONObject(text)
            require(invite.getInt("version") == 3)
            val c = V3Connection(invite.getString("endpoint"), invite.getString("serviceID"),
                invite.getString("vaultID"), invite.getString("epoch"), UUID.randomUUID().toString(),
                v3Token(), invite.getString("recoveryKey"))
            c.binding // Validate library identity before any server registration.
            SyncCrypto(c.recoveryKey)
            transportFactory(c.endpoint)
            invite to c
        } catch (_: org.json.JSONException) {
            throw InvalidInvitation()
        } catch (_: IllegalArgumentException) {
            throw InvalidInvitation()
        }
        stage(validated.second, "join", JSONObject().put("invitation", validated.first))
        commit(g)
        changed()
    }

    fun resume(): Boolean = launch("正在继续连接…") { g -> commit(g); changed() }

    private suspend fun commit(g: UUID) {
        val p = journal.getJSONObject("pending")
        var c = V3Connection.from(p.getJSONObject("connection"))
        val http = transportFactory(c.endpoint)
        val engine = V3Engine(store, http, SyncCrypto(c.recoveryKey), { check(g) })
        try { engine.info(c) }
        catch (e: Exception) {
            check(g)
            when (p.getString("operation")) {
                "create" -> http.request("POST", "/v3/bootstrap", JSONObject().put("version", 3)
                    .put("vaultID", c.vaultID).put("epoch", c.epoch).put("deviceID", c.deviceID)
                    .put("deviceToken", c.token).put("deviceName", deviceName).put("keyCheck", p.getJSONObject("keyCheck"))
                    .toString().toByteArray(), p.getString("bootstrapSecret"))
                "join" -> {
                    val i = p.getJSONObject("invitation")
                    http.request("POST", "/v3/vaults/${c.vaultID}/pairings/${i.getString("pairingID")}/consume",
                        JSONObject().put("epoch", c.epoch).put("deviceID", c.deviceID)
                            .put("deviceToken", c.token).put("deviceName", deviceName).put("code", i.getString("code")).toString().toByteArray())
                }
                "rotate" -> {
                    val old = active ?: error("authentication_required")
                    http.request("POST", "/v3/vaults/${c.vaultID}/devices/${c.deviceID}/rotate",
                        JSONObject().put("epoch", c.epoch).put("deviceToken", c.token).toString().toByteArray(), old.token)
                }
                else -> error("invalid_request")
            }
        }
        check(g); engine.info(c); check(g)
        val b = store.bind(c.binding)
        c = c.copy(epoch = b.epoch, transactionID = b.transactionID)
        applied()
        val promoted = (copyV3(journal) as JSONObject).put("active", c.json()).put("enabled", true)
        promoted.remove("pending")
        save(promoted)
        failures = 0; retryAt = 0; lastFailure = null
        status(true, false, "已连接加密同步，等待同步")
    }

    fun disconnect() {
        pause()
        journal.put("enabled", false)
        try { save(); lastFailure = null; idle() }
        catch (e: Exception) { failure(e) }
    }

    fun reconnect() {
        try {
            journal.put("enabled", true); save()
            if (pending) resume() else sync()
        } catch (e: Exception) { failure(e) }
    }

    fun sync(manual: Boolean = true) {
        if (!manual && SystemClock.elapsedRealtime() < retryAt) return
        if (pending && journal.optBoolean("enabled")) { resume(); return }
        if (!enabled) return
        launch { g ->
            var c = active!!
            store.binding()?.let { if (it.channel == c.binding.channel) c = c.copy(epoch = it.epoch, transactionID = it.transactionID) }
            val r = V3Engine(store, transportFactory(c.endpoint), SyncCrypto(c.recoveryKey), { check(g) }, applied).synchronize(c)
            check(g); journal.put("active", r.connection.json()); save()
            failures = 0; retryAt = 0; lastFailure = null
            status(true, false, if (r.hasMore) "继续同步剩余变化…" else if (r.waiting) "等待依赖记录到达；离线修改已保留。" else "已同步")
            if (r.hasMore) changed()
        }
    }

    private suspend fun call(c: V3Connection, path: String, method: String = "GET", body: JSONObject? = null) =
        transportFactory(c.endpoint).request(method, "/v3/vaults/${c.vaultID}/$path", body?.toString()?.toByteArray(), c.token)

    fun pair() {
        if (!enabled) return
        launch { g ->
            val c = active!!; val id = UUID.randomUUID().toString(); val code = v3Token()
            call(c, "pairings", "POST", JSONObject().put("id", id).put("code", code).put("epoch", c.epoch)); check(g)
            invitation = JSONObject().put("version", 3).put("endpoint", c.endpoint).put("serviceID", c.serviceID)
                .put("vaultID", c.vaultID).put("epoch", c.epoch).put("pairingID", id).put("code", code).put("recoveryKey", c.recoveryKey).toString()
            status(true, false, "配对信息已生成，10 分钟内有效且只能使用一次。")
        }
    }

    fun isCurrentDevice(id: String): Boolean = active?.deviceID == id

    private fun rememberDeviceName(name: String) {
        persistDeviceName(name)
        deviceName = name
    }

    private suspend fun fetchDevices(c: V3Connection, g: UUID): JSONArray {
        var list = call(c, "devices").getJSONArray("devices")
        check(g)
        val current = (0 until list.length()).map { list.getJSONObject(it) }
            .firstOrNull { it.getString("id") == c.deviceID }
        if (current != null) {
            val serverName = (current.opt("name") as? String).orEmpty()
            if (serverName.isBlank()) {
                // Existing devices acquire a readable name on first management
                // refresh. Never replace a name already set on the server.
                call(c, "devices/${c.deviceID}/name", "POST", JSONObject().put("epoch", c.epoch).put("name", deviceName))
                check(g)
                list = call(c, "devices").getJSONArray("devices")
                check(g)
            } else {
                val normalized = normalizedDeviceName(serverName)
                if (normalized != deviceName) rememberDeviceName(normalized)
            }
        }
        return list
    }

    fun listDevices(): Boolean {
        if (!enabled) return false
        return launch { g ->
            val c = active!!
            devices = fetchDevices(c, g)
            status(true, false, "设备列表已更新")
        }
    }

    fun saveDeviceName(value: String): Boolean {
        if (active != null && !enabled) {
            lastFailure = "继续同步后可修改设备名称"
            status(false, false, lastFailure!!)
            return false
        }
        val name = try { normalizedDeviceName(value) }
        catch (_: IllegalArgumentException) {
            lastFailure = "设备名称无效：请填写 1–80 个字符，不能包含控制字符。"
            status(enabled, false, lastFailure!!)
            return false
        }
        if (!enabled) {
            return try {
                rememberDeviceName(name)
                lastFailure = null
                status(false, false, "本机设备名称已保存")
                true
            } catch (e: Exception) { failure(e); false }
        }
        return launch("正在保存设备名称…") { g ->
            val c = active!!
            call(c, "devices/${c.deviceID}/name", "POST", JSONObject().put("epoch", c.epoch).put("name", name))
            check(g)
            rememberDeviceName(name)
            devices = fetchDevices(c, g)
            status(true, false, "设备名称已更新")
        }
    }

    fun deleteDevice(id: String): Boolean {
        if (!enabled) return false
        if (isCurrentDevice(id)) {
            lastFailure = "不能删除正在使用的这台设备。请在另一台已连接设备上操作。"
            status(true, false, lastFailure!!)
            return false
        }
        return launch { g ->
            val c = active!!
            val result = call(c, "devices/$id", "DELETE", JSONObject().put("epoch", c.epoch)); check(g)
            if (!result.optBoolean("deleted") || result.optString("deviceID") != id) throw V3Failure("corrupt_data")
            devices = JSONArray((0 until devices.length()).map { devices.getJSONObject(it) }.filter { it.getString("id") != id })
            invitation = null
            status(true, false, "设备已删除")
        }
    }

    fun rotate() {
        if (!enabled) return
        launch { g -> stage(active!!.copy(token = v3Token(), transactionID = UUID.randomUUID().toString()), "rotate"); commit(g); changed() }
    }
}
