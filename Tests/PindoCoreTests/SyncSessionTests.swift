import XCTest
@testable import PindoCore

final class SyncSessionTests: XCTestCase {
    private let digestA = String(repeating: "a", count: 64)
    private let digestB = String(repeating: "b", count: 64)
    private let actorA = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let actorB = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let actorC = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!

    private func makeRepository(io: MemoryStorage) throws -> PindoRepository {
        var document = PindoDocument(); document.groups = []
        document.tasks = [TodoItem(title: "Local task", now: Date(timeIntervalSinceReferenceDate: 0))]
        return try PindoRepository(directory: URL(fileURLWithPath: "/sync-session-\(UUID().uuidString)"), io: io, initialDocument: document)
    }

    func testReconnectPreservesSameChannelHistoryPendingBytesAndTransactions() throws {
        let io = MemoryStorage(), repository = try makeRepository(io: io)
        try repository.prepareSync(channelID: "channel-A", preserveLegacy: false, actorID: actorA, transactionID: "transaction-A")
        try repository.stageSyncUpload(key: "object-A", data: Data("encrypted-A".utf8), payloadDigest: digestA)
        let before = repository.document
        try repository.prepareSync(channelID: "channel-A", preserveLegacy: false, actorID: actorB, transactionID: "transaction-B")
        XCTAssertEqual(repository.syncPayload, before.syncState?.payload)
        XCTAssertEqual(repository.document.tasks, before.tasks)
        XCTAssertEqual(repository.syncSession?.pendingObject, before.syncSession?.pendingObject)
        XCTAssertEqual(repository.syncSession?.connectionTransaction, "transaction-B")
        XCTAssertEqual(repository.syncState?.deviceID, actorB.uuidString.lowercased())
        XCTAssertEqual(repository.syncPayload?.version, 2)
        let reopened = try PindoRepository(directory: repository.directory, io: io)
        XCTAssertEqual(reopened.document, repository.document)
    }

    func testOutboxWriteAndAcknowledgementFailuresAreAtomicAndDoNotClearNewEdits() throws {
        let io = MemoryStorage(), repository = try makeRepository(io: io)
        try repository.prepareSync(channelID: "channel-A", actorID: actorA)
        let before = repository.document, originalBytes = io.files[repository.dataURL]
        io.failNextWriteTo = repository.dataURL
        XCTAssertThrowsError(try repository.stageSyncUpload(key: "object-A", data: Data("encrypted-A".utf8), payloadDigest: digestA))
        XCTAssertEqual(repository.document, before); XCTAssertEqual(io.files[repository.dataURL], originalBytes)
        try repository.stageSyncUpload(key: "object-A", data: Data("encrypted-A".utf8), payloadDigest: digestA)
        let pendingBytes = repository.syncSession?.pendingObject?.data
        try repository.update { $0.tasks[0].title = "Edited while uploading" }
        XCTAssertThrowsError(try repository.stageSyncUpload(key: "object-B", data: Data("encrypted-B".utf8), payloadDigest: digestB))
        XCTAssertThrowsError(try repository.acknowledgeSyncUpload(key: "object-A", payloadDigest: digestB))
        let pending = repository.document, pendingDisk = io.files[repository.dataURL]
        io.failNextWriteTo = repository.dataURL
        XCTAssertThrowsError(try repository.acknowledgeSyncUpload(key: "object-A", payloadDigest: digestA))
        XCTAssertEqual(repository.document, pending); XCTAssertEqual(io.files[repository.dataURL], pendingDisk)
        XCTAssertEqual(repository.syncSession?.pendingObject?.data, pendingBytes)
        try repository.acknowledgeSyncUpload(key: "object-A", payloadDigest: digestA)
        XCTAssertNil(repository.syncSession?.pendingObject)
        XCTAssertEqual(repository.syncSession?.acknowledgedPayloadDigest, digestA)
        XCTAssertEqual(repository.syncSession?.acknowledgedObjectKey, "object-A")
        XCTAssertEqual(repository.syncSession?.acknowledgedObjects, ["object-A"])
        XCTAssertEqual(repository.document.tasks[0].title, "Edited while uploading")
        XCTAssertEqual(try PindoRepository(directory: repository.directory, io: io).document, repository.document)
    }

