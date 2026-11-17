package com.pindo.app

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Environment
import java.io.File
import java.io.IOException

internal data class AppUpdateDownloadSnapshot(
    val status: Int,
    val reason: Int,
    val downloadedBytes: Long,
    val totalBytes: Long,
    val sourceUrl: String
)

internal interface AppUpdateDownloads {
    fun enqueue(update: PublishedAppUpdate): Long
    fun query(id: Long): AppUpdateDownloadSnapshot?
    fun remove(id: Long)
    fun file(update: PublishedAppUpdate): File
}

/** The system owns the transfer; only a separately verified private copy may be installed. */
internal class AndroidAppUpdateDownloads(private val context: Context) : AppUpdateDownloads {
    private val downloads = context.getSystemService(DownloadManager::class.java)
        ?: error("系统下载服务不可用。")

    override fun file(update: PublishedAppUpdate): File {
        require(update.versionCode > 0 && update.sha256.matches(Regex("[0-9a-f]{64}"))) { "更新包信息无效。" }
        val base = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: throw IOException("下载存储空间暂不可用，请稍后重试。")
        val directory = File(base, "app-updates")
        require(directory.canonicalFile.parentFile == base.canonicalFile) { "更新下载目录无效。" }
        return File(directory, "Pindo-${update.versionCode}-${update.sha256.take(12)}.apk")
    }

    @Suppress("DEPRECATION")
    override fun enqueue(update: PublishedAppUpdate): Long {
        val target = file(update)
        val directory = requireNotNull(target.parentFile)
        if (!directory.isDirectory && !directory.mkdirs()) throw IOException("无法创建更新下载目录。")
        if (target.exists() && (!target.isFile || !target.delete())) throw IOException("无法清理上次的更新下载，请重试。")
        val request = DownloadManager.Request(Uri.parse(update.apkUrl))
            .setTitle("Pindo 更新")
            .setDescription("正在下载 ${update.versionName}")
            .setMimeType("application/vnd.android.package-archive")
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
            .setVisibleInDownloadsUi(false)
            .setAllowedOverMetered(true)
            .setAllowedOverRoaming(false)
            .setDestinationInExternalFilesDir(context, Environment.DIRECTORY_DOWNLOADS,
                "app-updates/${target.name}")
        return downloads.enqueue(request)
    }

    override fun query(id: Long): AppUpdateDownloadSnapshot? {
        require(id > 0) { "下载任务无效。" }
        return downloads.query(DownloadManager.Query().setFilterById(id))?.use { cursor ->
            if (!cursor.moveToFirst()) null else AppUpdateDownloadSnapshot(
                status = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)),
                reason = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)),
                downloadedBytes = cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)),
                totalBytes = cursor.getLong(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)),
                sourceUrl = cursor.getString(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_URI))
            )
        }
    }

    override fun remove(id: Long) {
        require(id > 0) { "下载任务无效。" }
        downloads.remove(id)
    }
}
