package com.pindo.app

import android.content.Context
import android.content.ContextWrapper
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.pm.PackageInfoCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.util.Locale

@Composable internal fun AppUpdateScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val activity = remember(context) { context.updateActivity() }
    val model = remember(activity) {
        ViewModelProvider(activity, ViewModelProvider.AndroidViewModelFactory(activity.application))[AppUpdateViewModel::class.java]
    }
    val state by model.state.collectAsStateWithLifecycle()
    val installer = remember(context) { AppUpdateInstaller(context) }
    val currentVersion = remember(context) {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        "${info.versionName ?: "未知版本"} (${PackageInfoCompat.getLongVersionCode(info)})"
    }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var resumed by remember(lifecycle) { mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
    var permissionMessage by rememberSaveable { mutableStateOf<String?>(null) }
    var continueAfterPermission by rememberSaveable { mutableStateOf(false) }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, _ ->
            resumed = lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    val installLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        model.installationReturned()
    }
    fun openInstaller() {
        try { installLauncher.launch(model.installerIntent()) }
        catch (_: Exception) { model.installationLaunchFailed() }
    }
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        try {
            continueAfterPermission = installer.canInstall()
            permissionMessage = if (continueAfterPermission) null else "需要允许 Pindo 安装此来源的应用，才能继续安装更新。"
        } catch (_: Exception) {
            permissionMessage = "无法读取安装权限，请稍后重试。"
            model.installationLaunchFailed()
        }
    }
    // A completed background download never opens an installer over another page.
    // Consume the request before leaving for system UI so rotation cannot repeat it.
    LaunchedEffect(resumed, state.stage, state.autoInstall, continueAfterPermission) {
        if (!resumed || state.stage != AppUpdateStage.READY) return@LaunchedEffect
        if (continueAfterPermission) {
            continueAfterPermission = false
            openInstaller()
        } else if (state.autoInstall && model.consumeInstallRequest()) {
            permissionMessage = null
            try {
                if (installer.canInstall()) openInstaller()
                else permissionLauncher.launch(installer.permissionIntent())
            } catch (_: Exception) { model.installationLaunchFailed() }
        }
    }
    AppUpdateContent(currentVersion, state, permissionMessage,
        onBack = { continueAfterPermission = false; onBack() },
        onStart = { permissionMessage = null; model.startUpdate() },
        onCancel = { permissionMessage = null; model.cancelDownload() },
        onInstall = { permissionMessage = null; model.requestInstall() })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun AppUpdateContent(currentVersion: String, state: AppUpdateState,
    permissionMessage: String? = null, onBack: () -> Unit, onStart: () -> Unit,
    onCancel: () -> Unit, onInstall: () -> Unit) {
    BackHandler(onBack = onBack)
    val busy = state.stage in setOf(AppUpdateStage.CHECKING, AppUpdateStage.VERIFYING, AppUpdateStage.INSTALLING)
    val heading = when (state.stage) {
        AppUpdateStage.IDLE -> "一键更新"
        AppUpdateStage.CHECKING -> "正在检查更新"
        AppUpdateStage.DOWNLOADING -> "正在下载更新"
        AppUpdateStage.VERIFYING -> "正在校验安装包"
        AppUpdateStage.READY -> "更新已下载"
        AppUpdateStage.INSTALLING -> "请在系统界面确认安装"
        AppUpdateStage.UP_TO_DATE -> "已是最新版本"
        AppUpdateStage.UNSUPPORTED -> "此版本不支持应用内更新"
        AppUpdateStage.ERROR -> "更新未完成"
    }
    val description = state.message ?: when (state.stage) {
        AppUpdateStage.IDLE -> "点击后自动检查、下载新版，再由系统确认安装。事项和设置会保留。"
        AppUpdateStage.CHECKING -> "正在获取可覆盖安装的最新版本。"
        AppUpdateStage.DOWNLOADING -> "下载完成后将打开系统安装界面。"
        AppUpdateStage.VERIFYING -> "确认安装包完整，并能覆盖当前版本。"
        AppUpdateStage.READY -> "可以开始安装，事项和设置会保留。"
        AppUpdateStage.INSTALLING -> "安装需要在 Android 系统界面中完成确认。"
        AppUpdateStage.UP_TO_DATE -> "当前版本无需更新。"
        AppUpdateStage.UNSUPPORTED -> "请使用正式版 Pindo。开发版不会覆盖正式应用。"
        AppUpdateStage.ERROR -> "请检查网络或可用空间后重试。"
    }
    val accent = if (state.stage == AppUpdateStage.ERROR) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary
    Scaffold(modifier = Modifier.testTag("app-update-screen"), containerColor = MaterialTheme.colorScheme.background,
        topBar = { SettingsTopBar("应用更新", "返回设置", onBack) },
        bottomBar = {
            if (state.stage != AppUpdateStage.UNSUPPORTED) {
                Surface(color = MaterialTheme.colorScheme.background) {
                    Box(Modifier.fillMaxWidth().navigationBarsPadding(), contentAlignment = Alignment.Center) {
                        Column(Modifier.widthIn(max = 560.dp).fillMaxWidth().padding(horizontal = 24.dp, vertical = 16.dp)) {
                            if (state.stage == AppUpdateStage.DOWNLOADING) OutlinedButton(onClick = onCancel,
                                modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).testTag("update-cancel")) { Text("取消下载") }
                            else Button(onClick = if (state.stage == AppUpdateStage.READY) onInstall else onStart,
                                enabled = !busy, modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).testTag("update-primary")) {
                                if (busy) {
                                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                                    Spacer(Modifier.width(10.dp))
                                }
                                Text(when (state.stage) {
                                    AppUpdateStage.READY -> "安装更新"
                                    AppUpdateStage.UP_TO_DATE -> "重新检查"
                                    AppUpdateStage.ERROR -> "重试更新"
                                    AppUpdateStage.CHECKING -> "检查中"
                                    AppUpdateStage.VERIFYING -> "校验中"
                                    AppUpdateStage.INSTALLING -> "等待安装结果"
                                    else -> "检查并更新"
                                })
                            }
                        }
                    }
                }
            }
        }) { padding ->
        Box(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = 560.dp).fillMaxSize().verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp).padding(top = 24.dp, bottom = 32.dp),
                verticalArrangement = Arrangement.spacedBy(24.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text("当前版本", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(currentVersion, style = MaterialTheme.typography.bodyLarge)
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    Surface(shape = CircleShape, color = accent.copy(alpha = .10f)) {
                        Icon(when (state.stage) {
                            AppUpdateStage.DOWNLOADING -> Icons.Outlined.CloudDownload
                            AppUpdateStage.VERIFYING -> Icons.Outlined.VerifiedUser
                            AppUpdateStage.READY, AppUpdateStage.UP_TO_DATE -> Icons.Outlined.CheckCircle
                            AppUpdateStage.ERROR -> Icons.Outlined.ErrorOutline
                            AppUpdateStage.UNSUPPORTED -> Icons.Outlined.Info
                            else -> Icons.Outlined.SystemUpdate
                        }, null, Modifier.padding(12.dp).size(26.dp), tint = accent)
                    }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(heading, Modifier.testTag("update-state"), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                        state.versionName?.let { Text("更新版本 $it", style = MaterialTheme.typography.bodyMedium, color = accent) }
                        Text(description, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                if (state.stage == AppUpdateStage.DOWNLOADING) {
                    val progress = if (state.totalBytes > 0) (state.downloadedBytes.toDouble() / state.totalBytes).coerceIn(0.0, 1.0).toFloat() else null
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        val progressModifier = Modifier.fillMaxWidth().testTag("update-progress")
                        if (progress != null) LinearProgressIndicator(progress = { progress }, modifier = progressModifier.semantics {
                            stateDescription = "已下载 ${(progress * 100).toInt()}%"
                        }) else LinearProgressIndicator(progressModifier)
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                            Text(if (state.totalBytes > 0) "${updateBytes(state.downloadedBytes)} / ${updateBytes(state.totalBytes)}" else updateBytes(state.downloadedBytes),
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            progress?.let { Text("${(it * 100).toInt()}%", style = MaterialTheme.typography.labelLarge, color = accent) }
                        }
                        Text("离开此页后，下载仍会继续。", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                permissionMessage?.let {
                    Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.secondaryContainer) {
                        Text(it, Modifier.fillMaxWidth().padding(16.dp), style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSecondaryContainer)
                    }
                }
            }
        }
    }
}

private fun updateBytes(bytes: Long): String {
    val safe = bytes.coerceAtLeast(0)
    return if (safe >= 1024 * 1024) String.format(Locale.ROOT, "%.1f MB", safe / (1024.0 * 1024))
    else if (safe >= 1024) String.format(Locale.ROOT, "%.0f KB", safe / 1024.0) else "$safe B"
}

private fun Context.updateActivity(): ComponentActivity {
    var current = this
    while (current is ContextWrapper) {
        if (current is ComponentActivity) return current
        val base = current.baseContext
        if (base === current) break
        current = base
    }
    return current as? ComponentActivity ?: error("应用更新需要在应用界面打开。")
}
