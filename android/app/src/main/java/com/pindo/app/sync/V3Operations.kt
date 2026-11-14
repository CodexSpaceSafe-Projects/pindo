package com.pindo.app.sync

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

internal fun copyV3(value: Any?): Any = when(value) {
    null,JSONObject.NULL -> JSONObject.NULL
    is JSONObject -> JSONObject().also { out -> value.keys().forEach { out.put(it,copyV3(value.get(it))) } }
    is JSONArray -> JSONArray().also { out -> for(i in 0 until value.length())out.put(copyV3(value.get(i))) }
    else -> value
}
internal fun equalV3(a:Any?,b:Any?):Boolean = when {
    a==null||a==JSONObject.NULL -> b==null||b==JSONObject.NULL
    b==null||b==JSONObject.NULL -> false
    a is Number && b is Number -> a.toDouble()==b.toDouble()
    a is JSONObject && b is JSONObject -> a.keys().asSequence().toSet()==b.keys().asSequence().toSet() && a.keys().asSequence().all { equalV3(a.get(it),b.get(it)) }
    a is JSONArray && b is JSONArray -> a.length()==b.length() && (0 until a.length()).all { equalV3(a.get(it),b.get(it)) }
    else -> a==b
}
internal class MissingV3Create(val key:String):Exception()
internal object V3Delta {
    fun empty()=JSONObject().put("version",2).put("seen",JSONObject()).put("records",JSONObject())
    fun baseline(payload:JSONObject)=JSONObject().put("version",3).put("type","baseline").put("operations",JSONArray()).put("payload",payload)
    fun capture(before:JSONObject,after:JSONObject,actor:String,clock:Long,known:Set<String>,notes:(String)->JSONArray):JSONObject {
        SyncV3.validateID(actor);require(clock in 1..SyncV3.MAX_COUNTER)
        val stamp=JSONObject().put("counter",clock).put("deviceID",actor)
        fun register(value:Any)=JSONObject().put("value",value).put("stamp",copyV3(stamp))
        val operations=JSONArray()
        for((kind,array) in listOf("group" to "groups","task" to "tasks")) {
            fun index(d:JSONObject):Map<String,JSONObject> { val a=d.getJSONArray(array);return (0 until a.length()).associate { a.getJSONObject(it).getString("id").lowercase() to a.getJSONObject(it) } }
            val old=index(before);val current=index(after)
            for(id in (old.keys+current.keys).sorted()) {
                val previous=old[id];val value=current[id];if(equalV3(previous,value))continue
                val key="$kind:$id";val fields=JSONObject();val versions=JSONArray()
                val operation=when { value==null -> "delete";previous==null -> if(key in known)"restore" else "create";else -> "patch" }
                if(value==null)fields.put("\$alive",register(false))
                else {
                    fun values(v:JSONObject):JSONObject {
                        if(kind=="group")return JSONObject().put("name",v.get("name")).put("colorHex",v.get("colorHex"))
                        val result=JSONObject()
                        for(name in listOf("title","plannedDay","groupID","parentID","phase","order","createdAt","updatedAt","startedAt","completedAt"))result.put(name,copyV3(v.opt(name)))
                        result.put("lifecycle",JSONObject().put("phase",v.getString("phase")).put("startedAt",copyV3(v.opt("startedAt"))).put("completedAt",copyV3(v.opt("completedAt")))
                            .put("isProgressExplicit",v.optBoolean("isProgressExplicit",v.getString("phase")=="inProgress")))
                        return result
                    }
                    val all=values(value);val prev=previous?.let(::values)?:JSONObject()
                    for(name in all.keys())if(!equalV3(all.get(name),prev.opt(name)))fields.put(name,register(all.get(name)))
                    if(previous==null)fields.put("\$alive",register(true))
                    if(fields.has("lifecycle"))for(name in listOf("phase","startedAt","completedAt"))fields.put(name,register(all.get(name)))
                    if(kind=="task"&&(previous==null||previous.optString("note")!=value.optString("note"))) {
                        val seen=JSONObject();val observed=notes(key)
                        for(i in 0 until observed.length()) {
                            val note=observed.getJSONObject(i);val dot=note.getJSONObject("stamp");val a=dot.getString("deviceID")
                            seen.put(a,maxOf(seen.optLong(a),dot.getLong("counter")))
                            val context=note.getJSONObject("seen");for(a2 in context.keys())seen.put(a2,maxOf(seen.optLong(a2),context.getLong(a2)))
                        }
                        versions.put(JSONObject().put("value",value.optString("note")).put("stamp",copyV3(stamp)).put("seen",seen))
                    }
                }
                operations.put(JSONObject().put("recordKey",key).put("kind",operation).put("fields",fields).put("notes",versions))
            }
        }
        require(operations.length()<=20_000)
        return JSONObject().put("version",3).put("type","batch").put("operations",operations)
    }
}
