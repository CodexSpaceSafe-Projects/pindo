package com.pindo.app

import android.app.Application
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import com.pindo.app.sync.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode
import java.io.File
import java.util.Base64

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@LooperMode(LooperMode.Mode.PAUSED)
class DeviceNameTest {
    private lateinit var store: V3Store
    private lateinit var scope: CoroutineScope
    private lateinit var remote: NamedServer
    private lateinit var secrets: MemoryJournal
    private val savedNames = mutableListOf<String>()
    private var lastStatus = ""

    @Before fun prepare() {
        val app = ApplicationProvider.getApplicationContext<Application>()
        app.filesDir.listFiles()?.forEach { it.deleteRecursively() }
        store = V3Store(app); store.initialize(emptyDocument())
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        secrets = MemoryJournal(); remote = NamedServer()
    }

    @After fun finish() { scope.cancel(); shadowOf(Looper.getMainLooper()).idle() }
    private fun drain() { shadowOf(Looper.getMainLooper()).idle() }
    private fun coordinator(initialName: String = "我的 Android") = SyncCoordinator(store, secrets, scope, { true }, {},
        { _, _, message -> lastStatus = message }, { remote }, initialName, { savedNames.add(it) })
    private fun connected(name: String = "", initialName: String = "我的 Android"): SyncCoordinator {
        val c = connection(); store.bind(c.binding, false)
        remote.registered = c; remote.name = name
        secrets.value = JSONObject().put("version", 3).put("enabled", true).put("archived", JSONObject()).put("active", c.json())
        return coordinator(initialName)
    }

    @Test fun sharedUnicodeRulesNormalizeNamesAndRejectInvalidInputs() {
        val fixture = JSONObject(generateSequence(File(System.getProperty("user.dir")).canonicalFile) { it.parentFile }
            .map { File(it, "sync-vectors/device-names.json") }.first { it.isFile }.readText())
        val valid = fixture.getJSONArray("valid")
        for (i in 0 until valid.length()) {
            val item = valid.getJSONObject(i)
            assertEquals(item.getString("name"), normalizedDeviceName(item.getString("input")))
        }
        val invalid = fixture.getJSONArray("invalid")
        for (i in 0 until invalid.length()) {
            val input = invalid.getString(i)
            assertThrows(IllegalArgumentException::class.java) { normalizedDeviceName(input) }
        }
    }

    @Test fun firstManagementRefreshNamesAnExistingUnnamedDeviceAndPreservesOtherNames() {
        val sync = connected()
        assertTrue(sync.listDevices()); drain()
        assertEquals(1, remote.renameCalls)
        assertEquals("我的 Android", remote.name)
        assertEquals("我的 Android", sync.devices.getJSONObject(0).getString("name"))
        assertEquals("工作 Mac", sync.devices.getJSONObject(1).getString("name"))
        assertTrue(sync.isCurrentDevice(sync.devices.getJSONObject(0).getString("id")))
        assertFalse(sync.isCurrentDevice(sync.devices.getJSONObject(1).getString("id")))
        assertTrue(sync.listDevices()); drain()
        assertEquals("Refresh must not keep writing the default name", 1, remote.renameCalls)
    }

    @Test fun managementAdoptsAnExistingCustomNameInsteadOfOverwritingItWithTheModel() {
        val sync = connected("出门手机", "Pixel 9")
        assertTrue(sync.listDevices()); drain()
        assertEquals(0, remote.renameCalls)
        assertEquals("出门手机", sync.deviceName)
        assertEquals(listOf("出门手机"), savedNames)
    }

    @Test fun savingAConnectedDeviceNamePersistsAndRefreshesTheSharedList() {
        val sync = connected("旧名称")
        assertTrue(sync.saveDeviceName("  我的新手机  ")); drain()
        assertEquals("我的新手机", remote.name)
        assertEquals("我的新手机", sync.deviceName)
        assertEquals(listOf("我的新手机"), savedNames)
        assertEquals("我的新手机", sync.devices.getJSONObject(0).getString("name"))
        assertEquals("工作 Mac", sync.devices.getJSONObject(1).getString("name"))
        assertEquals(connection().deviceID, remote.lastRenamedID)
    }

    @Test fun nameSavedBeforeConnectingIsSentByPairingRegistration() {
        val sync = coordinator()
        assertTrue(sync.saveDeviceName("随身手机"))
        assertEquals(listOf("随身手机"), savedNames)
        assertTrue(sync.join(invitation().toString())); drain()
        assertTrue(sync.enabled)
        assertEquals("随身手机", remote.registrationName)
    }

    @Test fun nameSavedBeforeCreatingAVaultIsSentByBootstrap() {
        val sync = coordinator()
        assertTrue(sync.saveDeviceName("测试平板"))
        assertTrue(sync.create("https://names.test", "test-bootstrap")); drain()
        assertTrue(sync.enabled)
        assertEquals("测试平板", remote.registrationName)
    }

    @Test fun invalidOrFailedRenameDoesNotChangeTheSavedName() {
        val sync = connected("旧名称")
        assertFalse(sync.saveDeviceName("\n新名称")); drain()
        assertEquals(0, remote.renameCalls)
        assertTrue(lastStatus.contains("名称无效"))
        remote.failRename = true
        assertTrue(sync.saveDeviceName("想改的名称")); drain()
        assertEquals("我的 Android", sync.deviceName)
        assertEquals("旧名称", remote.name)
        assertTrue(savedNames.isEmpty())
        assertTrue(lastStatus.contains("同步失败"))
    }

