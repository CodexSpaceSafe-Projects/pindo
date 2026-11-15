package com.pindo.app

import android.app.Application
import androidx.compose.material3.Surface
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.core.app.ApplicationProvider
import com.pindo.app.sync.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.util.Base64

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "zh-rCN-w411dp-h891dp-xhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class AndroidSyncUiTest {
    @get:Rule val compose = createComposeRule()
    private lateinit var app: Application
    private lateinit var store: AppStore

    @Before fun prepare() {
        app = ApplicationProvider.getApplicationContext()
        app.filesDir.listFiles()?.forEach { it.deleteRecursively() }
        app.noBackupFilesDir.listFiles()?.forEach { it.deleteRecursively() }
        store = AppStore(app)
    }

    @After fun stop() { compose.runOnUiThread { store.stopForeground() } }

    @Test fun settingsSummaryTracksTheConnectionAndDoesNotClaimSyncIsUnderDevelopment() {
        val ui = mutableStateOf(AppState(syncEnabled = true, syncStatus = "已同步"))
        compose.setContent { PindoTheme("system") { Surface { AppSettingsScreen(store, ui.value) {} } } }
        val row = compose.onNode(hasClickAction() and hasText("云同步"))
        row.performScrollTo().assert(hasText("已同步"))
        compose.onAllNodes(hasText("正在开发", substring = true)).assertCountEquals(0)
        compose.runOnIdle { ui.value = ui.value.copy(syncEnabled = false, syncStatus = "同步失败：配对信息已过期，请重新生成。") }
        row.assert(hasText("同步失败：配对信息已过期，请重新生成。"))
        compose.runOnIdle { ui.value = ui.value.copy(syncEnabled = false, syncStatus = "仅保存在本机") }
        row.assert(hasText("仅保存在本机"))
    }

    @Test fun invalidInvitationCanBeCorrectedAndTheJoinButtonUpdatesTheActualAppState() {
        val secrets = UiJournal()
        val remote = UiPairingServer()
        compose.runOnUiThread {
            store = AppStore(app, secrets) { remote }
            store.startForeground()
        }
        compose.setContent {
            val state by store.state.collectAsState()
            PindoTheme("system") { Surface { PindoScreen(store) } }
        }
        compose.onNode(hasText("设置") and hasClickAction()).performClick()
        compose.onNode(hasText("云同步") and hasClickAction()).performScrollTo().performClick()
        val input = compose.onNodeWithTag("sync-invitation")
        val join = compose.onNodeWithTag("sync-join")
        input.performScrollTo().performTextInput("invalid invitation")
        join.performScrollTo().performClick()
        compose.onNodeWithTag("sync-status").assert(hasText("同步失败：", substring = true))
        assertTrue("A failed connection must retain the invitation for correction",
            input.fetchSemanticsNode().config[SemanticsProperties.EditableText].text.isNotBlank())
        input.performScrollTo().performTextReplacement(remote.invitation.toString())
        join.performScrollTo().performClick()
        compose.runOnIdle {
            assertEquals(1, remote.consumeCalls)
            assertTrue(store.state.value.syncEnabled)
            assertFalse(store.state.value.syncing)
            assertNotEquals("仅保存在本机", store.state.value.syncStatus)
            assertNotNull(secrets.value?.optJSONObject("active"))
            assertFalse(secrets.value!!.has("pending"))
            assertEquals(remote.vault, DocumentStorage(app).sqlite.binding()?.vaultID)
            store.stopForeground()
        }
        compose.onNodeWithText("立即同步").assertExists()
        compose.onNodeWithTag("sync-invitation").assertDoesNotExist()
        compose.onNodeWithContentDescription("返回设置").performClick()
        compose.onNodeWithText("已连接加密同步").assertExists()
        compose.onNode(hasText("云同步") and hasClickAction()).performScrollTo()
            .assert(hasText(store.state.value.syncStatus))
        compose.onAllNodes(hasText("正在开发", substring = true)).assertCountEquals(0)
        compose.runOnUiThread {
            // Loading the saved credential journal must also restore the visible
            // connected state, without relying on an already-running activity.
            val restarted = AppStore(app, secrets) { remote }
            assertTrue(restarted.sync.enabled)
            assertTrue(restarted.state.value.syncEnabled)
            assertFalse(restarted.state.value.syncing)
            restarted.stopForeground()
        }
    }

    private class UiJournal : V3JournalStorage {
        var value: JSONObject? = null
        override fun readJournal() = value?.let { copyV3(it) as JSONObject }
        override fun writeJournal(journal: JSONObject) { value = copyV3(journal) as JSONObject }
    }

    /** The UI test includes the real coordinator, key check, journal and SQLite
     * binding; the independent HTTP tests exercise the actual Worker transport. */
    private class UiPairingServer : V3Transport {
        private val service = "00000000-0000-4000-8000-000000000001"
        val vault = "00000000-0000-4000-8000-000000000002"
        private val epoch = "00000000-0000-4000-8000-000000000003"
        private val key = "01".repeat(32)
        private var registeredToken: String? = null
        var consumeCalls = 0
        val invitation get() = JSONObject().put("version", 3).put("endpoint", "https://sync.test")
            .put("serviceID", service).put("vaultID", vault).put("epoch", epoch)
            .put("pairingID", "00000000-0000-4000-8000-000000000011").put("code", "A".repeat(43)).put("recoveryKey", key)

        override suspend fun request(method: String, path: String, body: ByteArray?, token: String?): JSONObject {
            if (path.endsWith("/consume")) {
                consumeCalls++
                registeredToken = JSONObject(String(body!!, Charsets.UTF_8)).getString("deviceToken")
                return JSONObject()
            }
            if (path.endsWith("/info")) {
                if (registeredToken == null || token != registeredToken) throw V3Failure("authentication_required")
                val id = "00000000-0000-4000-8000-000000000010"
                val encrypted = SyncCrypto(key).sealV3("PindoSync/v3/key-check".toByteArray(),
                    SyncV3EnvelopeContext(SyncV3Identity(service, vault), epoch, "checkpoint", id))
                return JSONObject().put("version", 3).put("serviceID", service).put("vaultID", vault).put("epoch", epoch)
                    .put("head", 0).put("gcFloor", 0).put("checkpointID", JSONObject.NULL)
                    .put("keyCheck", JSONObject().put("id", id).put("epoch", epoch)
                        .put("ciphertext", Base64.getEncoder().encodeToString(encrypted)))
            }
            throw V3Failure("storage_unavailable")
        }
    }
}
