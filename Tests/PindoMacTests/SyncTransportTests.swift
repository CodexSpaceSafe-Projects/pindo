import XCTest
import CryptoKit
@testable import Pindo

final class SyncTransportTests: XCTestCase {
    private let recoveryKey = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    private let vault = "630dcd2966c4336691125448bbb25b4f"
    private let device = "00000000-0000-0000-0000-000000000001"

    // Generated independently using Python cryptography AESGCM, shared with Kotlin tests.
    private let fixture = Data(#"{"version":1,"nonce":"AAECAwQFBgcICQoL","ciphertext":"PCCgfreWq3TjY626ncsLCOa4pQ6LBnNeSgKG6m8Nc5A7a9OB","tag":"1SCj+RLdikLz5cIh6qzeNw=="}"#.utf8)
    private let plaintext = Data(#"{"version":1,"seen":{},"records":{}}"#.utf8)
    private let plaintextV2 = Data(#"{"version":2,"seen":{},"records":{}}"#.utf8)
    private let fixtureV2 = Data(#"{"ciphertext":"PCCgfreWq3TjY625ncsLCOa4pQ6LBnNeSgKG6m8Nc5A7a9OB","nonce":"AAECAwQFBgcICQoL","tag":"KIX2rgCTc/epvQCHI8SKwA==","version":2}"#.utf8)

    override func tearDown() { SyncHTTPProtocol.responses = []; super.tearDown() }

    func testIndependentAESGCMFixtureAndVaultIdentity() throws {
        let cipher = try SyncEncryption(recoveryKey: recoveryKey)
        XCTAssertEqual(cipher.vaultID, vault)
        XCTAssertEqual(try cipher.open(fixture), plaintext)
        let sealed = try cipher.seal(plaintext, nonce: AES.GCM.Nonce(data: Data(0..<12)))
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: sealed) as? NSDictionary)
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? NSDictionary)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(SyncEncryption.headKey(vaultID: vault, deviceID: device.uppercased()), "pindo/v1/\(vault)/heads/\(device).json")
    }

    func testRandomNonceAndKeyGeneration() throws {
        let generated = try SyncEncryption.generateKey()
        XCTAssertEqual(generated.count, 64)
        let cipher = try SyncEncryption(recoveryKey: generated)
        let first = try cipher.seal(plaintext), second = try cipher.seal(plaintext)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try cipher.open(first), plaintext)
        XCTAssertEqual(try cipher.open(second), plaintext)
    }

