import XCTest
import CryptoKit
import PindoCore
@testable import Pindo

final class LegacySyncCryptoTests: XCTestCase {
    private let recoveryKey = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    private let vault = "630dcd2966c4336691125448bbb25b4f"
    private let device = "00000000-0000-0000-0000-000000000001"

    // Generated independently using Python cryptography AESGCM, shared with Kotlin tests.
    private let fixture = Data(#"{"version":1,"nonce":"AAECAwQFBgcICQoL","ciphertext":"PCCgfreWq3TjY626ncsLCOa4pQ6LBnNeSgKG6m8Nc5A7a9OB","tag":"1SCj+RLdikLz5cIh6qzeNw=="}"#.utf8)
    private let plaintext = Data(#"{"version":1,"seen":{},"records":{}}"#.utf8)
    private let plaintextV2 = Data(#"{"version":2,"seen":{},"records":{}}"#.utf8)
    private let fixtureV2 = Data(#"{"ciphertext":"PCCgfreWq3TjY625ncsLCOa4pQ6LBnNeSgKG6m8Nc5A7a9OB","nonce":"AAECAwQFBgcICQoL","tag":"KIX2rgCTc/epvQCHI8SKwA==","version":2}"#.utf8)


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

    func testSharedV3EncryptionAndCrossEpochRejection() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vector = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("sync-vectors/v3-contract.json"))) as? [String: Any])
        let c = vector["context"] as! [String: Any]
        let identity = try SyncV3Identity(serviceID: c["serviceID"] as! String, vaultID: c["vaultID"] as! String)
        let context = SyncV3EnvelopeContext(identity: identity, epoch: c["epoch"] as! String, kind: .batch, objectID: c["objectID"] as! String)
        let encryption = try SyncEncryption(recoveryKey: vector["keyHex"] as! String)
        let plaintext = Data((vector["plaintext"] as! String).utf8)
        let expected = try XCTUnwrap(Data(base64Encoded: vector["ciphertext"] as! String))
        XCTAssertEqual(try encryption.sealV3(plaintext, context: context, nonce: AES.GCM.Nonce(data: Data(0..<12))), expected)
        XCTAssertEqual(try encryption.openV3(expected, context: context), plaintext)
        let wrong = SyncV3EnvelopeContext(identity: identity, epoch: "00000000-0000-4000-8000-000000000099", kind: .batch, objectID: c["objectID"] as! String)
        XCTAssertThrowsError(try encryption.openV3(expected, context: wrong))
    }
}
