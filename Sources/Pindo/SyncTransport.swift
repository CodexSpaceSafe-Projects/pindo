import Foundation
import CryptoKit
import Security

/// These values are connection metadata only. Credentials and recovery keys belong in Keychain.
struct BitifulConfiguration: Codable, Equatable, Sendable {
    var endpoint: String = "https://s3.bitiful.net"
    var bucket: String
    var region: String = "cn-east-1"

    func validated() throws -> Self {
        guard let url = URLComponents(string: endpoint), url.scheme == "https",
              let host = url.host?.lowercased(), host.hasSuffix(".bitiful.net"),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port == nil || url.port == 443, url.path.isEmpty || url.path == "/",
              bucket.range(of: "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\\z", options: .regularExpression) != nil,
              !bucket.contains(".."), !bucket.contains(".-"), !bucket.contains("-."),
              bucket.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\\z", options: .regularExpression) == nil,
              region.range(of: "^[a-z0-9][a-z0-9-]{0,62}\\z", options: .regularExpression) != nil else {
            throw SyncTransportError.invalidConfiguration
        }
        return self
    }
}

struct BitifulCredentials: Codable, Equatable, Sendable {
    var accessKey: String
    var secretKey: String

    func validate() throws {
        guard !accessKey.isEmpty, accessKey.utf8.count <= 256, !secretKey.isEmpty, secretKey.utf8.count <= 1024,
              (accessKey + secretKey).utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw SyncTransportError.invalidCredentials
        }
    }
}

enum SyncTransportError: Error, LocalizedError, Equatable {
    case invalidConfiguration, invalidCredentials, invalidRecoveryKey, randomGenerationFailed
    case invalidEncryptedData, unsupportedVersion, invalidRemoteData, responseTooLarge, tooManyDevices
    case accessDenied, bucketNotFound, rateLimited, serverUnavailable, redirectRefused, networkUnavailable
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Use a valid Bitiful HTTPS endpoint, bucket and region."
        case .invalidCredentials: return "Enter valid Bitiful access and secret keys."
        case .invalidRecoveryKey: return "The recovery key must contain exactly 64 hexadecimal characters."
        case .randomGenerationFailed: return "A secure recovery key could not be generated."
        case .invalidEncryptedData: return "Encrypted sync data could not be verified. Check the recovery key."
        case .unsupportedVersion: return "This sync format requires a newer version of Pindo."
        case .invalidRemoteData: return "The sync listing is invalid. No remote data was applied."
        case .responseTooLarge: return "Sync data exceeds the 7 MiB plaintext or 10 MiB encrypted safety limit."
        case .tooManyDevices: return "The vault contains more than 100 device heads."
        case .accessDenied: return "Bitiful denied access. Check the keys and bucket permissions."
        case .bucketNotFound: return "The Bitiful bucket or sync object was not found."
        case .rateLimited: return "Bitiful is limiting requests. Sync will retry later."
        case .serverUnavailable: return "Bitiful is temporarily unavailable. Sync will retry later."
        case .redirectRefused: return "Bitiful redirected the request. Check the endpoint and region."
        case .networkUnavailable: return "Could not connect to Bitiful. Local changes are preserved."
        case .httpStatus(let status): return "Bitiful returned HTTP \(status). Local changes are preserved."
        }
    }
}

struct SyncEncryption: Sendable {
    static let maximumBytes = 10 * 1024 * 1024
    static let maximumPlaintextBytes = 7 * 1024 * 1024
    let vaultID: String
    private let key: SymmetricKey

    init(recoveryKey: String) throws {
        guard recoveryKey.utf8.count == 64, let bytes = Data(syncHex: recoveryKey) else {
            throw SyncTransportError.invalidRecoveryKey
        }
        key = SymmetricKey(data: bytes)
        vaultID = Data(SHA256.hash(data: bytes)).syncHex.prefix(32).description
    }

