package com.pindo.app

import com.pindo.app.sync.*
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64
import java.util.UUID

internal class SyncCoordinator(private val store:V3Store, private val secrets:V3SecretStorage,
    private val scope:CoroutineScope, private val ready:()->Boolean, private val applied:()->Unit,
    private val status:(Boolean,Boolean,String)->Unit) {
    private var journal=JSONObject().put("version",3).put("enabled",false).put("archived",JSONObject())
    private var generation=UUID.randomUUID();private var job:Job?=null;private var timer:Job?=null
    private var failures=0;private var retryAt=0L
    var invitation:String?=null;private set
    var devices:JSONArray=JSONArray();private set
    val active get()=journal.optJSONObject("active")?.let(V3Connection::from)
    val enabled get()=journal.optBoolean("enabled")&&active!=null
    val pending get()=journal.optJSONObject("pending")!=null
    init{try{secrets.readJournal()?.let{require(it.getInt("version")==3);journal=it}
        journal.optJSONObject("pending")?.let{val c=V3Connection.from(it.getJSONObject("connection"));if(store.binding()?.transactionID==c.transactionID){journal.put("active",c.json()).remove("pending");journal.put("enabled",true);save()}}
        status(enabled,false,if(enabled)"等待同步" else "仅保存在本机")
    }catch(_:Exception){status(false,false,"无法读取同步凭据；本机资料已保留。")}}
    private fun save(){secrets.writeJournal(journal)}
    private fun check(g:UUID){if(generation!=g||!ready())throw CancellationException()}
    fun pause(){generation=UUID.randomUUID();job?.cancel();job=null;status(enabled,false,if(enabled)"等待同步" else "仅保存在本机")}
    fun foreground(){if(timer==null)timer=scope.launch{while(isActive){delay(30_000);sync(false)}};if(pending&&journal.optBoolean("enabled"))resume()else sync(false)}
    fun background(){pause();timer?.cancel();timer=null}
    fun changed(){scope.launch{delay(1000);sync(false)}}
    private fun failure(e:Exception){if(e is CancellationException)return;failures=(failures+1).coerceAtMost(6);retryAt=System.currentTimeMillis()+(15_000L shl failures)
        val message=when((e as? V3Failure)?.code){"authentication_required"->"设备授权已失效；本机资料和离线修改已保留。";"pairing_invalid"->"配对信息已过期或已使用，请重新生成。";"bootstrap_closed"->"服务已初始化，请使用已连接设备生成配对信息。";"quota_unavailable"->"同步超出资源预算，将稍后重试。";"corrupt_data"->"云端资料校验失败，请核对恢复密钥。";else->"同步失败；本机资料和待上传内容已保留。"};status(enabled,false,message)}
    private fun launch(action:suspend(UUID)->Unit){if(job!=null||!ready())return;val g=generation;status(enabled,true,"正在同步…");job=scope.launch{try{action(g)}catch(e:Exception){if(generation==g)failure(e)}finally{if(generation==g){job=null}}}}
    private fun stage(c:V3Connection,operation:String,extra:JSONObject=JSONObject()){
        val archived=journal.getJSONObject("archived");active?.let{archived.put(it.binding.channel,it.json())};require(archived.length()<=8)
        journal.put("pending",extra.put("connection",c.json()).put("operation",operation)).put("enabled",true);save()
    }
    fun create(endpoint:String,secret:String){launch{g->
        val http=V3HTTP(endpoint);val health=http.request("GET","/health");check(g);require(health.getBoolean("clientSyncAvailable")&&health.getInt("version")==3)
        val c=V3Connection(endpoint,health.getString("serviceID"),UUID.randomUUID().toString(),UUID.randomUUID().toString(),UUID.randomUUID().toString(),v3Token(),SyncCrypto.generateKey())
        val id=UUID.randomUUID().toString();val crypto=SyncCrypto(c.recoveryKey)
        val probe=crypto.sealV3("PindoSync/v3/key-check".toByteArray(),SyncV3EnvelopeContext(SyncV3Identity(c.serviceID,c.vaultID),c.epoch,"checkpoint",id))
        stage(c,"create",JSONObject().put("bootstrapSecret",secret).put("keyCheck",JSONObject().put("id",id).put("epoch",c.epoch).put("ciphertext",Base64.getEncoder().encodeToString(probe))))
        commit(g);changed()
    }}
    fun join(text:String){launch{g->val invite=JSONObject(text);require(invite.getInt("version")==3);val c=V3Connection(invite.getString("endpoint"),invite.getString("serviceID"),invite.getString("vaultID"),invite.getString("epoch"),UUID.randomUUID().toString(),v3Token(),invite.getString("recoveryKey"));SyncCrypto(c.recoveryKey);V3HTTP(c.endpoint);stage(c,"join",JSONObject().put("invitation",invite));commit(g);changed()}}
    fun resume(){launch{g->commit(g);changed()}}
    private suspend fun commit(g:UUID){val p=journal.getJSONObject("pending");var c=V3Connection.from(p.getJSONObject("connection"));val http=V3HTTP(c.endpoint);val engine=V3Engine(store,http,SyncCrypto(c.recoveryKey),{check(g)})
        try{engine.info(c)}catch(e:Exception){check(g);when(p.getString("operation")){
            "create"->http.request("POST","/v3/bootstrap",JSONObject().put("version",3).put("vaultID",c.vaultID).put("epoch",c.epoch).put("deviceID",c.deviceID).put("deviceToken",c.token).put("keyCheck",p.getJSONObject("keyCheck")).toString().toByteArray(),p.getString("bootstrapSecret"))
            "join"->{val i=p.getJSONObject("invitation");http.request("POST","/v3/vaults/${c.vaultID}/pairings/${i.getString("pairingID")}/consume",JSONObject().put("epoch",c.epoch).put("deviceID",c.deviceID).put("deviceToken",c.token).put("code",i.getString("code")).toString().toByteArray())}
            "rotate"->{val old=active?:error("authentication_required");http.request("POST","/v3/vaults/${c.vaultID}/devices/${c.deviceID}/rotate",JSONObject().put("epoch",c.epoch).put("deviceToken",c.token).toString().toByteArray(),old.token)}
            else->error("invalid_request")}}
        check(g);engine.info(c);check(g);val b=store.bind(c.binding);c=c.copy(epoch=b.epoch,transactionID=b.transactionID);applied();journal.put("active",c.json()).put("enabled",true).remove("pending");save();status(true,false,"等待同步")
    }
    fun disconnect(){pause();journal.put("enabled",false);try{save();status(false,false,"仅保存在本机")}catch(e:Exception){failure(e)}}
    fun reconnect(){try{journal.put("enabled",true);save();if(pending)resume()else sync()}catch(e:Exception){failure(e)}}
    fun sync(manual:Boolean=true){if(!enabled||pending||(!manual&&System.currentTimeMillis()<retryAt))return;launch{g->var c=active!!;store.binding()?.let{if(it.channel==c.binding.channel)c=c.copy(epoch=it.epoch,transactionID=it.transactionID)}
        val r=V3Engine(store,V3HTTP(c.endpoint),SyncCrypto(c.recoveryKey),{check(g)},applied).synchronize(c);check(g);journal.put("active",r.connection.json());save();failures=0;retryAt=0;status(true,false,if(r.hasMore)"继续同步剩余变化…" else if(r.waiting)"等待依赖记录到达；离线修改已保留。" else "已同步");if(r.hasMore)changed()
    }}
    private suspend fun call(c:V3Connection,path:String,method:String="GET",body:JSONObject?=null)=V3HTTP(c.endpoint).request(method,"/v3/vaults/${c.vaultID}/$path",body?.toString()?.toByteArray(),c.token)
    fun pair(){if(!enabled)return;launch{g->val c=active!!;val id=UUID.randomUUID().toString();val code=v3Token();call(c,"pairings","POST",JSONObject().put("id",id).put("code",code).put("epoch",c.epoch));check(g);invitation=JSONObject().put("version",3).put("endpoint",c.endpoint).put("serviceID",c.serviceID).put("vaultID",c.vaultID).put("epoch",c.epoch).put("pairingID",id).put("code",code).put("recoveryKey",c.recoveryKey).toString();status(true,false,"配对信息已生成，10 分钟内有效且只能使用一次。")}}
    fun listDevices(){if(!enabled)return;launch{g->val r=call(active!!,"devices");check(g);devices=r.getJSONArray("devices");status(true,false,"设备列表已更新")}}
    fun revoke(id:String){if(!enabled)return;launch{g->val c=active!!;call(c,"devices/$id/revoke","POST",JSONObject().put("epoch",c.epoch));check(g);if(id==c.deviceID){journal.put("enabled",false);save()};devices=JSONArray();status(enabled,false,"设备授权已撤销")}}
    fun rotate(){if(!enabled)return;launch{g->stage(active!!.copy(token=v3Token(),transactionID=UUID.randomUUID().toString()),"rotate");commit(g);changed()}}
}