    func testRemoteCacheAndProjectionCommitTogether() throws {
        let io = MemoryStorage(), repository = try makeRepository(io: io)
        try repository.prepareSync(channelID: "channel-A", actorID: actorA)
        var remote = try XCTUnwrap(repository.syncState)
        try remote.rotateActor(actorB)
        var tasks = repository.document.tasks; tasks[0].title = "Remote task edit"
        try remote.capture(tasks: tasks, groups: repository.document.groups)
        let before = repository.document, disk = io.files[repository.dataURL]
        io.failNextWriteTo = repository.dataURL
        XCTAssertThrowsError(try repository.applySync(remote.payload, acknowledgedObjects: ["remote-object"], legacyETags: ["legacy-head": "etag-A"]))
        XCTAssertEqual(repository.document, before); XCTAssertEqual(io.files[repository.dataURL], disk)
        try repository.applySync(remote.payload, acknowledgedObjects: ["remote-object"], legacyETags: ["legacy-head": "etag-A"])
        XCTAssertEqual(repository.document.tasks[0].title, "Remote task edit")
        XCTAssertEqual(repository.syncSession?.acknowledgedObjects, ["remote-object"])
        XCTAssertEqual(repository.syncSession?.legacyETags, ["legacy-head": "etag-A"])
        XCTAssertEqual(try PindoRepository(directory: repository.directory, io: io).document, repository.document)
    }

    func testCacheSnapshotsPruneMissingObjectsOnlyAfterTheirAtomicCommit() throws {
        let io = MemoryStorage(), repository = try makeRepository(io: io)
        try repository.prepareSync(channelID: "channel-A", actorID: actorA)
        let empty = SyncPayload(version: 2)
        try repository.applySync(empty, acknowledgedObjects: ["one", "two"], legacyETags: ["old-one": "etag-1", "old-two": "etag-2"])
        let before = repository.document, disk = io.files[repository.dataURL]
        io.failNextWriteTo = repository.dataURL
        XCTAssertThrowsError(try repository.applySync(empty, acknowledgedObjects: ["two"], legacyETags: ["old-two": "etag-2"]))
        XCTAssertEqual(repository.document, before); XCTAssertEqual(io.files[repository.dataURL], disk)
        try repository.applySync(empty, acknowledgedObjects: ["two"], legacyETags: ["old-two": "etag-2"])
        XCTAssertEqual(repository.syncSession?.acknowledgedObjects, ["two"])
        XCTAssertEqual(repository.syncSession?.legacyETags, ["old-two": "etag-2"])
        let cached = repository.syncSession
        try repository.applySync(empty)
        XCTAssertEqual(repository.syncSession, cached)
    }

    func testChangedObjectETagsCommitAtomicallyAndCanBePruned() throws {
        let io = MemoryStorage(), repository = try makeRepository(io: io)
        try repository.prepareSync(channelID: "channel-A", actorID: actorA)
        let empty = SyncPayload(version: 2)
        try repository.applySync(empty, acknowledgedObjects: ["object-A"], objectETags: ["object-A": "etag-old"])
        let before = repository.document, disk = io.files[repository.dataURL]
        io.failNextWriteTo = repository.dataURL
        XCTAssertThrowsError(try repository.applySync(empty, acknowledgedObjects: ["object-A"], objectETags: ["object-A": "etag-changed"]))
        XCTAssertEqual(repository.document, before); XCTAssertEqual(io.files[repository.dataURL], disk)
        try repository.applySync(empty, acknowledgedObjects: ["object-A"], objectETags: ["object-A": "etag-changed"])
        XCTAssertEqual(repository.syncSession?.objectETags, ["object-A": "etag-changed"])
        try repository.applySync(empty)
        XCTAssertEqual(repository.syncSession?.objectETags, ["object-A": "etag-changed"])
        try repository.applySync(empty, objectETags: [:])
        XCTAssertEqual(repository.syncSession?.objectETags, [:])
        XCTAssertEqual(repository.syncSession?.acknowledgedObjects, ["object-A"])
        XCTAssertEqual(try PindoRepository(directory: repository.directory, io: io).syncSession, repository.syncSession)
    }

