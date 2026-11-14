package com.pindo.app.sync

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64

class SyncCryptoTest {
    private val key = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    private val plaintext = "{\"version\":1,\"seen\":{},\"records\":{}}".toByteArray()
    private val fixture = """{"version":1,"nonce":"AAECAwQFBgcICQoL","ciphertext":"PCCgfreWq3TjY626ncsLCOa4pQ6LBnNeSgKG6m8Nc5A7a9OB","tag":"1SCj+RLdikLz5cIh6qzeNw=="}"""
    private val plaintextV2 = """{"version":2,"seen":{},"records":{}}""".toByteArray()
    private val fixtureV2 = """{"ciphertext":"PCCgfreWq3TjY625ncsLCOa4pQ6LBnNeSgKG6m8Nc5A7a9OB","nonce":"AAECAwQFBgcICQoL","tag":"KIX2rgCTc/epvQCHI8SKwA==","version":2}""".toByteArray()

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

    @Test fun v2MatchesIndependentPythonAndSwiftBytesAndObjectDigest() {
        val crypto = SyncCrypto(key)
        assertArrayEquals(fixtureV2, crypto.sealV2WithNonce(plaintextV2, ByteArray(12) { it.toByte() }))
        assertArrayEquals(plaintextV2, crypto.openV2(fixtureV2))
        val objectKey = SyncCrypto.objectKey(crypto.vaultID, fixtureV2)
        assertEquals("pindo/v2/630dcd2966c4336691125448bbb25b4f/objects/58139da27e697ce48e61dba26242fc655c3b20e1063af9175517d2be93c5d8d2.json", objectKey)
        SyncCrypto.validateObject(fixtureV2, objectKey, crypto.vaultID)
        assertEquals("pindo/v1/${crypto.vaultID}/heads/ffffffff-ffff-ffff-ffff-ffffffffffff.json", SyncCrypto.migrationMarkerKey(crypto.vaultID))
        assertThrows(IllegalArgumentException::class.java) { crypto.open(fixtureV2) }
        assertThrows(IllegalArgumentException::class.java) { crypto.openV2(fixture.toByteArray()) }
        assertThrows(IllegalArgumentException::class.java) { crypto.open(JSONObject(String(fixtureV2)).put("version", 1).toString().toByteArray()) }
        assertThrows(IllegalArgumentException::class.java) { SyncCrypto.validateObject(fixtureV2 + byteArrayOf(32), objectKey, crypto.vaultID) }
        assertThrows(IllegalArgumentException::class.java) { SyncCrypto.validateObject(fixtureV2, objectKey, "a".repeat(32)) }
        assertThrows(IllegalArgumentException::class.java) { crypto.sealV2(ByteArray(SyncCrypto.MAX_BYTES + 1)) }
    }
}
