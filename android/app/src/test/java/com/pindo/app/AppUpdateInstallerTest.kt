package com.pindo.app

import android.Manifest
import android.app.Application
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import java.nio.file.Files

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AppUpdateInstallerTest {
    private lateinit var app: Application
    private lateinit var installer: AppUpdateInstaller
    private lateinit var updates: File

    @Before fun prepare() {
        app = ApplicationProvider.getApplicationContext()
        updates = File(app.filesDir, "app-updates").apply { deleteRecursively(); mkdirs() }
        AppUpdateFileProvider().attachInfo(app,
            requireNotNull(app.packageManager.resolveContentProvider("${app.packageName}.updates", 0)))
        installer = AppUpdateInstaller(app)
    }

    @Test fun permissionScreenTargetsOnlyThisAppAndManifestRequestsInstallPermission() {
        val intent = installer.permissionIntent()
        assertEquals(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, intent.action)
        assertEquals(Uri.parse("package:${app.packageName}"), intent.data)
        val info = app.packageManager.getPackageInfo(app.packageName, PackageManager.GET_PERMISSIONS)
        assertTrue(info.requestedPermissions.orEmpty().contains(Manifest.permission.REQUEST_INSTALL_PACKAGES))
    }

    @Test fun installationPermissionTracksTheCurrentSystemSetting() {
        val packages = shadowOf(app.packageManager)
        packages.setCanRequestPackageInstalls(false)
        assertFalse(installer.canInstall())
        packages.setCanRequestPackageInstalls(true)
        assertTrue(installer.canInstall())
        packages.setCanRequestPackageInstalls(false)
        assertFalse(installer.canInstall())
    }

    @Test fun installationSharesOnlyThePrivatePackageThroughAReadOnlyContentUri() {
        val contents = "verified APK fixture".toByteArray()
        val apk = File(updates, "Pindo-123.apk").apply { writeBytes(contents) }
        val intent = installer.installIntent(apk)
        val uri = requireNotNull(intent.data)
        assertEquals(Intent.ACTION_VIEW, intent.action)
        assertEquals("application/vnd.android.package-archive", intent.type)
        assertEquals("content", uri.scheme)
        assertEquals("${app.packageName}.updates", uri.authority)
        assertTrue(intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
        assertEquals(0, intent.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        assertTrue(intent.getBooleanExtra(Intent.EXTRA_RETURN_RESULT, false))
        assertEquals(uri, intent.clipData!!.getItemAt(0).uri)
        app.contentResolver.openInputStream(uri)!!.use { assertArrayEquals(contents, it.readBytes()) }
        val provider = app.packageManager.resolveContentProvider(uri.authority!!, 0)!!
        assertFalse(provider.exported)
        assertTrue(provider.grantUriPermissions)
    }

    @Test fun invalidMissingAndOutOfDirectoryPackagesCannotBeShared() {
        val outside = File(app.filesDir, "private-data.apk").apply { writeText("not an update") }
        val prefixSibling = File(app.filesDir, "app-updates-other").apply { mkdirs() }
        val prefixFile = File(prefixSibling, "outside.apk").apply { writeText("outside") }
        val invalid = listOf(outside, prefixFile, File(updates, "missing.apk"),
            File(updates, "empty.apk").apply { createNewFile() },
            File(updates, "data.json").apply { writeText("not APK") }, updates)
        invalid.forEach { file ->
            assertThrows(IllegalArgumentException::class.java) { installer.installIntent(file) }
        }
        val link = File(updates, "escaped.apk")
        Files.createSymbolicLink(link.toPath(), outside.toPath())
        assertThrows(IllegalArgumentException::class.java) { installer.installIntent(link) }
        assertEquals("not an update", outside.readText())
    }
}
