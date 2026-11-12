package com.pindo.app

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.util.UUID

data class Todo(val id: String, val title: String, val note: String, val day: LocalDate,
                val groupID: String?, val parentID: String?, val phase: String, val order: Int,
                val json: JSONObject) {
    companion object {
        fun from(json: JSONObject): Todo {
            val day = json.getJSONObject("plannedDay")
            return Todo(json.getString("id").lowercase(), json.getString("title"), json.optString("note"),
                LocalDate.of(day.getInt("year"), day.getInt("month"), day.getInt("day")),
                json.optionalID("groupID"), json.optionalID("parentID"), json.getString("phase"),
                json.getInt("order"), json)
        }
    }
}

data class TodoGroup(val id: String, val name: String, val color: String) {
    companion object {
        fun from(json: JSONObject) = TodoGroup(json.getString("id").lowercase(), json.getString("name"), json.getString("colorHex"))
    }
}

internal fun JSONObject.optionalID(key: String): String? = if (isNull(key) || !has(key)) null else getString(key).lowercase()
internal fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }
internal fun List<JSONObject>.jsonArray(): JSONArray = JSONArray().also { a -> forEach(a::put) }
internal fun swiftNow(): Double = Instant.now().toEpochMilli() / 1000.0 - 978307200.0

object TodoRules {
    fun newTask(title: String, note: String, day: LocalDate, groupID: String?, parentID: String?, order: Int): JSONObject {
        require(title.isNotBlank()) { "请填写事项内容。" }
        val now = swiftNow()
        return JSONObject().put("id", UUID.randomUUID().toString()).put("title", title.trim()).put("note", note)
            .put("plannedDay", dayJSON(day)).put("groupID", groupID ?: JSONObject.NULL)
            .put("parentID", parentID ?: JSONObject.NULL).put("phase", "pending").put("order", order)
            .put("createdAt", now).put("updatedAt", now)
    }

    fun dayJSON(day: LocalDate): JSONObject = JSONObject().put("year", day.year).put("month", day.monthValue).put("day", day.dayOfMonth)

    fun descendants(tasks: List<Todo>, id: String): Set<String> {
        val result = mutableSetOf(id)
        do { val previous = result.size; tasks.filter { it.parentID in result }.forEach { result.add(it.id) } } while (result.size != previous)
        return result
    }

    fun validateParent(tasks: List<Todo>, id: String?, parentID: String?) {
        if (parentID == null) return
        require(tasks.any { it.id == parentID }) { "找不到父事项。" }
        require(id == null || parentID !in descendants(tasks, id)) { "不能把事项移到自己或其子项下。" }
        var depth = 0
        var current: String? = parentID
        val visited = mutableSetOf<String>()
        while (current != null) {
            require(visited.add(current)) { "待办层级存在循环。" }
            depth++
            current = tasks.find { it.id == current }?.parentID
        }
        fun height(node: String): Int = 1 + (tasks.filter { it.parentID == node }.maxOfOrNull { height(it.id) } ?: 0)
        require(depth + (id?.let(::height) ?: 1) <= 3) { "待办层级最多为三级。" }
    }

    fun setPhase(tasks: JSONArray, id: String, phase: String): JSONArray {
        require(phase in listOf("pending", "inProgress", "completed"))
        val items = tasks.objects().map { JSONObject(it.toString()) }
        val parsed = items.map(Todo::from)
        require(parsed.any { it.id == id }) { "找不到这条待办。" }
        if (phase == "completed") require(parsed.filter { it.parentID == id }.all { it.phase == "completed" }) { "请先完成所有子项。" }
        val target = items.first { it.getString("id").equals(id, true) }
        setPhaseValue(target, phase)
        return reconcile(items.jsonArray())
    }

    fun reconcile(tasks: JSONArray): JSONArray {
        val items = tasks.objects().map { JSONObject(it.toString()) }
        val byID = items.associateBy { it.getString("id").lowercase() }
        fun visit(id: String, seen: MutableSet<String>) {
            require(seen.add(id)) { "待办层级存在循环。" }
            val children = items.filter { it.optionalID("parentID") == id }
            children.forEach { visit(it.getString("id").lowercase(), seen) }
            if (children.isNotEmpty()) {
                val item = byID.getValue(id)
                if (children.all { it.getString("phase") == "completed" }) setPhaseValue(item, "completed")
                else if (item.getString("phase") == "completed") setPhaseValue(item, "pending")
            }
            seen.remove(id)
        }
        items.filter { it.optionalID("parentID") == null }.forEach { visit(it.getString("id").lowercase(), mutableSetOf()) }
        return items.jsonArray()
    }

    private fun setPhaseValue(item: JSONObject, phase: String) {
        if (item.optString("phase") == phase) return
        val now = swiftNow()
        item.put("phase", phase).put("updatedAt", now)
        if (phase == "completed") item.put("completedAt", now) else item.remove("completedAt")
        if (phase == "inProgress" && item.isNull("startedAt")) item.put("startedAt", now)
        if (phase == "pending") item.remove("startedAt")
    }
}
