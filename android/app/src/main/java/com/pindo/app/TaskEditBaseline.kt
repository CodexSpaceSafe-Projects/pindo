package com.pindo.app

import org.json.JSONObject
import java.time.LocalDate
import java.security.MessageDigest

/** Small SavedState baseline: a large note is represented by its digest, never copied into the Bundle. */
internal data class TaskEditBaseline(val title: String, val day: LocalDate, val groupID: String?, val parentID: String?, val phase: String, val noteDigest: String) {
    fun encoded(): String = JSONObject().put("title", title).put("day", day.toString()).put("groupID", groupID ?: JSONObject.NULL)
        .put("parentID", parentID ?: JSONObject.NULL).put("phase", phase).put("noteDigest", noteDigest).toString()
    fun task(id: String): Todo = Todo(id, title, "", day, groupID, parentID, phase, 0L, JSONObject())
    companion object {
        fun capture(task: Todo): TaskEditBaseline = TaskEditBaseline(task.title, task.day, task.groupID, task.parentID, task.phase, taskNoteDigest(task.note))
        fun decode(text: String): TaskEditBaseline {
            val value = JSONObject(text)
            val digest = value.getString("noteDigest")
            require(digest.matches(Regex("[0-9a-f]{64}")))
            return TaskEditBaseline(value.getString("title"), LocalDate.parse(value.getString("day")),
                value.optionalID("groupID"), value.optionalID("parentID"), value.getString("phase"), digest)
        }
    }
}

internal fun taskNoteDigest(text: String): String = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
