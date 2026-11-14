package com.pindo.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class DocumentStorage(private val context: Context) {
    val sqlite by lazy { com.pindo.app.sync.V3Store(context) }
    private val file = AtomicFile(File(context.filesDir, "data.json"))
    fun read(): JSONObject? {
        if (sqlite.initialized()) return sqlite.read()
        val legacy = if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) null
            else file.openRead().use { JSONObject(it.readBytes().toString(Charsets.UTF_8)) }
        val document = legacy ?: emptyDocument()
        validateDocument(document)
        sqlite.initialize(document)
        if (legacy != null && !File(context.filesDir, "data.pre-sqlite.json").exists()) file.baseFile.renameTo(File(context.filesDir, "data.pre-sqlite.json"))
        return sqlite.read()
    }
    fun write(document: JSONObject) { if (!sqlite.initialized()) sqlite.initialize(document) else sqlite.write(document) }
}

// Retained solely to decode encrypted local recovery journals. Never used to connect.
data class CloudSettings(val enabled: Boolean = false, val endpoint: String = "",
    val bucket: String = "", val region: String = "cn-east-1", val accessKey: String = "",
    val secretKey: String = "", val recoveryKey: String = "", val createVault: Boolean = false) {
    fun json(): JSONObject = JSONObject().put("enabled", enabled).put("endpoint", endpoint).put("bucket", bucket)
        .put("region", region).put("accessKey", accessKey).put("secretKey", secretKey).put("recoveryKey", recoveryKey).put("createVault", createVault)
    companion object {
        fun from(value: JSONObject) = CloudSettings(value.getBoolean("enabled"), value.getString("endpoint"),
            value.getString("bucket"), value.getString("region"), value.getString("accessKey"),
            value.getString("secretKey"), value.getString("recoveryKey"), value.optBoolean("createVault", false))
    }
}

internal class SecretStorage(context: Context) {
    private val file = AtomicFile(File(context.noBackupFilesDir, "sync-secrets.json"))
    private val alias = "com.pindo.app.sync.credentials.v1"
    private val aad = "Pindo/AndroidSecrets/v1".toByteArray()
    fun readJournal(): SettingsJournal? {
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return null
        val envelope = file.openRead().use { JSONObject(it.readBytes().toString(Charsets.UTF_8)) }
        require(envelope.getInt("version") == 1) { "不支持的凭据格式。" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(create = false), GCMParameterSpec(128, Base64.decode(envelope.getString("nonce"), Base64.NO_WRAP)))
        cipher.updateAAD(aad)
        return SettingsJournal.from(JSONObject(cipher.doFinal(Base64.decode(envelope.getString("ciphertext"), Base64.NO_WRAP)).toString(Charsets.UTF_8)))
    }
    fun writeJournal(journal: SettingsJournal) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(create = true))
        cipher.updateAAD(aad)
        val data = cipher.doFinal(journal.json().toString().toByteArray())
        val envelope = JSONObject().put("version", 1).put("nonce", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .put("ciphertext", Base64.encodeToString(data, Base64.NO_WRAP))
        atomicWrite(file, envelope.toString().toByteArray())
    }
    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        check(create) { "无法访问此设备保存的同步密钥。" }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }
}

internal class V3SecretStorage(context: Context) {
    private val file = AtomicFile(File(context.noBackupFilesDir, "sync-v3-secrets.json"))
    private val alias = "com.pindo.app.sync.credentials.v3"
    private val aad = "Pindo/AndroidSecrets/v3".toByteArray()
    fun readJournal(): JSONObject? {
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return null
        val envelope = file.openRead().use { JSONObject(it.readBytes().toString(Charsets.UTF_8)) }
        require(envelope.getInt("version") == 1) { "不支持的凭据格式。" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(create = false), GCMParameterSpec(128, Base64.decode(envelope.getString("nonce"), Base64.NO_WRAP)))
        cipher.updateAAD(aad)
        return JSONObject(cipher.doFinal(Base64.decode(envelope.getString("ciphertext"), Base64.NO_WRAP)).toString(Charsets.UTF_8))
    }
    fun writeJournal(journal: JSONObject) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(create = true))
        cipher.updateAAD(aad)
        val data = cipher.doFinal(journal.toString().toByteArray())
        val envelope = JSONObject().put("version", 1).put("nonce", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .put("ciphertext", Base64.encodeToString(data, Base64.NO_WRAP))
        atomicWrite(file, envelope.toString().toByteArray())
    }
    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        check(create) { "无法访问此设备保存的同步密钥。" }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }
}

private fun atomicWrite(file: AtomicFile, bytes: ByteArray) {
    val stream = file.startWrite()
    try { stream.write(bytes); file.finishWrite(stream) }
    catch (error: Exception) { file.failWrite(stream); throw error }
}

internal fun emptyDocument(): JSONObject = JSONObject().put("version", 1).put("tasks", JSONArray()).put("groups", JSONArray())
