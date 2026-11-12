package com.pindo.app

import android.content.Context

/** Device-only choices. These never enter backup or synchronization payloads. */
data class AppPreferences(val theme: String = "system", val defaultGroupID: String? = null)

internal class PreferenceStorage(context: Context) {
    private val storage = context.getSharedPreferences("pindo.preferences", Context.MODE_PRIVATE)

    fun read(): AppPreferences {
        val theme = storage.getString("theme", "system")?.takeIf { it in listOf("system", "light", "dark") } ?: "system"
        return AppPreferences(theme, storage.getString("defaultGroupID", null)?.lowercase())
    }

    fun write(value: AppPreferences) {
        require(value.theme in listOf("system", "light", "dark")) { "外观选项无效。" }
        check(storage.edit().putString("theme", value.theme).putString("defaultGroupID", value.defaultGroupID).commit()) {
            "设置未能保存，请重试。"
        }
    }
}