    @Test fun pausedConnectionCannotPretendToSaveANameWithoutUpdatingTheServer() {
        val sync = connected("已保存名称")
        assertTrue(sync.listDevices()); drain()
        sync.disconnect()
        assertFalse(sync.saveDeviceName("暂停时的新名称")); drain()
        assertEquals("已保存名称", sync.deviceName)
        assertEquals("已保存名称", remote.name)
        assertEquals(listOf("已保存名称"), savedNames)
        assertEquals(0, remote.renameCalls)
        assertTrue(lastStatus.contains("继续同步后可修改"))
    }

    @Test fun cancelledRenameCannotPublishAStaleNameIntoAnotherConnection() {
        val sync = connected("旧名称")
        remote.beforeRenameResponse = { sync.pause() }
        assertTrue(sync.saveDeviceName("网络上已变但回调取消")); drain()
        assertEquals("我的 Android", sync.deviceName)
        assertTrue(savedNames.isEmpty())
        assertEquals(0, sync.devices.length())
    }

    private class MemoryJournal : V3JournalStorage {
        var value: JSONObject? = null
        override fun readJournal() = value?.let { copyV3(it) as JSONObject }
        override fun writeJournal(journal: JSONObject) { value = copyV3(journal) as JSONObject }
    }

    private class NamedServer : V3Transport {
        var registered: V3Connection? = null
        var name = ""
        var registrationName: String? = null
        var renameCalls = 0
        var lastRenamedID: String? = null
        var failRename = false
        var beforeRenameResponse: (() -> Unit)? = null
        var probe: JSONObject? = null
        override suspend fun request(method: String, path: String, body: ByteArray?, token: String?): JSONObject {
            val data = body?.let { JSONObject(String(it, Charsets.UTF_8)) }
            if (path == "/health") return JSONObject().put("version", 3).put("serviceID", SERVICE).put("clientSyncAvailable", true)
            if (path == "/v3/bootstrap" || path.endsWith("/consume")) {
                val info = data!!
                registered = V3Connection("https://names.test", SERVICE, info.optString("vaultID", VAULT),
                    info.getString("epoch"), info.getString("deviceID"), info.getString("deviceToken"), KEY)
                registrationName = info.getString("deviceName"); name = registrationName!!
                probe = info.optJSONObject("keyCheck")
                return JSONObject()
            }
            val c = registered ?: throw V3Failure("authentication_required")
            if (token != c.token) throw V3Failure("authentication_required")
            if (path.endsWith("/info")) {
                val checkID = "00000000-0000-4000-8000-000000000010"
                val encrypted = SyncCrypto(KEY).sealV3("PindoSync/v3/key-check".toByteArray(),
                    SyncV3EnvelopeContext(SyncV3Identity(SERVICE, c.vaultID), c.epoch, "checkpoint", checkID))
                return JSONObject().put("version", 3).put("serviceID", SERVICE).put("vaultID", c.vaultID)
                    .put("epoch", c.epoch).put("head", 0).put("gcFloor", 0).put("checkpointID", JSONObject.NULL)
                    .put("keyCheck", probe ?: JSONObject().put("id", checkID).put("epoch", c.epoch)
                        .put("ciphertext", Base64.getEncoder().encodeToString(encrypted)))
            }
            if (method == "GET" && path.endsWith("/devices")) return JSONObject().put("devices", JSONArray()
                .put(JSONObject().put("id", c.deviceID).put("name", name).put("revoked_at", JSONObject.NULL))
                .put(JSONObject().put("id", "00000000-0000-4000-8000-000000000077").put("name", "工作 Mac").put("revoked_at", JSONObject.NULL)))
            if (method == "POST" && path.endsWith("/name")) {
                renameCalls++
                if (failRename) throw V3Failure("storage_unavailable")
                lastRenamedID = path.substringBeforeLast('/').substringAfterLast('/')
                assertEquals(c.deviceID, lastRenamedID)
                name = data!!.getString("name")
                beforeRenameResponse?.invoke()
                return JSONObject().put("deviceID", c.deviceID).put("name", name)
            }
            error("Unexpected device-name test request: $method $path")
        }
    }

    companion object {
        private const val SERVICE = "00000000-0000-4000-8000-000000000001"
        private const val VAULT = "00000000-0000-4000-8000-000000000002"
        private const val EPOCH = "00000000-0000-4000-8000-000000000003"
        private val KEY = "01".repeat(32)
        private fun connection() = V3Connection("https://names.test", SERVICE, VAULT, EPOCH,
            "00000000-0000-4000-8000-000000000006", "B".repeat(43), KEY)
        private fun invitation() = JSONObject().put("version", 3).put("endpoint", "https://names.test")
            .put("serviceID", SERVICE).put("vaultID", VAULT).put("epoch", EPOCH)
            .put("pairingID", "00000000-0000-4000-8000-000000000011").put("code", "A".repeat(43)).put("recoveryKey", KEY)
    }
}
