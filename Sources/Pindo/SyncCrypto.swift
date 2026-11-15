import Foundation
import CryptoKit
import Security
import PindoCore

enum SyncEncryptionError: Error, LocalizedError, Equatable {
    case invalidRecoveryKey, randomGenerationFailed

    var errorDescription: String? {
        switch self {
        case .invalidRecoveryKey: return "The recovery key must contain exactly 64 hexadecimal characters."
        case .randomGenerationFailed: return "A secure recovery key could not be generated."
        }
    }
}

struct SyncEncryption: SyncV3Cryptography {
    private let key: SymmetricKey

    init(recoveryKey: String) throws {
        guard recoveryKey.utf8.count == 64, let bytes = Data(syncHex: recoveryKey) else {
            throw SyncEncryptionError.invalidRecoveryKey
        }
        key = SymmetricKey(data: bytes)
    }

    static func generateKey() throws -> String { try randomBytes().syncHex }

    static func deviceToken() throws -> String {
        try randomBytes().base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomBytes() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SyncEncryptionError.randomGenerationFailed
        }
        return Data(bytes)
    }

    func digestV3(_ bytes: Data) -> String { Data(SHA256.hash(data: bytes)).syncHex }

    func sealV3(_ plaintext: Data, context: SyncV3EnvelopeContext) throws -> Data {
        try sealV3(plaintext, context: context, nonce: AES.GCM.Nonce())
    }

    // A fixed nonce is injected only for the shared cross-platform test vector.
    func sealV3(_ plaintext: Data, context: SyncV3EnvelopeContext, nonce: AES.GCM.Nonce) throws -> Data {
        let limit = context.kind == .chunk ? SyncV3.maximumChunkBytes : SyncV3.maximumBatchBytes
        guard !plaintext.isEmpty, plaintext.count <= limit - 28 else { throw SyncV3Error.invalidRequest }
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: context.associatedData())
        guard let combined = box.combined else { throw SyncV3Error.corruptData }
        return combined
    }

    func openV3(_ combined: Data, context: SyncV3EnvelopeContext) throws -> Data {
        let limit = context.kind == .chunk ? SyncV3.maximumChunkBytes : SyncV3.maximumBatchBytes
        guard combined.count >= 29, combined.count <= limit else { throw SyncV3Error.corruptData }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key, authenticating: context.associatedData())
        } catch { throw SyncV3Error.corruptData }
    }
}

private extension Data {
    var syncHex: String { map { String(format: "%02x", $0) }.joined() }

    init?(syncHex: String) {
        let bytes = Array(syncHex.utf8)
        guard bytes.count == 64,
              bytes.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        var result = [UInt8]()
        result.reserveCapacity(32)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let value = UInt8(String(decoding: bytes[index..<(index + 2)], as: UTF8.self), radix: 16) else { return nil }
            result.append(value)
        }
        self.init(result)
    }
}
