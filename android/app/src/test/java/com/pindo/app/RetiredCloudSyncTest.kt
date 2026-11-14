package com.pindo.app

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import org.json.JSONObject
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.time.LocalDate
import com.pindo.app.sync.SyncCrypto
import com.pindo.app.sync.payloadDigest

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class RetiredCloudSyncTest {
    @Test fun startupAndOfflineEditsPreserveLegacyOutboxBindingAndUnreadableSecretJournal() {
        val app = ApplicationProvider.getApplicationContext<Application>()
        app.filesDir.listFiles()?.forEach { it.deleteRecursively() }
        app.noBackupFilesDir.listFiles()?.forEach { it.deleteRecursively() }
        val initial = emptyDocument().put("tasks", JSONArray().put(TodoRules.newTask("Old library", "Old note", LocalDate.now(), null, null, 0)))
        val bound = SyncConnectionBinding.prepare(initial, "legacy-library", "pending-transaction")
        val crypto = SyncCrypto("01".repeat(32))
        val payload = bound.getJSONObject("syncReplica").getJSONObject("payload")
        val encrypted = crypto.sealV2(payload.toString().toByteArray())
        val pending = JSONObject().put("key", SyncCrypto.objectKey(crypto.vaultID, encrypted))
            .put("data", java.util.Base64.getEncoder().encodeToString(encrypted)).put("payloadDigest", payloadDigest(payload))
        bound.getJSONObject("syncSession").put("pendingObject", pending)
        DocumentStorage(app).write(bound)
        val secrets = File(app.noBackupFilesDir, "sync-secrets.json")
        val bytes = "retained unreadable encrypted credential journal".toByteArray()
        secrets.writeBytes(bytes)
        val store = AppStore(app)
        assertFalse(store.state.value.readOnly)
        assertFalse(store.state.value.syncEnabled)
        assertEquals("Old library", store.state.value.tasks.single().title)
        store.startForeground(); store.markUiReady()
        assertTrue(store.addTask("New offline edit", "", LocalDate.now(), null, null))
        store.stopForeground()
        val saved = DocumentStorage(app).read()!!
        assertEquals(pending.toString(), saved.getJSONObject("syncSession").getJSONObject("pendingObject").toString())
        assertEquals("legacy-library", saved.getString("syncChannel"))
        assertEquals("pending-transaction", saved.getString(SyncConnectionBinding.TRANSACTION))
        assertArrayEquals(bytes, secrets.readBytes())
        assertEquals(2, store.state.value.tasks.size)
        assertFalse(JSONObject(store.exportData()).has("syncSession"))
    }
}
