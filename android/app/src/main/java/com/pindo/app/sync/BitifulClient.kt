package com.pindo.app.sync

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.StringReader
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.nio.charset.StandardCharsets.UTF_8
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.concurrent.CancellationException
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import javax.xml.parsers.DocumentBuilderFactory
import org.w3c.dom.Element
import org.xml.sax.InputSource

data class BitifulConfiguration(
    val endpoint: String = "https://s3.bitiful.net",
    val bucket: String,
    val region: String = "cn-east-1"
) {
    fun validated(): BitifulConfiguration {
        val uri = URI(endpoint)
        val host = uri.host?.lowercase() ?: ""
        require(uri.scheme == "https" && (host == "s3.bitiful.net" || host.endsWith(".bitiful.net")) &&
            uri.userInfo == null && uri.query == null && uri.fragment == null &&
            (uri.port == -1 || uri.port == 443) && (uri.path.isNullOrEmpty() || uri.path == "/")) {
            "请使用缤纷云控制台提供的 HTTPS S3 接入点。"
        }
        require(bucket.matches(Regex("[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]")) && !bucket.contains("..") && !bucket.contains(".-") && !bucket.contains("-.") &&
            !bucket.matches(Regex("[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+"))) { "存储桶名称无效。" }
        require(region.matches(Regex("[a-z0-9][a-z0-9-]{0,62}"))) { "服务区域无效。" }
        return this
    }
}

data class BitifulCredentials(val accessKey: String, val secretKey: String)
data class SyncRemoteHead(val key: String, val etag: String)
class SyncRemoteChangedException : IllegalStateException("读取期间云端同步对象发生变化，将重试且不应用部分资料。")

