package com.pindo.app.sync

import android.content.Context
import android.database.DatabaseErrorHandler
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteDatabaseCorruptException
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import com.pindo.app.emptyDocument
import com.pindo.app.validateDocument

internal data class V3Binding(val serviceID:String,val vaultID:String,val epoch:String,val transactionID:String=UUID.randomUUID().toString()) {
    val channel get()="cloudflare-v3:$serviceID:$vaultID"
    init{listOf(serviceID,vaultID,epoch,transactionID).forEach(SyncV3::validateID)}
    fun json()=JSONObject().put("serviceID",serviceID).put("vaultID",vaultID).put("epoch",epoch).put("transactionID",transactionID)
    companion object{fun from(j:JSONObject)=V3Binding(j.getString("serviceID"),j.getString("vaultID"),j.getString("epoch"),j.getString("transactionID"))}
}
internal data class V3Queued(val id:String,val epoch:String,val plain:ByteArray,val wire:ByteArray?,val digest:String?,val receipt:Long?)
internal data class V3Chunk(val objectID:String,val digest:String,val ciphertext:ByteArray)
internal data class V3PendingCheckpoint(val id:String,val covered:Long,val expectedID:String?,val wire:ByteArray,val digest:String)
internal data class V3Entry(val revision:Long,val id:String,val batch:JSONObject)

