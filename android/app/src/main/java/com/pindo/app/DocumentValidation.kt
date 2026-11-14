package com.pindo.app

import org.json.JSONObject
import java.util.UUID
import java.text.Normalizer

internal fun validateDocument(value: JSONObject) {
    val version = value.get("version")
    require(version is Number && version.toDouble() == 1.0) { "资料来自不支持的版本。" }
    val tasks = value.getJSONArray("tasks").objects().map(Todo::from)
    val groups = value.getJSONArray("groups").objects().map(TodoGroup::from)
    require(tasks.size <= 10_000 && groups.size <= 1_000) { "资料数量超过当前版本限制。" }
    require(tasks.map { it.id }.toSet().size == tasks.size && groups.map { it.id }.toSet().size == groups.size) { "资料中存在重复标识。" }
    tasks.forEach { UUID.fromString(it.id) }; groups.forEach { UUID.fromString(it.id) }
    require(groups.all { it.name.isNotBlank() && it.color.matches(Regex("#[0-9a-fA-F]{6}")) }) { "分组资料无效。" }
    require(groups.map { canonicalGroupName(it.name) }.toSet().size == groups.size) { "分组名称重复。" }
    val groupIDs = groups.map { it.id }.toSet()
    for (task in tasks) {
        require(task.title.isNotBlank() && task.phase in listOf("pending", "inProgress", "completed")) { "待办资料无效。" }
        require(task.groupID == null || task.groupID in groupIDs) { "待办引用不存在的分组。" }
        TodoRules.validateParent(tasks, task.id, task.parentID)
        if (task.phase == "completed") require(tasks.filter { it.parentID == task.id }.all { it.phase == "completed" }) { "父项仍有未完成子项。" }
    }
}

internal fun canonicalGroupName(value: String): String = Normalizer.normalize(value, Normalizer.Form.NFC)