    static func generateKey() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SyncTransportError.randomGenerationFailed
        }
        return Data(bytes).syncHex
    }

    static func headKey(vaultID: String, deviceID: String) -> String {
        "pindo/v1/\(vaultID)/heads/\(deviceID.lowercased()).json"
    }

    static func headKey(vaultID: String, deviceID: UUID) -> String {
        headKey(vaultID: vaultID, deviceID: deviceID.uuidString)
    }

    func seal(_ data: Data) throws -> Data {
        try seal(data, nonce: AES.GCM.Nonce())
    }

    /// Internal nonce injection exists only for the cross-platform test vector.
    func seal(_ data: Data, nonce: AES.GCM.Nonce) throws -> Data {
        guard data.count <= Self.maximumPlaintextBytes else { throw SyncTransportError.responseTooLarge }
        let box = try AES.GCM.seal(data, using: key, nonce: nonce, authenticating: associatedData)
        let envelope = SyncEncryptedEnvelope(version: 1, nonce: Data(box.nonce).base64EncodedString(),
                                             ciphertext: box.ciphertext.base64EncodedString(), tag: box.tag.base64EncodedString())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(envelope)
        guard encoded.count <= Self.maximumBytes else { throw SyncTransportError.responseTooLarge }
        return encoded
    }

    func open(_ data: Data) throws -> Data {
        guard data.count <= Self.maximumBytes else { throw SyncTransportError.responseTooLarge }
        do {
            let envelope = try JSONDecoder().decode(SyncEncryptedEnvelope.self, from: data)
            guard envelope.version == 1 else { throw SyncTransportError.unsupportedVersion }
            guard let nonce = Data(base64Encoded: envelope.nonce), nonce.count == 12,
                  let cipher = Data(base64Encoded: envelope.ciphertext),
                  let tag = Data(base64Encoded: envelope.tag), tag.count == 16 else {
                throw SyncTransportError.invalidEncryptedData
            }
            guard cipher.count <= Self.maximumPlaintextBytes else { throw SyncTransportError.responseTooLarge }
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: cipher, tag: tag)
            return try AES.GCM.open(box, using: key, authenticating: associatedData)
        } catch let error as SyncTransportError { throw error }
        catch { throw SyncTransportError.invalidEncryptedData }
    }

    private var associatedData: Data { Data("PindoSync/v1/\(vaultID)".utf8) }
}

private struct SyncEncryptedEnvelope: Codable {
    let version: Int
    let nonce: String
    let ciphertext: String
    let tag: String
}

struct SyncRemoteHead: Equatable, Sendable {
    let key: String
    let etag: String
}

/// Every caller uploads only its local installation's head; other heads are read-only inputs.
/// Independent writers never replace one another's object, so no S3 conditional-write extension is needed.
final class BitifulTransport: @unchecked Sendable {
    let configuration: BitifulConfiguration
    private let credentials: BitifulCredentials
    private let session: URLSession
    private let redirectDelegate: SyncRedirectDelegate
    private let now: @Sendable () -> Date

