import XCTest
import CryptoKit
import PindoCore
@testable import Pindo

final class SyncCryptoTests: XCTestCase {
    private func context() throws -> SyncV3EnvelopeContext {
        .init(identity: try .init(serviceID: "00000000-0000-4000-8000-000000000001", vaultID: "00000000-0000-4000-8000-000000000002"),
              epoch: "00000000-0000-4000-8000-000000000003", kind: .batch,
              objectID: "00000000-0000-4000-8000-000000000004")
    }

    func testRandomNoncesAndGeneratedKeys() throws {
        let key = try SyncEncryption.generateKey()
        XCTAssertNotNil(key.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        XCTAssertNotEqual(key, try SyncEncryption.generateKey())
        let cipher = try SyncEncryption(recoveryKey: key), context = try context()
        let plaintext = Data("Encrypted note".utf8)
        let first = try cipher.sealV3(plaintext, context: context), second = try cipher.sealV3(plaintext, context: context)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try cipher.openV3(first, context: context), plaintext)
        XCTAssertEqual(try cipher.openV3(second, context: context), plaintext)
        let token = try SyncEncryption.deviceToken()
        XCTAssertNotNil(token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression))
        XCTAssertNotEqual(token, try SyncEncryption.deviceToken())
    }

    func testInvalidKeysAndTamperedCiphertextAreRejected() throws {
        for key in ["", String(repeating: "0", count: 63), String(repeating: "0", count: 65), String(repeating: "z", count: 64)] {
            XCTAssertThrowsError(try SyncEncryption(recoveryKey: key)) {
                XCTAssertEqual($0 as? SyncEncryptionError, .invalidRecoveryKey)
            }
        }
        let cipher = try SyncEncryption(recoveryKey: String(repeating: "01", count: 32)), context = try context()
        var sealed = try cipher.sealV3(Data("A note".utf8), context: context)
        sealed[sealed.count - 1] ^= 1
        XCTAssertThrowsError(try cipher.openV3(sealed, context: context))
        XCTAssertThrowsError(try cipher.openV3(Data(repeating: 0, count: 28), context: context))
        XCTAssertThrowsError(try cipher.sealV3(Data(), context: context))
        XCTAssertThrowsError(try cipher.sealV3(Data(repeating: 0, count: SyncV3.maximumBatchBytes - 27), context: context))
    }

    func testSharedEncryptionVectorAndCrossEpochRejection() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vector = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("sync-vectors/v3-contract.json"))) as? [String: Any])
        let c = try XCTUnwrap(vector["context"] as? [String: Any])
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
