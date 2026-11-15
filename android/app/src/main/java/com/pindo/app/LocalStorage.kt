package com.pindo.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import com.pindo.app.sync.V3Store
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** SQLite is the only document authority. External JSON is an explicit import/export format. */
internal class DocumentStorage(context: Context) {
    val sqlite by lazy { V3Store(context) }
    fun read(): JSONObject {
        if (!sqlite.initialized()) sqlite.initialize(emptyDocument())
        return sqlite.read()
    }
    fun write(document: JSONObject) = sqlite.write(document)
}

internal interface V3JournalStorage {
    fun readJournal(): JSONObject?
    fun writeJournal(journal: JSONObject)
}

/** The current connection journal is encrypted by a device-bound Keystore key. */
internal class V3SecretStorage(context: Context) : V3JournalStorage {
    private val file = AtomicFile(File(context.noBackupFilesDir, "sync-v3-secrets.json"))
    private val alias = "com.pindo.app.sync.credentials.v3"
    private val aad = "Pindo/AndroidSecrets/v3".toByteArray()

    override fun readJournal(): JSONObject? {
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return null
        val envelope = file.openRead().use { JSONObject(it.readBytes().toString(Charsets.UTF_8)) }
        require(envelope.getInt("version") == 1) { "不支持的凭据格式。" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(create = false), GCMParameterSpec(128, Base64.decode(envelope.getString("nonce"), Base64.NO_WRAP)))
        cipher.updateAAD(aad)
        return JSONObject(cipher.doFinal(Base64.decode(envelope.getString("ciphertext"), Base64.NO_WRAP)).toString(Charsets.UTF_8))
    }

    override fun writeJournal(journal: JSONObject) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(create = true))
        cipher.updateAAD(aad)
        val data = cipher.doFinal(journal.toString().toByteArray())
        val envelope = JSONObject().put("version", 1).put("nonce", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .put("ciphertext", Base64.encodeToString(data, Base64.NO_WRAP))
        val stream = file.startWrite()
        try { stream.write(envelope.toString().toByteArray()); file.finishWrite(stream) }
        catch (error: Exception) { file.failWrite(stream); throw error }
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

internal fun emptyDocument(): JSONObject = JSONObject().put("version", 1).put("tasks", JSONArray()).put("groups", JSONArray())
