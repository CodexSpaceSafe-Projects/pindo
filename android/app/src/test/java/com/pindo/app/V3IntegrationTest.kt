package com.pindo.app

import android.app.Application
import android.database.sqlite.SQLiteException
import androidx.test.core.app.ApplicationProvider
import com.pindo.app.sync.*
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import org.junit.Assume.assumeTrue
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.Base64
import java.time.LocalDate

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[34])
class V3IntegrationTest {
    private fun token(n:Int)=Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32){n.toByte()})
    @Test fun encryptedHTTPPullPushLargeNotesAndSQLiteRestart()=runBlocking {
        val endpoint=System.getenv("PINDO_SYNC_TEST_ENDPOINT");assumeTrue(endpoint!=null)
        val app=ApplicationProvider.getApplicationContext<Application>();app.filesDir.listFiles()?.forEach{it.deleteRecursively()}
        val store=V3Store(app);store.initialize(emptyDocument())
        val service="00000000-0000-4000-8000-000000000001";val vault="00000000-0000-4000-8000-000000000002";val epoch="00000000-0000-4000-8000-000000000003"
        val c=V3Connection(endpoint!!,service,vault,epoch,"00000000-0000-4000-8000-000000000006",token(11),"01".repeat(32))
        val http=V3HTTP(endpoint,true);val crypto=SyncCrypto(c.recoveryKey)
        val probeID="00000000-0000-4000-8000-000000000010";val probe=crypto.sealV3("PindoSync/v3/key-check".toByteArray(),SyncV3EnvelopeContext(SyncV3Identity(service,vault),epoch,"checkpoint",probeID))
        val bootstrap=JSONObject().put("version",3).put("vaultID",vault).put("epoch",epoch).put("deviceID",c.deviceID).put("deviceToken",c.token).put("deviceName","Android 测试手机").put("keyCheck",JSONObject().put("id",probeID).put("epoch",epoch).put("ciphertext",Base64.getEncoder().encodeToString(probe)))
        try{http.request("POST","/v3/bootstrap",bootstrap.toString().toByteArray(),"integration-bootstrap")}
        catch(e:V3Failure){assertEquals("bootstrap_closed",e.code);http.request("POST","/v3/vaults/$vault/pairings/00000000-0000-4000-8000-000000000012/consume",JSONObject().put("epoch",epoch).put("deviceID",c.deviceID).put("deviceToken",c.token).put("deviceName","Android 测试手机").put("code",token(10)).toString().toByteArray())}
        val initialDevices=http.request("GET","/v3/vaults/$vault/devices",token=c.token).getJSONArray("devices").objects()
        assertEquals("Android 测试手机",initialDevices.first{it.getString("id")==c.deviceID}.getString("name"))
        if(System.getenv("PINDO_INTEROP_PHASE")=="android") assertTrue(initialDevices.any{it.getString("name")=="Swift 测试电脑"})
        http.request("POST","/v3/vaults/$vault/devices/${c.deviceID}/name",JSONObject().put("epoch",epoch).put("name","我的安卓测试手机").toString().toByteArray(),c.token)
        val renamed=http.request("GET","/v3/vaults/$vault/devices",token=c.token).getJSONArray("devices").objects()
        assertEquals("我的安卓测试手机",renamed.first{it.getString("id")==c.deviceID}.getString("name"))
        store.bind(c.binding,false)
        val lossy=object:V3Transport {var lose=true;override suspend fun request(method:String,path:String,body:ByteArray?,token:String?):JSONObject {
            val response=http.request(method,path,body,token)
            if(path.endsWith("/push")&&lose){lose=false;throw V3Failure("storage_unavailable")};return response
        }}
        val engine=V3Engine(store,lossy,crypto)
        repeat(8){engine.synchronize(c)}
        val before=store.read()
        if(System.getenv("PINDO_INTEROP_PHASE")=="android"){
            val swift=before.getJSONArray("tasks").objects().first{it.getString("title")=="Swift → Android"};assertEquals(210_000,swift.getString("note").toByteArray().size)
        }
        before.getJSONArray("tasks").put(TodoRules.newTask("Android → Swift","安".repeat(90_000),LocalDate.now(),null,null,1));store.write(before)
        repeat(8){engine.synchronize(c)}
        assertTrue(store.queue(c.binding).isEmpty());assertTrue(store.cursors(c.binding).second>0)
        assertTrue(V3Store(app).read().getJSONArray("tasks").objects().any{it.getString("title")=="Android → Swift"&&it.getString("note").length==90_000})
        val edited=store.read();edited.getJSONArray("tasks").getJSONObject(0).put("title","Tiny title change");store.write(edited)
        val delta=store.queue(c.binding).single();assertTrue(delta.plain.size<4096)
        assertFalse(delta.plain.toString(Charsets.UTF_8).contains("安".repeat(50)))
        // Leave the queued title offline; the previous acknowledged state is complete.
    }
    @Test fun sqliteFailureIsAtomicAndPatchCannotInventTask(){
        val app=ApplicationProvider.getApplicationContext<Application>();app.filesDir.listFiles()?.forEach{it.deleteRecursively()};val store=V3Store(app);store.initialize(emptyDocument())
        val b=V3Binding("00000000-0000-4000-8000-000000000001","00000000-0000-4000-8000-000000000002","00000000-0000-4000-8000-000000000003");store.bind(b,false)
        val next=store.read();next.getJSONArray("tasks").put(TodoRules.newTask("Rollback","",LocalDate.now(),null,null,0));store.beforeCommit={error("injected")}
        assertThrows(IllegalStateException::class.java){store.write(next)};store.beforeCommit=null;assertEquals(0,store.read().getJSONArray("tasks").length());assertTrue(store.queue(b).isEmpty())
    }

    @Test fun sqliteCommitFailurePreservesStateAndQueueAcrossRetryAndReopen() {
        val app = ApplicationProvider.getApplicationContext<Application>()
        app.filesDir.listFiles()?.forEach { it.deleteRecursively() }
        val task = TodoRules.newTask("需要确认的事项", "保留原备注", LocalDate.now(), null, null, 0)
        val store = V3Store(app)
        store.initialize(emptyDocument().put("tasks", JSONArray().put(task)))
        val binding = testConnection().binding
        store.bind(binding)
        val before = store.read()
        val next = copyV3(before) as JSONObject
        next.put("tasks", TodoRules.setPhase(next.getJSONArray("tasks"), task.getString("id"), "completed"))
        val previousQueue = store.queue(binding).map { it.id }
        var commitBoundaryReached = false
        store.beforeCommit = {
            commitBoundaryReached = Thread.currentThread().stackTrace.any { it.methodName.contains("endTransaction") }
            throw SQLiteException("injected commit failure")
        }
        try {
            assertThrows(SQLiteException::class.java) { store.write(next) }
        } finally {
            store.beforeCommit = null
        }
        assertTrue("The failure must come from SQLite's commit boundary, not the transaction body", commitBoundaryReached)
        assertTrue(equalV3(before, store.read()))
        assertEquals(previousQueue, store.queue(binding).map { it.id })

        store.write(next)
        val reopened = V3Store(app)
        assertTrue(equalV3(next, store.read()))
        assertTrue(equalV3(next, reopened.read()))
        assertEquals(previousQueue.size + 1, reopened.queue(binding).size)
        val patch = JSONObject(reopened.queue(binding).last().plain.toString(Charsets.UTF_8))
        val operation = patch.getJSONArray("operations").objects().single { it.getString("recordKey") == "task:${task.getString("id")}" }
        assertEquals("completed", operation.getJSONObject("fields").getJSONObject("lifecycle").getJSONObject("value").getString("phase"))
    }

    @Test fun newerCheckpointRefreshesRemoteHeadAndSynchronizesTheOfflineQueue() = runBlocking {
        val app = ApplicationProvider.getApplicationContext<Application>()
        app.filesDir.listFiles()?.forEach { it.deleteRecursively() }
        val connection = testConnection()
        val store = V3Store(app)
        store.initialize(emptyDocument())
        store.bind(connection.binding, false)
        val offline = TodoRules.newTask("离线事项", "本机修改不能丢失", LocalDate.now(), null, null, 0)
        store.write(emptyDocument().put("tasks", JSONArray().put(offline)))
        val queuedID = store.queue(connection.binding).single().id
        val serverTask = TodoRules.newTask("另一台设备的事项", "新检查点的资料", LocalDate.now(), null, null, 1)
        val transport = AdvancingCheckpointTransport(connection, serverTask)
        val engine = V3Engine(store, transport, SyncCrypto(connection.recoveryKey))

        val result = engine.synchronize(connection)

        assertFalse(result.hasMore)
        assertFalse(result.waiting)
        assertEquals(1, transport.checkpointReads)
        assertEquals(queuedID, transport.uploadedID)
        assertEquals(2L to 2L, store.cursors(connection.binding))
        assertTrue(store.queue(connection.binding).isEmpty())
        assertEquals(setOf(offline.getString("id"), serverTask.getString("id")),
            store.read().getJSONArray("tasks").objects().map { it.getString("id") }.toSet())
        assertTrue(equalV3(store.read(), V3Store(app).read()))
    }

    private fun testConnection() = V3Connection("https://sync.test",
        "00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002",
        "00000000-0000-4000-8000-000000000003", "00000000-0000-4000-8000-000000000006", token(11), "01".repeat(32))

    /** The server advances after info but before the checkpoint read. Its newer
     * authenticated checkpoint legitimately covers more than the old head. */
    private class AdvancingCheckpointTransport(private val c: V3Connection, task: JSONObject) : V3Transport {
        private val crypto = SyncCrypto(c.recoveryKey)
        private val oldCheckpointID = "00000000-0000-4000-8000-000000000070"
        private val checkpointID = "00000000-0000-4000-8000-000000000071"
        private val checkID = "00000000-0000-4000-8000-000000000072"
        private val leaseID = "00000000-0000-4000-8000-000000000073"
        private var head = 0L
        private var commit: JSONObject? = null
        private var serverPayload = SyncReplica.fresh().apply { capture(JSONArray().put(task), JSONArray()) }.payload
        var checkpointReads = 0
            private set
        var uploadedID: String? = null
            private set

        private fun context(kind: String, id: String) = SyncV3EnvelopeContext(SyncV3Identity(c.serviceID, c.vaultID), c.epoch, kind, id)
        private fun metadata() = JSONObject().put("version", 3).put("serviceID", c.serviceID).put("vaultID", c.vaultID)
            .put("epoch", c.epoch).put("head", head).put("gcFloor", 0)
            .put("checkpointID", if (head == 0L) oldCheckpointID else checkpointID)
            .put("checkpointCovered", if (head == 0L) 0 else 1).put("logBytes", 0)

        override suspend fun request(method: String, path: String, body: ByteArray?, token: String?): JSONObject {
            assertEquals(c.token, token)
            if (path.endsWith("/info")) {
                val probe = crypto.sealV3("PindoSync/v3/key-check".toByteArray(), context("checkpoint", checkID))
                return metadata().put("keyCheck", JSONObject().put("id", checkID).put("epoch", c.epoch)
                    .put("ciphertext", Base64.getEncoder().encodeToString(probe)))
            }
            if (method == "GET" && path.contains("/checkpoints?")) {
                checkpointReads++
                head = 1L
                val plain = JSONObject().put("version", 3).put("type", "checkpoint").put("covered", 1).put("payload", serverPayload)
                val sealed = crypto.sealV3(plain.toString().toByteArray(), context("checkpoint", checkpointID))
                return metadata().put("sourceEpoch", c.epoch).put("leaseID", leaseID).put("checkpoint",
                    JSONObject().put("id", checkpointID).put("epoch", c.epoch).put("covered", 1)
                        .put("ciphertext", Base64.getEncoder().encodeToString(sealed)).put("artifactIDs", JSONArray())
                        .put("digest", v3Hash(context("checkpoint", checkpointID).associatedData() + byteArrayOf(0) + sealed)))
            }
            if (method == "POST" && path.endsWith("/push")) {
                val upload = JSONObject(String(requireNotNull(body), Charsets.UTF_8))
                val id = upload.getString("batchID")
                assertEquals(0, upload.getJSONArray("artifactIDs").length())
                val sealed = Base64.getDecoder().decode(upload.getString("ciphertext"))
                val batch = JSONObject(crypto.openV3(sealed, context("batch", id)).toString(Charsets.UTF_8))
                serverPayload = SyncReplica.applyingV3(serverPayload, batch)
                head = 2L
                uploadedID = id
                val digest = v3Hash(context("batch", id).associatedData() + byteArrayOf(0) + sealed)
                commit = JSONObject().put("batchID", id).put("revision", head).put("digest", digest)
                    .put("ciphertext", upload.getString("ciphertext")).put("artifactIDs", JSONArray())
                return metadata().put("receipt", JSONObject().put("batchID", id).put("revision", head).put("digest", digest))
            }
            if (method == "GET" && path.contains("/pull?")) {
                assertTrue(path.contains("after=1"))
                return metadata().put("commits", JSONArray().put(requireNotNull(commit))).put("nextCursor", 2).put("hasMore", false)
            }
            if (method == "DELETE" && path.endsWith("/leases/$leaseID")) return JSONObject().put("released", true)
            error("Unexpected checkpoint-race request: $method $path")
        }
    }
}
