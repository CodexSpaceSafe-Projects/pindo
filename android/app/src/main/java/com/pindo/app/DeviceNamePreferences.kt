package com.pindo.app

import android.content.Context
import android.os.Build
import android.provider.Settings
import java.io.IOException

/** Display metadata is kept outside the credential journal and task backups. */
internal class DeviceNamePreferences(context: Context) {
    private val preferences = context.getSharedPreferences("pindo.sync-device", Context.MODE_PRIVATE)
    private val resolver = context.contentResolver

    val name: String
        get() = preferences.getString("name", null)?.takeIf { it.isNotBlank() } ?: systemName()

    fun save(name: String) {
        if (!preferences.edit().putString("name", name).commit()) throw IOException("无法保存设备名称。")
    }

    private fun systemName(): String {
        val configured = runCatching { Settings.Global.getString(resolver, "device_name") }.getOrNull()
        val model = listOf(Build.MANUFACTURER, Build.MODEL).filter { it.isNotBlank() }.distinct().joinToString(" ")
        val source = configured?.takeIf { it.isNotBlank() } ?: model
        val result = StringBuilder()
        var offset = 0
        var points = 0
        while (offset < source.length && points < 80) {
            val point = source.codePointAt(offset)
            offset += Character.charCount(point)
            if (point in 0..31 || point in 127..159 || point in 0xD800..0xDFFF) continue
            val next = String(Character.toChars(point))
            if ((result.toString() + next).toByteArray(Charsets.UTF_8).size > 256) break
            result.append(next)
            points++
        }
        return result.toString().trim().ifBlank { "Android" }
    }
}
