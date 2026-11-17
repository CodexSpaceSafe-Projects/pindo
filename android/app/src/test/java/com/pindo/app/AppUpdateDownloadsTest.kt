package com.pindo.app

import android.app.Application
import android.app.DownloadManager
import android.content.ContextWrapper
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Environment
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadow.api.Shadow
import org.robolectric.shadows.ShadowDownloadManager
import java.io.File
import java.io.IOException

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], shadows = [AppUpdateDownloadsTest.RecordingDownloads::class])
class AppUpdateDownloadsTest {
    private lateinit var app: Application
    private lateinit var manager: DownloadManager
    private lateinit var transfer: AndroidAppUpdateDownloads
    private lateinit var record: RecordingDownloads
    private val update = PublishedAppUpdate("com.pindo.app", 1200, "0.6.0-build200.abcdef0",
        "01".repeat(32), "ab".repeat(32), "abcdef0123456789abcdef0123456789abcdef01",
        "https://github.com/CodexSpaceSafe-Projects/pindo/releases/download/android-build-200/Pindo-Android.apk",
        1024, "https://github.com/CodexSpaceSafe-Projects/pindo/releases/tag/android-build-200")

    @Before fun prepare() {
        app = ApplicationProvider.getApplicationContext()
        manager = app.getSystemService(DownloadManager::class.java)
        record = Shadow.extract(manager)
        transfer = AndroidAppUpdateDownloads(app)
        File(app.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "app-updates").deleteRecursively()
        // Robolectric starts IDs at zero; Android's download database uses positive IDs.
        manager.enqueue(DownloadManager.Request(Uri.parse("https://example.invalid/reserved")))
    }

    @Test fun transferUsesAppSpecificStorageAndHasNoUnverifiedCompletionInstallNotification() {
        val target = transfer.file(update)
        target.parentFile!!.mkdirs()
        target.writeText("unfinished previous download")
        val id = transfer.enqueue(update)
        val request = Shadow.extract<ShadowDownloadManager.ShadowRequest>(record.getRequest(id))
        assertEquals(update.apkUrl, request.uri.toString())
        assertEquals(Uri.fromFile(target), request.destination)
        assertEquals("Pindo 更新", request.title.toString())
        assertTrue(request.description.toString().contains(update.versionName))
        assertEquals("application/vnd.android.package-archive", request.mimeType)
        assertEquals(DownloadManager.Request.VISIBILITY_VISIBLE, request.notificationVisibility)
        assertTrue(request.allowedOverMetered)
        assertFalse(request.allowedOverRoaming)
        assertFalse(request.visibleInDownloadsUi)
        assertFalse(target.exists())
        assertEquals(app.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)!!.canonicalFile,
            target.parentFile!!.canonicalFile.parentFile)
    }

    @Test fun restoredTransferQueriesOnlyItsIdAndClosesTheSystemCursor() {
        val id = transfer.enqueue(update)
        val unrelated = transfer.enqueue(update.copy(versionCode = 1201))
        val request = Shadow.extract<ShadowDownloadManager.ShadowRequest>(record.getRequest(id))
        request.setStatus(DownloadManager.STATUS_RUNNING)
        request.setTotalSize(1024)
        request.setBytesSoFar(512)
        val result = transfer.query(id)!!
        assertArrayEquals(longArrayOf(id), record.ids)
        assertEquals(DownloadManager.STATUS_RUNNING, result.status)
        assertEquals(512L, result.downloadedBytes)
        assertEquals(1024L, result.totalBytes)
        assertEquals(update.apkUrl, result.sourceUrl)
        assertTrue(record.cursor!!.isClosed)
        transfer.remove(id)
        assertNull(transfer.query(id))
        assertTrue(record.cursor!!.isClosed)
        assertNotNull(record.getRequest(unrelated))
    }

    @Test fun pausedTransferPreservesSystemReasonAndAlwaysClosesEvenOnMalformedRows() {
        val cursor = MatrixCursor(arrayOf(DownloadManager.COLUMN_STATUS, DownloadManager.COLUMN_REASON,
            DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR, DownloadManager.COLUMN_TOTAL_SIZE_BYTES,
            DownloadManager.COLUMN_URI)).apply {
            addRow(arrayOf<Any>(DownloadManager.STATUS_PAUSED, DownloadManager.PAUSED_WAITING_FOR_NETWORK, 22L, -1L, update.apkUrl))
        }
        record.supplied = cursor
        assertEquals(DownloadManager.PAUSED_WAITING_FOR_NETWORK, transfer.query(99)!!.reason)
        assertTrue(cursor.isClosed)
        val incomplete = MatrixCursor(arrayOf(DownloadManager.COLUMN_STATUS)).apply { addRow(arrayOf(DownloadManager.STATUS_RUNNING)) }
        record.supplied = incomplete
        assertThrows(IllegalArgumentException::class.java) { transfer.query(99) }
        assertTrue(incomplete.isClosed)
    }

    @Test fun invalidNamesStorageAndIdsDoNotTouchOtherFilesOrTransfers() {
        assertThrows(IllegalArgumentException::class.java) { transfer.file(update.copy(sha256 = "../../private")) }
        assertThrows(IllegalArgumentException::class.java) { transfer.file(update.copy(versionCode = -1)) }
        assertThrows(IllegalArgumentException::class.java) { transfer.remove(0) }
        assertThrows(IllegalArgumentException::class.java) { transfer.query(-1) }
        val unavailable = object : ContextWrapper(app) {
            override fun getExternalFilesDir(type: String?): File? = null
        }
        val failure = assertThrows(IOException::class.java) { AndroidAppUpdateDownloads(unavailable).enqueue(update) }
        assertTrue(failure.message!!.contains("存储"))
        val blocked = transfer.file(update).apply { mkdirs() }
        val preserved = File(blocked, "keep.txt").apply { writeText("preserve") }
        assertThrows(IOException::class.java) { transfer.enqueue(update) }
        assertEquals("preserve", preserved.readText())
    }

    @Implements(DownloadManager::class)
    class RecordingDownloads : ShadowDownloadManager() {
        var ids: LongArray? = null
        var cursor: Cursor? = null
        var supplied: Cursor? = null

        @Implementation
        override fun query(query: DownloadManager.Query): Cursor {
            ids = Shadow.extract<ShadowDownloadManager.ShadowQuery>(query).ids
            return (supplied.also { supplied = null } ?: super.query(query)).also { cursor = it }
        }
    }
}
