package com.pindo.app

import android.app.Application
import android.app.DownloadManager
import android.os.Looper
import androidx.core.content.pm.PackageInfoCompat
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.Collections
import java.util.IdentityHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@LooperMode(LooperMode.Mode.PAUSED)
class AppUpdateViewModelTest {
    private lateinit var app: Application
    private lateinit var installed: InstalledAppIdentity
    private lateinit var update: PublishedAppUpdate
    private lateinit var downloads: FakeDownloads
    private val contents = "A future signed-package fixture; actual certificate parsing is tested separately.".toByteArray()
    private val stores = IdentityHashMap<AppUpdateViewModel, ViewModelStore>()
    private val gates = mutableListOf<CountDownLatch>()
    private val preferences get() = app.getSharedPreferences("pindo.app-update", Application.MODE_PRIVATE)
    private val privateDirectory get() = File(app.filesDir, "app-updates")

    @Before fun prepare() {
        app = ApplicationProvider.getApplicationContext()
        AppUpdateFileProvider().attachInfo(app,
            requireNotNull(app.packageManager.resolveContentProvider("${app.packageName}.updates", 0)))
        preferences.edit().clear().commit()
        privateDirectory.deleteRecursively()
        val code = PackageInfoCompat.getLongVersionCode(app.packageManager.getPackageInfo(app.packageName, 0)).coerceAtLeast(1000)
        installed = InstalledAppIdentity(app.packageName, code, "02".repeat(32))
        val futureCode = code + 100
        val tag = "android-build-${futureCode - 1000}"
        update = PublishedAppUpdate(installed.applicationId, futureCode, "0.6.0-build${futureCode - 1000}.0101010",
            installed.certificateSha256, digest(contents), "01".repeat(20),
            "https://github.com/CodexSpaceSafe-Projects/pindo/releases/download/$tag/Pindo-Android.apk",
            contents.size.toLong(), "https://github.com/CodexSpaceSafe-Projects/pindo/releases/tag/$tag")
        downloads = FakeDownloads(File(app.cacheDir, "update-viewmodel-downloads"), contents)
    }

    @After fun stop() {
        gates.forEach(CountDownLatch::countDown)
        stores.values.forEach(ViewModelStore::clear)
        stores.clear()
        shadowOf(Looper.getMainLooper()).idle()
    }

    @Test fun oneClickDownloadsAndVerifiesAPrivateCopyBeforeOneAutomaticInstallRequest() {
        val source = FakeSource { update }
        val verified = AtomicInteger()
        val vm = model(source) { file, candidate, identity ->
            assertEquals(update, candidate)
            assertEquals(installed, identity)
            assertEquals(privateDirectory.canonicalFile, file.parentFile!!.canonicalFile)
            assertArrayEquals(contents, file.readBytes())
            verified.incrementAndGet()
        }
        vm.startUpdate()
        awaitState(vm, AppUpdateStage.READY)
        assertEquals(1, source.calls.get())
        assertEquals(1, downloads.enqueues.get())
        assertEquals(1, verified.get())
        assertEquals(listOf(41L), downloads.removed.toList())
        assertFalse(downloads.file(update).exists())
        assertArrayEquals(contents, readyFile().readBytes())
        assertTrue(vm.state.value.autoInstall)
        assertTrue(vm.consumeInstallRequest())
        assertFalse(vm.consumeInstallRequest())
        assertFalse(vm.state.value.autoInstall)
        assertTrue(preferences.contains("pending"))
    }

    @Test fun closingAViewModelKeepsTheSystemDownloadAndRecreationDoesNotEnqueueAgain() {
        downloads.status = DownloadManager.STATUS_RUNNING
        val source = FakeSource { update }
        val first = model(source)
        first.startUpdate()
        awaitState(first, AppUpdateStage.DOWNLOADING)
        assertTrue(preferences.contains("pending"))
        dispose(first)
        assertTrue(downloads.removed.isEmpty())
        assertTrue(downloads.file(update).exists())

        val second = model(source)
        awaitState(second, AppUpdateStage.DOWNLOADING)
        assertEquals(1, source.calls.get())
        assertEquals(1, downloads.enqueues.get())
        downloads.status = DownloadManager.STATUS_SUCCESSFUL
        awaitState(second, AppUpdateStage.READY)
        assertFalse("A cold restoration must not unexpectedly launch the installer", second.state.value.autoInstall)
        assertArrayEquals(contents, readyFile().readBytes())
        assertEquals(1, downloads.enqueues.get())
    }

