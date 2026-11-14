import CryptoKit
import Foundation
import PindoCore

private actor SyncPayloadMergeWorker {
    func merge(_ data: Data, legacy: Bool, marker: Bool, key: String, encryption: SyncEncryption,
               previous: SyncPayload) throws -> SyncPayload {
        try Task.checkCancellation()
        let plaintext: Data
        if legacy && !marker { plaintext = try encryption.open(data) }
        else {
            if !legacy { try SyncEncryption.validateObject(data: data, key: key, vaultID: encryption.vaultID) }
            do { plaintext = try encryption.openV2(data) }
            catch {
                if marker { throw CloudSyncError.migrationCollision }
                throw error
            }
        }
        try Task.checkCancellation()
        let payload = try DocumentCodec.decode(SyncPayload.self, from: plaintext).validated()
        if !legacy || marker { guard payload.version == 2 else { throw SyncTransportError.unsupportedVersion } }
        try Task.checkCancellation()
        let merged = try previous.merging(payload)
        try Task.checkCancellation()
        return merged
    }
}

/// A round reads immutable commits into a bounded candidate, then commits its
/// cache with the replica. Upload acknowledgements name the frozen outbox only.
@MainActor enum ImmutableCloudSync {
    private static let batchBytes = 64 * 1024 * 1024
    private static let mergeWorker = SyncPayloadMergeWorker()

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func channelID(configuration: BitifulConfiguration, encryption: SyncEncryption) -> String {
        digest(Data("PindoSync/v2\n\(configuration.bucket.lowercased())\n\(encryption.vaultID)".utf8))
    }

    /// Read-only verification precedes assigning an unbound legacy history to
    /// an entered key. A typo must not consume or relabel that history.
    static func verifyTarget(encryption: SyncEncryption, transport: any CloudSyncTransport,
                             allowCreate: Bool, check: () throws -> Void) async throws {
        try check()
        let heads = try await transport.listHeads(vaultID: encryption.vaultID)
        try check()
        let objects = try await transport.listObjects(vaultID: encryption.vaultID)
        try check()
        let marker = SyncEncryption.migrationMarkerKey(vaultID: encryption.vaultID)
        let selected = heads.first(where: { $0.key == marker }) ?? objects.first ?? heads.first
        guard let selected else {
            guard allowCreate else { throw CloudSyncError.vaultNotFound }
            return
        }
        let legacy = selected.key.hasPrefix("pindo/v1/")
        let data = legacy ? try await transport.download(key: selected.key, expectedETag: selected.etag) :
            try await transport.download(key: selected.key)
        try check()
        _ = try await mergeWorker.merge(data, legacy: legacy, marker: selected.key == marker,
                                        key: selected.key, encryption: encryption, previous: SyncPayload(version: 2))
        try check()
    }

