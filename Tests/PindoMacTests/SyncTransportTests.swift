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
