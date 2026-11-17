package com.pindo.app

import android.app.Application
import android.app.DownloadManager
import android.content.Intent
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

internal enum class AppUpdateStage { IDLE, CHECKING, DOWNLOADING, VERIFYING, READY, INSTALLING, UP_TO_DATE, UNSUPPORTED, ERROR }
internal data class AppUpdateState(val stage: AppUpdateStage = AppUpdateStage.IDLE, val versionName: String? = null,
    val downloadedBytes: Long = 0, val totalBytes: Long = 0, val message: String? = null, val autoInstall: Boolean = false)

/** DownloadManager owns the transfer. Only a verified, private copy can reach the installer. */
internal class AppUpdateViewModel internal constructor(
    application: Application,
    private val source: AppUpdateSource,
    private val downloads: AppUpdateDownloads,
    private val installed: InstalledAppIdentity?,
    private val verify: (File, PublishedAppUpdate, InstalledAppIdentity) -> Unit
) : AndroidViewModel(application) {
    constructor(application: Application) : this(application, GitHubAppUpdateSource(), AndroidAppUpdateDownloads(application),
        officialIdentity(application), { file, update, identity -> AppUpdateVerifier.verify(application, file, update, identity) })

    private val preferences = application.getSharedPreferences("pindo.app-update", Application.MODE_PRIVATE)
    private val mutable = MutableStateFlow(AppUpdateState())
    val state: StateFlow<AppUpdateState> = mutable
    private var pending: Pending? = null
    private var operation: Job? = null
    private var autoInstallRequested = false

    init {
        if (installed == null) mutable.value = AppUpdateState(AppUpdateStage.UNSUPPORTED,
            message = "当前安装无法使用正式版应用内更新，请使用正式 Pindo 安装包。")
        else runOperation { restore() }
    }

    fun startUpdate() {
        if (installed == null || operation?.isCompleted == false) return
        if (state.value.stage == AppUpdateStage.READY) { requestInstall(); return }
        autoInstallRequested = true
        runOperation {
            val previous = pending
            if (previous != null) {
                val snapshot = if (previous.downloadID > 0) withContext(Dispatchers.IO) { downloads.query(previous.downloadID) } else null
                if (previous.downloadID == 0L || snapshot != null && snapshot.sourceUrl == previous.update.apkUrl &&
                    snapshot.status != DownloadManager.STATUS_FAILED) {
                    resume(previous); return@runOperation
                }
                discard(previous)
            }
            mutable.value = AppUpdateState(AppUpdateStage.CHECKING)
            val update = source.latest(installed)
            ensureActive()
            if (update == null) {
                autoInstallRequested = false
                mutable.value = AppUpdateState(AppUpdateStage.UP_TO_DATE, message = "已是最新版本。")
                return@runOperation
            }
            update.validateFor(installed)
            // Enqueue and persist without a suspension between them. If the UI
            // is cancelled during this block, cancellation joins it before cleanup.
            val next = withContext(Dispatchers.IO) {
                val id = downloads.enqueue(update)
                require(id > 0) { "无法开始下载，请稍后重试。" }
                val record = Pending(update, id)
                try { writeRecord(record) }
                catch (e: Exception) { downloads.remove(id); throw e }
                record
            }
            pending = next
            resume(next)
        }
    }

    fun cancelDownload() {
        val previous = operation
        previous?.cancel()
        autoInstallRequested = false
        val old = pending
        val cleanup = viewModelScope.launch(start = CoroutineStart.LAZY) {
            try {
                previous?.join()
                val saved = runCatching { readRecord() }.getOrNull()
                withContext(Dispatchers.IO) {
                    listOfNotNull(old, saved).distinct().forEach(::removeFiles)
                    check(preferences.edit().remove("pending").commit())
                }
                pending = null
                mutable.value = AppUpdateState()
            } catch (e: CancellationException) { throw e }
            catch (_: Exception) {
                mutable.value = state.value.copy(stage = AppUpdateStage.ERROR, autoInstall = false,
                    message = "未能完整取消更新，请稍后重试。")
            } finally { if (operation === coroutineContext[Job]) operation = null }
        }
        operation = cleanup
        cleanup.start()
    }

    fun requestInstall() {
        if (state.value.stage == AppUpdateStage.READY) {
            autoInstallRequested = true
            mutable.value = state.value.copy(autoInstall = true, message = null)
        } else if (state.value.stage == AppUpdateStage.VERIFYING) autoInstallRequested = true
    }

    fun consumeInstallRequest(): Boolean {
        if (state.value.stage != AppUpdateStage.READY || !state.value.autoInstall) return false
        autoInstallRequested = false
        mutable.value = state.value.copy(autoInstall = false)
        return true
    }

    fun installerIntent(): Intent {
        check(state.value.stage == AppUpdateStage.READY)
        val update = checkNotNull(pending).update
        update.validateFor(checkNotNull(installed))
        val intent = AppUpdateInstaller(getApplication()).installIntent(readyFile(update))
        mutable.value = state.value.copy(stage = AppUpdateStage.INSTALLING, autoInstall = false, message = null)
        return intent
    }

    fun installationReturned() {
        autoInstallRequested = false
        val next = pending ?: return
        val current = runCatching { AppUpdateVerifier.installed(getApplication()) }.getOrNull()
        if (current != null && installed != null && current.applicationId == installed.applicationId &&
            current.certificateSha256 == installed.certificateSha256 && current.versionCode >= next.update.versionCode) {
            runOperation { discard(next); mutable.value = AppUpdateState(AppUpdateStage.UP_TO_DATE, message = "更新已安装。") }
        } else mutable.value = state.value.copy(stage = AppUpdateStage.READY, autoInstall = false,
            message = "尚未完成安装，可以再次安装更新。")
    }

    fun installationLaunchFailed() {
        autoInstallRequested = false
        mutable.value = state.value.copy(stage = AppUpdateStage.READY, autoInstall = false,
            message = "无法打开系统安装界面，请稍后重试。")
    }

    private fun runOperation(action: suspend kotlinx.coroutines.CoroutineScope.() -> Unit) {
        if (operation?.isCompleted == false) return
        val job = viewModelScope.launch(start = CoroutineStart.LAZY) {
            try { action() }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                autoInstallRequested = false
                val text = e.message?.takeIf { e is IllegalArgumentException || e is IllegalStateException }
                    ?.takeIf { it.any { ch -> ch.code in 0x3400..0x9fff } }?.take(160)
                    ?: "更新未完成，请检查网络和可用空间后重试。"
                mutable.value = state.value.copy(stage = AppUpdateStage.ERROR, message = text, autoInstall = false)
            }
            finally { if (operation === coroutineContext[Job]) operation = null }
        }
        operation = job
        job.start()
    }

    private suspend fun restore() {
        val restored = try { readRecord() } catch (e: Exception) {
            // This is a disposable update record, never the user's document or sync journal.
            pending = null
            preferences.edit().remove("pending").commit()
            throw e
        } ?: return
        pending = restored
        if (restored.update.versionCode <= checkNotNull(installed).versionCode) discard(restored)
        else resume(restored)
    }

    private fun readRecord(): Pending? {
        val text = preferences.getString("pending", null) ?: return null
        val json = JSONObject(text)
        val update = PublishedAppUpdate.fromMetadata(json.getJSONObject("metadata"), json.getString("apkUrl"),
            json.getLong("apkBytes"), json.getString("releaseUrl"), checkNotNull(installed), requireNewer = false)
        val id = json.get("downloadID").let { require(it is Number); it.toString().toLong() }
        require(id >= 0)
        return Pending(update, id)
    }

    private suspend fun resume(record: Pending) {
        record.update.validateFor(checkNotNull(installed))
        if (record.downloadID == 0L) {
            mutable.value = AppUpdateState(AppUpdateStage.VERIFYING, record.update.versionName)
            try { withContext(Dispatchers.IO) { verify(readyFile(record.update), record.update, checkNotNull(installed)) } }
            catch (e: IllegalArgumentException) { discard(record); throw e }
            mutable.value = AppUpdateState(AppUpdateStage.READY, record.update.versionName, autoInstall = autoInstallRequested)
            return
        }
        while (true) {
            val snapshot = withContext(Dispatchers.IO) { downloads.query(record.downloadID) }
                ?: throw IOException("download_missing")
            require(snapshot.sourceUrl == record.update.apkUrl) { "下载记录与更新包不一致，请重新检查更新。" }
            if (snapshot.downloadedBytes > record.update.apkBytes) {
                discard(record)
                error("更新包大小与发布信息不一致，请重新下载。")
            }
            when (snapshot.status) {
                DownloadManager.STATUS_SUCCESSFUL -> { prepare(record); return }
                DownloadManager.STATUS_FAILED -> {
                    discard(record)
                    error(if (snapshot.reason == DownloadManager.ERROR_INSUFFICIENT_SPACE) "存储空间不足，请清理空间后重试。" else "下载未完成，请重试。")
                }
                DownloadManager.STATUS_PENDING, DownloadManager.STATUS_RUNNING, DownloadManager.STATUS_PAUSED -> {
                    mutable.value = AppUpdateState(AppUpdateStage.DOWNLOADING, record.update.versionName,
                        snapshot.downloadedBytes.coerceAtLeast(0), record.update.apkBytes,
                        if (snapshot.status == DownloadManager.STATUS_PAUSED) "等待网络后继续下载。" else null)
                }
                else -> error("下载状态无效，请重新检查更新。")
            }
            delay(750)
        }
    }

    private suspend fun prepare(record: Pending) {
        mutable.value = AppUpdateState(AppUpdateStage.VERIFYING, record.update.versionName)
        val target = readyFile(record.update)
        val temporary = File(target.parentFile, "${target.name}.part.apk")
        try {
            withContext(Dispatchers.IO) {
                check(target.parentFile!!.isDirectory || target.parentFile!!.mkdirs()) { "无法保存更新包，请检查可用空间。" }
                val downloaded = downloads.file(record.update)
                require(downloaded.length() == record.update.apkBytes) { "更新包大小不符，请重新下载。" }
                FileOutputStream(temporary).use { output ->
                    downloaded.inputStream().use { input ->
                        val buffer = ByteArray(32 * 1024)
                        var copied = 0L
                        while (true) {
                            ensureActive()
                            val count = input.read(buffer)
                            if (count < 0) break
                            copied += count
                            require(copied <= record.update.apkBytes) { "更新包大小不符，请重新下载。" }
                            output.write(buffer, 0, count)
                        }
                    }
                    output.fd.sync()
                }
                verify(temporary, record.update, checkNotNull(installed))
                ensureActive()
                Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            }
            save(Pending(record.update, 0))
            withContext(Dispatchers.IO) { runCatching { downloads.remove(record.downloadID) } }
            mutable.value = AppUpdateState(AppUpdateStage.READY, record.update.versionName, autoInstall = autoInstallRequested)
        } catch (e: IllegalArgumentException) {
            discard(record)
            throw e
        } finally { temporary.delete() }
    }

    private fun readyFile(update: PublishedAppUpdate) = File(getApplication<Application>().filesDir,
        "app-updates/Pindo-${update.versionCode}-${update.sha256.take(12)}.apk")

    private suspend fun save(record: Pending) {
        withContext(Dispatchers.IO) { writeRecord(record) }
        pending = record
    }

    private fun writeRecord(record: Pending) {
        val u = record.update
        val metadata = JSONObject().put("applicationId", u.applicationId).put("versionCode", u.versionCode)
            .put("versionName", u.versionName).put("certificateSha256", u.certificateSha256)
            .put("sha256", u.sha256).put("sourceRevision", u.sourceRevision)
        val text = JSONObject().put("metadata", metadata).put("apkUrl", u.apkUrl).put("apkBytes", u.apkBytes)
            .put("releaseUrl", u.releaseUrl).put("downloadID", record.downloadID).toString()
        check(preferences.edit().putString("pending", text).commit()) { "更新记录未能保存，请重试。" }
    }

    private suspend fun discard(record: Pending) {
        withContext(Dispatchers.IO) { removeFiles(record) }
        if (pending == record) pending = null
        check(preferences.edit().remove("pending").commit()) { "更新记录未能清理，请重试。" }
    }

    private fun removeFiles(record: Pending) {
        if (record.downloadID > 0) {
            if (downloads.query(record.downloadID)?.sourceUrl == record.update.apkUrl) downloads.remove(record.downloadID)
        }
        readyFile(record.update).delete()
        File(readyFile(record.update).path + ".part.apk").delete()
    }

    private data class Pending(val update: PublishedAppUpdate, val downloadID: Long)

    private companion object {
        fun officialIdentity(application: Application): InstalledAppIdentity? = runCatching {
            AppUpdateVerifier.installed(application).takeIf { it.applicationId == "com.pindo.app" && !it.isDebuggable }
        }.getOrNull()
    }
}