    static func run(repository: PindoRepository, encryption: SyncEncryption, transport: any CloudSyncTransport,
                    allowCreate: Bool, check: () throws -> Void, applied: () -> Void,
                    progress: (CloudSyncPhase) -> Void) async throws -> Bool {
        progress(.downloading)
        let objects = try await transport.listObjects(vaultID: encryption.vaultID)
        try check()
        let heads = try await transport.listHeads(vaultID: encryption.vaultID)
        try check()
        guard let session = repository.syncSession, let local = repository.syncPayload else {
            throw PindoError.invalidData("同步状态不存在")
        }
        let marker = SyncEncryption.migrationMarkerKey(vaultID: encryption.vaultID)
        var objectKeys = Set(objects.map(\.key))
        var known = Set(session.acknowledgedObjects).intersection(objectKeys)
        var objectETags = session.objectETags.filter { objectKeys.contains($0.key) }
        let headKeys = Set(heads.map(\.key))
        var legacyETags = session.legacyETags.filter { headKeys.contains($0.key) }
        if objects.isEmpty && heads.isEmpty && !allowCreate && session.acknowledgedPayloadDigest == nil && session.pendingObject == nil {
            throw CloudSyncError.vaultNotFound
        }
        var candidate = try local.upgraded()
        let inputs = heads.filter { legacyETags[$0.key] != $0.etag }.map { ($0, true) } +
            objects.filter { !known.contains($0.key) || objectETags[$0.key] != $0.etag }.map { ($0, false) }
        var bytesRead = 0, more = false
        for (index, input) in inputs.enumerated() {
            let (object, legacy) = input
            let data: Data
            if legacy { data = try await transport.download(key: object.key, expectedETag: object.etag) }
            else { data = try await transport.download(key: object.key) }
            try check()
            candidate = try await mergeWorker.merge(data, legacy: legacy, marker: object.key == marker,
                                                    key: object.key, encryption: encryption, previous: candidate)
            try check()
            if legacy { legacyETags[object.key] = object.etag }
            else { known.insert(object.key); objectETags[object.key] = object.etag }
            bytesRead += data.count
            if bytesRead >= batchBytes && index + 1 < inputs.count { more = true; break }
        }
        try check()
        if !inputs.isEmpty || known.sorted() != session.acknowledgedObjects || legacyETags != session.legacyETags || objectETags != session.objectETags {
            try repository.applySync(candidate, acknowledgedObjects: known.sorted(), legacyETags: legacyETags, objectETags: objectETags)
            applied()
        }
        // Each bounded batch is monotone and durable. An incomplete scan cannot
        // publish a checkpoint, establish the upgrade barrier, or claim success.
        if more { return false }

        var confirmedBytes: Data?
        for _ in 0..<2 {
            try check()
            guard let current = repository.syncPayload, let state = repository.syncSession else {
                throw PindoError.invalidData("同步状态不存在")
            }
            let plaintext = try DocumentCodec.encode(current)
            let payloadDigest = digest(plaintext)
            if state.pendingObject == nil &&
                (state.acknowledgedPayloadDigest != payloadDigest || state.acknowledgedObjectKey.map({ !objectKeys.contains($0) }) != false) {
                guard objectKeys.count < 10_000 else { throw SyncTransportError.tooManyObjects }
                let encrypted = try encryption.sealV2(plaintext)
                let key = SyncEncryption.objectKey(vaultID: encryption.vaultID, encryptedData: encrypted)
                try repository.stageSyncUpload(key: key, data: encrypted, payloadDigest: payloadDigest)
            }
            guard let pending = repository.syncSession?.pendingObject else { break }
            try SyncEncryption.validateObject(data: pending.data, key: pending.key, vaultID: encryption.vaultID)
            let pendingPlaintext = try encryption.openV2(pending.data)
            guard digest(pendingPlaintext) == pending.payloadDigest else { throw SyncTransportError.objectMismatch }
            _ = try DocumentCodec.decode(SyncPayload.self, from: pendingPlaintext).validated()
            progress(.uploading)
            var uploadFailure: Error?
            do { try await transport.upload(data: pending.data, key: pending.key) }
            catch { uploadFailure = error }
            try check()
            progress(.confirming)
            let receipt: Data
            do { receipt = try await transport.download(key: pending.key) }
            catch { throw uploadFailure ?? error }
            try check()
            guard receipt == pending.data else { throw SyncTransportError.objectMismatch }
            try repository.acknowledgeSyncUpload(key: pending.key, payloadDigest: pending.payloadDigest)
            objectKeys.insert(pending.key)
            confirmedBytes = pending.data
        }
        try check()
        guard let current = repository.syncPayload, let state = repository.syncSession,
              state.pendingObject == nil, state.acknowledgedPayloadDigest == digest(try DocumentCodec.encode(current)),
              let confirmedKey = state.acknowledgedObjectKey, objectKeys.contains(confirmedKey) else { return false }

        // The reserved v1 head is a full authenticated checkpoint. New clients
        // retain it as a recovery source; old clients stop on envelope version 2.
        if !headKeys.contains(marker) {
            var existingMarker: Data?
            do { existingMarker = try await transport.download(key: marker) }
            catch SyncTransportError.bucketNotFound { existingMarker = nil }
            try check()
            if let existingMarker {
                try applyMarker(existingMarker, repository: repository, encryption: encryption)
                applied()
            } else {
                let checkpoint: Data
                if let confirmedBytes { checkpoint = confirmedBytes }
                else { checkpoint = try await transport.download(key: confirmedKey) }
                try check()
                try SyncEncryption.validateObject(data: checkpoint, key: confirmedKey, vaultID: encryption.vaultID)
                _ = try encryption.openV2(checkpoint)
                progress(.migrating)
                var markerFailure: Error?
                do { try await transport.upload(data: checkpoint, key: marker) }
                catch { markerFailure = error }
                try check()
                let verified: Data
                do { verified = try await transport.download(key: marker) }
                catch { throw markerFailure ?? error }
                try check()
                // Concurrent migrations can publish different valid checkpoints.
                try applyMarker(verified, repository: repository, encryption: encryption)
                applied()
            }
        }
        try check()
        guard let finalPayload = repository.syncPayload, let finalState = repository.syncSession else { return false }
        let finalDigest = digest(try DocumentCodec.encode(finalPayload))
        return finalState.pendingObject == nil && finalState.acknowledgedPayloadDigest == finalDigest
    }

    private static func applyMarker(_ data: Data, repository: PindoRepository, encryption: SyncEncryption) throws {
        let plaintext: Data
        do { plaintext = try encryption.openV2(data) }
        catch { throw CloudSyncError.migrationCollision }
        let payload = try DocumentCodec.decode(SyncPayload.self, from: plaintext).validated()
        guard payload.version == 2 else { throw CloudSyncError.migrationCollision }
        let session = repository.syncSession
        try repository.applySync(payload, acknowledgedObjects: session?.acknowledgedObjects ?? [], legacyETags: session?.legacyETags ?? [:],
                                 objectETags: session?.objectETags ?? [:])
    }
}
