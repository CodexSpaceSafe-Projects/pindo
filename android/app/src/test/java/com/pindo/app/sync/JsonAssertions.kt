package com.pindo.app.sync

import org.json.JSONArray
import org.json.JSONObject

// Android's compile-time org.json API has no toMap/toList, even though the
// standalone JVM test implementation does. Keep assertions portable to both.
internal fun JSONObject.toMap(): Map<String, Any?> = keys().asSequence().associateWith { jsonAssertionValue(get(it)) }
internal fun JSONArray.toList(): List<Any?> = (0 until length()).map { jsonAssertionValue(get(it)) }

private fun jsonAssertionValue(value: Any?): Any? = when (value) {
    null, JSONObject.NULL -> null
    is JSONObject -> value.toMap()
    is JSONArray -> value.toList()
    is Number -> value.toDouble()
    else -> value
}
