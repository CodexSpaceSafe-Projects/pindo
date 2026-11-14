import Foundation

/// P0 wire primitives. v3 is deliberately separate from the legacy full-state
/// payload: a receipt confirms upload only; a cursor confirms durable application.
public enum SyncV3 {
    public static let maximumCounter: Int64 = 9_007_199_254_740_991
    public static let maximumBatchBytes = 128 * 1024
    public static let maximumOperations = 50
    public static let maximumChunkBytes = 64 * 1024

    public static func validateCounter(_ value: Int64) throws {
        guard value >= 0, value <= maximumCounter else { throw SyncV3Error.invalidRequest }
    }
    public static func validateID(_ value: String) throws {
        guard UUID(uuidString: value)?.uuidString.lowercased() == value else { throw SyncV3Error.invalidRequest }
    }
}

public enum SyncV3Error: String, Error, Codable, Sendable {
    case authenticationRequired = "authentication_required", unsupportedVersion = "unsupported_version"
    case epochMismatch = "epoch_mismatch", batchConflict = "batch_conflict"
    case checkpointRequired = "checkpoint_required", corruptData = "corrupt_data"
    case quotaUnavailable = "quota_unavailable", storageUnavailable = "storage_unavailable"
    case maintenance, invalidRequest = "invalid_request", cursorMismatch = "cursor_mismatch"
    case notFound = "not_found", unsupportedFeature = "unsupported_feature"
    case bootstrapClosed = "bootstrap_closed", pairingInvalid = "pairing_invalid", checkpointConflict = "checkpoint_conflict", artifactMissing = "artifact_missing", leaseExpired = "lease_expired"
}

public struct SyncV3Identity: Codable, Equatable, Sendable {
    public let provider: String
    public let serviceID: String
    public let vaultID: String
    public init(serviceID: String, vaultID: String) throws {
        try SyncV3.validateID(serviceID); try SyncV3.validateID(vaultID)
        provider = "cloudflare-v3"; self.serviceID = serviceID; self.vaultID = vaultID
    }
}

public struct SyncV3EnvelopeContext: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case batch, checkpoint, chunk }
    public let identity: SyncV3Identity
    public let epoch: String
    public let kind: Kind
    public let objectID: String
    public let artifactIDs: [String]

    public init(identity: SyncV3Identity, epoch: String, kind: Kind, objectID: String, artifactIDs: [String] = []) {
        self.identity = identity; self.epoch = epoch; self.kind = kind
        self.objectID = objectID; self.artifactIDs = artifactIDs
    }
    public func associatedData() throws -> Data {
        guard identity.provider == "cloudflare-v3" else { throw SyncV3Error.invalidRequest }
        try [identity.serviceID, identity.vaultID, epoch, objectID].forEach(SyncV3.validateID)
        guard artifactIDs.count <= 512, artifactIDs == artifactIDs.sorted(), Set(artifactIDs).count == artifactIDs.count,
              artifactIDs.allSatisfy({ $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) else {
            throw SyncV3Error.invalidRequest
        }
        return Data(["PindoSync/v3", identity.serviceID, identity.vaultID, epoch, kind.rawValue, objectID, artifactIDs.joined(separator: ",")].joined(separator: "\n").utf8)
    }
}

/// An observed note dot is scoped to that record's note register. Observing a
/// newer title from an actor must never imply observing its earlier note.
public struct SyncV3NoteDot: Codable, Hashable, Sendable {
    public let actorID: String
    public let counter: Int64
    public init(actorID: String, counter: Int64) throws {
        try SyncV3.validateID(actorID); try SyncV3.validateCounter(counter)
        guard counter > 0 else { throw SyncV3Error.invalidRequest }
        self.actorID = actorID; self.counter = counter
    }
}

/// P0 reference register. Keep observed removals even when their writes have not
/// arrived yet. No tombstone/context collection is permitted in the first version.
public struct SyncV3NoteRegister: Equatable, Sendable {
    public private(set) var writes: [SyncV3NoteDot: String] = [:]
    private var contexts: [SyncV3NoteDot: Set<SyncV3NoteDot>] = [:]
    public private(set) var removed: Set<SyncV3NoteDot> = []
    public init() {}
    public var visible: [SyncV3NoteDot: String] { writes.filter { !removed.contains($0.key) } }
    public mutating func apply(dot: SyncV3NoteDot, value: String, observed: Set<SyncV3NoteDot>) throws {
        // Revalidate decoded dots, including those constructed by Codable.
        for item in observed.union([dot]) {
            _ = try SyncV3NoteDot(actorID: item.actorID, counter: item.counter)
        }
        guard !observed.contains(dot), value.utf8.count <= SyncV3.maximumChunkBytes else { throw SyncV3Error.invalidRequest }
        if let old = writes[dot], old != value || contexts[dot] != observed { throw SyncV3Error.corruptData }
        writes[dot] = value; contexts[dot] = observed
        removed.formUnion(observed)
    }
    public mutating func merge(_ other: Self) throws {
        var next = self
        for (dot, value) in other.writes {
            if let old = next.writes[dot], old != value || next.contexts[dot] != other.contexts[dot] { throw SyncV3Error.corruptData }
            next.writes[dot] = value; next.contexts[dot] = other.contexts[dot]
        }
        next.removed.formUnion(other.removed)
        self = next
    }
}
