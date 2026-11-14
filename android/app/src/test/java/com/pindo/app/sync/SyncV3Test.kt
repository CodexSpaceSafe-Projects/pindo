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
    @Test fun delayedWritesAndObservedRemovalsConvergeInSharedOrders() {
        val vector=fixture(); val writes=vector.getJSONArray("noteWrites"); val orders=vector.getJSONArray("noteOrders")
        for (i in 0 until orders.length()) {
            val register=SyncV3NoteRegister(); val order=orders.getJSONArray(i)
            for (j in 0 until order.length()) {
                val w=writes.getJSONObject(order.getInt(j)); val observed=w.getJSONArray("observed")
                register.apply(dot(w),w.getString("value"),(0 until observed.length()).map { dot(observed.getJSONObject(it)) }.toSet())
            }
            val expected=vector.getJSONArray("visibleNotes")
            assertEquals((0 until expected.length()).map { expected.getString(it) }.toSet(),register.visible.values.toSet())
        }
    }
    @Test fun titleClockDoesNotSuppressAnUnseenNoteAndIdentityCannotChangeContext() {
        val a=SyncV3NoteDot("00000000-0000-4000-8000-000000000101",1)
        val b=SyncV3NoteDot("00000000-0000-4000-8000-000000000102",101)
        val register=SyncV3NoteRegister()
        register.apply(b,"Concurrent",emptySet());register.apply(a,"Delayed",emptySet())
        assertEquals(2,register.visible.size)
        assertThrows(IllegalArgumentException::class.java) { register.apply(b,"Concurrent",setOf(a)) }
        assertEquals(2,register.visible.size)
        val corrupt=SyncV3NoteRegister().apply { apply(a,"Different",emptySet()) }
        assertThrows(IllegalArgumentException::class.java) { register.merge(corrupt) }
        assertEquals("Delayed",register.visible[a])
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
    private fun dot(value: JSONObject)=SyncV3NoteDot(value.getString("actorID"),value.getLong("counter"))
}
