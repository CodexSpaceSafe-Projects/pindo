import Foundation

/// Durable encrypted bytes are retried verbatim; a later edit must not replace an in-flight object.
public struct SyncPendingObject: Codable, Equatable, Sendable {
    public var key: String
    public var data: Data
    public var payloadDigest: String
    public init(key: String, data: Data, payloadDigest: String) {
        self.key = key; self.data = data; self.payloadDigest = payloadDigest
    }
}

/// Installation-local acknowledgement and connection state, excluded from exports and snapshots.
public struct SyncSessionState: Codable, Equatable, Sendable {
    public static let maximumChannels = 8
    public var channelID: String
    public var pendingObject: SyncPendingObject?
    public var acknowledgedObjects: [String]
    public var legacyETags: [String: String]
    public var objectETags: [String: String]
    public var acknowledgedPayloadDigest: String?
    public var acknowledgedObjectKey: String?
    public var connectionTransaction: String?

    public init(channelID: String, pendingObject: SyncPendingObject? = nil, acknowledgedObjects: [String] = [],
                legacyETags: [String: String] = [:], objectETags: [String: String] = [:], acknowledgedPayloadDigest: String? = nil,
                acknowledgedObjectKey: String? = nil, connectionTransaction: String? = nil) {
        self.channelID = channelID; self.pendingObject = pendingObject; self.acknowledgedObjects = acknowledgedObjects
        self.legacyETags = legacyETags; self.objectETags = objectETags; self.acknowledgedPayloadDigest = acknowledgedPayloadDigest
        self.acknowledgedObjectKey = acknowledgedObjectKey; self.connectionTransaction = connectionTransaction
    }

    private enum CodingKeys: String, CodingKey {
        case channelID, pendingObject, acknowledgedObjects, legacyETags, objectETags
        case acknowledgedPayloadDigest, acknowledgedObjectKey, connectionTransaction
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        channelID = try values.decode(String.self, forKey: .channelID)
        pendingObject = try values.decodeIfPresent(SyncPendingObject.self, forKey: .pendingObject)
        acknowledgedObjects = try values.decodeIfPresent([String].self, forKey: .acknowledgedObjects) ?? []
        legacyETags = try values.decodeIfPresent([String: String].self, forKey: .legacyETags) ?? [:]
        objectETags = try values.decodeIfPresent([String: String].self, forKey: .objectETags) ?? [:]
        acknowledgedPayloadDigest = try values.decodeIfPresent(String.self, forKey: .acknowledgedPayloadDigest)
        acknowledgedObjectKey = try values.decodeIfPresent(String.self, forKey: .acknowledgedObjectKey)
        connectionTransaction = try values.decodeIfPresent(String.self, forKey: .connectionTransaction)
    }

    @discardableResult public func validated() throws -> Self {
        guard validSyncMetadata(channelID, maximumBytes: 1024), acknowledgedObjects.count <= 10_000,
              Set(acknowledgedObjects).count == acknowledgedObjects.count,
              acknowledgedObjects.allSatisfy({ validSyncMetadata($0, maximumBytes: 2048) }),
              legacyETags.count <= 101,
              legacyETags.allSatisfy({ validSyncMetadata($0.key, maximumBytes: 2048) && validSyncMetadata($0.value, maximumBytes: 1024) }),
              objectETags.count <= 10_000,
              objectETags.allSatisfy({ validSyncMetadata($0.key, maximumBytes: 2048) && validSyncMetadata($0.value, maximumBytes: 1024) }),
              acknowledgedPayloadDigest.map(validSyncDigest) ?? true,
              acknowledgedObjectKey.map({ validSyncMetadata($0, maximumBytes: 2048) }) ?? true,
              (acknowledgedPayloadDigest == nil) == (acknowledgedObjectKey == nil),
              connectionTransaction.map({ validSyncMetadata($0, maximumBytes: 1024) }) ?? true else {
            throw PindoError.invalidData("同步会话资料无效")
        }
        if let pending = pendingObject {
            guard validSyncMetadata(pending.key, maximumBytes: 2048), validSyncDigest(pending.payloadDigest),
                  !pending.data.isEmpty, pending.data.count <= 10 * 1024 * 1024 else { throw PindoError.invalidData("待上传同步资料无效") }
        }
        return self
    }
}

public struct SyncChannelArchive: Codable, Equatable, Sendable {
    public var tasks: [TodoItem]
    public var groups: [TaskGroup]
    public var syncState: SyncReplica
    public var syncSession: SyncSessionState
    public init(tasks: [TodoItem], groups: [TaskGroup], syncState: SyncReplica, syncSession: SyncSessionState) {
        self.tasks = tasks; self.groups = groups; self.syncState = syncState; self.syncSession = syncSession
    }
    @discardableResult public func validated() throws -> Self {
        var document = PindoDocument()
        document.tasks = tasks; document.groups = groups; document.syncState = syncState; document.syncSession = syncSession
        _ = try document.validated()
        return self
    }
}

private func validSyncMetadata(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumBytes && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
}
private func validSyncDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
