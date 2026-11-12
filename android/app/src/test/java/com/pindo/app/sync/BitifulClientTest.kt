package com.pindo.app.sync

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.time.Instant

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

    private class FakeConnection(url: URL, private val status: Int, private val data: ByteArray) : HttpURLConnection(url) {
        private val output = ByteArrayOutputStream()
        override fun connect() {}
        override fun disconnect() {}
        override fun usingProxy() = false
        override fun getResponseCode() = status
        override fun getInputStream() = ByteArrayInputStream(data)
        override fun getOutputStream() = output
        override fun getContentLengthLong() = data.size.toLong()
    }
}
