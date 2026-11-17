package com.pindo.app

import android.app.Activity
import android.app.Application
import android.app.DownloadManager
import android.content.Intent
import android.os.Looper
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.content.pm.PackageInfoCompat
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.annotation.LooperMode
import org.robolectric.shadows.ShadowActivity
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/** Runs the production ActivityResult wiring, not only the update-page callbacks. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "zh-rCN-w411dp-h891dp-xhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@LooperMode(LooperMode.Mode.PAUSED)
class AppUpdateActivityTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private lateinit var app: Application
    private lateinit var model: AppUpdateViewModel
    private val contents = "Verified future APK bytes for ActivityResult integration.".toByteArray()

    @Before fun prepareReadyUpdateInTheActivityViewModelStore() {
        app = ApplicationProvider.getApplicationContext()
        app.getSharedPreferences("pindo.app-update", Application.MODE_PRIVATE).edit().clear().commit()
        File(app.filesDir, "app-updates").deleteRecursively()
        val packages = shadowOf(compose.activity.packageManager)
        packages.setCanRequestPackageInstalls(false)
        AppUpdateFileProvider().attachInfo(app,
            requireNotNull(app.packageManager.resolveContentProvider("${app.packageName}.updates", 0)))
        val code = PackageInfoCompat.getLongVersionCode(app.packageManager.getPackageInfo(app.packageName, 0)).coerceAtLeast(1000)
        val identity = InstalledAppIdentity(app.packageName, code, "02".repeat(32))
        val future = code + 100
        val tag = "android-build-${future - 1000}"
        val update = PublishedAppUpdate(identity.applicationId, future, "0.6.0-build${future - 1000}.0101010",
            identity.certificateSha256, digest(contents), "01".repeat(20),
            "https://github.com/CodexSpaceSafe-Projects/pindo/releases/download/$tag/Pindo-Android.apk", contents.size.toLong(),
            "https://github.com/CodexSpaceSafe-Projects/pindo/releases/tag/$tag")
        val downloads = FixtureDownloads(File(app.cacheDir, "activity-result-update.apk"), contents)
        val source = object : AppUpdateSource {
            override suspend fun latest(installed: InstalledAppIdentity) = update
        }
        compose.runOnUiThread {
            val factory = object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T {
                    require(modelClass == AppUpdateViewModel::class.java)
                    return AppUpdateViewModel(app, source, downloads, identity) { file, candidate, installed ->
                        assertEquals(update, candidate)
                        assertEquals(identity, installed)
                        assertArrayEquals(contents, file.readBytes())
                    } as T
                }
            }
            model = ViewModelProvider(compose.activity, factory)[AppUpdateViewModel::class.java]
        }
        shadowOf(Looper.getMainLooper()).idle()
        compose.runOnUiThread { model.startUpdate() }
        awaitReady()
        assertTrue(model.state.value.autoInstall)
    }

    @After fun clearActivityModel() {
        compose.runOnUiThread { compose.activity.viewModelStore.clear() }
    }

    @Test fun permissionDenialCanBeRetriedAndGrantContinuesToOneInstallerWithoutACancelLoop() {
        compose.setContent { PindoTheme("light") { AppUpdateScreen {} } }
        val activity = shadowOf(compose.activity)
        val firstPermission = nextIntent(activity, Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
        assertEquals("package:${app.packageName}", firstPermission.intent.data.toString())
        compose.runOnIdle {
            assertEquals(AppUpdateStage.READY, model.state.value.stage)
            assertFalse(model.state.value.autoInstall)
        }
        assertNoFurtherLaunch(activity)

        // The source-settings activity does not grant permission merely by returning.
        compose.runOnUiThread { activity.receiveResult(firstPermission.intent, Activity.RESULT_CANCELED, Intent()) }
        compose.onNodeWithText("需要允许 Pindo 安装此来源的应用，才能继续安装更新。").assertIsDisplayed()
        compose.onNodeWithText("安装更新").assertIsEnabled()
        assertNoFurtherLaunch(activity)
        compose.runOnIdle { assertEquals(AppUpdateStage.READY, model.state.value.stage) }

        compose.onNodeWithText("安装更新").performClick()
        val permissionRetry = nextIntent(activity, Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
        assertNoFurtherLaunch(activity)
        shadowOf(compose.activity.packageManager).setCanRequestPackageInstalls(true)
        compose.runOnUiThread { activity.receiveResult(permissionRetry.intent, Activity.RESULT_CANCELED, Intent()) }
        val install = nextIntent(activity, Intent.ACTION_VIEW)
        assertEquals("application/vnd.android.package-archive", install.intent.type)
        val uri = requireNotNull(install.intent.data)
        assertEquals("content", uri.scheme)
        assertEquals("${app.packageName}.updates", uri.authority)
        assertTrue(install.intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
        assertEquals(0, install.intent.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        assertTrue(install.intent.getBooleanExtra(Intent.EXTRA_RETURN_RESULT, false))
        assertEquals(uri, install.intent.clipData!!.getItemAt(0).uri)
        app.contentResolver.openInputStream(uri)!!.use { assertArrayEquals(contents, it.readBytes()) }
        compose.runOnIdle { assertEquals(AppUpdateStage.INSTALLING, model.state.value.stage) }
        assertNoFurtherLaunch(activity)

        compose.runOnUiThread { activity.receiveResult(install.intent, Activity.RESULT_CANCELED, Intent()) }
        compose.onNodeWithText("尚未完成安装，可以再次安装更新。").assertIsDisplayed()
        compose.runOnIdle {
            assertEquals(AppUpdateStage.READY, model.state.value.stage)
            assertFalse(model.state.value.autoInstall)
        }
        assertNoFurtherLaunch(activity)
        compose.onNodeWithText("安装更新").performClick()
        val directRetry = nextIntent(activity, Intent.ACTION_VIEW)
        assertEquals(uri, directRetry.intent.data)
        assertNoFurtherLaunch(activity)
        compose.runOnUiThread { activity.receiveResult(directRetry.intent, Activity.RESULT_CANCELED, Intent()) }
        assertNoFurtherLaunch(activity)
    }

    private fun awaitReady() {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(6)
        while (System.nanoTime() < deadline) {
            shadowOf(Looper.getMainLooper()).idleFor(25, TimeUnit.MILLISECONDS)
            if (model.state.value.stage == AppUpdateStage.READY) return
            Thread.sleep(5)
        }
        fail("Update must be verified before the screen opens: ${model.state.value}")
    }

    private fun nextIntent(activity: ShadowActivity, action: String): ShadowActivity.IntentForResult {
        compose.waitForIdle()
        try { compose.waitUntil(6_000) {
            // ShadowActivity delivers the external result, but Compose's clock
            // alone does not dispatch a paused Android main-looper continuation.
            shadowOf(Looper.getMainLooper()).idle()
            activity.peekNextStartedActivityForResult() != null
        } }
        catch (failure: ComposeTimeoutException) {
            throw AssertionError("No $action; update=${model.state.value}; " +
                "activityPermission=${compose.activity.packageManager.canRequestPackageInstalls()}; " +
                "applicationPermission=${app.packageManager.canRequestPackageInstalls()}; " +
                "application=${model.getApplication<Application>().filesDir}; " +
                compose.onRoot().printToString(), failure)
        }
        return requireNotNull(activity.nextStartedActivityForResult).also { assertEquals(action, it.intent.action) }
    }

    private fun assertNoFurtherLaunch(activity: ShadowActivity) {
        compose.waitForIdle()
        compose.runOnIdle { assertNull("Each explicit update action may launch system UI only once", activity.peekNextStartedActivityForResult()) }
    }

    private class FixtureDownloads(private val target: File, private val bytes: ByteArray) : AppUpdateDownloads {
        private var update: PublishedAppUpdate? = null
        private var removed = false
        override fun enqueue(update: PublishedAppUpdate): Long {
            this.update = update
            removed = false
            target.writeBytes(bytes)
            return 72
        }
        override fun query(id: Long): AppUpdateDownloadSnapshot? = update?.takeIf { id == 72L && !removed }?.let {
            AppUpdateDownloadSnapshot(DownloadManager.STATUS_SUCCESSFUL, 0, bytes.size.toLong(), bytes.size.toLong(), it.apkUrl)
        }
        override fun remove(id: Long) { require(id == 72L); removed = true; target.delete() }
        override fun file(update: PublishedAppUpdate) = target
    }

    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}