    func testV2IndependentEncryptionAndContentAddressVector() throws {
        let encryption = try SyncEncryption(recoveryKey: recoveryKey)
        let sealed = try encryption.sealV2(plaintextV2, nonce: AES.GCM.Nonce(data: Data(0..<12)))
        XCTAssertEqual(sealed, fixtureV2)
        XCTAssertEqual(try encryption.openV2(fixtureV2), plaintextV2)
        let key = SyncEncryption.objectKey(vaultID: vault, encryptedData: fixtureV2)
        XCTAssertEqual(key, "pindo/v2/\(vault)/objects/58139da27e697ce48e61dba26242fc655c3b20e1063af9175517d2be93c5d8d2.json")
        try SyncEncryption.validateObject(data: fixtureV2, key: key, vaultID: vault)
        XCTAssertEqual(SyncEncryption.migrationMarkerKey(vaultID: vault), "pindo/v1/\(vault)/heads/ffffffff-ffff-ffff-ffff-ffffffffffff.json")
        XCTAssertThrowsError(try encryption.open(fixtureV2)) { XCTAssertEqual($0 as? SyncTransportError, .unsupportedVersion) }
        XCTAssertThrowsError(try encryption.openV2(fixture)) { XCTAssertEqual($0 as? SyncTransportError, .unsupportedVersion) }
        var downgraded = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureV2) as? [String: Any])
        downgraded["version"] = 1
        XCTAssertThrowsError(try encryption.open(JSONSerialization.data(withJSONObject: downgraded))) {
            XCTAssertEqual($0 as? SyncTransportError, .invalidEncryptedData)
        }
        XCTAssertThrowsError(try SyncEncryption.validateObject(data: fixtureV2 + Data(" ".utf8), key: key, vaultID: vault)) {
            XCTAssertEqual($0 as? SyncTransportError, .objectMismatch)
        }
        XCTAssertThrowsError(try SyncEncryption.validateObject(data: fixtureV2, key: key, vaultID: String(repeating: "a", count: 32)))
        XCTAssertThrowsError(try encryption.sealV2(Data(repeating: 0, count: SyncEncryption.maximumPlaintextBytes + 1)))
    }

    func testV2ObjectUploadAndDownloadVerifyExactCiphertextDigest() async throws {
        let transport = try makeTransport(), key = SyncEncryption.objectKey(vaultID: vault, encryptedData: fixtureV2)
        SyncHTTPProtocol.responses = [.init(status: 200, body: ""), .init(status: 200, body: String(decoding: fixtureV2, as: UTF8.self))]
        try await transport.upload(data: fixtureV2, key: key)
        let downloaded = try await transport.download(key: key)
        XCTAssertEqual(downloaded, fixtureV2)
        XCTAssertEqual(SyncHTTPProtocol.requests.first?.httpBody, fixtureV2)
        XCTAssertTrue(SyncHTTPProtocol.requests.first?.url?.path.hasSuffix("/objects/58139da27e697ce48e61dba26242fc655c3b20e1063af9175517d2be93c5d8d2.json") == true)
        let count = SyncHTTPProtocol.requests.count
        do { try await transport.upload(data: fixture, key: key); XCTFail("Different bytes must never overwrite the immutable key") }
        catch { XCTAssertEqual(error as? SyncTransportError, .objectMismatch) }
        XCTAssertEqual(SyncHTTPProtocol.requests.count, count)
        SyncHTTPProtocol.responses = [.init(status: 200, body: String(decoding: fixture, as: UTF8.self))]
        do { _ = try await transport.download(key: key); XCTFail("Changed remote bytes must fail before decryption") }
        catch { XCTAssertEqual(error as? SyncTransportError, .objectMismatch) }
        for path in [key.uppercased(), key + "/extra", "pindo/v2/\(vault)/objects/short.json", "pindo/v2/\(vault)/objects/../data.json"] {
            do { _ = try await transport.download(key: path); XCTFail("Invalid path must fail") }
            catch { XCTAssertEqual(error as? SyncTransportError, .invalidConfiguration) }
        }
    }

    func testV2ListingPaginatesAndRejectsDuplicatesCrossVaultAndUnknownKeys() async throws {
        let first = SyncEncryption.objectKey(vaultID: vault, encryptedData: fixtureV2)
        let second = SyncEncryption.objectKey(vaultID: vault, encryptedData: fixture)
        SyncHTTPProtocol.responses = [.init(status: 200, body: listing([(first, "one")], truncated: true, token: "+/=")),
                                      .init(status: 200, body: listing([(second, "two")]))]
        let objects = try await makeTransport().listObjects(vaultID: vault)
        XCTAssertEqual(objects,
                       [SyncRemoteHead(key: first, etag: "one"), SyncRemoteHead(key: second, etag: "two")].sorted { $0.key < $1.key })
        XCTAssertTrue(SyncHTTPProtocol.requests[1].url!.absoluteString.contains("continuation-token=%2B%2F%3D"))
        let foreign = SyncEncryption.objectKey(vaultID: String(repeating: "a", count: 32), encryptedData: fixtureV2)
        for entries in [[(first, "one"), (first, "two")], [(foreign, "one")], [(first.uppercased(), "one")], [(SyncEncryption.headKey(vaultID: vault, deviceID: device), "one")]] {
            SyncHTTPProtocol.responses = [.init(status: 200, body: listing(entries))]
            do { _ = try await makeTransport().listObjects(vaultID: vault); XCTFail("Invalid immutable listing must fail") }
            catch { XCTAssertEqual(error as? SyncTransportError, .invalidRemoteData) }
        }
    }

    func testV2ObjectLimitFailsClosedAndLegacyMarkerDoesNotConsumeADeviceSlot() async throws {
        let entries = (0..<10_001).map { ("pindo/v2/\(vault)/objects/\(String(format: "%064x", $0)).json", "etag") }
        SyncHTTPProtocol.responses = stride(from: 0, to: entries.count, by: 100).map { start in
            let end = min(start + 100, entries.count)
            return .init(status: 200, body: listing(Array(entries[start..<end]), truncated: end < entries.count,
                                                  token: end < entries.count ? "page-\(end)" : nil))
        }
        do { _ = try await makeTransport().listObjects(vaultID: vault); XCTFail("The immutable journal must have a bounded listing") }
        catch { XCTAssertEqual(error as? SyncTransportError, .tooManyObjects) }
        let heads = (1...100).map { (SyncEncryption.headKey(vaultID: vault, deviceID: String(format: "00000000-0000-0000-0000-%012x", $0)), "etag") }
        SyncHTTPProtocol.responses = [.init(status: 200, body: listing(heads, truncated: true, token: "marker-page")),
                                      .init(status: 200, body: listing([(SyncEncryption.migrationMarkerKey(vaultID: vault), "marker")]))]
        let allowedHeads = try await makeTransport().listHeads(vaultID: vault)
        XCTAssertEqual(allowedHeads.count, 101)
        SyncHTTPProtocol.responses = [.init(status: 200, body: listing(heads + [(SyncEncryption.headKey(vaultID: vault, deviceID: "00000000-0000-0000-0000-000000000101"), "extra")]))]
        do { _ = try await makeTransport().listHeads(vaultID: vault); XCTFail("A 101st writer must still fail") }
        catch { XCTAssertEqual(error as? SyncTransportError, .tooManyDevices) }
    }

    func testPlaintextLimitMatchesAndroidBeforeEncryption() throws {
        let cipher = try SyncEncryption(recoveryKey: recoveryKey)
        XCTAssertEqual(SyncEncryption.maximumPlaintextBytes, 7 * 1024 * 1024)
        XCTAssertThrowsError(try cipher.seal(Data(repeating: 0, count: SyncEncryption.maximumPlaintextBytes + 1))) {
            XCTAssertEqual($0 as? SyncTransportError, .responseTooLarge)
        }
    }

    func testWrongKeyTamperingAndNewerEnvelopeFailClosed() throws {
        let cipher = try SyncEncryption(recoveryKey: recoveryKey)
        XCTAssertThrowsError(try SyncEncryption(recoveryKey: String(repeating: "ff", count: 32)).open(fixture)) {
            XCTAssertEqual($0 as? SyncTransportError, .invalidEncryptedData)
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        object["tag"] = Data(repeating: 0, count: 16).base64EncodedString()
        XCTAssertThrowsError(try cipher.open(JSONSerialization.data(withJSONObject: object)))
        object["version"] = 2
        XCTAssertThrowsError(try cipher.open(JSONSerialization.data(withJSONObject: object))) {
            XCTAssertEqual($0 as? SyncTransportError, .unsupportedVersion)
        }
        for bad in ["", String(repeating: "g", count: 64), String(repeating: "+0", count: 32), " " + recoveryKey, recoveryKey + "00"] {
            XCTAssertThrowsError(try SyncEncryption(recoveryKey: bad))
        }
        XCTAssertThrowsError(try cipher.open(Data("not JSON".utf8)))
    }

    func testLegacyConditionalReadRequiresTheListedETagEvenWhenTheServerIgnoresIfMatch() async throws {
        let key = SyncEncryption.headKey(vaultID: vault, deviceID: device)
        SyncHTTPProtocol.responses = [.init(status: 200, body: String(decoding: fixture, as: UTF8.self), headers: ["ETag": "\"listed\""])]
        let bytes = try await makeTransport().download(key: key, expectedETag: "\"listed\"")
        XCTAssertEqual(bytes, fixture)
        XCTAssertEqual(SyncHTTPProtocol.requests.first?.value(forHTTPHeaderField: "If-Match"), "\"listed\"")
        for response in [SyncHTTPProtocol.Response(status: 412, body: ""),
                         .init(status: 200, body: "", headers: ["ETag": "\"changed\""]), .init(status: 200, body: "")] {
            SyncHTTPProtocol.responses = [response]
            do { _ = try await makeTransport().download(key: key, expectedETag: "\"listed\""); XCTFail("A raced or unversioned response must not be cached under the listed version") }
            catch { XCTAssertEqual(error as? SyncTransportError, .remoteChanged) }
        }
        SyncHTTPProtocol.responses = []
        do { _ = try await makeTransport().download(key: key, expectedETag: "bad\r\nInjected: value"); XCTFail("Unsafe ETag must fail before network") }
        catch { XCTAssertEqual(error as? SyncTransportError, .invalidRemoteData) }
        XCTAssertTrue(SyncHTTPProtocol.requests.isEmpty)
    }

    func testImmutableListingRejectsAmbiguousCriticalFieldsAndRepeatedPaginationTokens() async throws {
        let key = SyncEncryption.objectKey(vaultID: vault, encryptedData: fixtureV2)
        for body in [
            "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>\(key)</Key><Key>\(key)</Key><ETag>one</ETag></Contents></ListBucketResult>",
            "<ListBucketResult><IsTruncated>false</IsTruncated><Other><Contents><Key>\(key)</Key><ETag>one</ETag></Contents></Other></ListBucketResult>",
            listing([(key, "one")], truncated: true, token: String(repeating: "x", count: 8193))
        ] {
            SyncHTTPProtocol.responses = [.init(status: 200, body: body)]
            do { _ = try await makeTransport().listObjects(vaultID: vault); XCTFail("Ambiguous listing must fail") }
            catch { XCTAssertEqual(error as? SyncTransportError, .invalidRemoteData) }
        }
        let other = SyncEncryption.objectKey(vaultID: vault, encryptedData: fixture)
        SyncHTTPProtocol.responses = [.init(status: 200, body: listing([(key, "one")], truncated: true, token: "same")),
                                      .init(status: 200, body: listing([(other, "two")], truncated: true, token: "same"))]
        do { _ = try await makeTransport().listObjects(vaultID: vault); XCTFail("Repeated pagination token must fail") }
        catch { XCTAssertEqual(error as? SyncTransportError, .invalidRemoteData) }
        SyncHTTPProtocol.responses = [.init(status: 200, body: "", headers: ["Content-Length": String(1024 * 1024 + 1)])]
        do { _ = try await makeTransport().listObjects(vaultID: vault); XCTFail("Every listing page has a one MiB bound") }
        catch { XCTAssertEqual(error as? SyncTransportError, .responseTooLarge) }
    }

    func testSigV4MatchesIndependentHMACVector() throws {
        // Python hashlib/hmac reference calculation; fixed AWS example credentials are public test data.
        let credentials = BitifulCredentials(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z"))
        let request = SyncS3Signer.sign(method: "GET", url: URL(string: "https://examplebucket.s3.amazonaws.com/examplebucket/test.txt")!,
                                        host: "examplebucket.s3.amazonaws.com", body: Data(), region: "us-east-1", credentials: credentials, date: date)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-date"), "20130524T000000Z")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=e262308ffddff051393fc1e4f15361c623b2f8157cc41c3a1441cdba342e744d")
    }

    func testQueryEncodingAndEndpointValidation() throws {
        XCTAssertEqual(SyncS3Signer.canonicalQuery([("prefix", "a/b c"), ("continuation-token", "+/=é"), ("a", "~")]), "a=~&continuation-token=%2B%2F%3D%C3%A9&prefix=a%2Fb%20c")
        let transport = try makeTransport()
        let request = try transport.signedRequest(method: "GET", key: nil, query: [("list-type", "2"), ("prefix", "pindo/v1/a/heads/")])
        XCTAssertEqual(request.url?.absoluteString, "https://s3.bitiful.net/test-bucket?list-type=2&prefix=pindo%2Fv1%2Fa%2Fheads%2F")
        for endpoint in ["http://s3.bitiful.net", "https://s3.bitiful.net.evil.test", "https://evil.test", "https://user@s3.bitiful.net", "https://s3.bitiful.net/extra", "https://s3.bitiful.net?token=x", "https://s3.bitiful.net:444"] {
            XCTAssertThrowsError(try BitifulConfiguration(endpoint: endpoint, bucket: "test-bucket").validated())
        }
        XCTAssertThrowsError(try BitifulConfiguration(bucket: "../invalid").validated())
        XCTAssertThrowsError(try BitifulConfiguration(bucket: "test-bucket", region: "cn-east-1\n").validated())
        XCTAssertThrowsError(try BitifulCredentials(accessKey: "key\r\nInjected: value", secretKey: "secret").validate())
    }

    func testPaginatedListingEscapesTokenAndCollectsHeads() async throws {
        let firstKey = SyncEncryption.headKey(vaultID: vault, deviceID: device)
        let secondKey = SyncEncryption.headKey(vaultID: vault, deviceID: "00000000-0000-0000-0000-000000000002")
        SyncHTTPProtocol.responses = [
            .init(status: 200, body: listing([(firstKey, "\"one\"")], truncated: true, token: "+/=")),
            .init(status: 200, body: listing([(secondKey, "\"two\"")]))
        ]
        let heads = try await makeTransport().listHeads(vaultID: vault)
        XCTAssertEqual(heads, [.init(key: firstKey, etag: "\"one\""), .init(key: secondKey, etag: "\"two\"")])
        XCTAssertEqual(SyncHTTPProtocol.requests.count, 2)
        XCTAssertTrue(SyncHTTPProtocol.requests[1].url!.absoluteString.contains("continuation-token=%2B%2F%3D"))
    }

    func testMalformedPaginationAndCrossVaultKeysAreRejected() async throws {
        let key = SyncEncryption.headKey(vaultID: vault, deviceID: device)
        SyncHTTPProtocol.responses = [.init(status: 200, body: listing([(key, "one")], truncated: true))]
        do { _ = try await makeTransport().listHeads(vaultID: vault); XCTFail("Missing token must fail") }
        catch { XCTAssertEqual(error as? SyncTransportError, .invalidRemoteData) }
        let foreignKey = SyncEncryption.headKey(vaultID: String(repeating: "a", count: 32), deviceID: device)
        SyncHTTPProtocol.responses = [.init(status: 200, body: listing([(foreignKey, "one")]))]
        do { _ = try await makeTransport().listHeads(vaultID: vault); XCTFail("Cross-vault key must fail") }
        catch { XCTAssertEqual(error as? SyncTransportError, .invalidRemoteData) }
        SyncHTTPProtocol.responses = [.init(status: 200, body: "<ListBucketResult/>")]
        do { _ = try await makeTransport().listHeads(vaultID: vault); XCTFail("Truncated field must be present") }
        catch { XCTAssertEqual(error as? SyncTransportError, .invalidRemoteData) }
    }

    func testListingsRejectDTDsAndAlternativeEncodingsBeforeParsing() async throws {
        let dtd = "<!DOCTYPE ListBucketResult [<!ENTITY text 'expanded'>]><ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>"
        for encoding in [String.Encoding.utf8, .utf16] {
            SyncHTTPProtocol.responses = [.init(status: 200, body: dtd, bodyEncoding: encoding)]
            do { _ = try await makeTransport().listHeads(vaultID: vault); XCTFail("DTD listing must fail") }
            catch { XCTAssertEqual(error as? SyncTransportError, .invalidRemoteData) }
        }
        SyncHTTPProtocol.responses = [.init(status: 200, body: listing([]), bodyEncoding: .utf16)]
        do { _ = try await makeTransport().listHeads(vaultID: vault); XCTFail("Only UTF-8 listings are accepted") }
        catch { XCTAssertEqual(error as? SyncTransportError, .invalidRemoteData) }
    }

    func testHTTPFailuresAndSizeLimitAreSanitized() async throws {
        let failures: [(Int, SyncTransportError)] = [(403, .accessDenied), (404, .bucketNotFound), (429, .rateLimited), (503, .serverUnavailable), (302, .redirectRefused)]
        for (status, expected) in failures {
            SyncHTTPProtocol.responses = [.init(status: status, body: "SERVER SECRET MUST NOT BE SHOWN")]
            do { _ = try await makeTransport().listHeads(vaultID: vault); XCTFail("HTTP failure must fail") }
            catch {
                XCTAssertEqual(error as? SyncTransportError, expected)
                XCTAssertFalse(error.localizedDescription.contains("SERVER SECRET"))
            }
        }
        SyncHTTPProtocol.responses = [.init(status: 200, body: "", headers: ["Content-Length": String(SyncEncryption.maximumBytes + 1)])]
        do { _ = try await makeTransport().listHeads(vaultID: vault); XCTFail("Large response must fail") }
        catch { XCTAssertEqual(error as? SyncTransportError, .responseTooLarge) }
    }

    func testUploadContainsCiphertextAndOnlyAcceptsHeadPaths() async throws {
        let encrypted = try SyncEncryption(recoveryKey: recoveryKey).seal(plaintext)
        let transport = try makeTransport()
        SyncHTTPProtocol.responses = [.init(status: 200, body: "")]
        try await transport.upload(data: encrypted, key: SyncEncryption.headKey(vaultID: vault, deviceID: device))
        let request = try XCTUnwrap(SyncHTTPProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.httpBody, encrypted)
        XCTAssertFalse(String(data: encrypted, encoding: .utf8)!.contains("records"))
        do { try await transport.upload(data: encrypted, key: "../../data.json"); XCTFail("Invalid path must fail before network") }
        catch { XCTAssertEqual(error as? SyncTransportError, .invalidConfiguration) }
    }

    private func makeTransport() throws -> BitifulTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncHTTPProtocol.self]
        return try BitifulTransport(configuration: .init(bucket: "test-bucket"), credentials: .init(accessKey: "test-key", secretKey: "test-secret"), sessionConfiguration: configuration)
    }

    private func listing(_ heads: [(String, String)], truncated: Bool = false, token: String? = nil) -> String {
        "<ListBucketResult><IsTruncated>\(truncated)</IsTruncated>" + heads.map { "<Contents><Key>\($0.0)</Key><ETag>\($0.1)</ETag></Contents>" }.joined() + (token.map { "<NextContinuationToken>\($0)</NextContinuationToken>" } ?? "") + "</ListBucketResult>"
    }
}

private final class SyncHTTPProtocol: URLProtocol, @unchecked Sendable {
    struct Response { let status: Int; let body: String; var headers: [String: String] = [:]; var bodyEncoding: String.Encoding = .utf8 }
    private static let lock = NSLock()
    private static var storedResponses: [Response] = []
    private static var storedRequests: [URLRequest] = []
    static var responses: [Response] {
        get { lock.lock(); defer { lock.unlock() }; return storedResponses }
        set { lock.lock(); defer { lock.unlock() }; storedResponses = newValue; storedRequests = [] }
    }
    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return storedRequests
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        // URLSession may present uploaded Data as a body stream to URLProtocol.
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        Self.lock.lock()
        Self.storedRequests.append(captured)
        let next = Self.storedResponses.isEmpty ? Response(status: 500, body: "") : Self.storedResponses.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: next.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.body.data(using: next.bodyEncoding)!)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
