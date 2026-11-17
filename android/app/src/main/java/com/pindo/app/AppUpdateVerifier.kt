package com.pindo.app

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.pm.PackageInfoCompat
import java.io.File
import java.security.MessageDigest

/** The installed application's current signer is the update trust anchor.
 * Metadata and archive inspection supplement Android's final installer checks. */
internal object AppUpdateVerifier {
    @Suppress("DEPRECATION")
    fun installed(context: Context): InstalledAppIdentity {
        val info = context.packageManager.getPackageInfo(context.packageName, signingFlags())
        val app = info.applicationInfo ?: throw IllegalArgumentException("无法读取当前应用信息。")
        return InstalledAppIdentity(info.packageName, PackageInfoCompat.getLongVersionCode(info), certificate(info),
            app.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0)
    }

    fun verify(context: Context, file: File, update: PublishedAppUpdate, installed: InstalledAppIdentity) {
        update.validateFor(installed)
        require(installed(context) == installed) { "应用版本已变化，请重新检查更新。" }
        require(file.isFile && file.length() == update.apkBytes) { "安装包不完整，请重新下载。" }
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(32 * 1024)
            var count = 0L
            while (true) {
                val size = input.read(buffer)
                if (size < 0) break
                count += size
                require(count <= update.apkBytes) { "安装包大小不符，请重新下载。" }
                digest.update(buffer, 0, size)
            }
            require(count == update.apkBytes) { "安装包不完整，请重新下载。" }
        }
        require(digest.digest().hex() == update.sha256) { "安装包校验失败，请重新下载。" }
        @Suppress("DEPRECATION")
        val archive = context.packageManager.getPackageArchiveInfo(file.absolutePath, signingFlags())
            ?: throw IllegalArgumentException("无法读取安装包，请重新下载。")
        require(archive.packageName == installed.applicationId && archive.packageName == update.applicationId) {
            "安装包不属于此应用。"
        }
        val versionCode = PackageInfoCompat.getLongVersionCode(archive)
        require(versionCode == update.versionCode && versionCode > installed.versionCode && archive.versionName == update.versionName) {
            "安装包版本不符，请重新检查更新。"
        }
        val app = archive.applicationInfo ?: throw IllegalArgumentException("安装包信息不完整。")
        require((app.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) == installed.isDebuggable) {
            "安装包与当前应用的发布类型不匹配。"
        }
        require(certificate(archive) == installed.certificateSha256) { "安装包签名不匹配，已停止安装。" }
    }

    @Suppress("DEPRECATION")
    private fun signingFlags(): Int = if (Build.VERSION.SDK_INT >= 28) {
        // Android 10's archive parser collects certificates only when the
        // legacy flag is present, even if modern SigningInfo was requested.
        PackageManager.GET_SIGNATURES or PackageManager.GET_SIGNING_CERTIFICATES
    } else PackageManager.GET_SIGNATURES

    @Suppress("DEPRECATION")
    private fun certificate(info: PackageInfo): String {
        val signatures = (if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures)
            ?: throw IllegalArgumentException("无法确认应用的固定签名，已停止更新。")
        require(signatures.size == 1) { "无法确认应用的固定签名，已停止更新。" }
        return MessageDigest.getInstance("SHA-256").digest(signatures.single().toByteArray()).hex()
    }

    private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
