package com.pindo.app

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.Application
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.core.content.pm.PackageInfoCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.pindo.app.sync.equalV3
import java.io.File
import java.security.MessageDigest
import java.util.Locale
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** CI supplies its newer, same-signed APK while the older build is installed.
 * The real system confirmation is opened and cancelled; normal upgrade checks
 * then install that exact file without removing the seeded data. */
@RunWith(AndroidJUnit4::class)
class AppUpdatePlatformTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val app get() = instrumentation.targetContext.applicationContext as Application
    private val automation get() = instrumentation.uiAutomation
    private val output get() = File(app.filesDir, "update-platform").apply { mkdirs() }
    private val installers = setOf("com.android.packageinstaller", "com.google.android.packageinstaller",
        "com.android.permissioncontroller", "com.google.android.permissioncontroller")

    @Test fun newerSameSignedPackageReachesTheSystemUpdateConfirmationWithoutChangingData() {
        val original = DocumentStorage(app).read()
        val installed = AppUpdateVerifier.installed(app)
        val apk = File(app.filesDir, "app-updates/platform-update.apk")
        @Suppress("DEPRECATION")
        val archive = requireNotNull(app.packageManager.getPackageArchiveInfo(apk.absolutePath, 0))
        val futureCode = PackageInfoCompat.getLongVersionCode(archive)
        assertTrue("The supplied package must update the installed version", futureCode > installed.versionCode)
        val revision = requireNotNull(InstrumentationRegistry.getArguments().getString("sourceRevision"))
        val tag = "android-build-${futureCode - 1000}"
        val release = "https://github.com/CodexSpaceSafe-Projects/pindo/releases"
        val update = PublishedAppUpdate(installed.applicationId, futureCode, requireNotNull(archive.versionName),
            installed.certificateSha256, digest(apk), revision, "$release/download/$tag/Pindo-Android.apk",
            apk.length(), "$release/tag/$tag")
        AppUpdateVerifier.verify(app, apk, update, installed)
        val bridge = AppUpdateInstaller(app)
        assertTrue("CI grants the actual install-source app-op before opening Android's installer", bridge.canInstall())
        val intent = bridge.installIntent(apk)
        assertEquals("content", intent.data!!.scheme)
        app.contentResolver.openInputStream(intent.data!!)!!.use { input ->
            val read = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(32 * 1024)
            while (true) { val n = input.read(buffer); if (n < 0) break; read.update(buffer, 0, n) }
            assertEquals(update.sha256, read.digest().hex())
        }
        val flags = automation.serviceInfo.flags
        automation.serviceInfo = automation.serviceInfo.apply {
            this.flags = this.flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        }
        val activity = instrumentation.startActivitySync(Intent(app, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        var complete = false
        try {
            instrumentation.runOnMainSync { activity.startActivity(intent) }
            val label = normal(app.packageManager.getApplicationLabel(app.applicationInfo))
            await("Android must show an update confirmation for this installed app") {
                val visible = nodes()
                visible.any { it.packageName?.toString() in installers } &&
                    visible.any { normal(it.text).contains(label) || normal(it.contentDescription).contains(label) } &&
                    visible.any { normal(it.text).contains("update") || normal(it.text).contains("更新") } &&
                    cancel() != null
            }
            screenshot("installer-confirmation")
            tap(requireNotNull(cancel()))
            await("Cancelling must close the system installer") { nodes().none { it.packageName?.toString() in installers } }
            assertEquals("Cancelling an update must retain the installed version and signer", installed, AppUpdateVerifier.installed(app))
            assertTrue("Opening and cancelling an update must not modify the original document", equalV3(original, DocumentStorage(app).read()))
            complete = true
        } finally {
            if (!complete) {
                runCatching { screenshot("failure") }
                runCatching { File(output, "failure-hierarchy.txt").writeText(hierarchy()) }
            }
            instrumentation.runOnMainSync { activity.finish() }
            automation.serviceInfo = automation.serviceInfo.apply { this.flags = flags }
        }
    }

    private fun normal(text: CharSequence?): String = text?.filterNot(Char::isWhitespace)?.toString()?.lowercase(Locale.ROOT).orEmpty()
    private fun nodes(): List<AccessibilityNodeInfo> {
        val result = mutableListOf<AccessibilityNodeInfo>()
        val queue = java.util.ArrayDeque<AccessibilityNodeInfo>()
        automation.windows.mapNotNull { it.root }.forEach(queue::add)
        while (queue.isNotEmpty()) {
            val node = queue.removeFirst()
            if (!node.refresh()) continue
            if (node.isVisibleToUser) result.add(node)
            for (i in 0 until node.childCount) node.getChild(i)?.let(queue::add)
        }
        return result
    }
    private fun cancel(): AccessibilityNodeInfo? {
        val labels = nodes().filter { normal(it.text) in setOf("cancel", "取消") && it.packageName?.toString() in installers }
        for (label in labels) {
            var node: AccessibilityNodeInfo? = label
            while (node != null) {
                if (node.refresh() && node.isVisibleToUser && node.isEnabled && node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK }) return node
                node = node.parent
            }
        }
        return null
    }
    private fun tap(node: AccessibilityNodeInfo) {
        val rect = Rect().also(node::getBoundsInScreen)
        assertFalse("Installer confirmation needs a real, visible cancel target", rect.isEmpty)
        val time = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(time, SystemClock.uptimeMillis(), action, rect.exactCenterX(), rect.exactCenterY(), 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            try { assertTrue(automation.injectInputEvent(event, true)) } finally { event.recycle() }
        }
        instrumentation.waitForIdleSync()
    }
    private fun await(message: String, condition: () -> Boolean) {
        val limit = SystemClock.uptimeMillis() + 15_000
        while (SystemClock.uptimeMillis() < limit) {
            if (condition()) return
            SystemClock.sleep(100)
        }
        fail("$message\n${hierarchy()}")
    }
    private fun screenshot(name: String) {
        val bitmap = requireNotNull(automation.takeScreenshot())
        try { File(output, "$name.png").outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
        finally { bitmap.recycle() }
    }
    private fun hierarchy() = nodes().joinToString("\n") {
        "${it.packageName} ${it.className} text=${it.text} description=${it.contentDescription} bounds=${Rect().also(it::getBoundsInScreen)}"
    }
    private fun digest(file: File): String {
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(32 * 1024)
            while (true) { val n = input.read(buffer); if (n < 0) break; hash.update(buffer, 0, n) }
        }
        return hash.digest().hex()
    }
    private fun ByteArray.hex() = joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