/** Synchronous network calls. The app must call these from a worker thread. */
class BitifulClient(
    private val configuration: BitifulConfiguration,
    private val credentials: BitifulCredentials,
    private val connectionFactory: (URL) -> HttpURLConnection = { it.openConnection() as HttpURLConnection },
    private val now: () -> Instant = Instant::now
) {
    private val connectionLock = Any()
    private val activeConnections = mutableSetOf<HttpURLConnection>()
    @Volatile private var cancelled = false
    init {
        configuration.validated()
        require(credentials.accessKey.length in 1..256 && credentials.secretKey.length in 1..1024 &&
            credentials.accessKey.all { it.code in 33..126 } && credentials.secretKey.all { it.code in 33..126 }) { "请填写有效的 Access Key 和 Secret Key。" }
    }

    /** Permanently cancels this run's client. Immutable uploads remain safe if already accepted remotely. */
    fun cancel() {
        val active = synchronized(connectionLock) {
            cancelled = true
            activeConnections.toList().also { activeConnections.clear() }
        }
        active.forEach { runCatching { it.disconnect() } }
    }

    fun listHeads(vaultID: String): List<SyncRemoteHead> = list(vaultID, immutable = false)

    fun listObjects(vaultID: String): List<SyncRemoteHead> = list(vaultID, immutable = true)

    private fun list(vaultID: String, immutable: Boolean): List<SyncRemoteHead> {
        require(vaultID.matches(Regex("[0-9a-f]{32}")))
        val prefix = if (immutable) "pindo/v2/$vaultID/objects/" else "pindo/v1/$vaultID/heads/"
        val maximumCount = if (immutable) 10_000 else 101 // 100 legacy writers plus the upgrade marker.
        var legacyWriters = 0
        val result = mutableListOf<SyncRemoteHead>()
        val keys = mutableSetOf<String>()
        val continuations = mutableSetOf<String>()
        var continuation: String? = null
        do {
            val query = mutableListOf("list-type" to "2", "prefix" to prefix, "max-keys" to "100")
            continuation?.let { query.add("continuation-token" to it) }
            val body = request("GET", null, query, null, 1024 * 1024)
            val document = parseList(body)
            val contents = document.getElementsByTagName("Contents")
            for (index in 0 until contents.length) {
                val entry = contents.item(index) as Element
                val key = entry.value("Key")
                require(entry.parentNode === document.documentElement && key.startsWith(prefix) &&
                    (if (immutable) isObjectKey(key) else isHeadKey(key)) && keys.add(key)) { "云端同步文件列表无效。" }
                val etag = entry.value("ETag")
                require(validETag(etag)) { "云端同步文件缺少版本标识。" }
                result.add(SyncRemoteHead(key, etag))
                if (!immutable && key != migrationMarkerKey(vaultID)) legacyWriters++
                require(legacyWriters <= 100) { "同步设备数量超过此版本支持的上限。" }
                require(result.size <= maximumCount) {
                    if (immutable) "同步资料库超过 10,000 个不可变对象，本机修改已保留。" else "同步设备数量超过此版本支持的上限。"
                }
            }
            val truncated = document.documentElement.value("IsTruncated").trim()
            require(truncated == "true" || truncated == "false") { "云端同步文件列表无效。" }
            continuation = if (truncated == "true") document.documentElement.value("NextContinuationToken") else null
            if (continuation != null) {
                require(contents.length > 0 && continuation.isNotEmpty() && continuation.toByteArray(UTF_8).size <= 8192 &&
                    continuations.add(continuation) && continuations.size < maximumCount) { "云端同步分页无效。" }
            }
        } while (continuation != null)
        return result.sortedBy { it.key }
    }

    fun download(key: String, expectedETag: String? = null): ByteArray {
        require(isHeadKey(key) || isObjectKey(key)) { "同步文件路径无效。" }
        require(expectedETag == null || validETag(expectedETag)) { "云端同步文件版本标识无效。" }
        return request("GET", key, emptyList(), null, SyncCrypto.MAX_ENVELOPE_BYTES, expectedETag).also {
            if (isObjectKey(key)) SyncCrypto.validateObject(it, key, key.split('/')[2])
        }
    }

    fun upload(data: ByteArray, key: String) {
        require((isHeadKey(key) || isObjectKey(key)) && data.size <= SyncCrypto.MAX_ENVELOPE_BYTES) { "同步文件路径无效或资料过大。" }
        if (isObjectKey(key)) SyncCrypto.validateObject(data, key, key.split('/')[2])
        request("PUT", key, emptyList(), data, 1024 * 1024)
    }

    private fun request(method: String, key: String?, query: List<Pair<String, String>>, body: ByteArray?, limit: Int,
                        expectedETag: String? = null): ByteArray {
        checkCancellation()
        val endpoint = URI(configuration.endpoint)
        val path = "/" + SigV4.encode(configuration.bucket) + (key?.let { "/" + it.split('/').joinToString("/") { part -> SigV4.encode(part) } } ?: "")
        val canonicalQuery = SigV4.query(query)
        val target = URI("https://${endpoint.host.lowercase()}$path" + if (canonicalQuery.isEmpty()) "" else "?$canonicalQuery")
        val headers = SigV4.headers(method, target, body ?: byteArrayOf(), configuration.region, credentials, now())
        val connection = connectionFactory(target.toURL())
        synchronized(connectionLock) {
            if (cancelled) { connection.disconnect(); throw CancellationException("Sync request cancelled.") }
            activeConnections.add(connection)
        }
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 30_000
            connection.readTimeout = 30_000
            connection.requestMethod = method
            headers.forEach { (name, value) -> connection.setRequestProperty(name, value) }
            if (expectedETag != null) connection.setRequestProperty("If-Match", expectedETag)
            if (body != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/octet-stream")
                connection.setFixedLengthStreamingMode(body.size)
                connection.outputStream.use { it.write(body) }
            }
            val status = connection.responseCode
            if (status == 412 && expectedETag != null) throw SyncRemoteChangedException()
            if (status !in 200..299) throw IllegalStateException(when (status) {
                401, 403 -> "缤纷云授权失败，请检查密钥及存储桶权限。"
                404 -> "缤纷云存储桶或同步文件不存在。"
                429 -> "缤纷云请求过于频繁，请稍后重试。"
                in 300..399 -> "同步接入点发生重定向，已停止发送凭据。"
                else -> "缤纷云同步请求失败（HTTP $status）。"
            })
            if (expectedETag != null && connection.getHeaderField("ETag") != expectedETag) throw SyncRemoteChangedException()
            require(connection.contentLengthLong <= limit) { "云端同步资料过大。" }
            return connection.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(16 * 1024)
                while (true) {
                    checkCancellation()
                    val read = input.read(buffer)
                    if (read == -1) break
                    require(output.size() + read <= limit) { "云端同步资料过大。" }
                    output.write(buffer, 0, read)
                }
                checkCancellation()
                output.toByteArray()
            }
        } catch (error: Exception) {
            checkCancellation()
            throw error
        } finally {
            synchronized(connectionLock) { activeConnections.remove(connection) }
            connection.disconnect()
        }
    }

    private fun checkCancellation() {
        if (cancelled || Thread.currentThread().isInterrupted) throw CancellationException("Sync request cancelled.")
    }

    private fun parseList(bytes: ByteArray): org.w3c.dom.Document {
        try {
            val text = UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString()
            require(!text.contains("<!DOCTYPE", ignoreCase = true))
            val factory = DocumentBuilderFactory.newInstance()
            factory.isExpandEntityReferences = false
            factory.isNamespaceAware = false
            val builder = factory.newDocumentBuilder()
            builder.setEntityResolver { _, _ -> InputSource(ByteArrayInputStream(byteArrayOf())) }
            // Inspect and parse exactly the same decoded text; no XML encoding auto-detection.
            return builder.parse(InputSource(StringReader(text))).also { require(it.documentElement.tagName == "ListBucketResult") }
        } catch (error: Exception) { throw IllegalArgumentException("同步文件列表格式无效。") }
    }

    private fun Element.value(name: String): String {
        val nodes = (0 until childNodes.length).map { childNodes.item(it) }.filter { it.nodeName == name }
        require(nodes.size == 1) { "云端同步文件列表无效。" }
        return nodes.single().textContent
    }

    companion object {
        private fun validETag(value: String): Boolean = value.isNotBlank() && value.toByteArray(UTF_8).size <= 1024 &&
            value.all { it.code >= 32 && it.code != 127 }
        fun headKey(vaultID: String, deviceID: String): String = "pindo/v1/$vaultID/heads/${deviceID.lowercase()}.json".also {
            require(isHeadKey(it)) { "同步文件路径无效。" }
        }
        fun objectKey(vaultID: String, encryptedData: ByteArray): String = SyncCrypto.objectKey(vaultID, encryptedData)
        fun migrationMarkerKey(vaultID: String): String = SyncCrypto.migrationMarkerKey(vaultID)
        private fun isHeadKey(key: String): Boolean = key.matches(Regex("pindo/v1/[0-9a-f]{32}/heads/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.json"))
        private fun isObjectKey(key: String): Boolean = key.matches(Regex("pindo/v2/[0-9a-f]{32}/objects/[0-9a-f]{64}\\.json"))
    }
}

