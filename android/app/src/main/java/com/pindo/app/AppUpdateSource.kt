package com.pindo.app

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI

internal interface AppUpdateSource {
    suspend fun latest(installed: InstalledAppIdentity): PublishedAppUpdate?
}

/** Android releases are prereleases, so GitHub's /latest (the Mac app) is not this channel. */
internal class GitHubAppUpdateSource(
    private val read: (String, Int) -> ByteArray = ::readUpdateResponse
) : AppUpdateSource {
    override suspend fun latest(installed: InstalledAppIdentity): PublishedAppUpdate? = withContext(Dispatchers.IO) {
        for (page in 1..10) {
            ensureActive()
            val releases = JSONArray(String(read("$API/releases?per_page=20&page=$page", 4 * 1024 * 1024), Charsets.UTF_8))
            val candidates = (0 until releases.length()).map { releases.getJSONObject(it) }
                .filter { !it.optBoolean("draft") && TAG.matches(it.optString("tag_name")) }
                .sortedByDescending { it.getString("tag_name").removePrefix("android-build-").toLong() }
            for (release in candidates) {
                val tag = release.getString("tag_name")
                val assets = release.getJSONArray("assets")
                fun asset(name: String): JSONObject? = (0 until assets.length()).map { assets.getJSONObject(it) }
                    .singleOrNull { it.optString("name") == name }
                val apk = asset("Pindo-Android.apk") ?: continue
                val manifest = asset("android-update.json") ?: continue
                val base = "$REPOSITORY/releases/download/$tag"
                require(apk.getString("browser_download_url") == "$base/Pindo-Android.apk" &&
                    manifest.getString("browser_download_url") == "$base/android-update.json") { "更新下载地址无效。" }
                fun size(value: JSONObject): Long {
                    val number = value.get("size")
                    require(number is Number)
                    return number.toString().toLongOrNull() ?: error("更新包大小无效。")
                }
                require(size(manifest) in 1..64 * 1024)
                val metadata = JSONObject(String(read("$base/android-update.json", 64 * 1024), Charsets.UTF_8))
                ensureActive()
                val update = PublishedAppUpdate.fromMetadata(metadata, "$base/Pindo-Android.apk", size(apk),
                    "$REPOSITORY/releases/tag/$tag", installed, requireNewer = false)
                val build = tag.removePrefix("android-build-").toLong()
                require(build <= Int.MAX_VALUE - 1000L && update.versionCode == 1000L + build) { "更新版本信息无效。" }
                val target = release.optString("target_commitish")
                if (REVISION.matches(target)) require(target == update.sourceRevision) { "更新提交信息不一致。" }
                return@withContext update.takeIf { it.versionCode > installed.versionCode }
            }
            if (releases.length() < 20) break
        }
        error("暂未找到可用的 Android 更新，请稍后重试。")
    }

    private companion object {
        const val REPOSITORY = "https://github.com/CodexSpaceSafe-Projects/pindo"
        const val API = "https://api.github.com/repos/CodexSpaceSafe-Projects/pindo"
        val TAG = Regex("android-build-[1-9][0-9]{0,9}")
        val REVISION = Regex("[0-9a-f]{40}")
    }
}

private fun readUpdateResponse(initial: String, limit: Int): ByteArray {
    var uri = URI(initial)
    repeat(6) {
        val host = uri.host.orEmpty().lowercase()
        require(uri.scheme == "https" && uri.userInfo == null &&
            (host == "github.com" || host == "api.github.com" || host.endsWith(".githubusercontent.com"))) { "更新地址无效。" }
        val connection = uri.toURL().openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            connection.setRequestProperty("Accept", "application/vnd.github+json")
            connection.setRequestProperty("User-Agent", "Pindo-Android")
            connection.setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
            val code = connection.responseCode
            if (code in listOf(301, 302, 303, 307, 308)) {
                uri = uri.resolve(connection.getHeaderField("Location") ?: error("更新服务响应无效。"))
            } else {
                check(code in 200..299) {
                    if (code == 403 || code == 429) "检查更新过于频繁，请稍后重试。" else "更新服务暂不可用，请稍后重试。"
                }
                require(connection.contentLengthLong <= limit) { "更新信息超过大小限制。" }
                return connection.inputStream.use { input ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        require(output.size().toLong() + count <= limit) { "更新信息超过大小限制。" }
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                }
            }
        } finally { connection.disconnect() }
    }
    error("更新服务重定向过多，请稍后重试。")
}