    @Test fun cancellationRemovesTheOwnedTransferFilesAndDurableRecord() {
        downloads.status = DownloadManager.STATUS_RUNNING
        val vm = model(FakeSource { update })
        vm.startUpdate()
        awaitState(vm, AppUpdateStage.DOWNLOADING)
        readyFile().apply { parentFile!!.mkdirs(); writeText("incomplete private copy") }
        File(readyFile().path + ".part.apk").writeText("partial")
        vm.cancelDownload()
        awaitState(vm, AppUpdateStage.IDLE)
        assertEquals(listOf(41L), downloads.removed.toList())
        assertFalse(downloads.file(update).exists())
        assertFalse(readyFile().exists())
        assertFalse(File(readyFile().path + ".part.apk").exists())
        assertFalse(preferences.contains("pending"))
        idle()
        assertEquals(AppUpdateStage.IDLE, vm.state.value.stage)
    }

    @Test fun aLateCancelledCheckCannotCreateANewDownloadOrRestoreItsRecord() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1).also(gates::add)
        val source = FakeSource {
            entered.countDown()
            withContext(NonCancellable + Dispatchers.IO) {
                check(release.await(5, TimeUnit.SECONDS))
            }
            update
        }
        val vm = model(source)
        vm.startUpdate()
        await("source check must start") { entered.count == 0L }
        vm.cancelDownload()
        release.countDown()
        awaitState(vm, AppUpdateStage.IDLE)
        idle()
        assertEquals(0, downloads.enqueues.get())
        assertFalse(preferences.contains("pending"))
        assertFalse(readyFile().exists())
    }

    @Test fun rejectedPackageNeverBecomesReadyAndCannotBeReusedFromTheSavedTask() {
        val vm = model(FakeSource { update }) { _, _, _ -> throw IllegalArgumentException("更新包校验失败。") }
        vm.startUpdate()
        awaitState(vm, AppUpdateStage.ERROR)
        assertFalse(vm.state.value.autoInstall)
        assertFalse(vm.consumeInstallRequest())
        assertFalse(preferences.contains("pending"))
        assertFalse(readyFile().exists())
        assertTrue(privateDirectory.listFiles().orEmpty().isEmpty())
        assertEquals(listOf(41L), downloads.removed.toList())
        assertThrows(IllegalStateException::class.java) { vm.installerIntent() }
    }

    @Test fun anAlreadyCurrentAppDoesNotDownloadAndAnUnsupportedIdentityDoesNotCheck() {
        val source = FakeSource { null }
        val current = model(source)
        current.startUpdate()
        awaitState(current, AppUpdateStage.UP_TO_DATE)
        assertEquals(1, source.calls.get())
        assertEquals(0, downloads.enqueues.get())
        assertFalse(preferences.contains("pending"))

        val unsupportedSource = FakeSource { error("Unsupported build must not contact the update service") }
        val unsupported = model(unsupportedSource, identity = null)
        unsupported.startUpdate()
        unsupported.requestInstall()
        assertEquals(AppUpdateStage.UNSUPPORTED, unsupported.state.value.stage)
        assertEquals(0, unsupportedSource.calls.get())
        assertEquals(0, downloads.enqueues.get())
    }

    @Test fun returningFromACancelledInstallerKeepsTheVerifiedPackageWithoutAnAutomaticLoop() {
        val vm = model(FakeSource { update })
        vm.startUpdate()
        awaitState(vm, AppUpdateStage.READY)
        assertTrue(vm.consumeInstallRequest())
        val intent = vm.installerIntent()
        assertEquals("content", intent.data!!.scheme)
        assertEquals(AppUpdateStage.INSTALLING, vm.state.value.stage)
        vm.installationReturned()
        assertEquals(AppUpdateStage.READY, vm.state.value.stage)
        assertFalse(vm.state.value.autoInstall)
        assertFalse(vm.consumeInstallRequest())
        assertArrayEquals(contents, readyFile().readBytes())
        vm.requestInstall()
        assertTrue(vm.consumeInstallRequest())
    }

    @Test fun cancellationFailurePreservesTheRecordForASafeRetry() {
        downloads.status = DownloadManager.STATUS_RUNNING
        val vm = model(FakeSource { update })
        vm.startUpdate()
        awaitState(vm, AppUpdateStage.DOWNLOADING)
        downloads.failRemove = true
        vm.cancelDownload()
        awaitState(vm, AppUpdateStage.ERROR)
        assertFalse(vm.state.value.autoInstall)
        assertTrue(preferences.contains("pending"))
        assertTrue(downloads.file(update).exists())
        downloads.failRemove = false
        vm.cancelDownload()
        awaitState(vm, AppUpdateStage.IDLE)
        assertFalse(preferences.contains("pending"))
        assertFalse(downloads.file(update).exists())
    }

    private fun model(source: AppUpdateSource, identity: InstalledAppIdentity? = installed,
                      verification: (File, PublishedAppUpdate, InstalledAppIdentity) -> Unit = { file, _, _ -> assertArrayEquals(contents, file.readBytes()) }): AppUpdateViewModel {
        val vm = AppUpdateViewModel(app, source, downloads, identity, verification)
        stores[vm] = ViewModelStore().apply { put("update-test", vm) }
        return vm
    }

    private fun dispose(vm: AppUpdateViewModel) { stores.remove(vm)?.clear(); idle() }
    private fun readyFile() = File(privateDirectory, "Pindo-${update.versionCode}-${update.sha256.take(12)}.apk")
    private fun idle() { shadowOf(Looper.getMainLooper()).idleFor(50, TimeUnit.MILLISECONDS) }
    private fun awaitState(vm: AppUpdateViewModel, stage: AppUpdateStage) = await("$stage; actual ${vm.state.value}") { vm.state.value.stage == stage }
    private fun await(description: String, condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(6)
        while (System.nanoTime() < deadline) {
            idle()
            if (condition()) return
            Thread.sleep(5)
        }
        fail("Timed out waiting for $description")
    }

    private class FakeSource(private val response: suspend (InstalledAppIdentity) -> PublishedAppUpdate?) : AppUpdateSource {
        val calls = AtomicInteger()
        override suspend fun latest(installed: InstalledAppIdentity): PublishedAppUpdate? { calls.incrementAndGet(); return response(installed) }
    }

    private class FakeDownloads(private val directory: File, private val bytes: ByteArray) : AppUpdateDownloads {
        val enqueues = AtomicInteger()
        val removed = Collections.synchronizedList(mutableListOf<Long>())
        @Volatile var status = DownloadManager.STATUS_SUCCESSFUL
        @Volatile var failRemove = false
        @Volatile private var update: PublishedAppUpdate? = null
        @Volatile private var removedTask = false

        init { directory.deleteRecursively(); directory.mkdirs() }
        override fun enqueue(update: PublishedAppUpdate): Long {
            enqueues.incrementAndGet(); this.update = update; removedTask = false
            file(update).writeBytes(bytes)
            return 41
        }
        override fun query(id: Long): AppUpdateDownloadSnapshot? = update?.takeIf { id == 41L && !removedTask }?.let {
            AppUpdateDownloadSnapshot(status, 0, if (status == DownloadManager.STATUS_SUCCESSFUL) bytes.size.toLong() else 1L,
                bytes.size.toLong(), it.apkUrl)
        }
        override fun remove(id: Long) {
            if (failRemove) throw IOException("Injected system download removal failure")
            check(id == 41L)
            removed.add(id); removedTask = true; update?.let { file(it).delete() }
        }
        override fun file(update: PublishedAppUpdate) = File(directory, "Pindo-${update.versionCode}.apk")
    }

    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}
