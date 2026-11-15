package com.pindo.app.sync

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Current authenticated encryption. Cloud credentials never serve as encryption keys. */
class SyncCrypto(recoveryKey: String) {
    private val key: ByteArray

    init {
        val text = recoveryKey.replace(Regex("\\s"), "").lowercase()
        require(text.matches(Regex("[0-9a-f]{64}"))) { "恢复密钥必须是 64 位十六进制字符。" }
        key = ByteArray(32) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }

    fun sealV3(plaintext: ByteArray, context: SyncV3EnvelopeContext): ByteArray =
        sealV3WithNonce(plaintext, context, ByteArray(12).also(random::nextBytes))

    internal fun sealV3WithNonce(plaintext: ByteArray, context: SyncV3EnvelopeContext, nonce: ByteArray): ByteArray {
        val limit = if (context.kind == "chunk") SyncV3.MAX_CHUNK_BYTES else SyncV3.MAX_BATCH_BYTES
        require(plaintext.isNotEmpty() && plaintext.size <= limit - 28 && nonce.size == 12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(context.associatedData())
        return nonce + cipher.doFinal(plaintext)
    }

    fun openV3(combined: ByteArray, context: SyncV3EnvelopeContext): ByteArray {
        val limit = if (context.kind == "chunk") SyncV3.MAX_CHUNK_BYTES else SyncV3.MAX_BATCH_BYTES
        require(combined.size in 29..limit)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, combined.copyOfRange(0, 12)))
        cipher.updateAAD(context.associatedData())
        return cipher.doFinal(combined.copyOfRange(12, combined.size))
    }

    companion object {
        private val random = SecureRandom()
        fun generateKey(): String = hex(ByteArray(32).also(random::nextBytes))
        internal fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
    }
}
