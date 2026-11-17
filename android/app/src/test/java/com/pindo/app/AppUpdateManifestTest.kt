package com.pindo.app

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AppUpdateManifestTest {
    private val installed = InstalledAppIdentity("com.pindo.app", 1066, "a".repeat(64))
    private val apk = "https://github.com/CodexSpaceSafe-Projects/pindo/releases/download/android-build-67/Pindo-Android.apk"
    private val release = "https://github.com/CodexSpaceSafe-Projects/pindo/releases/tag/android-build-67"
    private val bytes = 12_345L

    private fun metadata() = JSONObject().put("applicationId", installed.applicationId)
        .put("versionCode", 1067).put("versionName", "0.6.0-build67.${"b".repeat(7)}")
        .put("certificateSha256", installed.certificateSha256).put("sha256", "c".repeat(64))
        .put("sourceRevision", "b".repeat(40))

    private fun parse(json: JSONObject = metadata(), apkUrl: String = apk, apkBytes: Long = bytes,
                      releaseUrl: String = release) =
        PublishedAppUpdate.fromMetadata(json, apkUrl, apkBytes, releaseUrl, installed)

    @Test fun newerOfficialReleaseKeepsExactPublishedIdentityAndBounds() {
        val update = parse()
        assertEquals(installed.applicationId, update.applicationId)
        assertEquals(1067L, update.versionCode)
        assertEquals(installed.certificateSha256, update.certificateSha256)
        assertEquals(apk, update.apkUrl)
        assertEquals(bytes, update.apkBytes)
        assertEquals(release, update.releaseUrl)
        update.copy(apkBytes = PublishedAppUpdate.MAX_APK_BYTES).validateFor(installed)
        // Metadata is pinned to the installation, not to a different app variant.
        val dev = installed.copy(applicationId = "com.pindo.app.dev")
        PublishedAppUpdate.fromMetadata(metadata().put("applicationId", dev.applicationId), apk, bytes, release, dev)
    }

    @Test fun versionMustBeAnIncreasingIntegerWithinAndroidsSupportedRange() {
        for (value in listOf<Any>("1067", 1067.0, 1067.5, true, JSONObject.NULL, 0, -1, 1065, 1066,
            Int.MAX_VALUE.toLong() + 1, Long.MAX_VALUE)) {
            assertThrows("Unexpected accepted version: $value", IllegalArgumentException::class.java) {
                parse(metadata().put("versionCode", value))
            }
        }
        assertThrows(IllegalArgumentException::class.java) { parse(metadata().apply { remove("versionCode") }) }
        assertEquals(Int.MAX_VALUE.toLong(), parse(metadata().put("versionCode", Int.MAX_VALUE.toLong())).versionCode)
    }

    @Test fun missingOrCoercedFieldsAndUnusableVersionNamesAreRejected() {
        for (key in listOf("applicationId", "versionName", "certificateSha256", "sha256", "sourceRevision")) {
            for (value in listOf<Any>(123, true, JSONObject.NULL)) {
                assertThrows("Unexpected accepted $key", IllegalArgumentException::class.java) {
                    parse(metadata().put(key, value))
                }
            }
            assertThrows(IllegalArgumentException::class.java) { parse(metadata().apply { remove(key) }) }
        }
        for (name in listOf("", "  ", "x".repeat(129), "0.6.0\n", "0.6.0\u007f")) {
            assertThrows(IllegalArgumentException::class.java) { parse(metadata().put("versionName", name)) }
        }
    }

    @Test fun wrongPackageSignerHashOrRevisionCannotBecomeAnUpdate() {
        val changes = listOf("applicationId" to "com.example.other", "certificateSha256" to "d".repeat(64),
            "certificateSha256" to "A".repeat(64), "sha256" to "C".repeat(64), "sha256" to "c".repeat(63),
            "sha256" to "z".repeat(64), "sourceRevision" to "b".repeat(39), "sourceRevision" to "B".repeat(40))
        for ((key, value) in changes) assertThrows("Unexpected accepted $key", IllegalArgumentException::class.java) {
            parse(metadata().put(key, value))
        }
        assertThrows(IllegalArgumentException::class.java) { parse(apkBytes = 0) }
        assertThrows(IllegalArgumentException::class.java) { parse(apkBytes = -1) }
        assertThrows(IllegalArgumentException::class.java) { parse(apkBytes = PublishedAppUpdate.MAX_APK_BYTES + 1) }
    }

    @Test fun onlyTheMatchingCanonicalOfficialReleaseAndApkAreAllowed() {
        val invalidApks = listOf(apk.replace("https:", "http:"), apk.replace("github.com", "github.com.example.test"),
            apk.replace("github.com", "user@github.com"), apk.replace("github.com", "github.com:443"),
            apk.replace("CodexSpaceSafe-Projects", "other"), apk.replace("/pindo/", "/other/"),
            apk.replace("Pindo-Android.apk", "another.apk"), apk.replace("android-build-67", "android-build-0"),
            apk.replace("android-build-67", "android-build-067"), apk.replace("/releases/", "/./releases/"),
            "$apk?token=example", "$apk#fragment", "$apk/", apk.replace(".apk", "%2eapk"))
        for (url in invalidApks) assertThrows("Unexpected accepted download URL", IllegalArgumentException::class.java) {
            parse(apkUrl = url)
        }
        for (url in listOf(release.replace("67", "68"), "$release?query=1", "$release#part", "$release/",
            release.replace("https:", "http:"), release.replace("pindo", "other"))) {
            assertThrows("Unexpected accepted release URL", IllegalArgumentException::class.java) { parse(releaseUrl = url) }
        }
    }

    @Test fun restoredRecordsMustStillMatchTheCurrentInstalledVersionAndCertificate() {
        val update = parse()
        assertThrows(IllegalArgumentException::class.java) { update.validateFor(installed.copy(versionCode = 1067)) }
        assertThrows(IllegalArgumentException::class.java) { update.validateFor(installed.copy(certificateSha256 = "d".repeat(64))) }
        assertThrows(IllegalArgumentException::class.java) { update.copy(apkUrl = "https://example.test/update.apk").validateFor(installed) }
    }

    @Test fun checkingCanReadAValidCurrentOrOlderReleaseWithoutMakingItInstallable() {
        for (code in listOf(1065, 1066)) {
            val update = PublishedAppUpdate.fromMetadata(metadata().put("versionCode", code), apk, bytes, release,
                installed, requireNewer = false)
            assertEquals(code.toLong(), update.versionCode)
            assertThrows(IllegalArgumentException::class.java) { update.validateFor(installed) }
        }
        assertThrows(IllegalArgumentException::class.java) {
            PublishedAppUpdate.fromMetadata(metadata().put("certificateSha256", "d".repeat(64)), apk, bytes, release,
                installed, requireNewer = false)
        }
    }
}
