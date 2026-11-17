package com.pindo.app

import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AppUpdateSourceTest {
    private val installed = InstalledAppIdentity("com.pindo.app", 1066, "a".repeat(64))

    @Test fun macLatestAndAndroidPrereleaseOrderDoNotHideTheHighestAndroidBuild() = runBlocking {
        val older = metadata(67)
        val newest = metadata(69)
        val middle = metadata(68)
        val reader = FixtureReader(mapOf(page(1) to arrayBytes(macRelease(101), release(67, older),
            release(69, newest), release(68, middle), release(70, metadata(70)).put("draft", true)),
            manifest(69) to bytes(newest)))

        val update = GitHubAppUpdateSource(reader::read).latest(installed)

        assertNotNull(update)
        assertEquals(1069L, update!!.versionCode)
        assertEquals("$REPOSITORY/releases/download/android-build-69/Pindo-Android.apk", update.apkUrl)
        assertEquals("$REPOSITORY/releases/tag/android-build-69", update.releaseUrl)
        assertEquals(listOf(page(1), manifest(69)), reader.requested)
    }

    @Test fun fullMacOnlyPageContinuesToTheNextPageForTheAndroidChannel() = runBlocking {
        val android = metadata(67)
        val first = JSONArray().also { page -> repeat(20) { page.put(macRelease(200 - it)) } }
        val reader = FixtureReader(mapOf(page(1) to bytes(first), page(2) to arrayBytes(release(67, android)),
            manifest(67) to bytes(android)))

        assertEquals(1067L, GitHubAppUpdateSource(reader::read).latest(installed)!!.versionCode)
        assertEquals(listOf(page(1), page(2), manifest(67)), reader.requested)
    }

    @Test fun validCurrentAndOlderPublishedVersionsMeanUpToDateWithoutReadingOlderCandidates() = runBlocking {
        for (current in listOf(1067L, 1068L)) {
            val newest = metadata(67)
            val reader = FixtureReader(mapOf(page(1) to arrayBytes(release(66, metadata(66)), release(67, newest)),
                manifest(67) to bytes(newest)))

            assertNull(GitHubAppUpdateSource(reader::read).latest(installed.copy(versionCode = current)))
            assertEquals(listOf(page(1), manifest(67)), reader.requested)
        }
    }

    @Test fun noPublishedAndroidChannelIsAnExplicitError() {
        val reader = FixtureReader(mapOf(page(1) to arrayBytes(macRelease(100),
            release(67, metadata(67)).put("draft", true))))
        assertThrows(IllegalStateException::class.java) {
            runBlocking { GitHubAppUpdateSource(reader::read).latest(installed) }
        }
        assertEquals(listOf(page(1)), reader.requested)
    }

    @Test fun foreignApkOrMetadataAddressesAreRejectedBeforeAnotherHostCanBeRead() {
        for (name in listOf("Pindo-Android.apk", "android-update.json")) {
            val data = metadata(67)
            val release = release(67, data)
            val assets = release.getJSONArray("assets")
            (0 until assets.length()).map(assets::getJSONObject).single { it.getString("name") == name }
                .put("browser_download_url", "https://example.invalid/$name")
            val reader = FixtureReader(mapOf(page(1) to arrayBytes(release)))

            assertThrows(IllegalArgumentException::class.java) {
                runBlocking { GitHubAppUpdateSource(reader::read).latest(installed) }
            }
            assertEquals(listOf(page(1)), reader.requested)
        }
    }

    @Test fun wrongSignerCommitOrBuildNumberCannotBecomeAnAvailableUpdate() {
        for (change in listOf("signer", "commit", "build", "package")) {
            val data = metadata(67)
            when (change) {
                "signer" -> data.put("certificateSha256", "d".repeat(64))
                "build" -> data.put("versionCode", 1068)
                "package" -> data.put("applicationId", "com.example.unrelated")
            }
            val release = release(67, data).also {
                if (change == "commit") it.put("target_commitish", "d".repeat(40))
            }
            val reader = FixtureReader(mapOf(page(1) to arrayBytes(release), manifest(67) to bytes(data)))

            assertThrows("Unexpected accepted $change", IllegalArgumentException::class.java) {
                runBlocking { GitHubAppUpdateSource(reader::read).latest(installed) }
            }
            assertEquals(listOf(page(1), manifest(67)), reader.requested)
        }
    }

    private fun metadata(build: Int) = JSONObject().put("applicationId", installed.applicationId)
        .put("versionCode", 1000 + build).put("versionName", "0.6.0-build$build.${REVISION.take(7)}")
        .put("certificateSha256", installed.certificateSha256).put("sha256", "c".repeat(64))
        .put("sourceRevision", REVISION)

    private fun release(build: Int, data: JSONObject): JSONObject {
        val base = "$REPOSITORY/releases/download/android-build-$build"
        return JSONObject().put("tag_name", "android-build-$build").put("draft", false).put("prerelease", true)
            .put("target_commitish", REVISION).put("assets", JSONArray()
                .put(JSONObject().put("name", "Pindo-Android.apk").put("size", 12_345)
                    .put("browser_download_url", "$base/Pindo-Android.apk"))
                .put(JSONObject().put("name", "android-update.json").put("size", bytes(data).size)
                    .put("browser_download_url", "$base/android-update.json")))
    }

    private fun macRelease(build: Int) = JSONObject().put("tag_name", "build-$build").put("draft", false)
        .put("prerelease", false).put("assets", JSONArray())

    private fun arrayBytes(vararg releases: JSONObject): ByteArray = bytes(JSONArray().also { a -> releases.forEach(a::put) })
    private fun bytes(value: Any): ByteArray = value.toString().toByteArray(Charsets.UTF_8)

    private class FixtureReader(private val replies: Map<String, ByteArray>) {
        val requested = mutableListOf<String>()
        fun read(url: String, limit: Int): ByteArray {
            assertFalse("The Mac /latest endpoint must never select Android updates", url.contains("/latest"))
            assertTrue("Only the fixed repository or its release metadata can be read",
                url.startsWith("$API/releases?per_page=20&page=") ||
                    url.matches(Regex(Regex.escape(REPOSITORY) + "/releases/download/android-build-[1-9][0-9]*/android-update\\.json")))
            requested.add(url)
            val result = replies[url] ?: throw AssertionError("Unexpected update read: $url")
            assertTrue("Fixture must respect the requested response bound", result.size <= limit)
            return result.copyOf()
        }
    }

    private companion object {
        const val REPOSITORY = "https://github.com/CodexSpaceSafe-Projects/pindo"
        const val API = "https://api.github.com/repos/CodexSpaceSafe-Projects/pindo"
        val REVISION = "b".repeat(40)
        fun page(number: Int) = "$API/releases?per_page=20&page=$number"
        fun manifest(build: Int) = "$REPOSITORY/releases/download/android-build-$build/android-update.json"
    }
}