internal class V3Store(context:Context) {
    private val file=File(context.filesDir,"pindo.sqlite")
    val actor=UUID.randomUUID().toString()
    private val db=SQLiteDatabase.openDatabase(file.path,null,SQLiteDatabase.CREATE_IF_NECESSARY or SQLiteDatabase.ENABLE_WRITE_AHEAD_LOGGING,
        DatabaseErrorHandler{throw SQLiteDatabaseCorruptException("数据库损坏，原文件已保留。")})
    private var cached:JSONObject?=null
    var beforeCommit:(()->Unit)?=null
    init{
        db.execSQL("PRAGMA foreign_keys=ON");db.execSQL("PRAGMA synchronous=FULL");db.execSQL("PRAGMA busy_timeout=5000")
        require(db.version<=1){"本机数据库来自更新版本。"}
        transaction{
            for(sql in listOf(
                "CREATE TABLE IF NOT EXISTS app_meta(key TEXT PRIMARY KEY,value BLOB NOT NULL)",
                "CREATE TABLE IF NOT EXISTS app_entities(kind TEXT NOT NULL,id TEXT NOT NULL,position INTEGER NOT NULL,data BLOB NOT NULL,note BLOB,PRIMARY KEY(kind,id))",
                "CREATE TABLE IF NOT EXISTS v3_vaults(channel TEXT PRIMARY KEY,epoch TEXT NOT NULL,fetch_cursor INTEGER NOT NULL DEFAULT 0,apply_cursor INTEGER NOT NULL DEFAULT 0,anchor BLOB,checkpoint_applied TEXT)",
                "CREATE TABLE IF NOT EXISTS v3_records(channel TEXT NOT NULL,layer TEXT NOT NULL,key TEXT NOT NULL,field TEXT NOT NULL,data BLOB NOT NULL,PRIMARY KEY(channel,layer,key,field))",
                "CREATE TABLE IF NOT EXISTS v3_seen(channel TEXT NOT NULL,layer TEXT NOT NULL,actor TEXT NOT NULL,counter INTEGER NOT NULL,PRIMARY KEY(channel,layer,actor))",
                "CREATE TABLE IF NOT EXISTS v3_queue(seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,channel TEXT NOT NULL,epoch TEXT NOT NULL,plain BLOB NOT NULL,wire BLOB,digest TEXT,receipt INTEGER)",
                "CREATE TABLE IF NOT EXISTS v3_chunks(batch_id TEXT NOT NULL REFERENCES v3_queue(id) ON DELETE CASCADE,object_id TEXT NOT NULL,digest TEXT NOT NULL,ciphertext BLOB NOT NULL,PRIMARY KEY(batch_id,digest))",
                "CREATE TABLE IF NOT EXISTS v3_inbox(channel TEXT NOT NULL,epoch TEXT NOT NULL,revision INTEGER NOT NULL,id TEXT NOT NULL,data BLOB NOT NULL,applied INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(channel,epoch,revision))",
                "CREATE TABLE IF NOT EXISTS v3_retired(id TEXT PRIMARY KEY,channel TEXT NOT NULL,epoch TEXT NOT NULL,plain BLOB NOT NULL,wire BLOB,digest TEXT,receipt INTEGER)",
                "CREATE TABLE IF NOT EXISTS v3_retired_chunks(batch_id TEXT NOT NULL,object_id TEXT NOT NULL,digest TEXT NOT NULL,ciphertext BLOB NOT NULL,PRIMARY KEY(batch_id,digest))",
                "CREATE TABLE IF NOT EXISTS v3_pending_checkpoints(channel TEXT PRIMARY KEY,epoch TEXT NOT NULL,id TEXT NOT NULL,covered INTEGER NOT NULL,expected TEXT,wire BLOB NOT NULL,digest TEXT NOT NULL)",
                "CREATE TABLE IF NOT EXISTS v3_checkpoint_chunks(channel TEXT NOT NULL,object_id TEXT NOT NULL,digest TEXT NOT NULL,ciphertext BLOB NOT NULL,PRIMARY KEY(channel,digest))"
            ))db.execSQL(sql)
            db.version=1
        }
        file.setReadable(false,false);file.setWritable(false,false);file.setReadable(true,true);file.setWritable(true,true)
    }
    private fun bytes(j:Any)=j.toString().toByteArray(Charsets.UTF_8)
    @Synchronized fun <T> transaction(body:()->T):T {
        if(db.inTransaction())return body()
        val old=cached;db.beginTransaction()
        try{val result=body();beforeCommit?.invoke();db.setTransactionSuccessful();return result}
        catch(e:Exception){cached=old;throw e}finally{db.endTransaction()}
    }
    private fun exec(sql:String,vararg args:Any?){db.execSQL(sql,args)}
    private fun rows(sql:String,vararg args:Any?):List<Map<String,Any?>> = db.rawQuery(sql,args.map{it?.toString()}.toTypedArray()).use{c->
        buildList{while(c.moveToNext()){val row=mutableMapOf<String,Any?>();for(i in 0 until c.columnCount)row[c.getColumnName(i)]=when(c.getType(i)){android.database.Cursor.FIELD_TYPE_NULL->null;android.database.Cursor.FIELD_TYPE_BLOB->c.getBlob(i);android.database.Cursor.FIELD_TYPE_INTEGER->c.getLong(i);else->c.getString(i)};add(row)}}}
    private fun meta(key:String)=rows("SELECT value FROM app_meta WHERE key=?",key).firstOrNull()?.get("value") as? ByteArray
    private fun put(key:String,value:Any?){if(value==null)exec("DELETE FROM app_meta WHERE key=?",key)else exec("INSERT OR REPLACE INTO app_meta VALUES(?,?)",key,bytes(value))}
    fun initialized()=meta("document")!=null
    @Synchronized fun initialize(document:JSONObject){validateDocument(document);transaction{if(!initialized()){entities(document,null);put("migration",JSONObject().put("state","committed"))}};check(equalV3(read(),document))}
    @Synchronized fun binding():V3Binding?=meta("active_v3")?.let{V3Binding.from(JSONObject(it.toString(Charsets.UTF_8)))}
    @Synchronized fun read():JSONObject {
        cached?.let{return copyV3(it) as JSONObject}
        val doc=JSONObject((meta("document")?:error("本机资料尚未迁移。")).toString(Charsets.UTF_8))
        for((kind,array) in listOf("task" to "tasks","group" to "groups")){
            val items=JSONArray();for(r in rows("SELECT data,note FROM app_entities WHERE kind=? ORDER BY position,id",kind)){
                val j=JSONObject((r["data"] as ByteArray).toString(Charsets.UTF_8));if(kind=="task")j.put("note",(r["note"] as? ByteArray)?.toString(Charsets.UTF_8)?:"");items.put(j)
            };doc.put(array,items)
        }
        validateDocument(doc);cached=copyV3(doc) as JSONObject;return doc
    }
    private fun shell(j:JSONObject):JSONObject=(copyV3(j) as JSONObject).put("tasks",JSONArray()).put("groups",JSONArray())
    private fun entities(next:JSONObject,previous:JSONObject?){
        for((kind,array) in listOf("task" to "tasks","group" to "groups")){
            fun index(j:JSONObject?):Map<String,Pair<Int,JSONObject>>{val a=j?.getJSONArray(array)?:JSONArray();return (0 until a.length()).associate{a.getJSONObject(it).getString("id") to (it to a.getJSONObject(it))}}
            val old=index(previous);val current=index(next)
            for(id in old.keys-current.keys)exec("DELETE FROM app_entities WHERE kind=? AND id=?",kind,id)
            for((id,pair) in current){val (position,item)=pair;val prev=old[id];val header=copyV3(item) as JSONObject;val oldHeader=prev?.second?.let{copyV3(it) as JSONObject}
                if(kind=="task"){header.remove("note");oldHeader?.remove("note")}
                if(prev==null)exec("INSERT INTO app_entities VALUES(?,?,?,?,?)",kind,id,position,bytes(header),if(kind=="task")item.optString("note").toByteArray() else null)
                else{
                    if(position!=prev.first||!equalV3(header,oldHeader))exec("UPDATE app_entities SET position=?,data=? WHERE kind=? AND id=?",position,bytes(header),kind,id)
                    if(kind=="task"&&item.optString("note")!=prev.second.optString("note"))exec("UPDATE app_entities SET note=? WHERE kind=? AND id=?",item.optString("note").toByteArray(),kind,id)
                }
            }
        }
        if(previous==null||!equalV3(shell(next),shell(previous)))put("document",shell(next))
    }
    @Synchronized fun write(next:JSONObject,capture:Boolean=true){
        validateDocument(next);val previous=if(initialized())read() else null
        transaction{
            val b=binding()
            if(capture&&b!=null&&previous!=null){
                val known=rows("SELECT key FROM v3_records WHERE channel=? AND layer='optimistic' AND field='\$alive'",b.channel).map{it["key"].toString()}.toSet()
                val clock=(rows("SELECT COALESCE(MAX(counter),0) AS n FROM v3_seen WHERE channel=?",b.channel).first()["n"] as Number).toLong()
                require(clock<SyncV3.MAX_COUNTER)
                val batch=V3Delta.capture(previous,next,actor,clock+1,known){key->
                    val data=rows("SELECT data FROM v3_records WHERE channel=? AND layer='optimistic' AND key=? AND field='\$notes'",b.channel,key).firstOrNull()?.get("data") as? ByteArray
                    data?.let{JSONArray(it.toString(Charsets.UTF_8))}?:JSONArray()
                }
                if(batch.getJSONArray("operations").length()>0){
                    enqueue(b,batch);val ops=batch.getJSONArray("operations")
                    for(i in 0 until ops.length()){
                        val op=ops.getJSONObject(i);val fields=op.getJSONObject("fields");val key=op.getString("recordKey")
                        for(field in fields.keys()){val reg=fields.getJSONObject(field);record(b,"optimistic",key,field,reg);seen(b,"optimistic",reg.getJSONObject("stamp"))}
                        val notes=op.getJSONArray("notes");if(notes.length()>0){record(b,"optimistic",key,"\$notes",notes);for(j in 0 until notes.length())seen(b,"optimistic",notes.getJSONObject(j).getJSONObject("stamp"))}
                    }
                }
            }
            entities(next,previous);cached=copyV3(next) as JSONObject
        }
    }
    private fun enqueue(b:V3Binding,batch:JSONObject){val data=bytes(batch);require(data.size<=24*1024*1024){"单个逻辑事务超过 24 MiB，本机内容已保留。"};exec("INSERT INTO v3_queue(id,channel,epoch,plain) VALUES(?,?,?,?)",UUID.randomUUID().toString(),b.channel,b.epoch,data)}
    private fun record(b:V3Binding,layer:String,key:String,field:String,value:Any)=exec("INSERT OR REPLACE INTO v3_records VALUES(?,?,?,?,?)",b.channel,layer,key,field,bytes(value))
    private fun seen(b:V3Binding,layer:String,stamp:JSONObject)=exec("INSERT OR REPLACE INTO v3_seen VALUES(?,?,?,MAX(?,COALESCE((SELECT counter FROM v3_seen WHERE channel=? AND layer=? AND actor=?),0)))",b.channel,layer,stamp.getString("deviceID"),stamp.getLong("counter"),b.channel,layer,stamp.getString("deviceID"))
    @Synchronized fun state(b:V3Binding,layer:String):JSONObject {
        val result=V3Delta.empty();val records=result.getJSONObject("records");val seen=result.getJSONObject("seen")
        for(row in rows("SELECT key,field,data FROM v3_records WHERE channel=? AND layer=?",b.channel,layer)){
            val key=row["key"].toString();val field=row["field"].toString();val r=records.optJSONObject(key)?:JSONObject().put("fields",JSONObject()).put("notes",JSONArray())
            val raw=(row["data"] as ByteArray).toString(Charsets.UTF_8)
            if(field=="\$notes")r.put("notes",JSONArray(raw))else r.getJSONObject("fields").put(field,JSONObject(raw));records.put(key,r)
        }
        for(row in rows("SELECT actor,counter FROM v3_seen WHERE channel=? AND layer=?",b.channel,layer))seen.put(row["actor"].toString(),row["counter"])
        return SyncReplica.validatedPayload(result)
    }
    private fun saveState(b:V3Binding,layer:String,next:JSONObject,old:JSONObject){
        val records=next.getJSONObject("records");val previous=old.getJSONObject("records")
        for(key in previous.keys())if(!records.has(key))exec("DELETE FROM v3_records WHERE channel=? AND layer=? AND key=?",b.channel,layer,key)
        for(key in records.keys()){
            val r=records.getJSONObject(key);val before=previous.optJSONObject(key);val fields=r.getJSONObject("fields")
            for(name in fields.keys())if(!equalV3(fields.get(name),before?.optJSONObject("fields")?.opt(name)))record(b,layer,key,name,fields.get(name))
            if(!equalV3(r.getJSONArray("notes"),before?.optJSONArray("notes")))record(b,layer,key,"\$notes",r.getJSONArray("notes"))
        }
        val clocks=next.getJSONObject("seen");val oldClocks=old.getJSONObject("seen")
        for(a in oldClocks.keys())if(!clocks.has(a))exec("DELETE FROM v3_seen WHERE channel=? AND layer=? AND actor=?",b.channel,layer,a)
        for(a in clocks.keys())if(clocks.getLong(a)!=oldClocks.optLong(a))seen(b,layer,JSONObject().put("deviceID",a).put("counter",clocks.getLong(a)))
    }
    private fun project(b:V3Binding,confirmed:JSONObject,oldOptimistic:JSONObject,before:JSONObject){
        var optimistic=confirmed;for(q in queue(b))optimistic=SyncReplica.applyingV3(optimistic,JSONObject(q.plain.toString(Charsets.UTF_8)))
        saveState(b,"optimistic",optimistic,oldOptimistic)
        val visible=SyncReplica.fresh(version=2).apply{merge(optimistic)}.projected()
        val next=(copyV3(before) as JSONObject).put("tasks",visible.first).put("groups",visible.second)
        entities(next,before);cached=next
    }
    @Synchronized fun bind(b:V3Binding,importLocal:Boolean=true):V3Binding=transaction{
        val original=read();val row=rows("SELECT epoch FROM v3_vaults WHERE channel=?",b.channel).firstOrNull()
        if(row==null){
            require(rows("SELECT channel FROM v3_vaults").size<8){"本机资料库归档已满，未删除旧库。"}
            if(binding()==null&&meta("unbound_source")==null)put("unbound_source",original)
            exec("INSERT INTO v3_vaults(channel,epoch) VALUES(?,?)",b.channel,b.epoch)
            if(importLocal){
                val legacy=if(binding()==null&&original.optJSONObject("syncReplica")!=null)SyncReplica.fromJson(original.getJSONObject("syncReplica")).upgraded() else SyncReplica.fresh(version=2)
                legacy.rotateActor();legacy.capture(original.getJSONArray("tasks"),original.getJSONArray("groups"))
                if(legacy.payload.getJSONObject("records").length()>0){enqueue(b,V3Delta.baseline(legacy.payload));saveState(b,"optimistic",legacy.payload,V3Delta.empty())}
            }
        }
        val installed=if(row!=null)b.copy(epoch=row["epoch"].toString())else b
        put("active_v3",installed.json())
        val state=state(installed,"optimistic");val visible=SyncReplica.fresh(version=2).apply{merge(state)}.projected()
        val next=(copyV3(original) as JSONObject).put("tasks",visible.first).put("groups",visible.second);entities(next,original);cached=next;installed
    }
    @Synchronized fun cursors(b:V3Binding):Pair<Long,Long>{val r=rows("SELECT fetch_cursor,apply_cursor FROM v3_vaults WHERE channel=? AND epoch=?",b.channel,b.epoch).firstOrNull()?:error("epoch_mismatch");return (r["fetch_cursor"] as Number).toLong() to (r["apply_cursor"] as Number).toLong()}
    @Synchronized fun queue(b:V3Binding):List<V3Queued> = rows("SELECT id,epoch,plain,wire,digest,receipt FROM v3_queue WHERE channel=? AND epoch=? ORDER BY seq",b.channel,b.epoch).map{V3Queued(it["id"].toString(),it["epoch"].toString(),it["plain"] as ByteArray,it["wire"] as? ByteArray,it["digest"] as? String,(it["receipt"] as? Number)?.toLong())}
    @Synchronized fun freeze(b:V3Binding,id:String,wire:ByteArray,digest:String,chunks:List<V3Chunk>)=transaction{
        require(binding()==b);val q=queue(b).first{it.id==id};require(q.wire==null||q.wire.contentEquals(wire))
        for(c in chunks)exec("INSERT OR IGNORE INTO v3_chunks VALUES(?,?,?,?)",id,c.objectID,c.digest,c.ciphertext)
        exec("UPDATE v3_queue SET wire=?,digest=? WHERE id=? AND channel=? AND epoch=?",wire,digest,id,b.channel,b.epoch)
    }
    @Synchronized fun chunks(id:String):List<V3Chunk> = rows("SELECT object_id,digest,ciphertext FROM v3_chunks WHERE batch_id=? ORDER BY digest",id).map{V3Chunk(it["object_id"].toString(),it["digest"].toString(),it["ciphertext"] as ByteArray)}
    @Synchronized fun acknowledge(b:V3Binding,id:String,digest:String,revision:Long)=transaction{
        require(binding()==b);SyncV3.validateCounter(revision);val q=queue(b).first{it.id==id};require(q.wire!=null&&q.digest==digest)
        exec("UPDATE v3_queue SET receipt=? WHERE id=? AND channel=? AND epoch=? AND digest=?",revision,id,b.channel,b.epoch,digest)
        exec("UPDATE v3_vaults SET anchor=? WHERE channel=? AND epoch=?",bytes(JSONObject().put("batchID",id).put("revision",revision).put("digest",digest)),b.channel,b.epoch)
    }
    @Synchronized fun anchor(b:V3Binding):JSONObject?=(rows("SELECT anchor FROM v3_vaults WHERE channel=?",b.channel).firstOrNull()?.get("anchor") as? ByteArray)?.let{JSONObject(it.toString(Charsets.UTF_8))}
    @Synchronized fun receive(b:V3Binding,entries:List<V3Entry>)=transaction{
        require(binding()==b);val before=read();val old=state(b,"confirmed");val oldOpt=state(b,"optimistic");var confirmed=old
        var(fetched,applied)=cursors(b)
        for(e in entries){require(e.revision==fetched+1);require(queue(b).none{it.receipt==e.revision&&it.id!=e.id});exec("INSERT INTO v3_inbox VALUES(?,?,?,?,?,0)",b.channel,b.epoch,e.revision,e.id,bytes(e.batch));fetched=e.revision}
        var progress=true
        while(progress){progress=false
            for(r in rows("SELECT revision,data FROM v3_inbox WHERE channel=? AND epoch=? AND applied=0 ORDER BY revision",b.channel,b.epoch)){
                try{confirmed=SyncReplica.applyingV3(confirmed,JSONObject((r["data"] as ByteArray).toString(Charsets.UTF_8)));exec("UPDATE v3_inbox SET applied=1 WHERE channel=? AND epoch=? AND revision=?",b.channel,b.epoch,r["revision"]);progress=true}catch(_:MissingV3Create){}
            }
        }
        while((rows("SELECT applied FROM v3_inbox WHERE channel=? AND epoch=? AND revision=?",b.channel,b.epoch,applied+1).firstOrNull()?.get("applied") as? Number)?.toLong()==1L)applied++
        exec("UPDATE v3_vaults SET fetch_cursor=?,apply_cursor=? WHERE channel=? AND epoch=?",fetched,applied,b.channel,b.epoch)
        exec("DELETE FROM v3_queue WHERE channel=? AND epoch=? AND receipt IS NOT NULL AND receipt<=?",b.channel,b.epoch,applied)
        saveState(b,"confirmed",confirmed,old);project(b,confirmed,oldOpt,before)
        exec("DELETE FROM v3_inbox WHERE channel=? AND epoch=? AND revision<=?",b.channel,b.epoch,applied)
    }
    @Synchronized fun installCheckpoint(b:V3Binding,payload:JSONObject,covered:Long,id:String?=null)=transaction{
        require(binding()==b);SyncV3.validateCounter(covered);SyncReplica.validatedPayload(payload)
        val before=read();val oldOpt=state(b,"optimistic")
        exec("DELETE FROM v3_records WHERE channel=? AND layer='confirmed'",b.channel);exec("DELETE FROM v3_seen WHERE channel=? AND layer='confirmed'",b.channel)
        saveState(b,"confirmed",payload,V3Delta.empty());exec("UPDATE v3_vaults SET fetch_cursor=?,apply_cursor=?,checkpoint_applied=? WHERE channel=? AND epoch=?",covered,covered,id,b.channel,b.epoch)
        exec("DELETE FROM v3_inbox WHERE channel=? AND epoch=?",b.channel,b.epoch);project(b,payload,oldOpt,before)
    }
    @Synchronized fun installedCheckpoint(b:V3Binding)=rows("SELECT checkpoint_applied FROM v3_vaults WHERE channel=? AND epoch=?",b.channel,b.epoch).firstOrNull()?.get("checkpoint_applied") as? String
    @Synchronized fun rebaseEpoch(old:V3Binding,epoch:String):V3Binding=transaction{
        require(binding()==old);val next=old.copy(epoch=epoch,transactionID=UUID.randomUUID().toString());val optimistic=state(old,"optimistic")
        clearCheckpoint(old)
        exec("INSERT OR IGNORE INTO v3_retired SELECT id,channel,epoch,plain,wire,digest,receipt FROM v3_queue WHERE channel=?",old.channel)
        exec("INSERT OR IGNORE INTO v3_retired_chunks SELECT * FROM v3_chunks WHERE batch_id IN (SELECT id FROM v3_queue WHERE channel=?)",old.channel)
        exec("DELETE FROM v3_queue WHERE channel=?",old.channel);exec("DELETE FROM v3_records WHERE channel=? AND layer='confirmed'",old.channel);exec("DELETE FROM v3_seen WHERE channel=? AND layer='confirmed'",old.channel)
        exec("DELETE FROM v3_inbox WHERE channel=?",old.channel);exec("UPDATE v3_vaults SET epoch=?,fetch_cursor=0,apply_cursor=0,anchor=NULL,checkpoint_applied=NULL WHERE channel=?",epoch,old.channel)
        if(optimistic.getJSONObject("records").length()>0)enqueue(next,V3Delta.baseline(optimistic))
        put("active_v3",next.json());next
    }
    @Synchronized fun pendingCheckpoint(b:V3Binding):V3PendingCheckpoint?=rows("SELECT id,covered,expected,wire,digest FROM v3_pending_checkpoints WHERE channel=? AND epoch=?",b.channel,b.epoch).firstOrNull()?.let{V3PendingCheckpoint(it["id"].toString(),(it["covered"] as Number).toLong(),it["expected"] as? String,it["wire"] as ByteArray,it["digest"].toString())}
    @Synchronized fun freezeCheckpoint(b:V3Binding,p:V3PendingCheckpoint,chunks:List<V3Chunk>)=transaction{
        require(binding()==b&&pendingCheckpoint(b)==null);exec("INSERT INTO v3_pending_checkpoints VALUES(?,?,?,?,?,?,?)",b.channel,b.epoch,p.id,p.covered,p.expectedID,p.wire,p.digest)
        for(c in chunks)exec("INSERT INTO v3_checkpoint_chunks VALUES(?,?,?,?)",b.channel,c.objectID,c.digest,c.ciphertext)
    }
    @Synchronized fun checkpointChunks(b:V3Binding)=rows("SELECT object_id,digest,ciphertext FROM v3_checkpoint_chunks WHERE channel=? ORDER BY digest",b.channel).map{V3Chunk(it["object_id"].toString(),it["digest"].toString(),it["ciphertext"] as ByteArray)}
    @Synchronized fun clearCheckpoint(b:V3Binding)=transaction{exec("DELETE FROM v3_pending_checkpoints WHERE channel=?",b.channel);exec("DELETE FROM v3_checkpoint_chunks WHERE channel=?",b.channel)}
}
