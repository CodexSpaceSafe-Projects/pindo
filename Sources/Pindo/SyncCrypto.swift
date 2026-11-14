import Foundation
import CryptoKit
import Security
import PindoCore

// Client encryption for v3 envelopes and local v1/v2 archives. No legacy cloud transport.
enum SyncTransportError: Error, LocalizedError, Equatable {
    case invalidRecoveryKey, randomGenerationFailed, invalidEncryptedData, unsupportedVersion, responseTooLarge, objectMismatch
    var errorDescription: String? {
        switch self {
        case .invalidRecoveryKey: return "The recovery key must contain exactly 64 hexadecimal characters."
        case .randomGenerationFailed: return "A secure recovery key could not be generated."
        case .invalidEncryptedData: return "Encrypted sync data could not be verified. Check the recovery key."
        case .unsupportedVersion: return "This sync format requires a newer version of Pindo."
        case .responseTooLarge: return "Sync data exceeds the 7 MiB plaintext or 10 MiB encrypted safety limit."
        case .objectMismatch: return "The sync object's path does not match its encrypted contents. No remote data was applied."
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

    static func migrationMarkerKey(vaultID: String) -> String {
        headKey(vaultID: vaultID, deviceID: "ffffffff-ffff-ffff-ffff-ffffffffffff")
    }

    static func objectKey(vaultID: String, encryptedData: Data) -> String {
        "pindo/v2/\(vaultID)/objects/\(Data(SHA256.hash(data: encryptedData)).syncHex).json"
    }

    static func validateObject(data: Data, key: String, vaultID: String) throws {
        guard data.count <= maximumBytes else { throw SyncTransportError.responseTooLarge }
        guard vaultID.range(of: "^[a-f0-9]{32}\\z", options: .regularExpression) != nil,
              key == objectKey(vaultID: vaultID, encryptedData: data) else { throw SyncTransportError.objectMismatch }
    }

    func seal(_ data: Data) throws -> Data {
        try seal(data, nonce: AES.GCM.Nonce())
    }

    /// Internal nonce injection exists only for the cross-platform test vector.
    func seal(_ data: Data, nonce: AES.GCM.Nonce) throws -> Data {
        try seal(data, nonce: nonce, version: 1)
    }

    func sealV2(_ data: Data) throws -> Data {
        try sealV2(data, nonce: AES.GCM.Nonce())
    }

    /// Fixed nonces are used only in interoperable test vectors.
    func sealV2(_ data: Data, nonce: AES.GCM.Nonce) throws -> Data {
        try seal(data, nonce: nonce, version: 2)
    }

    private func seal(_ data: Data, nonce: AES.GCM.Nonce, version: Int) throws -> Data {
        guard data.count <= Self.maximumPlaintextBytes else { throw SyncTransportError.responseTooLarge }
        let box = try AES.GCM.seal(data, using: key, nonce: nonce, authenticating: associatedData(version: version))
        let envelope = SyncEncryptedEnvelope(version: version, nonce: Data(box.nonce).base64EncodedString(),
                                             ciphertext: box.ciphertext.base64EncodedString(), tag: box.tag.base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = version == 2 ? [.sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        let encoded = try encoder.encode(envelope)
        guard encoded.count <= Self.maximumBytes else { throw SyncTransportError.responseTooLarge }
        return encoded
    }

    func open(_ data: Data) throws -> Data {
        try open(data, version: 1)
    }

    func openV2(_ data: Data) throws -> Data {
        try open(data, version: 2)
    }

    private func open(_ data: Data, version: Int) throws -> Data {
        guard data.count <= Self.maximumBytes else { throw SyncTransportError.responseTooLarge }
        do {
            let envelope = try JSONDecoder().decode(SyncEncryptedEnvelope.self, from: data)
            guard envelope.version == version else { throw SyncTransportError.unsupportedVersion }
            guard let nonce = Data(base64Encoded: envelope.nonce), nonce.count == 12,
                  let cipher = Data(base64Encoded: envelope.ciphertext),
                  let tag = Data(base64Encoded: envelope.tag), tag.count == 16 else {
                throw SyncTransportError.invalidEncryptedData
            }
            guard cipher.count <= Self.maximumPlaintextBytes else { throw SyncTransportError.responseTooLarge }
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: cipher, tag: tag)
            return try AES.GCM.open(box, using: key, authenticating: associatedData(version: version))
        } catch let error as SyncTransportError { throw error }
        catch { throw SyncTransportError.invalidEncryptedData }
    }

    /// Frozen v3 combined bytes: nonce (12), ciphertext, authentication tag (16).
    func sealV3(_ plaintext: Data, context: SyncV3EnvelopeContext) throws -> Data {
        try sealV3(plaintext, context: context, nonce: AES.GCM.Nonce())
    }
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

    private func associatedData(version: Int) -> Data { Data("PindoSync/v\(version)/\(vaultID)".utf8) }
}

private struct SyncEncryptedEnvelope: Codable {
    let version: Int
    let nonce: String
    let ciphertext: String
    let tag: String
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
