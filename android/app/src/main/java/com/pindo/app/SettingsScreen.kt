package com.pindo.app

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.PersistableBundle
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.core.graphics.toColorInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun CloudSettingsScreen(store: AppStore, state: AppState, onBack: () -> Unit) {
    val context = LocalContext.current
    var draft by remember { mutableStateOf(store.settingsDraft()) }
    // Keep unsaved secrets in the ViewModel across rotation, never in an unencrypted saved-state Bundle.
    SideEffect { store.stageSettingsDraft(draft) }
    var regenerate by remember { mutableStateOf(false) }
    var localError by remember { mutableStateOf<String?>(null) }
    BackHandler(onBack = onBack)
    Scaffold(topBar = { TopAppBar(title = { Text("同步设置") }, navigationIcon = { TextButton(onClick = onBack) { Text("返回") } }) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(15.dp)) {
            Text("缤纷云 · 使用自己的账号", style = MaterialTheme.typography.titleLarge)
            Text("待办和备注默认先在客户端进行端到端加密，再上传到私有存储桶。Access Key、Secret Key 和恢复密钥通过 Android Keystore 加密后保存在此设备。", style = MaterialTheme.typography.bodyMedium)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("启用云同步", Modifier.weight(1f)); Switch(draft.enabled, { draft = draft.copy(enabled = it) })
            }
            OutlinedTextField(draft.endpoint, { draft = draft.copy(endpoint = it) }, label = { Text("S3 Endpoint") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
            OutlinedTextField(draft.bucket, { draft = draft.copy(bucket = it) }, label = { Text("Bucket 名称") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
            OutlinedTextField(draft.region, { draft = draft.copy(region = it) }, label = { Text("Region") }, modifier = Modifier.fillMaxWidth(), singleLine = true)
            SecretField("Access Key", draft.accessKey) { draft = draft.copy(accessKey = it) }
            SecretField("Secret Key", draft.secretKey) { draft = draft.copy(secretKey = it) }
            HorizontalDivider()
            Text("恢复密钥", style = MaterialTheme.typography.titleMedium)
            Text("已有同步空间：在此粘贴另一台设备的同一份 64 位十六进制密钥。首次使用：生成新密钥并妥善保存；遗失后无法解密云端资料。", style = MaterialTheme.typography.bodySmall)
            SecretField("恢复密钥（64 位十六进制）", draft.recoveryKey) { draft = draft.copy(recoveryKey = it) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = {
                    if (draft.recoveryKey.isBlank()) draft = draft.copy(recoveryKey = store.generateRecoveryKey()) else regenerate = true
                }) { Text("生成新密钥") }
                OutlinedButton(enabled = draft.recoveryKey.isNotBlank(), onClick = {
                    val clip = ClipData.newPlainText("Pindo 恢复密钥", draft.recoveryKey)
                    if (Build.VERSION.SDK_INT >= 33) clip.description.extras = PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }
                    (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(clip)
                }) { Text("复制密钥") }
            }
            Text("前台约每 30 秒检查一次变化，修改后立即尝试上传；失败时自动退避。切到后台后不保证实时同步。修改标题或备注期间会暂缓拉取，避免打断编辑。", style = MaterialTheme.typography.bodySmall)
            Text("请给同步凭据仅授予该私有桶的列举、读取和写入权限。不同设备使用相同 Bucket、Region 和恢复密钥。", style = MaterialTheme.typography.bodySmall)
            (localError ?: state.error)?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            Button(onClick = { if (store.saveSettings(draft)) onBack() else localError = "配置未保存，请检查输入和错误提示。" }, enabled = !state.readOnly, modifier = Modifier.fillMaxWidth()) { Text("保存同步设置") }
            Text("本机资料：应用私有目录中的 data.json。当前版本不向 Android 系统备份凭据或待办。", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    if (regenerate) AlertDialog(onDismissRequest = { regenerate = false }, title = { Text("生成新的恢复密钥？") },
        text = { Text("新密钥对应独立的同步空间。其他设备需要改用新密钥；旧密钥仍是解密旧空间所必需的。请先保留旧密钥。") },
        confirmButton = { TextButton(onClick = { draft = draft.copy(recoveryKey = store.generateRecoveryKey()); regenerate = false }) { Text("生成新密钥") } },
        dismissButton = { TextButton(onClick = { regenerate = false }) { Text("取消") } })
}

@Composable private fun SecretField(label: String, value: String, changed: (String) -> Unit) {
    var visible by remember { mutableStateOf(false) }
    OutlinedTextField(value, changed, modifier = Modifier.fillMaxWidth(), label = { Text(label) }, singleLine = true,
        visualTransformation = if (visible) VisualTransformation.None else PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
        trailingIcon = { TextButton(onClick = { visible = !visible }) { Text(if (visible) "隐藏" else "显示") } })
}

@Composable internal fun GroupDialog(store: AppStore, state: AppState, onDismiss: () -> Unit) {
    var name by remember { mutableStateOf("") }
    var color by remember { mutableStateOf("#4477AA") }
    val colors = listOf("#4477AA", "#EE6677", "#228833", "#CCBB44", "#66CCEE", "#AA3377", "#BBBBBB")
    DisposableEffect(Unit) { store.setEditing(true); onDispose { store.setEditing(false) } }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("管理分组") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            state.groups.forEach { group ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(14.dp).background(Color(group.color.toColorInt()), CircleShape))
                    Text(group.name, Modifier.weight(1f).padding(horizontal = 10.dp))
                    TextButton(onClick = { store.deleteGroup(group.id) }) { Text("删除") }
                }
            }
            Text("删除分组保留待办和备注。", style = MaterialTheme.typography.bodySmall)
            OutlinedTextField(name, { name = it }, label = { Text("新分组名称") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Row(Modifier.horizontalScroll(rememberScrollState())) {
                colors.forEach { hex -> FilterChip(selected = color == hex, onClick = { color = hex }, label = { Box(Modifier.size(18.dp).background(Color(hex.toColorInt()), CircleShape)) }, modifier = Modifier.padding(end = 5.dp)) }
            }
            TextButton(onClick = { if (store.addGroup(name, color)) name = "" }, enabled = name.isNotBlank()) { Text("添加分组") }
            state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        }
    }, confirmButton = { TextButton(onClick = onDismiss) { Text("完成") } })
}
