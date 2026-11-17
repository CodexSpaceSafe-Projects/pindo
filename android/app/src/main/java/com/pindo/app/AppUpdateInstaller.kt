package com.pindo.app

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File

class AppUpdateFileProvider : FileProvider()

/** Opens Android's permission and installation screens without changing app data. */
internal class AppUpdateInstaller(private val context: Context) {
    fun canInstall(): Boolean = context.packageManager.canRequestPackageInstalls()

    fun permissionIntent(): Intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
        Uri.parse("package:${context.packageName}"))

    fun installIntent(file: File): Intent {
        val directory = File(context.filesDir, "app-updates").canonicalFile
        val apk = file.canonicalFile
        require(apk.isFile && apk.length() > 0 && apk.extension.equals("apk", ignoreCase = true) &&
            apk.toPath().startsWith(directory.toPath()) && apk != directory) { "更新安装包不可用，请重新下载。" }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.updates", apk)
        return Intent(Intent.ACTION_VIEW).setDataAndType(uri, APK_TYPE)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .putExtra(Intent.EXTRA_RETURN_RESULT, true)
            .apply { clipData = ClipData.newRawUri("Pindo update", uri) }
    }

    private companion object { const val APK_TYPE = "application/vnd.android.package-archive" }
}
