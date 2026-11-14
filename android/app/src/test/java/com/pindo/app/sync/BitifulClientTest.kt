package com.pindo.app.sync

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.time.Instant
import java.util.concurrent.CancellationException

class BitifulClientTest {
    private val vault = "630dcd2966c4336691125448bbb25b4f"
    private val device = "00000000-0000-0000-0000-000000000001"
    private val key = BitifulClient.headKey(vault, device)

    @Test fun signatureMatchesIndependentPythonAndSwiftVector() {
        val headers = SigV4.headers("GET", URI("https://examplebucket.s3.amazonaws.com/examplebucket/test.txt"), byteArrayOf(), "us-east-1",
            BitifulCredentials("AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"), Instant.parse("2013-05-24T00:00:00Z"))
        assertTrue(headers.getValue("Authorization").endsWith("Signature=e262308ffddff051393fc1e4f15361c623b2f8157cc41c3a1441cdba342e744d"))
        assertEquals("a=~&continuation-token=%2B%2F%3D%C3%A9&prefix=a%2Fb%20c",
            SigV4.query(listOf("prefix" to "a/b c", "continuation-token" to "+/=é", "a" to "~")))
    }

    @Test fun paginatedListRetainsETagsAndSignsEveryRequest() {
        val requests = mutableListOf<FakeConnection>()
        val responses = ArrayDeque(listOf(
            "<ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>next+token</NextContinuationToken><Contents><Key>$key</Key><ETag>&quot;v1&quot;</ETag></Contents></ListBucketResult>",
            "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>"
        ))
        val client = BitifulClient(BitifulConfiguration(bucket = "test-bucket"), BitifulCredentials("example-key", "example-secret"), { url ->
            FakeConnection(url, 200, responses.removeFirst().toByteArray()).also { requests.add(it) }
        })
        assertEquals(listOf(SyncRemoteHead(key, "\"v1\"")), client.listHeads(vault))
        assertEquals(2, requests.size)
        assertTrue(requests[1].url.query.contains("continuation-token=next%2Btoken"))
        assertNotNull(requests[0].getRequestProperty("Authorization"))
        assertFalse(requests[0].instanceFollowRedirects)
    }

    @Test fun redirectsAndHttpErrorsFailWithoutLeakingCredentials() {
        for (status in listOf(301, 403, 404, 429, 503)) {
            val client = BitifulClient(BitifulConfiguration(bucket = "test-bucket"), BitifulCredentials("secret-access", "secret-secret"), { url ->
                FakeConnection(url, status, "sensitive response".toByteArray())
            })
            val error = assertThrows(IllegalStateException::class.java) { client.download(key) }
            assertFalse(error.message.orEmpty().contains("secret"))
            assertFalse(error.message.orEmpty().contains("sensitive"))
        }
    }

    @Test fun malformedAndExternalXmlListsAreRejected() {
        val examples = listOf(
            "<!DOCTYPE x [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>",
            "<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>",
            "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>elsewhere</Key><ETag>etag</ETag></Contents></ListBucketResult>"
        )
        for (xml in examples) {
            val client = BitifulClient(BitifulConfiguration(bucket = "test-bucket"), BitifulCredentials("example-key", "example-secret"), { url -> FakeConnection(url, 200, xml.toByteArray()) })
            assertThrows(IllegalArgumentException::class.java) { client.listHeads(vault) }
        }
        val utf16 = examples.first().toByteArray(Charsets.UTF_16)
        val client = BitifulClient(BitifulConfiguration(bucket = "test-bucket"), BitifulCredentials("example-key", "example-secret"), { url -> FakeConnection(url, 200, utf16) })
        assertThrows(IllegalArgumentException::class.java) { client.listHeads(vault) }
    }

    @Test fun endpointsAndRegionCannotRedirectOrInjectCredentials() {
        for (endpoint in listOf("http://s3.bitiful.net", "https://bitiful.net.evil.example", "https://user:password@s3.bitiful.net", "https://s3.bitiful.net/path", "https://s3.bitiful.net:444")) {
            assertThrows(IllegalArgumentException::class.java) { BitifulConfiguration(endpoint, "test-bucket").validated() }
        }
        assertThrows(IllegalArgumentException::class.java) { BitifulConfiguration(bucket = "test-bucket", region = "cn-east-1\r\nInjected: yes").validated() }
    }

