package com.pindo.app.sync

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class SyncV3Test {
    private fun fixture(): JSONObject = JSONObject(generateSequence(File(System.getProperty("user.dir")).canonicalFile) { it.parentFile }
        .map { File(it, "sync-vectors/v3-contract.json") }.first { it.isFile }.readText())
    @Test fun sharedAADAndIntegerBoundary() {
        val vector=fixture(); val c=vector.getJSONObject("context")
        val context=SyncV3EnvelopeContext(SyncV3Identity(c.getString("serviceID"),c.getString("vaultID")),
            c.getString("epoch"),c.getString("kind"),c.getString("objectID"))
        assertEquals(vector.getString("aadHex"),context.associatedData().joinToString("") { "%02x".format(it) })
        SyncV3.validateCounter(SyncV3.MAX_COUNTER)
        assertThrows(IllegalArgumentException::class.java) { SyncV3.validateCounter(SyncV3.MAX_COUNTER+1) }
        assertThrows(IllegalArgumentException::class.java) { SyncV3.validateCounter(-1) }
        assertThrows(IllegalArgumentException::class.java) { context.copy(artifactIDs=listOf("a".repeat(64),"a".repeat(64))).associatedData() }
    }
    @Test fun sharedEncryptionAndCrossEpochRejection() {
        val vector=fixture(); val c=vector.getJSONObject("context")
        val context=SyncV3EnvelopeContext(SyncV3Identity(c.getString("serviceID"),c.getString("vaultID")),c.getString("epoch"),"batch",c.getString("objectID"))
        val crypto=SyncCrypto(vector.getString("keyHex"))
        val expected=java.util.Base64.getDecoder().decode(vector.getString("ciphertext"))
        assertArrayEquals(expected,crypto.sealV3WithNonce(vector.getString("plaintext").toByteArray(),context,ByteArray(12) { it.toByte() }))
        assertEquals(vector.getString("plaintext"),crypto.openV3(expected,context).toString(Charsets.UTF_8))
        assertThrows(javax.crypto.AEADBadTagException::class.java) {
            crypto.openV3(expected,context.copy(epoch="00000000-0000-4000-8000-000000000099"))
        }
    }
    @Test fun rejectsMalformedKeysAndUsesFreshRandomNonces() {
        val crypto = SyncCrypto("01".repeat(32))
        val context = SyncV3EnvelopeContext(
            SyncV3Identity("00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002"),
            "00000000-0000-4000-8000-000000000003", "batch", "00000000-0000-4000-8000-000000000004")
        val content = "Current encrypted note".toByteArray()
        val first = crypto.sealV3(content, context)
        val second = crypto.sealV3(content, context)
        assertFalse(first.contentEquals(second))
        assertArrayEquals(content, crypto.openV3(first, context))
        assertNotEquals(SyncCrypto.generateKey(), SyncCrypto.generateKey())
        assertThrows(IllegalArgumentException::class.java) { SyncCrypto("password") }
        assertThrows(IllegalArgumentException::class.java) { crypto.openV3(ByteArray(28), context) }
        first[first.lastIndex] = (first.last().toInt() xor 1).toByte()
        assertThrows(javax.crypto.AEADBadTagException::class.java) { crypto.openV3(first, context) }
    }
}
