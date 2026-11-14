package com.pindo.app.sync

import org.json.JSONObject
import java.nio.charset.StandardCharsets.UTF_8
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Interoperable authenticated client-side encryption. No cloud API credential is used as a key. */
class SyncCrypto(recoveryKey: String) {
    private val key: ByteArray
    val vaultID: String

    init {
        val text = recoveryKey.replace(Regex("\\s"), "").lowercase()
        require(text.matches(Regex("[0-9a-f]{64}"))) { "恢复密钥必须是 64 位十六进制字符。" }
        key = ByteArray(32) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        vaultID = hex(MessageDigest.getInstance("SHA-256").digest(key)).take(32)
    }

    fun seal(plaintext: ByteArray): ByteArray = sealWithNonce(plaintext, ByteArray(12).also(random::nextBytes))

    internal fun sealWithNonce(plaintext: ByteArray, nonce: ByteArray): ByteArray {
        return sealWithNonce(plaintext, nonce, 1)
    }

    fun sealV2(plaintext: ByteArray): ByteArray = sealV2WithNonce(plaintext, ByteArray(12).also(random::nextBytes))

    internal fun sealV2WithNonce(plaintext: ByteArray, nonce: ByteArray): ByteArray = sealWithNonce(plaintext, nonce, 2)

    private fun sealWithNonce(plaintext: ByteArray, nonce: ByteArray, version: Int): ByteArray {
        require(plaintext.size <= MAX_BYTES && nonce.size == 12) { "同步资料过大或 nonce 无效。" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad(version))
        val sealed = cipher.doFinal(plaintext)
        val ciphertext = base64(sealed.copyOfRange(0, sealed.size - 16))
        val tag = base64(sealed.copyOfRange(sealed.size - 16, sealed.size))
        // V2 canonical bytes also make the shared object's SHA-256 testable across platforms.
        val envelope = if (version == 2) {
            """{"ciphertext":"$ciphertext","nonce":"${base64(nonce)}","tag":"$tag","version":2}""".toByteArray(UTF_8)
        } else {
            JSONObject().put("version", version).put("nonce", base64(nonce))
                .put("ciphertext", ciphertext).put("tag", tag).toString().toByteArray(UTF_8)
        }
        require(envelope.size <= MAX_ENVELOPE_BYTES) { "同步密文过大。" }
        return envelope
    }

    fun open(envelope: ByteArray): ByteArray = open(envelope, 1)

    fun openV2(envelope: ByteArray): ByteArray = open(envelope, 2)

    private fun open(envelope: ByteArray, version: Int): ByteArray {
        require(envelope.size <= MAX_ENVELOPE_BYTES) { "同步密文过大。" }
        try {
            val json = JSONObject(String(envelope, UTF_8))
            require(json.get("version") is Number && json.getDouble("version") == version.toDouble()) {
                "此同步格式需要更新版本的 Pindo。"
            }
            require(listOf("nonce", "ciphertext", "tag").all { json.get(it) is String })
            val nonce = Base64.getDecoder().decode(json.getString("nonce"))
            val ciphertext = Base64.getDecoder().decode(json.getString("ciphertext"))
            val tag = Base64.getDecoder().decode(json.getString("tag"))
            require(nonce.size == 12 && tag.size == 16 && ciphertext.size <= MAX_BYTES)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD(aad(version))
            return cipher.doFinal(ciphertext + tag)
        } catch (error: Exception) {
            // Do not expose plaintext, account keys, or the remote response in errors.
            throw IllegalArgumentException("无法解密同步资料，请检查恢复密钥或云端文件是否损坏。")
        }
    }

    private fun aad(version: Int) = "PindoSync/v$version/$vaultID".toByteArray(UTF_8)

    companion object {
        const val MAX_BYTES = 7 * 1024 * 1024
        const val MAX_ENVELOPE_BYTES = 10 * 1024 * 1024
        private val random = SecureRandom()
        fun generateKey(): String = hex(ByteArray(32).also(random::nextBytes))
        fun objectKey(vaultID: String, encryptedData: ByteArray): String =
            "pindo/v2/$vaultID/objects/${hex(MessageDigest.getInstance("SHA-256").digest(encryptedData))}.json"
        fun migrationMarkerKey(vaultID: String): String =
            "pindo/v1/$vaultID/heads/ffffffff-ffff-ffff-ffff-ffffffffffff.json"
        fun validateObject(data: ByteArray, key: String, vaultID: String) {
            require(data.size <= MAX_ENVELOPE_BYTES) { "同步密文过大。" }
            require(vaultID.matches(Regex("[0-9a-f]{32}")) && key == objectKey(vaultID, data)) {
                "同步对象路径与密文摘要不符，未应用云端资料。"
            }
        }
        internal fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
        private fun base64(bytes: ByteArray) = Base64.getEncoder().encodeToString(bytes)
    }
}