/** AWS Signature Version 4 using S3's path-preserving canonical URI. */
object SigV4 {
    fun encode(text: String): String = buildString {
        for (byte in text.toByteArray(UTF_8)) {
            val c = byte.toInt() and 255
            if (c in 65..90 || c in 97..122 || c in 48..57 || c == 45 || c == 46 || c == 95 || c == 126) append(c.toChar())
            else append("%%%02X".format(c))
        }
    }
    fun query(pairs: List<Pair<String, String>>): String = pairs.map { encode(it.first) to encode(it.second) }
        .sortedWith(compareBy<Pair<String, String>> { it.first }.thenBy { it.second })
        .joinToString("&") { "${it.first}=${it.second}" }

    fun headers(method: String, url: URI, body: ByteArray, region: String, credentials: BitifulCredentials, instant: Instant): Map<String, String> {
        val date = DateTimeFormatter.ofPattern("yyyyMMdd").withZone(ZoneOffset.UTC).format(instant)
        val timestamp = DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'").withZone(ZoneOffset.UTC).format(instant)
        val hash = hash(body)
        val host = url.host.lowercase()
        val signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        val canonical = listOf(method, url.rawPath.ifEmpty { "/" }, url.rawQuery ?: "",
            "host:$host\nx-amz-content-sha256:$hash\nx-amz-date:$timestamp\n", signedHeaders, hash).joinToString("\n")
        val scope = "$date/$region/s3/aws4_request"
        val toSign = "AWS4-HMAC-SHA256\n$timestamp\n$scope\n${hash(canonical.toByteArray(UTF_8))}"
        val kDate = hmac(("AWS4" + credentials.secretKey).toByteArray(UTF_8), date)
        val kRegion = hmac(kDate, region)
        val kService = hmac(kRegion, "s3")
        val signingKey = hmac(kService, "aws4_request")
        val signature = SyncCrypto.hex(hmac(signingKey, toSign))
        return linkedMapOf("Host" to host, "x-amz-content-sha256" to hash, "x-amz-date" to timestamp,
            "Authorization" to "AWS4-HMAC-SHA256 Credential=${credentials.accessKey}/$scope, SignedHeaders=$signedHeaders, Signature=$signature")
    }
    private fun hash(value: ByteArray): String = SyncCrypto.hex(MessageDigest.getInstance("SHA-256").digest(value))
    private fun hmac(key: ByteArray, value: String): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(key, "HmacSHA256")); doFinal(value.toByteArray(UTF_8))
    }
}
