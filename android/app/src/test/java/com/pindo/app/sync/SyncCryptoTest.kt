package com.pindo.app.sync

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64

class SyncCryptoTest {
    private val key = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    private val plaintext = "{\"version\":1,\"seen\":{},\"records\":{}}".toByteArray()
    private val fixture = """{"version":1,"nonce":"AAECAwQFBgcICQoL","ciphertext":"PCCgfreWq3TjY626ncsLCOa4pQ6LBnNeSgKG6m8Nc5A7a9OB","tag":"1SCj+RLdikLz5cIh6qzeNw=="}"""

    @Test fun matchesIndependentPythonAndSwiftAESGCMVector() {
        val crypto = SyncCrypto(key)
        assertEquals("630dcd2966c4336691125448bbb25b4f", crypto.vaultID)
        assertArrayEquals(plaintext, crypto.open(fixture.toByteArray()))
        val actual = JSONObject(String(crypto.sealWithNonce(plaintext, Base64.getDecoder().decode("AAECAwQFBgcICQoL"))))
        assertEquals(JSONObject(fixture).toMap(), actual.toMap())
    }

    @Test fun rejectsWrongKeyDamagedTagAndUnsupportedEnvelope() {
        assertThrows(IllegalArgumentException::class.java) { SyncCrypto("00".repeat(32)).open(fixture.toByteArray()) }
        val corrupted = JSONObject(fixture).put("tag", Base64.getEncoder().encodeToString(ByteArray(16)))
        assertThrows(IllegalArgumentException::class.java) { SyncCrypto(key).open(corrupted.toString().toByteArray()) }
        assertThrows(IllegalArgumentException::class.java) { SyncCrypto(key).open(JSONObject(fixture).put("version", 2).toString().toByteArray()) }
    }

    @Test fun freshNoncesAndRecoveryKeysAreRandomAndMalformedKeysRejected() {
        val crypto = SyncCrypto(key)
        assertNotEquals(JSONObject(String(crypto.seal(plaintext))).getString("nonce"), JSONObject(String(crypto.seal(plaintext))).getString("nonce"))
        assertNotEquals(SyncCrypto.generateKey(), SyncCrypto.generateKey())
        assertThrows(IllegalArgumentException::class.java) { SyncCrypto("password") }
    }
}