    @Test fun immutableObjectsPaginateAndVerifyExactUploadAndDownloadBytes() {
        val crypto = SyncCrypto("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        val encrypted = crypto.sealV2("immutable state".toByteArray())
        val objectKey = SyncCrypto.objectKey(vault, encrypted)
        val secondKey = SyncCrypto.objectKey(vault, "another object".toByteArray())
        val pages = ArrayDeque(listOf(listing(listOf(objectKey), true, "+/="), listing(listOf(secondKey))))
        val connections = mutableListOf<FakeConnection>()
        val client = makeClient { url -> FakeConnection(url, 200, pages.removeFirst().toByteArray()).also(connections::add) }
        assertEquals(listOf(objectKey, secondKey).sorted(), client.listObjects(vault).map { it.key })
        assertTrue(connections[1].url.query.contains("continuation-token=%2B%2F%3D"))
        val writes = mutableListOf<FakeConnection>()
        val writer = makeClient { url -> FakeConnection(url, 200, encrypted).also(writes::add) }
        writer.upload(encrypted, objectKey)
        assertArrayEquals(encrypted, writes.single().output.toByteArray())
        assertArrayEquals(encrypted, writer.download(objectKey))
        val count = writes.size
        assertThrows(IllegalArgumentException::class.java) { writer.upload("changed".toByteArray(), objectKey) }
        assertEquals(count, writes.size)
        val corrupted = makeClient { url -> FakeConnection(url, 200, "changed".toByteArray()) }
        assertThrows(IllegalArgumentException::class.java) { corrupted.download(objectKey) }
        for (bad in listOf(objectKey.uppercase(), "$objectKey/extra", "pindo/v2/$vault/objects/../data.json")) {
            assertThrows(IllegalArgumentException::class.java) { writer.download(bad) }
        }
    }

    @Test fun immutableListsRejectDuplicatesWrongNamespacesAndOverCapacity() {
        val objectKey = SyncCrypto.objectKey(vault, "one".toByteArray())
        val foreign = SyncCrypto.objectKey("a".repeat(32), "one".toByteArray())
        for (keys in listOf(listOf(objectKey, objectKey), listOf(foreign), listOf(key), listOf(objectKey.uppercase()))) {
            val client = makeClient { url -> FakeConnection(url, 200, listing(keys).toByteArray()) }
            assertThrows(IllegalArgumentException::class.java) { client.listObjects(vault) }
        }
        val keys = (0..10_000).map { "pindo/v2/$vault/objects/${"%064x".format(it)}.json" }
        val batches = keys.chunked(100)
        var page = 0
        val bounded = makeClient { url ->
            val index = page++
            FakeConnection(url, 200, listing(batches[index], index < batches.lastIndex,
                if (index < batches.lastIndex) "page-$index" else null).toByteArray())
        }
        val failure = assertThrows(IllegalArgumentException::class.java) { bounded.listObjects(vault) }
        assertTrue(failure.message.orEmpty().contains("10,000"))
    }

    @Test fun legacyUpgradeMarkerDoesNotConsumeOneOfTheHundredWriterSlots() {
        val heads = (1..100).map { BitifulClient.headKey(vault, "00000000-0000-0000-0000-${"%012x".format(it)}") }
        val pages = ArrayDeque(listOf(listing(heads, true, "marker-page"), listing(listOf(SyncCrypto.migrationMarkerKey(vault)))))
        val allowed = makeClient { url -> FakeConnection(url, 200, pages.removeFirst().toByteArray()) }
        assertEquals(101, allowed.listHeads(vault).size)
        val excess = makeClient { url -> FakeConnection(url, 200, listing(heads + BitifulClient.headKey(vault, "00000000-0000-0000-0000-000000000101")).toByteArray()) }
        assertThrows(IllegalArgumentException::class.java) { excess.listHeads(vault) }
    }

    @Test fun cancellationDisconnectsTheRunAndPreventsNewRequests() {
        lateinit var active: BitifulClient
        lateinit var connection: FakeConnection
        var requests = 0
        active = makeClient { url ->
            requests++
            FakeConnection(url, 200, byteArrayOf()).also { connection = it; it.onResponse = { active.cancel() } }
        }
        assertThrows(CancellationException::class.java) { active.download(key) }
        assertTrue(connection.disconnected)
        assertThrows(CancellationException::class.java) { active.listObjects(vault) }
        assertEquals(1, requests)
    }

    @Test fun conditionalLegacyReadsVerifyTheResponseVersionWhenIfMatchIsIgnored() {
        val bytes = "legacy ciphertext".toByteArray()
        lateinit var connection: FakeConnection
        val reader = makeClient { url -> FakeConnection(url, 200, bytes, mapOf("ETag" to "\"listed\"")).also { connection = it } }
        assertArrayEquals(bytes, reader.download(key, "\"listed\""))
        assertEquals("\"listed\"", connection.getRequestProperty("If-Match"))
        for ((status, headers) in listOf(412 to emptyMap(), 200 to mapOf("ETag" to "\"changed\""), 200 to emptyMap())) {
            val raced = makeClient { url -> FakeConnection(url, status, bytes, headers) }
            assertThrows(SyncRemoteChangedException::class.java) { raced.download(key, "\"listed\"") }
        }
        var requested = false
        val safe = makeClient { url -> requested = true; FakeConnection(url, 200, bytes) }
        assertThrows(IllegalArgumentException::class.java) { safe.download(key, "bad\r\nInjected: value") }
        assertFalse(requested)
    }

    @Test fun immutableListingRejectsAmbiguousFieldsRepeatedTokensAndLargePages() {
        val objectKey = SyncCrypto.objectKey(vault, "one".toByteArray())
        val another = SyncCrypto.objectKey(vault, "two".toByteArray())
        val examples = listOf(
            "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>$objectKey</Key><Key>$objectKey</Key><ETag>one</ETag></Contents></ListBucketResult>",
            "<ListBucketResult><IsTruncated>false</IsTruncated><Other><Contents><Key>$objectKey</Key><ETag>one</ETag></Contents></Other></ListBucketResult>",
            listing(listOf(objectKey), true, "x".repeat(8193))
        )
        for (body in examples) {
            val reader = makeClient { url -> FakeConnection(url, 200, body.toByteArray()) }
            assertThrows(IllegalArgumentException::class.java) { reader.listObjects(vault) }
        }
        val pages = ArrayDeque(listOf(listing(listOf(objectKey), true, "same"), listing(listOf(another), true, "same")))
        val repeated = makeClient { url -> FakeConnection(url, 200, pages.removeFirst().toByteArray()) }
        assertThrows(IllegalArgumentException::class.java) { repeated.listObjects(vault) }
        val large = makeClient { url -> FakeConnection(url, 200, ByteArray(1024 * 1024 + 1)) }
        assertThrows(IllegalArgumentException::class.java) { large.listObjects(vault) }
    }

    private fun makeClient(factory: (URL) -> HttpURLConnection) = BitifulClient(
        BitifulConfiguration(bucket = "test-bucket"), BitifulCredentials("example-key", "example-secret"), factory)

    private fun listing(keys: List<String>, truncated: Boolean = false, token: String? = null) =
        "<ListBucketResult><IsTruncated>$truncated</IsTruncated>" +
            keys.joinToString("") { "<Contents><Key>$it</Key><ETag>etag</ETag></Contents>" } +
            (token?.let { "<NextContinuationToken>$it</NextContinuationToken>" } ?: "") + "</ListBucketResult>"

    private class FakeConnection(url: URL, private val status: Int, private val data: ByteArray,
                                 private val responseHeaders: Map<String, String> = emptyMap()) : HttpURLConnection(url) {
        val output = ByteArrayOutputStream()
        var disconnected = false
        var onResponse: (() -> Unit)? = null
        override fun connect() {}
        override fun disconnect() { disconnected = true }
        override fun usingProxy() = false
        override fun getResponseCode(): Int { onResponse?.invoke(); return status }
        override fun getInputStream() = ByteArrayInputStream(data)
        override fun getOutputStream() = output
        override fun getContentLengthLong() = data.size.toLong()
        override fun getHeaderField(name: String?): String? = responseHeaders.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value
    }
}
