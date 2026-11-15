package com.pindo.app

import android.app.Application
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import com.pindo.app.sync.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
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
import java.util.Base64
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@LooperMode(LooperMode.Mode.PAUSED)
class SyncCoordinatorTest {
    private lateinit var store: V3Store
    private lateinit var scope: CoroutineScope
    private lateinit var secrets: MemoryJournal
    private lateinit var remote: PairingServer
    private val states = mutableListOf<ConnectionState>()
    private var uiReady = true
    private var applied = 0

    @Before fun prepare() {
        val app = ApplicationProvider.getApplicationContext<Application>()
        app.filesDir.listFiles()?.forEach { it.deleteRecursively() }
        store = V3Store(app)
        store.initialize(emptyDocument())
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        secrets = MemoryJournal()
        remote = PairingServer()
    }

    @After fun stop() { scope.cancel(); shadowOf(Looper.getMainLooper()).idle() }

    private fun coordinator() = SyncCoordinator(store, secrets, scope, { uiReady }, { applied++ },
        { enabled, busy, text -> states.add(ConnectionState(enabled, busy, text)) }, { remote })
    private fun drain() { shadowOf(Looper.getMainLooper()).idle() }

    @Test fun synchronousBadInvitationDoesNotBlockNextValidJoinOnMainImmediate() {
        assertFalse(Dispatchers.Main.immediate.isDispatchNeeded(kotlin.coroutines.EmptyCoroutineContext))
        val sync = coordinator()
        assertTrue(sync.join("invalid invitation"))
        drain()
        assertEquals("同步失败：配对信息格式无效，请粘贴完整配对信息。", states.last().text)
        assertFalse(states.last().busy)
        assertTrue(sync.join(invitation().toString()))
        drain()
        assertEquals(1, remote.consumeCalls)
        assertTrue(sync.enabled)
        assertFalse(sync.pending)
        assertTrue(states.last().enabled)
        assertFalse(states.last().busy)
        assertTrue(states.last().text.contains("已连接"))
        val active = V3Connection.from(secrets.value!!.getJSONObject("active"))
        assertEquals(active.binding, store.binding())
        assertEquals(1, applied)
        assertFalse(secrets.value!!.has("pending"))
    }

    @Test fun failedPairingRetainsPendingIdentityAndForegroundCannotRetryEveryRecomposition() {
        remote.failConsume = true
        val sync = coordinator()
        sync.foreground()
        assertTrue(sync.join(invitation().toString()))
        drain()
        assertTrue(sync.pending)
        assertFalse(sync.enabled)
        assertTrue(states.last().text.startsWith("同步失败："))
        val frozenDevice = secrets.value!!.getJSONObject("pending").getJSONObject("connection").getString("deviceID")
        repeat(20) { sync.foreground(); sync.sync(false) }
        drain()
        assertEquals(1, remote.consumeCalls)
        sync.background()
        assertTrue(states.last().text.startsWith("同步失败："))
        sync.foreground()
        drain()
        assertEquals(1, remote.consumeCalls)
        // The timer may retry once after the backoff, using the persisted identity.
        remote.failConsume = false
        shadowOf(Looper.getMainLooper()).idleFor(30, TimeUnit.SECONDS)
        assertEquals(2, remote.consumeCalls)
        assertTrue(sync.enabled)
        assertEquals(frozenDevice, secrets.value!!.getJSONObject("active").getString("deviceID"))
    }

    @Test fun editingEndResumesPersistedPendingInsteadOfDroppingItBehindThePendingGuard() {
        secrets.value = pendingJournal()
        uiReady = false
        val sync = coordinator()
        sync.foreground()
        drain()
        assertEquals(0, remote.consumeCalls)
        assertTrue(states.last().text.contains("连接尚未完成"))
        uiReady = true
        sync.sync(false) // AppStore.endEditing's actual entry point.
        drain()
        assertTrue(sync.enabled)
        assertEquals(1, remote.consumeCalls)
        assertTrue(states.last().enabled)
    }

    @Test fun foregroundIsOneTransitionAndDoesNotTurnAnActiveConnectionIntoAnIdleRequestLoop() {
        val c = connection()
        remote.registeredToken = c.token
        remote.failInfo = true
        store.bind(c.binding, false)
        secrets.value = JSONObject().put("version", 3).put("enabled", true).put("archived", JSONObject()).put("active", c.json())
        val sync = coordinator()
        repeat(20) { sync.foreground() }
        drain()
        assertEquals(1, remote.infoCalls)
        assertTrue(sync.enabled)
        assertTrue(states.last().text.startsWith("同步失败："))
        assertFalse(states.last().busy)
    }

    @Test fun pendingIsDurableBeforeRegistrationAndAWriteFailureNeverConsumesThePairing() {
        secrets.failWrite = true
        val sync = coordinator()
        assertTrue(sync.join(invitation().toString()))
        drain()
        assertEquals(0, remote.consumeCalls)
        assertFalse(sync.pending)
        assertNull(store.binding())
        assertTrue(states.last().text.startsWith("同步失败："))
        secrets.failWrite = false
        assertTrue(sync.join(invitation().toString()))
        drain()
        assertEquals(1, remote.consumeCalls)
        assertTrue(sync.enabled)
    }

