package com.pindo.app

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Portable plaintext export. Whitelisting keeps credentials and replica history out. */
object BackupCodec {
    const val MAX_BYTES = 10 * 1024 * 1024
    private val taskFields = setOf("id", "title", "note", "plannedDay", "groupID", "parentID", "phase", "order", "createdAt", "updatedAt", "startedAt", "completedAt", "isProgressExplicit")
    private val groupFields = setOf("id", "name", "colorHex")
    private val uuidShape = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    fun encode(document: JSONObject): String {
        val result = sanitized(document)
        val text = result.toString(2)
        require(text.toByteArray(Charsets.UTF_8).size <= MAX_BYTES) { "资料超过 10 MiB 导出上限。" }
        return text
    }

    fun decode(text: String): JSONObject {
        require(text.toByteArray(Charsets.UTF_8).size <= MAX_BYTES) { "导入文件超过 10 MiB 上限。" }
        val input = JSONObject(text)
        val version = if (input.has("version")) input.get("version") else input.opt("schemaVersion")
        require(version is Number && version.toDouble() == 1.0) { "资料来自不支持的版本。" }
        return sanitized(input)
    }

    internal fun sanitized(document: JSONObject): JSONObject {
        val tasks = JSONArray()
        val groups = JSONArray()
        for (source in document.getJSONArray("tasks").objects()) {
            val task = keep(source, taskFields)
            task.put("order", validatedTaskOrder(task.get("order")))
            if (task.has("isProgressExplicit") && !task.isNull("isProgressExplicit")) {
                require(task.get("isProgressExplicit") is Boolean) { "事项进度来源无效。" }
            }
            for (field in listOf("title", "note", "phase")) {
                if (field == "note" && !task.has(field)) continue
                require(task.get(field) is String) { "事项文字或状态无效。" }
            }
            val day = task.getJSONObject("plannedDay")
            task.put("plannedDay", TodoRules.dayJSON(validatedTaskDay(day)))
            task.put("id", canonicalID(task.getString("id")))
            for (field in listOf("groupID", "parentID")) {
                if (task.has(field) && !task.isNull(field)) task.put(field, canonicalID(task.getString(field)))
            }
            if (!task.has("note")) task.put("note", "")
            for (date in listOf("createdAt", "updatedAt")) {
                val value = task.get(date)
                require(value is Number && value.toDouble().isFinite()) { "事项时间无效。" }
            }
            for (date in listOf("startedAt", "completedAt")) {
                if (task.has(date) && !task.isNull(date)) {
                    val value = task.get(date)
                    require(value is Number && value.toDouble().isFinite()) { "事项时间无效。" }
                }
            }
            tasks.put(task)
        }
        for (source in document.getJSONArray("groups").objects()) {
            val group = keep(source, groupFields)
            require(group.get("name") is String && group.get("colorHex") is String) { "分组资料无效。" }
            group.put("id", canonicalID(group.getString("id")))
            groups.put(group)
        }
        val result = emptyDocument().put("tasks", tasks).put("groups", groups)
        validateDocument(result)
        return result
    }

    private fun keep(source: JSONObject, allowed: Set<String>): JSONObject = JSONObject().also { result ->
        allowed.forEach { field -> if (source.has(field)) result.put(field, source.get(field)) }
    }

    private fun canonicalID(value: String): String {
        require(uuidShape.matches(value)) { "资料中的标识无效。" }
        return UUID.fromString(value).toString()
    }
}