    init(configuration: BitifulConfiguration, credentials: BitifulCredentials,
         sessionConfiguration: URLSessionConfiguration = .ephemeral,
         now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.configuration = try configuration.validated()
        try credentials.validate(); self.credentials = credentials; self.now = now
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 60
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let redirectDelegate = SyncRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        session = URLSession(configuration: sessionConfiguration, delegate: redirectDelegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func listHeads(vaultID: String) async throws -> [SyncRemoteHead] {
        guard Self.validVaultID(vaultID) else { throw SyncTransportError.invalidConfiguration }
        let prefix = "pindo/v1/\(vaultID)/heads/"
        var heads: [SyncRemoteHead] = [], knownKeys: Set<String> = [], tokens: Set<String> = []
        var token: String?
        var pages = 0
        repeat {
            pages += 1
            guard pages <= 100 else { throw SyncTransportError.invalidRemoteData }
            var query = [("list-type", "2"), ("prefix", prefix), ("max-keys", "100")]
            if let token { query.append(("continuation-token", token)) }
            let data = try await request(method: "GET", key: nil, query: query)
            // S3 listings are UTF-8 XML. Reject DTDs before parsing; checking the
            // same strict encoding also prevents UTF-16 from bypassing this check.
            guard let xml = String(data: data, encoding: .utf8), !xml.contains("\0"),
                  xml.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil else {
                throw SyncTransportError.invalidRemoteData
            }
            let listing = SyncListParser()
            let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = listing
            guard parser.parse(), listing.valid, listing.root == "ListBucketResult" else { throw SyncTransportError.invalidRemoteData }
            for head in listing.heads {
                guard Self.validHeadKey(head.key), head.key.hasPrefix(prefix), !head.etag.isEmpty,
                      knownKeys.insert(head.key).inserted else { throw SyncTransportError.invalidRemoteData }
                heads.append(head)
                guard heads.count <= 100 else { throw SyncTransportError.tooManyDevices }
            }
            if listing.isTruncated {
                guard !listing.heads.isEmpty, let next = listing.nextToken, !next.isEmpty, next.utf8.count <= 8192,
                      tokens.insert(next).inserted else { throw SyncTransportError.invalidRemoteData }
                token = next
            } else { token = nil }
        } while token != nil
        return heads.sorted { $0.key < $1.key }
    }

    func download(key: String) async throws -> Data {
        guard Self.validHeadKey(key) else { throw SyncTransportError.invalidConfiguration }
        return try await request(method: "GET", key: key)
    }

    func upload(data: Data, key: String) async throws {
        guard Self.validHeadKey(key) else { throw SyncTransportError.invalidConfiguration }
        guard data.count <= SyncEncryption.maximumBytes else { throw SyncTransportError.responseTooLarge }
        _ = try await request(method: "PUT", key: key, body: data)
    }

    private func request(method: String, key: String?, query: [(String, String)] = [], body: Data = Data()) async throws -> Data {
        let request = try signedRequest(method: method, key: key, query: query, body: body)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw SyncTransportError.networkUnavailable }
            switch http.statusCode {
            case 200...299: break
            case 301...399: throw SyncTransportError.redirectRefused
            case 401, 403: throw SyncTransportError.accessDenied
            case 404: throw SyncTransportError.bucketNotFound
            case 429: throw SyncTransportError.rateLimited
            case 500...599: throw SyncTransportError.serverUnavailable
            default: throw SyncTransportError.httpStatus(http.statusCode)
            }
            guard response.expectedContentLength <= Int64(SyncEncryption.maximumBytes) else {
                throw SyncTransportError.responseTooLarge
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= SyncEncryption.maximumBytes else { throw SyncTransportError.responseTooLarge }
            }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as SyncTransportError { throw error }
        catch { throw SyncTransportError.networkUnavailable }
    }

    func signedRequest(method: String, key: String?, query: [(String, String)] = [], body: Data = Data()) throws -> URLRequest {
        var components = URLComponents(string: configuration.endpoint)!
        components.percentEncodedPath = "/" + SyncS3Signer.encode(configuration.bucket) + (key.map { "/" + SyncS3Signer.encode($0, preservingSlashes: true) } ?? "")
        let encodedQuery = SyncS3Signer.canonicalQuery(query)
        components.percentEncodedQuery = encodedQuery.isEmpty ? nil : encodedQuery
        guard let url = components.url, let host = components.host else { throw SyncTransportError.invalidConfiguration }
        return SyncS3Signer.sign(method: method, url: url, host: host.lowercased(), body: body,
                                 region: configuration.region, credentials: credentials, date: now())
    }

    private static func validVaultID(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{32}\\z", options: .regularExpression) != nil
    }
    private static func validHeadKey(_ value: String) -> Bool {
        value.range(of: "^pindo/v1/[a-f0-9]{32}/heads/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\\.json\\z", options: .regularExpression) != nil
    }
}

private final class SyncRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum SyncS3Signer {
    static let signedHeaders = "host;x-amz-content-sha256;x-amz-date"

