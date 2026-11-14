package com.pindo.app

import android.app.Application
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
        val bootstrap=JSONObject().put("version",3).put("vaultID",vault).put("epoch",epoch).put("deviceID",c.deviceID).put("deviceToken",c.token).put("keyCheck",JSONObject().put("id",probeID).put("epoch",epoch).put("ciphertext",Base64.getEncoder().encodeToString(probe)))
        try{http.request("POST","/v3/bootstrap",bootstrap.toString().toByteArray(),"integration-bootstrap")}
        catch(e:V3Failure){assertEquals("bootstrap_closed",e.code);http.request("POST","/v3/vaults/$vault/pairings/00000000-0000-4000-8000-000000000012/consume",JSONObject().put("epoch",epoch).put("deviceID",c.deviceID).put("deviceToken",c.token).put("code",token(10)).toString().toByteArray())}
        store.bind(c.binding,false);val engine=V3Engine(store,http,crypto)
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
}