    func testOlderLocalSessionsWithoutObjectETagsDecodeAsAnUnverifiedCache() throws {
        let session = SyncSessionState(channelID: "channel-A", acknowledgedObjects: ["object-A"])
        var values = try XCTUnwrap(JSONSerialization.jsonObject(with: DocumentCodec.encode(session)) as? [String: Any])
        values.removeValue(forKey: "objectETags")
        let decoded = try DocumentCodec.decode(SyncSessionState.self, from: JSONSerialization.data(withJSONObject: values)).validated()
        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.objectETags, [:])
    }

    func testReturningToAnArchivedChannelRestoresItsOwnDataHistoryAndOutbox() throws {
        let io = MemoryStorage(), repository = try makeRepository(io: io)
        try repository.prepareSync(channelID: "channel-A", actorID: actorA)
        try repository.update { $0.tasks[0].title = "A's task" }
        try repository.stageSyncUpload(key: "object-A", data: Data("A's encrypted bytes".utf8), payloadDigest: digestA)
        let aPayload = repository.syncPayload, aSession = repository.syncSession
        try repository.prepareSync(channelID: "channel-B", actorID: actorB)
        try repository.update { $0.tasks[0].title = "B's different task" }
        try repository.stageSyncUpload(key: "object-B", data: Data("B's encrypted bytes".utf8), payloadDigest: digestB)
        let bPayload = repository.syncPayload, bSession = repository.syncSession
        try repository.prepareSync(channelID: "channel-A", actorID: actorC)
        XCTAssertEqual(repository.document.tasks[0].title, "A's task")
        XCTAssertEqual(repository.syncPayload, aPayload)
        XCTAssertEqual(repository.syncSession?.pendingObject, aSession?.pendingObject)
        XCTAssertEqual(repository.document.syncChannels?["channel-B"]?.syncState.payload, bPayload)
        XCTAssertEqual(repository.document.syncChannels?["channel-B"]?.syncSession, bSession)
        XCTAssertNil(repository.document.syncChannels?["channel-A"])
        XCTAssertEqual(repository.syncState?.deviceID, actorC.uuidString.lowercased())
    }

    func testSwitchFailureAndArchiveCapacityNeverOverwriteTheActiveChannel() throws {
        let io = MemoryStorage(), repository = try makeRepository(io: io)
        try repository.prepareSync(channelID: "channel-0", actorID: actorA)
        let before = repository.document, disk = io.files[repository.dataURL]
        io.failNextWriteTo = repository.dataURL
        XCTAssertThrowsError(try repository.prepareSync(channelID: "channel-failed", actorID: actorB, transactionID: "uncommitted"))
        XCTAssertEqual(repository.document, before); XCTAssertEqual(io.files[repository.dataURL], disk)
        for index in 1..<SyncSessionState.maximumChannels { try repository.prepareSync(channelID: "channel-\(index)") }
        let full = repository.document, fullDisk = io.files[repository.dataURL]
        XCTAssertThrowsError(try repository.prepareSync(channelID: "channel-overflow"))
        XCTAssertEqual(repository.document, full); XCTAssertEqual(io.files[repository.dataURL], fullDisk)
        try repository.prepareSync(channelID: "channel-0")
        XCTAssertEqual(repository.syncSession?.channelID, "channel-0")
        XCTAssertEqual(repository.document.syncChannels?.count, SyncSessionState.maximumChannels - 1)
    }

    func testStartupActorRotationProtectsDisconnectedClonesAndFailsClosedOnWriteFailure() throws {
        let io = MemoryStorage(), repository = try makeRepository(io: io)
        try repository.prepareSync(channelID: "channel-A", actorID: actorA)
        try repository.stageSyncUpload(key: "object-A", data: Data("old pending bytes".utf8), payloadDigest: digestA)
        let cloneIO = MemoryStorage(); cloneIO.files = io.files
        let clone = try PindoRepository(directory: repository.directory, io: cloneIO)
        let before = repository.document
        io.failNextWriteTo = repository.dataURL
        XCTAssertThrowsError(try repository.beginSyncSession(actorID: actorB))
        XCTAssertEqual(repository.document, before)
        try repository.beginSyncSession(actorID: actorB)
        try clone.beginSyncSession(actorID: actorC)
        XCTAssertEqual(repository.syncSession?.pendingObject, before.syncSession?.pendingObject)
        try repository.update { $0.tasks[0].title = "Offline clone B" }
        try clone.update { $0.tasks[0].title = "Offline clone C" }
        let aPayload = try XCTUnwrap(repository.syncPayload), bPayload = try XCTUnwrap(clone.syncPayload)
        XCTAssertNoThrow(try aPayload.merging(bPayload))
        XCTAssertEqual(try aPayload.merging(bPayload), try bPayload.merging(aPayload))
    }

    func testSyncMetadataDoesNotCreateSnapshotsOrEscapeExportsAndForeignImports() throws {
        let io = MemoryStorage(), repository = try makeRepository(io: io)
        try repository.prepareSync(channelID: "channel-A", actorID: actorA)
        // Semantic v1-to-v2 normalization happens once; session-only changes do not.
        _ = try repository.captureIfChanged()
        let baseline = try repository.document.snapshotValue()
        try repository.stageSyncUpload(key: "object-A", data: Data("private encrypted bytes".utf8), payloadDigest: digestA)
        try repository.acknowledgeSyncUpload(key: "object-A", payloadDigest: digestA)
        try repository.beginSyncSession(actorID: actorB)
        XCTAssertEqual(try repository.document.snapshotValue(), baseline)
        XCTAssertFalse(try repository.captureIfChanged())
        try repository.prepareSync(channelID: "channel-B", actorID: actorC)
        let session = repository.syncSession, archives = repository.document.syncChannels
        let exported = try repository.exportDocument()
        let text = String(decoding: exported, as: UTF8.self)
        XCTAssertFalse(text.contains("syncState")); XCTAssertFalse(text.contains("syncSession")); XCTAssertFalse(text.contains("syncChannels"))
        let backup = String(decoding: try repository.exportSnapshots(), as: UTF8.self)
        XCTAssertFalse(backup.contains("syncSession")); XCTAssertFalse(backup.contains("syncChannels"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        object["syncSession"] = ["malformed": true]; object["syncChannels"] = ["foreign": ["malformed": true]]
        try repository.importDocument(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(repository.syncSession, session); XCTAssertEqual(repository.document.syncChannels, archives)
        XCTAssertEqual(repository.syncState?.deviceID, actorC.uuidString.lowercased())
    }

    func testRestorePreservesChannelBindingAndRecordsAnExplicitResurrection() throws {
        let io = MemoryStorage(), repository = try makeRepository(io: io)
        try repository.prepareSync(channelID: "channel-A", actorID: actorA)
        try repository.update { $0.tasks[0].title = "Snapshot task" }
        _ = try repository.captureIfChanged()
        let snapshot = try XCTUnwrap(repository.archive.records.last?.id), id = repository.document.tasks[0].id
        try repository.update { _ = try $0.applyBatch(.delete, to: [id]) }
        let session = repository.syncSession
        try repository.restore(snapshotID: snapshot)
        XCTAssertEqual(repository.syncSession, session)
        XCTAssertEqual(repository.document.tasks[0].title, "Snapshot task")
        XCTAssertEqual(repository.syncPayload?.records["task:\(id.uuidString.lowercased())"]?.fields["$alive"]?.value, .bool(true))
    }

    func testLegacyMigrationRecordsAKnownDerivedMarkerAsANewAtomicEvent() throws {
        let io = MemoryStorage(), repository = try makeRepository(io: io)
        try repository.update {
            $0.tasks[0].phase = .inProgress
            $0.tasks[0].startedAt = Date(timeIntervalSinceReferenceDate: 10)
            $0.tasks[0].isProgressExplicit = false
        }
        try repository.enableSync(deviceID: actorA)
        let legacyClock = try XCTUnwrap(repository.syncState?.clock)
        try repository.prepareSync(channelID: "legacy-channel", preserveLegacy: true, actorID: actorB)
        let fields = try XCTUnwrap(repository.syncPayload?.records.values.first?.fields)
        guard case .object(let life) = fields["lifecycle"]?.value else { return XCTFail("A known derived marker must not become unknown legacy intent") }
        XCTAssertEqual(life["isProgressExplicit"], .bool(false))
        XCTAssertGreaterThan(try XCTUnwrap(repository.syncState?.clock), legacyClock)
        XCTAssertEqual(fields["lifecycle"]?.stamp.deviceID, actorB.uuidString.lowercased())
    }
}
