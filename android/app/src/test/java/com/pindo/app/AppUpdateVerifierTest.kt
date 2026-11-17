package com.pindo.app

import android.app.Application
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.Signature
import android.content.pm.SigningInfo
import android.os.Build
import androidx.test.core.app.ApplicationProvider
import java.io.File
import java.security.MessageDigest
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.util.ReflectionHelpers

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AppUpdateVerifierTest {
    private lateinit var app: Application
    private lateinit var apk: File
    private lateinit var identity: InstalledAppIdentity
    private lateinit var update: PublishedAppUpdate
    private val certificate = Signature(byteArrayOf(1, 4, 9, 16, 25, 36))
    private val otherCertificate = Signature(byteArrayOf(36, 25, 16, 9, 4, 1))
    private val bytes = "Synthetic APK bytes: archive identity is supplied by Android PackageManager's test shadow.".toByteArray()

    @Before fun prepare() {
        app = ApplicationProvider.getApplicationContext()
        apk = File(app.cacheDir, "app-update-verifier.apk").apply { writeBytes(bytes) }
        shadowOf(app.packageManager).installPackage(info(app.packageName, 1000, "0.6.0", arrayOf(certificate)))
        identity = AppUpdateVerifier.installed(app)
        update = PublishedAppUpdate(app.packageName, 1001, "0.6.1", digest(certificate.toByteArray()), digest(bytes),
            "b".repeat(40), "https://github.com/CodexSpaceSafe-Projects/pindo/releases/download/android-build-1/Pindo-Android.apk",
            bytes.size.toLong(), "https://github.com/CodexSpaceSafe-Projects/pindo/releases/tag/android-build-1")
        setArchive()
    }

    @Test fun exactHigherVersionWithCurrentSignerAndHashIsAccepted() {
        assertEquals(app.packageName, identity.applicationId)
        assertEquals(1000L, identity.versionCode)
        assertFalse(identity.isDebuggable)
        assertEquals(digest(certificate.toByteArray()), identity.certificateSha256)
        AppUpdateVerifier.verify(app, apk, update, identity)
        assertArrayEquals(bytes, apk.readBytes())
    }

    @Test fun sameSizedTamperingAndTruncatedOrMissingFilesNeverReachInstallation() {
        apk.writeBytes(bytes.copyOf().also { it[0] = (it[0].toInt() xor 1).toByte() })
        assertRejected()
        apk.writeBytes(bytes.copyOf(bytes.size - 1))
        assertRejected()
        apk.delete()
        assertRejected()
    }

    @Test fun wrongPackageDowngradeMetadataMismatchAndDebugArchivesAreRejected() {
        val invalid = listOf(info("com.example.unrelated", 1001, "0.6.1", arrayOf(certificate)),
            info(app.packageName, 1000, "0.6.1", arrayOf(certificate)),
            info(app.packageName, 1002, "0.6.1", arrayOf(certificate)),
            info(app.packageName, 1001, "other-version", arrayOf(certificate)),
            info(app.packageName, 1001, "0.6.1", arrayOf(certificate)).apply {
                requireNotNull(applicationInfo).apply { flags = flags or ApplicationInfo.FLAG_DEBUGGABLE }
            })
        for (archive in invalid) {
            shadowOf(app.packageManager).setPackageArchiveInfo(apk.absolutePath, archive)
            assertRejected()
        }
        assertThrows(IllegalArgumentException::class.java) {
            AppUpdateVerifier.verify(app, apk, update.copy(versionCode = identity.versionCode), identity)
        }
    }

    @Test fun missingWrongOrMultipleArchiveSignersAreRejected() {
        for (signers in listOf(emptyArray(), arrayOf(otherCertificate), arrayOf(certificate, otherCertificate))) {
            setArchive(signers = signers)
            assertRejected()
        }
        setArchive()
        assertThrows(IllegalArgumentException::class.java) {
            AppUpdateVerifier.verify(app, apk, update.copy(certificateSha256 = digest(otherCertificate.toByteArray())), identity)
        }
    }

    @Test fun anInstalledVersionChangeInvalidatesPreviouslyPreparedUpdates() {
        shadowOf(app.packageManager).installPackage(info(app.packageName, 1001, "0.6.1", arrayOf(certificate)))
        assertRejected()
        val current = AppUpdateVerifier.installed(app)
        assertEquals(1001L, current.versionCode)
        assertThrows(IllegalArgumentException::class.java) { AppUpdateVerifier.verify(app, apk, update, current) }
    }

    @Test fun installedIdentityRequiresExactlyOneCurrentSigner() {
        for (signers in listOf(emptyArray(), arrayOf(certificate, otherCertificate))) {
            shadowOf(app.packageManager).installPackage(info(app.packageName, 1000, "0.6.0", signers))
            assertThrows(IllegalArgumentException::class.java) { AppUpdateVerifier.installed(app) }
        }
    }

    @Test fun developerUpdatesMustKeepTheRealInstalledPackageSignerAndDebuggableIdentity() {
        val installedInfo = info(app.packageName, 1000, "0.6.0", arrayOf(certificate)).apply {
            requireNotNull(applicationInfo).flags = ApplicationInfo.FLAG_DEBUGGABLE
        }
        shadowOf(app.packageManager).installPackage(installedInfo)
        val dev = AppUpdateVerifier.installed(app)
        assertTrue(dev.isDebuggable)
        val future = info(app.packageName, 1001, "0.6.1", arrayOf(certificate)).apply {
            requireNotNull(applicationInfo).flags = ApplicationInfo.FLAG_DEBUGGABLE
        }
        shadowOf(app.packageManager).setPackageArchiveInfo(apk.absolutePath, future)
        AppUpdateVerifier.verify(app, apk, update, dev)
        assertThrows(IllegalArgumentException::class.java) {
            AppUpdateVerifier.verify(app, apk, update, dev.copy(isDebuggable = false))
        }
        setArchive()
        assertThrows(IllegalArgumentException::class.java) { AppUpdateVerifier.verify(app, apk, update, dev) }
    }

    private fun assertRejected() {
        assertThrows(IllegalArgumentException::class.java) { AppUpdateVerifier.verify(app, apk, update, identity) }
    }

    private fun setArchive(signers: Array<Signature> = arrayOf(certificate)) {
        shadowOf(app.packageManager).setPackageArchiveInfo(apk.absolutePath, info(app.packageName, 1001, "0.6.1", signers))
    }

    @Suppress("DEPRECATION")
    private fun info(name: String, code: Long, version: String, signers: Array<Signature>) = PackageInfo().apply {
        packageName = name
        versionName = version
        if (Build.VERSION.SDK_INT >= 28) {
            setLongVersionCode(code)
            signingInfo = ReflectionHelpers.callConstructor(SigningInfo::class.java).also {
                shadowOf(it).setSignatures(signers)
            }
        } else versionCode = code.toInt()
        signatures = signers
        applicationInfo = ApplicationInfo().apply { packageName = name; flags = 0 }
    }

    private fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
