package com.pindo.app

import org.json.JSONObject

internal data class InstalledAppIdentity(
    val applicationId: String,
    val versionCode: Long,
    val certificateSha256: String,
    val isDebuggable: Boolean = false
)

internal data class PublishedAppUpdate(
    val applicationId: String,
    val versionCode: Long,
    val versionName: String,
    val certificateSha256: String,
    val sha256: String,
    val sourceRevision: String,
    val apkUrl: String,
    val apkBytes: Long,
    val releaseUrl: String
) {
    /** A restored download record must satisfy the same checks as fresh metadata. */
    fun validateFor(installed: InstalledAppIdentity, requireNewer: Boolean = true) {
        require(installed.applicationId.isNotBlank() && installed.versionCode >= 0 &&
            SHA256.matches(installed.certificateSha256)) { "无法验证当前应用身份。" }
        require(applicationId == installed.applicationId && certificateSha256 == installed.certificateSha256) {
            "更新包与当前应用的安装身份不匹配。"
        }
        require(versionCode in 1..Int.MAX_VALUE.toLong()) { "更新版本信息无效。" }
        if (requireNewer) require(versionCode > installed.versionCode) { "更新版本必须高于当前版本。" }
        require(versionName.isNotBlank() && versionName.length <= 128 &&
            versionName.none { it.code in 0..31 || it.code in 127..159 }) { "更新版本信息无效。" }
        require(SHA256.matches(sha256) && SHA256.matches(certificateSha256) && REVISION.matches(sourceRevision)) {
            "更新包校验信息无效。"
        }
        require(apkBytes in 1..MAX_APK_BYTES) { "更新包大小无效。" }
        val tag = OFFICIAL_APK.matchEntire(apkUrl)?.groupValues?.get(1)
        require(tag != null && releaseUrl == "$REPOSITORY/releases/tag/$tag") {
            "更新下载地址无效。"
        }
    }

    companion object {
        const val MAX_APK_BYTES = 128L * 1024 * 1024
        private const val REPOSITORY = "https://github.com/CodexSpaceSafe-Projects/pindo"
        private val SHA256 = Regex("[0-9a-f]{64}")
        private val REVISION = Regex("[0-9a-f]{40}")
        private val OFFICIAL_APK = Regex(Regex.escape(REPOSITORY) +
            "/releases/download/(android-build-[1-9][0-9]*)/Pindo-Android\\.apk")

        fun fromMetadata(json: JSONObject, apkUrl: String, apkBytes: Long, releaseUrl: String,
                         installed: InstalledAppIdentity, requireNewer: Boolean = true): PublishedAppUpdate {
            fun text(key: String): String = json.opt(key).let {
                require(it is String) { "更新信息格式无效。" }
                it
            }
            val codeValue = json.opt("versionCode")
            require(codeValue is Number) { "更新版本信息无效。" }
            val code = codeValue.toString().toLongOrNull()
                ?: throw IllegalArgumentException("更新版本信息无效。")
            return PublishedAppUpdate(text("applicationId"), code, text("versionName"),
                text("certificateSha256"), text("sha256"), text("sourceRevision"),
                apkUrl, apkBytes, releaseUrl).also { it.validateFor(installed, requireNewer) }
        }
    }
}
