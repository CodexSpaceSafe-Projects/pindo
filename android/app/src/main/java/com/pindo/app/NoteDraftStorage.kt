package com.pindo.app

import android.util.AtomicFile
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.util.UUID

internal interface NoteDraftFiles {
    fun read(id: String): ByteArray?
    fun write(id: String, data: ByteArray)
    fun delete(id: String)
}

/** This directory is below Context.noBackupFilesDir, outside data.json and all exports. */
internal class AtomicNoteDraftFiles(private val directory: File, private val beforeFinish: () -> Unit = {}) : NoteDraftFiles {
    private fun file(id: String): AtomicFile {
        require(id.matches(DRAFT_ID))
        return AtomicFile(File(directory, "$id.json"))
    }
    override fun read(id: String): ByteArray? {
        val file = file(id)
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return null
        return file.openRead().use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count == -1) break
                require(output.size().toLong() + count <= MAX_DRAFT_BYTES) { "本地备注草稿超过安全上限。" }
                output.write(buffer, 0, count)
            }
            output.toByteArray()
        }
    }
    override fun write(id: String, data: ByteArray) {
        require(data.size <= MAX_DRAFT_BYTES)
        if (!directory.exists() && !directory.mkdirs()) throw IOException("无法创建本地草稿目录。")
        val file = file(id)
        val stream = file.startWrite()
        try { stream.write(data); beforeFinish(); file.finishWrite(stream) }
        catch (failure: Throwable) { file.failWrite(stream); throw failure }
    }
    override fun delete(id: String) {
        val file = file(id)
        file.delete()
        if (listOf(file.baseFile, File(file.baseFile.path + ".bak"), File(file.baseFile.path + ".new")).any(File::exists)) {
            throw IOException("本地草稿未能清理。")
        }
    }
}

internal data class NoteDraft(val text: String, val selectionStart: Int, val selectionEnd: Int)

/** A Bundle stores only this handle's short token, never the note's text. */
internal class NoteDraftHandle(private val files: NoteDraftFiles) {
    private var id = UUID.randomUUID().toString()
    var error: String? = null
        private set

    fun save(value: NoteDraft): String {
        var digest = "0".repeat(64)
        return try {
            require(value.text.length <= MAX_DRAFT_CHARACTERS)
            require(value.selectionStart in 0..value.text.length && value.selectionEnd in 0..value.text.length)
            val data = JSONObject().put("version", 1).put("id", id).put("text", value.text)
                .put("selectionStart", value.selectionStart).put("selectionEnd", value.selectionEnd)
                .put("valueDigest", noteDraftValueDigest(value)).toString().toByteArray(Charsets.UTF_8)
            require(data.size <= MAX_DRAFT_BYTES)
            digest = draftDigest(data)
            files.write(id, data)
            require(files.read(id)?.contentEquals(data) == true)
            error = null
            "v1:$id:$digest:ok"
        } catch (_: Exception) {
            // AtomicFile leaves the previous complete draft intact. The failure
            // marker survives recreation without throwing from Compose's Saver.
            error = "备注草稿未能完整保存。请保持编辑页并重试，当前文字尚未提交同步。"
            "v1:$id:$digest:failed"
        } catch (_: OutOfMemoryError) {
            error = "可用内存不足，备注草稿未保存。请保留当前文字并重试。"
            "v1:$id:$digest:failed"
        }
    }

    fun restore(token: String): NoteDraft? {
        return try {
            val parts = token.split(':')
            require(parts.size == 4 && parts[0] == "v1" && parts[1].matches(DRAFT_ID) && parts[2].matches(Regex("[0-9a-f]{64}")) && parts[3] in setOf("ok", "failed"))
            id = parts[1]
            val data = files.read(id) ?: throw IOException("草稿文件缺失。")
            require(data.size <= MAX_DRAFT_BYTES)
            if (parts[3] == "ok") require(draftDigest(data) == parts[2])
            val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(data)).toString()
            val json = JSONObject(text)
            require(json.get("version") is Number && json.getDouble("version") == 1.0 && json.get("id") == id && json.get("text") is String)
            val body = json.getString("text")
            require(body.length <= MAX_DRAFT_CHARACTERS)
            fun selection(key: String): Int {
                val value = json.get(key)
                require(value is Number && value.toDouble().isFinite() && value.toDouble() == value.toInt().toDouble())
                return value.toInt().also { require(it in 0..body.length) }
            }
            val result = NoteDraft(body, selection("selectionStart"), selection("selectionEnd"))
            require(json.get("valueDigest") is String && json.getString("valueDigest") == noteDraftValueDigest(result))
            error = if (parts[3] == "failed") "上次备注草稿保存未确认，仅恢复了最后可读取的完整草稿。请检查后再保存。" else null
            result
        } catch (_: Exception) {
            error = "未能恢复上次未保存的备注草稿，原草稿文件已保留；当前显示事项上次已保存的备注。"
            null
        } catch (_: OutOfMemoryError) {
            error = "可用内存不足，未能恢复备注草稿。原草稿文件已保留。"
            null
        }
    }

    fun clear(): Boolean = try { files.delete(id); error = null; true }
    catch (_: Exception) { error = "本地备注草稿未能清理，请重试关闭编辑页。"; false }
}

private val DRAFT_ID = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
private const val MAX_DRAFT_CHARACTERS = 7 * 1024 * 1024
private const val MAX_DRAFT_BYTES = 64 * 1024 * 1024
private fun draftDigest(data: ByteArray) = MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }
private fun noteDraftValueDigest(value: NoteDraft): String = MessageDigest.getInstance("SHA-256").run {
    update("${value.selectionStart}\n${value.selectionEnd}\n".toByteArray(Charsets.UTF_8))
    update(value.text.toByteArray(Charsets.UTF_8))
    digest().joinToString("") { "%02x".format(it) }
}