    static func encode(_ value: String, preservingSlashes: Bool = false) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~".utf8)
        return value.utf8.map { allowed.contains($0) || (preservingSlashes && $0 == 47) ? String(UnicodeScalar($0)) : String(format: "%%%02X", $0) }.joined()
    }

    static func canonicalQuery(_ items: [(String, String)]) -> String {
        var encoded: [(name: String, value: String)] = []
        encoded.reserveCapacity(items.count)
        for (name, value) in items {
            encoded.append((name: encode(name), value: encode(value)))
        }
        encoded.sort { lhs, rhs in
            if lhs.name == rhs.name { return lhs.value < rhs.value }
            return lhs.name < rhs.name
        }
        var components: [String] = []
        components.reserveCapacity(encoded.count)
        for item in encoded { components.append(item.name + "=" + item.value) }
        return components.joined(separator: "&")
    }

    static func sign(method: String, url: URL, host: String, body: Data, region: String,
                     credentials: BitifulCredentials, date: Date) -> URLRequest {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date), day = String(timestamp.prefix(8))
        let digest = Data(SHA256.hash(data: body)).syncHex
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let headers = "host:\(host)\nx-amz-content-sha256:\(digest)\nx-amz-date:\(timestamp)\n"
        let canonical = [method, parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath,
                         parts.percentEncodedQuery ?? "", headers, signedHeaders, digest].joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let toSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(Data(SHA256.hash(data: Data(canonical.utf8))).syncHex)"
        var signingKey = hmac(Data(("AWS4" + credentials.secretKey).utf8), day)
        for component in [region, "s3", "aws4_request"] { signingKey = hmac(signingKey, component) }
        let signature = hmac(signingKey, toSign).syncHex
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        if method == "PUT" { request.httpBody = body; request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(digest, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue("AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }
}

private final class SyncListParser: NSObject, XMLParserDelegate {
    private var stack: [String] = []
    private var text = ""
    private var key: String?, etag: String?
    private(set) var root: String?
    private(set) var heads: [SyncRemoteHead] = []
    private(set) var nextToken: String?
    private(set) var isTruncated = false
    private(set) var valid = true
    private var sawTruncated = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if stack.isEmpty { root = elementName }
        stack.append(elementName); text = ""
        if elementName == "Contents" { key = nil; etag = nil }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let parent = stack.dropLast().last
        if parent == "Contents" {
            if elementName == "Key" { key = text }
            if elementName == "ETag" { etag = text }
        } else if parent == "ListBucketResult" {
            if elementName == "IsTruncated" {
                if sawTruncated || !["true", "false"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines)) { valid = false }
                sawTruncated = true; isTruncated = text.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            }
            if elementName == "NextContinuationToken" { nextToken = text }
        }
        if elementName == "Contents" {
            if let key, let etag { heads.append(SyncRemoteHead(key: key, etag: etag)) }
            else { valid = false }
        }
        stack.removeLast(); text = ""
    }
    func parserDidEndDocument(_ parser: XMLParser) { if !sawTruncated { valid = false } }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        valid = false; parser.abortParsing()
    }
}

private extension Data {
    var syncHex: String { map { String(format: "%02x", $0) }.joined() }
    init?(syncHex: String) {
        guard syncHex.utf8.count % 2 == 0 else { return nil }
        let bytes = Array(syncHex.utf8)
        guard bytes.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        var result = [UInt8](); result.reserveCapacity(bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let value = UInt8(String(decoding: bytes[index..<(index + 2)], as: UTF8.self), radix: 16) else { return nil }
            result.append(value)
        }
        self.init(result)
    }
}
