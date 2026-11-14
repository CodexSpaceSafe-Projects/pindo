package com.pindo.app.sync

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID

internal class V3Failure(val code:String):Exception(code)
internal data class V3Connection(val endpoint:String,val serviceID:String,val vaultID:String,val epoch:String,val deviceID:String,val token:String,val recoveryKey:String,val transactionID:String=UUID.randomUUID().toString()) {
    val binding get()=V3Binding(serviceID,vaultID,epoch,transactionID)
    fun json()=JSONObject().put("endpoint",endpoint).put("serviceID",serviceID).put("vaultID",vaultID).put("epoch",epoch).put("deviceID",deviceID).put("token",token).put("recoveryKey",recoveryKey).put("transactionID",transactionID)
    companion object{fun from(j:JSONObject)=V3Connection(j.getString("endpoint"),j.getString("serviceID"),j.getString("vaultID"),j.getString("epoch"),j.getString("deviceID"),j.getString("token"),j.getString("recoveryKey"),j.getString("transactionID"))}
}
internal fun v3Token():String=Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32).also{SecureRandom().nextBytes(it)})
internal fun v3Hash(bytes:ByteArray)=MessageDigest.getInstance("SHA-256").digest(bytes).joinToString(""){"%02x".format(it)}
internal interface V3Transport { suspend fun request(method:String,path:String,body:ByteArray?=null,token:String?=null):JSONObject }
internal class V3HTTP(private val endpoint:String,allowLoopback:Boolean=false):V3Transport {
    init{val uri=URI(endpoint);require(uri.userInfo==null&&uri.query==null&&uri.fragment==null&&(uri.scheme=="https"||(allowLoopback&&uri.scheme=="http"&&uri.host in listOf("localhost","127.0.0.1","::1"))))}
    override suspend fun request(method:String,path:String,body:ByteArray?,token:String?):JSONObject=withContext(Dispatchers.IO){
        require(path.startsWith('/')&&!path.startsWith("//")&&!path.contains(".."))
        val connection=URL(endpoint.trimEnd('/')+path).openConnection() as HttpURLConnection
        try{
            connection.instanceFollowRedirects=false;connection.connectTimeout=15_000;connection.readTimeout=30_000;connection.requestMethod=method
            connection.setRequestProperty("Accept","application/json")
            if(token!=null){require(token.all{it.code in 33..126});connection.setRequestProperty("Authorization","Bearer $token")}
            if(body!=null){connection.doOutput=true;connection.setRequestProperty("Content-Type","application/json");connection.setFixedLengthStreamingMode(body.size);connection.outputStream.use{it.write(body)}}
            val status=connection.responseCode;require(connection.contentLengthLong<=2*1024*1024){"corrupt_data"}
            val bytes=(if(status in 200..299)connection.inputStream else connection.errorStream)?.use{input->
                val out=ByteArrayOutputStream();val buffer=ByteArray(8192);while(true){val n=input.read(buffer);if(n<0)break;require(out.size()+n<=2*1024*1024){"corrupt_data"};out.write(buffer,0,n)};out.toByteArray()
            }?:ByteArray(0)
            val value=runCatching{JSONObject(bytes.toString(Charsets.UTF_8))}.getOrNull()
            if(status !in 200..299)throw V3Failure(value?.optJSONObject("error")?.optString("code")?.takeIf{c->SyncV3Error.entries.any{it.wire==c}}?:if(status==401||status==403)"authentication_required" else "storage_unavailable")
            value?:throw V3Failure("corrupt_data")
        }finally{connection.disconnect()}
    }
}
internal data class V3SyncResult(val connection:V3Connection,val hasMore:Boolean,val waiting:Boolean)
internal class V3Engine(private val store:V3Store,private val transport:V3Transport,private val crypto:SyncCrypto,
                        private val check:()->Unit={},private val applied:()->Unit={}) {
    private val leases=mutableListOf<Pair<String,String>>()
    private val renewed=mutableMapOf<String,Long>()
    private suspend fun renew(c:V3Connection,id:String?,epoch:String){if(id!=null&&System.currentTimeMillis()-(renewed[id]?:0)>=60_000){call(c,"leases/$id","POST",JSONObject().put("epoch",epoch).put("floor",0));renewed[id]=System.currentTimeMillis()}}
    private fun body(j:JSONObject)=j.toString().toByteArray(Charsets.UTF_8)
    private fun context(c:V3Connection,kind:String,id:String,refs:List<String> = emptyList(),epoch:String=c.epoch)=SyncV3EnvelopeContext(SyncV3Identity(c.serviceID,c.vaultID),epoch,kind,id,refs)
    private suspend fun call(c:V3Connection,path:String,method:String="GET",value:JSONObject?=null):JSONObject{check();val r=transport.request(method,"/v3/vaults/${c.vaultID}/$path",value?.let(::body),c.token);check();return r}
    suspend fun info(c:V3Connection):JSONObject {
        val i=call(c,"info");require(i.getInt("version")==3&&i.getString("serviceID")==c.serviceID&&i.getString("vaultID")==c.vaultID)
        SyncV3.validateID(i.getString("epoch"));SyncV3.validateCounter(i.getLong("head"));SyncV3.validateCounter(i.getLong("gcFloor"));require(i.getLong("gcFloor")<=i.getLong("head"))
        val k=i.optJSONObject("keyCheck")?:throw V3Failure("corrupt_data")
        val probe=crypto.openV3(Base64.getDecoder().decode(k.getString("ciphertext")),context(c,"checkpoint",k.getString("id"),epoch=k.getString("epoch")))
        if(!probe.contentEquals("PindoSync/v3/key-check".toByteArray()))throw V3Failure("corrupt_data")
        return i
    }
    private fun digest(c:V3Connection,kind:String,id:String,refs:List<String>,sealed:ByteArray,epoch:String=c.epoch)=v3Hash(context(c,kind,id,refs,epoch).associatedData()+byteArrayOf(0)+sealed)
    private data class Frame(val sealed:ByteArray,val refs:List<String>,val chunks:List<V3Chunk>)
    private fun encode(plaintext:ByteArray,c:V3Connection,kind:String,id:String,forceChunks:Boolean=false):Frame {
        require(plaintext.isNotEmpty()&&plaintext.size<=24*1024*1024)
        var plain=plaintext;val chunks=mutableListOf<V3Chunk>();val parts=JSONArray()
        if(forceChunks||plain.size>96*1024){
            for(offset in plaintext.indices step 48*1024){val objectID=UUID.randomUUID().toString();val sealed=crypto.sealV3(plaintext.copyOfRange(offset,minOf(offset+48*1024,plaintext.size)),context(c,"chunk",objectID));val digest=v3Hash(sealed);chunks.add(V3Chunk(objectID,digest,sealed));parts.put(JSONObject().put("objectID",objectID).put("digest",digest).put("bytes",sealed.size))}
            plain=body(JSONObject().put("version",3).put("type","chunk-manifest").put("contentType",kind).put("parts",parts))
        }
        val refs=chunks.map{it.digest}.sorted();require(refs.size<=512)
        return Frame(crypto.sealV3(plain,context(c,kind,id,refs)),refs,chunks)
    }
    private fun strings(a:JSONArray)=(0 until a.length()).map{a.getString(it)}
    private suspend fun decode(c:V3Connection,epoch:String,kind:String,id:String,sealed:ByteArray,refs:List<String>,lease:String?=null):ByteArray {
        val plain=crypto.openV3(sealed,context(c,kind,id,refs,epoch));if(refs.isEmpty())return plain
        val manifest=JSONObject(plain.toString(Charsets.UTF_8));val parts=manifest.getJSONArray("parts")
        require(manifest.getInt("version")==3&&manifest.getString("type")=="chunk-manifest"&&manifest.getString("contentType")==kind&&parts.length()<=512)
        require((0 until parts.length()).map{parts.getJSONObject(it).getString("digest")}.sorted()==refs&&refs.distinct().size==refs.size)
        val result=ByteArrayOutputStream()
        for(i in 0 until parts.length()){
            renew(c,lease,epoch)
            val p=parts.getJSONObject(i);val digest=p.getString("digest");val objectID=p.getString("objectID");SyncV3.validateID(objectID)
            val r=call(c,"artifacts/$digest?epoch=$epoch"+(lease?.let{"&lease=$it"}?:""));val bytes=Base64.getDecoder().decode(r.getString("ciphertext"))
            require(r.getString("epoch")==epoch&&r.getString("digest")==digest&&r.getString("objectID")==objectID&&r.getInt("bytes")==p.getInt("bytes")&&bytes.size==p.getInt("bytes")&&bytes.size<=64*1024&&v3Hash(bytes)==digest)
            result.write(crypto.openV3(bytes,context(c,"chunk",objectID,epoch=epoch)));require(result.size()<=24*1024*1024)
        }
        return result.toByteArray()
    }
    private suspend fun upload(chunks:List<V3Chunk>,c:V3Connection){for(chunk in chunks){
        call(c,"artifacts/${chunk.digest}","POST",JSONObject().put("epoch",c.epoch).put("objectID",chunk.objectID).put("ciphertext",Base64.getEncoder().encodeToString(chunk.ciphertext)))
        val r=call(c,"artifacts/${chunk.digest}?epoch=${c.epoch}");require(r.getString("digest")==chunk.digest&&r.getString("objectID")==chunk.objectID&&Base64.getDecoder().decode(r.getString("ciphertext")).contentEquals(chunk.ciphertext))
    }}
    private data class Checkpoint(val payload:JSONObject,val covered:Long,val response:JSONObject)
    private suspend fun readCheckpoint(c:V3Connection,epoch:String):Checkpoint {
        val r=call(c,"checkpoints?epoch=$epoch");require(r.getString("serviceID")==c.serviceID&&r.getString("vaultID")==c.vaultID&&r.getString("sourceEpoch")==epoch)
        leases.add(r.getString("leaseID") to epoch);renewed[r.getString("leaseID")]=System.currentTimeMillis();val cp=r.optJSONObject("checkpoint")?:return Checkpoint(V3Delta.empty(),0,r)
        val sealed=Base64.getDecoder().decode(cp.getString("ciphertext"));val refs=strings(cp.getJSONArray("artifactIDs"));val id=cp.getString("id")
        require(cp.getString("epoch")==epoch&&digest(c,"checkpoint",id,refs,sealed,epoch)==cp.getString("digest"))
        val plain=JSONObject(decode(c,epoch,"checkpoint",id,sealed,refs,r.getString("leaseID")).toString(Charsets.UTF_8))
        require(plain.getInt("version")==3&&plain.getString("type")=="checkpoint"&&plain.getLong("covered")==cp.getLong("covered"))
        return Checkpoint(SyncReplica.validatedPayload(plain.getJSONObject("payload")),cp.getLong("covered"),r)
    }
    private suspend fun page(c:V3Connection,epoch:String,after:Long,lease:String?=null):Pair<JSONObject,List<V3Entry>> {
        renew(c,lease,epoch)
        val r=call(c,"pull?epoch=$epoch&after=$after"+(lease?.let{"&lease=$it"}?:""));val commits=r.getJSONArray("commits");require(r.getString("epoch")==epoch&&commits.length()<=8)
        val entries=mutableListOf<V3Entry>();var cursor=after
        for(i in 0 until commits.length()){
            val item=commits.getJSONObject(i);val id=item.getString("batchID");val sealed=Base64.getDecoder().decode(item.getString("ciphertext"));val refs=strings(item.getJSONArray("artifactIDs"))
            require(item.getLong("revision")==cursor+1&&digest(c,"batch",id,refs,sealed,epoch)==item.getString("digest"))
            val batch=JSONObject(decode(c,epoch,"batch",id,sealed,refs,lease).toString(Charsets.UTF_8));require(refs.isNotEmpty()||maxOf(batch.getJSONArray("operations").length(),batch.optJSONObject("payload")?.optJSONObject("records")?.length()?:0)<=50)
            cursor=item.getLong("revision");entries.add(V3Entry(cursor,id,batch))
        }
        require(r.getLong("nextCursor")==cursor&&r.getLong("head")>=cursor&&r.getBoolean("hasMore")== (cursor<r.getLong("head")))
        return r to entries
    }
    private suspend fun release(c:V3Connection){for((id,epoch) in leases)runCatching{transport.request("DELETE","/v3/vaults/${c.vaultID}/leases/$id",body(JSONObject().put("epoch",epoch).put("floor",0)),c.token)};leases.clear();renewed.clear()}
    private suspend fun publish(c:V3Connection,info:JSONObject,initial:Pair<JSONObject,Long>?=null){
        val b=c.binding
        if(store.pendingCheckpoint(b)==null){
            val(fetched,applied)=store.cursors(b);if(fetched!=applied)return
            val payload=initial?.first?:store.state(b,"confirmed");val covered=initial?.second?:applied;val id=UUID.randomUUID().toString()
            val frame=encode(body(JSONObject().put("version",3).put("type","checkpoint").put("covered",covered).put("payload",payload)),c,"checkpoint",id)
            val expected=if(info.isNull("checkpointID"))null else info.getString("checkpointID")
            val wire=body(JSONObject().put("epoch",c.epoch).put("id",id).put("covered",covered).put("expectedID",expected?:JSONObject.NULL).put("ciphertext",Base64.getEncoder().encodeToString(frame.sealed)).put("artifactIDs",JSONArray(frame.refs)))
            check();store.freezeCheckpoint(b,V3PendingCheckpoint(id,covered,expected,wire,digest(c,"checkpoint",id,frame.refs,frame.sealed)),frame.chunks)
        }
        val p=store.pendingCheckpoint(b)?:return;upload(store.checkpointChunks(b),c)
        try{call(c,"checkpoints","POST",JSONObject(p.wire.toString(Charsets.UTF_8)))}catch(e:V3Failure){
            if(e.code!="checkpoint_conflict")throw e
            readCheckpoint(c,c.epoch);check();store.clearCheckpoint(b);return
        }
        val verified=readCheckpoint(c,c.epoch);require(verified.covered>=p.covered);check();store.clearCheckpoint(b)
    }
    suspend fun synchronize(original:V3Connection):V3SyncResult {
        var c=original
        try{
            var remote=info(c)
            if(remote.getString("epoch")!=c.epoch){val b=store.rebaseEpoch(c.binding,remote.getString("epoch"));c=c.copy(epoch=b.epoch,transactionID=b.transactionID)}
            val source=remote.optString("recoveryFromEpoch").takeUnless{it.isEmpty()||it=="null"}
            if(source!=null){
                var restored=readCheckpoint(c,source);var cursor=restored.covered;val target=remote.optLong("recoveryHead",cursor)
                while(cursor<target){val(p,entries)=page(c,source,cursor,restored.response.getString("leaseID"));var payload=restored.payload;for(e in entries)payload=SyncReplica.applyingV3(payload,e.batch);restored=restored.copy(payload=payload);cursor=p.getLong("nextCursor")}
                check();store.installCheckpoint(c.binding,restored.payload,0);applied();publish(c,remote,restored.payload to 0L)
            }
            remote=info(c)
            store.anchor(c.binding)?.let{anchor->val receipt=call(c,"receipts/${anchor.getString("batchID")}?epoch=${c.epoch}").getJSONObject("receipt");if(!equalV3(receipt,anchor))throw V3Failure("cursor_mismatch")}
            repeat(16){
                val b=c.binding;val(fetched,appliedCursor)=store.cursors(b);if(fetched>remote.getLong("head"))throw V3Failure("cursor_mismatch")
                val checkpointID=remote.optString("checkpointID").takeUnless{it.isEmpty()||it=="null"}
                if(fetched<remote.getLong("gcFloor")||(fetched==0L&&checkpointID!=null&&store.installedCheckpoint(b)!=checkpointID)){
                    val cp=readCheckpoint(c,c.epoch);check();store.installCheckpoint(b,cp.payload,cp.covered,cp.response.optJSONObject("checkpoint")?.getString("id"));applied();return@repeat
                }
                if(fetched<remote.getLong("head")){
                    val(p,entries)=page(c,c.epoch,fetched);check();store.receive(b,entries);applied();remote.put("head",p.getLong("head")).put("gcFloor",p.getLong("gcFloor"));return@repeat
                }
                val covered=remote.optLong("checkpointCovered",0)
                val needsCheckpoint=checkpointID==null||((remote.getLong("head")-covered>=500||remote.optLong("logBytes")>=4*1024*1024)&&remote.getLong("head")>covered)||store.pendingCheckpoint(b)!=null
                if(appliedCursor==fetched&&needsCheckpoint){publish(c,remote);release(c);for(gcRound in 0 until 8){if(!call(c,"gc","POST",JSONObject().put("epoch",c.epoch)).getBoolean("hasMore"))break};remote=info(c);return@repeat}
                val first=store.queue(b).firstOrNull()
                if(first!=null){
                    if(first.receipt!=null&&fetched==remote.getLong("head")){release(c);return V3SyncResult(c,false,true)}
                    if(first.wire==null){
                        val batch=JSONObject(first.plain.toString(Charsets.UTF_8));val frame=encode(first.plain,c,"batch",first.id,maxOf(batch.getJSONArray("operations").length(),batch.optJSONObject("payload")?.optJSONObject("records")?.length()?:0)>50)
                        val wire=body(JSONObject().put("version",3).put("epoch",c.epoch).put("batchID",first.id).put("ciphertext",Base64.getEncoder().encodeToString(frame.sealed)).put("artifactIDs",JSONArray(frame.refs)))
                        check();store.freeze(b,first.id,wire,digest(c,"batch",first.id,frame.refs,frame.sealed),frame.chunks)
                    }
                    val frozen=store.queue(b).first{it.id==first.id};upload(store.chunks(frozen.id),c)
                    val result=try{call(c,"push","POST",JSONObject(frozen.wire!!.toString(Charsets.UTF_8)))}catch(e:Exception){try{call(c,"receipts/${frozen.id}?epoch=${c.epoch}")}catch(_:Exception){throw e}}
                    val receipt=result.getJSONObject("receipt");require(result.getString("serviceID")==c.serviceID&&result.getString("vaultID")==c.vaultID&&result.getString("epoch")==c.epoch&&receipt.getString("batchID")==frozen.id&&receipt.getString("digest")==frozen.digest)
                    check();store.acknowledge(b,frozen.id,frozen.digest!!,receipt.getLong("revision"));remote=info(c);store.receive(b,emptyList());applied();return@repeat
                }
                release(c);return V3SyncResult(c,false,fetched!=appliedCursor)
            }
            release(c);return V3SyncResult(c,true,false)
        }catch(e:Exception){release(c);throw e}
    }
}