    @Test fun responseLossAfterPairConsumptionResumesWithTheRegisteredToken() {
        remote.loseConsumeResponse = true
        val sync = coordinator()
        assertTrue(sync.join(invitation().toString()))
        drain()
        assertTrue(sync.pending)
        assertTrue(states.last().text.startsWith("同步失败："))
        sync.sync()
        drain()
        assertTrue(sync.enabled)
        assertFalse(sync.pending)
        assertEquals(1, remote.consumeCalls)
    }

    @Test fun failedCredentialPromotionKeepsTheDurablePendingJournalAndCanRetry() {
        secrets.failOnWrite = 2
        val sync = coordinator()
        assertTrue(sync.join(invitation().toString()))
        drain()
        assertNotNull(store.binding())
        assertTrue(sync.pending)
        assertTrue(secrets.value!!.has("pending"))
        assertFalse(secrets.value!!.has("active"))
        assertTrue(states.last().text.startsWith("同步失败："))
        sync.sync()
        drain()
        assertTrue(sync.enabled)
        assertFalse(sync.pending)
        assertTrue(secrets.value!!.has("active"))
        assertEquals(1, remote.consumeCalls)
    }

    @Test fun startupPromotionFailureKeepsPendingUntilCredentialStorageRecovers() {
        val persisted = pendingJournal()
        val c = V3Connection.from(persisted.getJSONObject("pending").getJSONObject("connection"))
        store.bind(c.binding, false)
        remote.registeredToken = c.token
        secrets.value = persisted
        secrets.failWrite = true
        val sync = coordinator()
        assertTrue(sync.pending)
        assertFalse(sync.enabled)
        assertTrue(secrets.value!!.has("pending"))
        assertTrue(states.last().text.startsWith("同步失败："))
        secrets.failWrite = false
        sync.sync()
        drain()
        assertTrue(sync.enabled)
        assertFalse(sync.pending)
        assertEquals(0, remote.consumeCalls)
    }

    private data class ConnectionState(val enabled: Boolean, val busy: Boolean, val text: String)
    private class MemoryJournal : V3JournalStorage {
        var value: JSONObject? = null
        var failWrite = false
        var failOnWrite: Int? = null
        private var writes = 0
        override fun readJournal() = value?.let { copyV3(it) as JSONObject }
        override fun writeJournal(journal: JSONObject) {
            writes++
            if (failWrite || writes == failOnWrite) throw V3Failure("storage_unavailable")
            value = copyV3(journal) as JSONObject
        }
    }

    private class PairingServer : V3Transport {
        var registeredToken: String? = null
        var consumeCalls = 0
        var infoCalls = 0
        var failConsume = false
        var failInfo = false
        var loseConsumeResponse = false
        override suspend fun request(method: String, path: String, body: ByteArray?, token: String?): JSONObject {
            if (path.endsWith("/info")) {
                infoCalls++
                if (failInfo) throw V3Failure("storage_unavailable")
                if (token != registeredToken) throw V3Failure("authentication_required")
                val checkID = "00000000-0000-4000-8000-000000000010"
                val encrypted = SyncCrypto(KEY).sealV3("PindoSync/v3/key-check".toByteArray(),
                    SyncV3EnvelopeContext(SyncV3Identity(SERVICE, VAULT), EPOCH, "checkpoint", checkID))
                return JSONObject().put("version", 3).put("serviceID", SERVICE).put("vaultID", VAULT)
                    .put("epoch", EPOCH).put("head", 0).put("gcFloor", 0).put("checkpointID", JSONObject.NULL)
                    .put("checkpointCovered", 0).put("logCount", 0).put("logBytes", 0)
                    .put("keyCheck", JSONObject().put("id", checkID).put("epoch", EPOCH)
                        .put("ciphertext", Base64.getEncoder().encodeToString(encrypted)))
            }
            if (path.endsWith("/consume")) {
                consumeCalls++
                if (failConsume) throw V3Failure("storage_unavailable")
                registeredToken = JSONObject(String(body!!, Charsets.UTF_8)).getString("deviceToken")
                if (loseConsumeResponse) { loseConsumeResponse = false; throw V3Failure("storage_unavailable") }
                return JSONObject()
            }
            error("Unexpected test request: $method $path")
        }
    }

    companion object {
        private const val SERVICE = "00000000-0000-4000-8000-000000000001"
        private const val VAULT = "00000000-0000-4000-8000-000000000002"
        private const val EPOCH = "00000000-0000-4000-8000-000000000003"
        private val KEY = "01".repeat(32)
        private fun invitation() = JSONObject().put("version", 3).put("endpoint", "https://test.invalid")
            .put("serviceID", SERVICE).put("vaultID", VAULT).put("epoch", EPOCH)
            .put("pairingID", "00000000-0000-4000-8000-000000000011").put("code", "A".repeat(43)).put("recoveryKey", KEY)
        private fun connection() = V3Connection("https://test.invalid", SERVICE, VAULT, EPOCH,
            "00000000-0000-4000-8000-000000000006", "B".repeat(43), KEY)
        private fun pendingJournal(): JSONObject {
            val pending = JSONObject().put("connection", connection().json()).put("operation", "join").put("invitation", invitation())
            return JSONObject().put("version", 3).put("enabled", true).put("archived", JSONObject()).put("pending", pending)
        }
    }
}
