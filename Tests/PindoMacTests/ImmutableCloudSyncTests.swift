import Foundation
import XCTest
import PindoCore
@testable import Pindo

final class MemorySyncSecrets: SyncSecretStorage {
    var data: Data?
    var rejectWrites = false
    var rejectedSaveNumbers = Set<Int>()
    private(set) var saveCalls = 0

    func load() throws -> Data? { data }
    func save(_ data: Data?) throws {
        saveCalls += 1
        if rejectWrites || rejectedSaveNumbers.contains(saveCalls) { throw CloudSyncError.keychain }
        self.data = data
    }
}

/// Accepted PUTs survive lost responses. Conditional GETs use the version of the
/// actual stored bytes, so tests cannot accidentally cache a different payload.
@MainActor final class MemoryCloudTransport: CloudSyncTransport {
    var objects: [String: Data] = [:]
    var rejectUploads = false
    var loseNextUploadResponses = 0
    var holdDownload = false
    var holdNextUpload = false
    var hideMarkerFromListing = false
    var beforeDownload: ((String) throws -> Void)?
    var afterUpload: ((Data, String) throws -> Void)?
    private(set) var downloadEntered = false
    private(set) var downloadReturned = false
    private(set) var uploadEntered = false
    private var downloadContinuation: CheckedContinuation<Void, Never>?
    private var uploadContinuation: CheckedContinuation<Void, Never>?
    private(set) var listCalls = 0
    private(set) var uploadCalls = 0
    private(set) var uploads: [(key: String, data: Data)] = []
    private(set) var downloads: [String] = []

    var immutableUploads: [(key: String, data: Data)] { uploads.filter { $0.key.contains("/objects/") } }
    func etag(for key: String) -> String? { objects[key].map { "\"\(ImmutableCloudSync.digest($0))\"" } }

    func listHeads(vaultID: String) async throws -> [SyncRemoteHead] {
        listCalls += 1
        let marker = SyncEncryption.migrationMarkerKey(vaultID: vaultID)
        return listing(prefix: "pindo/v1/\(vaultID)/heads/").filter { !hideMarkerFromListing || $0.key != marker }
    }
    func listObjects(vaultID: String) async throws -> [SyncRemoteHead] {
        listCalls += 1
        return listing(prefix: "pindo/v2/\(vaultID)/objects/")
    }
    private func listing(prefix: String) -> [SyncRemoteHead] {
        objects.keys.filter { $0.hasPrefix(prefix) }.sorted().map { SyncRemoteHead(key: $0, etag: etag(for: $0)!) }
    }
    func download(key: String) async throws -> Data { try await read(key: key, expectedETag: nil) }
    func download(key: String, expectedETag: String) async throws -> Data { try await read(key: key, expectedETag: expectedETag) }
    private func read(key: String, expectedETag: String?) async throws -> Data {
        downloadEntered = true; downloads.append(key)
        try beforeDownload?(key)
        guard let data = objects[key] else { throw SyncTransportError.bucketNotFound }
        if let expectedETag, etag(for: key) != expectedETag { throw SyncTransportError.remoteChanged }
        if holdDownload {
            holdDownload = false
            await withCheckedContinuation { downloadContinuation = $0 }
        }
        downloadReturned = true
        if key.contains("/objects/") { try SyncEncryption.validateObject(data: data, key: key, vaultID: String(key.split(separator: "/")[2])) }
        return data
    }
    func upload(data: Data, key: String) async throws {
        uploadCalls += 1; uploadEntered = true; uploads.append((key, data))
        if rejectUploads { throw SyncTransportError.networkUnavailable }
        if key.contains("/objects/") { try SyncEncryption.validateObject(data: data, key: key, vaultID: String(key.split(separator: "/")[2])) }
        if holdNextUpload {
            holdNextUpload = false
            await withCheckedContinuation { uploadContinuation = $0 }
        }
        objects[key] = data
        try afterUpload?(data, key)
        if loseNextUploadResponses > 0 { loseNextUploadResponses -= 1; throw SyncTransportError.networkUnavailable }
    }
    func releaseDownload() {
        let continuation = downloadContinuation; downloadContinuation = nil; continuation?.resume()
    }
    func releaseUpload() {
        let continuation = uploadContinuation; uploadContinuation = nil; continuation?.resume()
    }
}

final class ImmutableCloudSyncTests: XCTestCase {
    private let recoveryKey = String(repeating: "01", count: 32)
    private let configuration = BitifulConfiguration(bucket: "test-bucket")

    @MainActor private func makeRepository() throws -> (PindoRepository, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PindoImmutableTests-\(UUID().uuidString)")
        let repository = try PindoRepository(directory: directory)
        let encryption = try SyncEncryption(recoveryKey: recoveryKey)
        try repository.prepareSync(channelID: ImmutableCloudSync.channelID(configuration: configuration, encryption: encryption))
        return (repository, { try? FileManager.default.removeItem(at: directory) })
    }
    @MainActor private func round(_ repository: PindoRepository, _ transport: MemoryCloudTransport,
                                  allowCreate: Bool = true, check: () throws -> Void = {}) async throws -> Bool {
        try await ImmutableCloudSync.run(repository: repository, encryption: SyncEncryption(recoveryKey: recoveryKey),
            transport: transport, allowCreate: allowCreate, check: check, applied: {}, progress: { _ in })
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Injected operation did not reach its hold point")
        throw CancellationError()
    }
    private func payload(_ tasks: [TodoItem], version: Int = 2, actor: UUID = UUID()) throws -> SyncPayload {
        var replica = SyncReplica(deviceID: actor, version: version)
        try replica.capture(tasks: tasks, groups: [])
        return replica.payload
    }

    @MainActor func testAcceptedPutWithLostResponseRetriesIdenticalBytesAndKey() async throws {
        let (repository, cleanup) = try makeRepository()
        defer { cleanup() }
        let item = TodoItem(title: "Durable pending upload")
        try repository.update { $0.tasks.append(item) }
        let transport = MemoryCloudTransport(); transport.loseNextUploadResponses = 1
        do { _ = try await round(repository, transport); XCTFail("The unknown upload outcome must remain pending") }
        catch { XCTAssertEqual(error as? SyncTransportError, .networkUnavailable) }
        let frozen = try XCTUnwrap(repository.syncSession?.pendingObject)
        XCTAssertEqual(transport.objects[frozen.key], frozen.data)
        XCTAssertEqual(try PindoRepository(directory: repository.directory).syncSession?.pendingObject, frozen)
        let complete = try await round(repository, transport)
        XCTAssertTrue(complete)
        XCTAssertEqual(transport.immutableUploads.count, 2)
        XCTAssertEqual(transport.immutableUploads[0].key, transport.immutableUploads[1].key)
        XCTAssertEqual(transport.immutableUploads[0].data, transport.immutableUploads[1].data)
        XCTAssertNil(repository.syncSession?.pendingObject)
        XCTAssertEqual(repository.document.tasks.first?.id, item.id)
    }

    @MainActor func testEditsDuringEachUploadCannotBeClearedByAnOlderAcknowledgement() async throws {
        let (repository, cleanup) = try makeRepository()
        defer { cleanup() }
        let item = TodoItem(title: "Initial")
        try repository.update { $0.tasks.append(item) }
        let transport = MemoryCloudTransport()
        var edits = 0
        transport.afterUpload = { _, key in
            guard key.contains("/objects/") else { return }
            edits += 1
            try repository.update { $0.tasks[0].title = "Edit \(edits)" }
        }
        let complete = try await round(repository, transport)
        XCTAssertFalse(complete)
        XCTAssertEqual(edits, 2)
        XCTAssertEqual(repository.document.tasks.first?.title, "Edit 2")
        XCTAssertNotEqual(repository.syncSession?.acknowledgedPayloadDigest,
                          ImmutableCloudSync.digest(try DocumentCodec.encode(XCTUnwrap(repository.syncPayload))))
        XCTAssertFalse(transport.objects.keys.contains(SyncEncryption.migrationMarkerKey(vaultID: try SyncEncryption(recoveryKey: recoveryKey).vaultID)))
        transport.afterUpload = nil
        let retried = try await round(repository, transport)
        XCTAssertTrue(retried)
        XCTAssertEqual(repository.syncSession?.acknowledgedPayloadDigest,
                       ImmutableCloudSync.digest(try DocumentCodec.encode(XCTUnwrap(repository.syncPayload))))
    }

    @MainActor func testADeletedAcknowledgedObjectIsRepublishedWithoutDiscardingLocalState() async throws {
        let (repository, cleanup) = try makeRepository()
        defer { cleanup() }
        try repository.update { $0.tasks.append(TodoItem(title: "Recover missing cloud object")) }
        let transport = MemoryCloudTransport()
        let first = try await round(repository, transport)
        XCTAssertTrue(first)
        let missing = try XCTUnwrap(repository.syncSession?.acknowledgedObjectKey)
        transport.objects.removeValue(forKey: missing)
        let second = try await round(repository, transport, allowCreate: false)
        XCTAssertTrue(second)
        let restored = try XCTUnwrap(repository.syncSession?.acknowledgedObjectKey)
        XCTAssertNotEqual(restored, missing)
        XCTAssertNotNil(transport.objects[restored])
        XCTAssertEqual(repository.document.tasks.first?.title, "Recover missing cloud object")
    }

    @MainActor func testALateCancelledPutCannotOverwriteTheNewerImmutableObject() async throws {
        let (repository, cleanup) = try makeRepository()
        defer { cleanup() }
        try repository.update { $0.tasks.append(TodoItem(title: "Before delayed PUT")) }
        let transport = MemoryCloudTransport(); transport.holdNextUpload = true
        var current = true
        let old = Task { @MainActor in
            try await self.round(repository, transport, check: { if !current { throw CancellationError() } })
        }
        defer { transport.releaseUpload() }
        try await waitUntil { transport.uploadEntered }
        let oldPending = try XCTUnwrap(repository.syncSession?.pendingObject)
        current = false
        try repository.update { $0.tasks[0].title = "After delayed PUT" }
        let finished = try await round(repository, transport)
        XCTAssertTrue(finished)
        let latest = try XCTUnwrap(repository.syncSession?.acknowledgedObjectKey)
        let latestBytes = try XCTUnwrap(transport.objects[latest])
        XCTAssertNotEqual(latest, oldPending.key)
        transport.releaseUpload()
        do { _ = try await old.value; XCTFail("The cancelled generation must not acknowledge or apply") }
        catch is CancellationError {}
        XCTAssertEqual(transport.objects[latest], latestBytes)
        XCTAssertEqual(transport.objects[oldPending.key], oldPending.data)
        XCTAssertEqual(repository.syncSession?.acknowledgedObjectKey, latest)
        XCTAssertEqual(repository.document.tasks.first?.title, "After delayed PUT")
    }

    @MainActor func testARealV1WriterAtTheReservedMarkerPathIsNeverOverwritten() async throws {
        let (repository, cleanup) = try makeRepository()
        defer { cleanup() }
        let encryption = try SyncEncryption(recoveryKey: recoveryKey), marker = SyncEncryption.migrationMarkerKey(vaultID: encryption.vaultID)
        let occupied = try encryption.seal(DocumentCodec.encode(payload([TodoItem(title: "Reserved legacy writer")], version: 1)))
        for hidden in [false, true] {
            let transport = MemoryCloudTransport(); transport.objects[marker] = occupied; transport.hideMarkerFromListing = hidden
            do { _ = try await round(repository, transport); XCTFail("A v1 writer cannot be used as the upgrade checkpoint") }
            catch { XCTAssertEqual(error as? CloudSyncError, .migrationCollision) }
            XCTAssertEqual(transport.objects[marker], occupied)
            XCTAssertFalse(transport.uploads.contains { $0.key == marker })
        }
    }

    @MainActor func testConcurrentValidMarkerCheckpointsAreMergedBeforeClaimingSuccess() async throws {
        let (repository, cleanup) = try makeRepository()
        defer { cleanup() }
        let encryption = try SyncEncryption(recoveryKey: recoveryKey), marker = SyncEncryption.migrationMarkerKey(vaultID: encryption.vaultID)
        let remote = TodoItem(title: "Concurrent migration")
        let checkpoint = try encryption.sealV2(DocumentCodec.encode(payload([remote])))
        let transport = MemoryCloudTransport()
        transport.afterUpload = { _, key in if key == marker { transport.objects[marker] = checkpoint } }
        let complete = try await round(repository, transport)
        XCTAssertFalse(complete)
        XCTAssertTrue(repository.document.tasks.contains { $0.id == remote.id })
        XCTAssertEqual(transport.objects[marker], checkpoint)
        transport.afterUpload = nil
        let retried = try await round(repository, transport)
        XCTAssertTrue(retried)
    }

    @MainActor func testAnEditingLeaseDuringDownloadPreventsApplyAndCacheCommit() async throws {
        let (repository, cleanup) = try makeRepository()
        defer { cleanup() }
        let suite = "PindoEditingLease.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = try AppModel(directory: repository.directory, defaults: defaults)
        let leasedRepository = model.repository
        let encryption = try SyncEncryption(recoveryKey: recoveryKey)
        let remote = TodoItem(title: "Deferred while editing")
        let bytes = try encryption.sealV2(DocumentCodec.encode(payload([remote])))
        let key = SyncEncryption.objectKey(vaultID: encryption.vaultID, encryptedData: bytes)
        let transport = MemoryCloudTransport(); transport.objects[key] = bytes; transport.holdDownload = true
        let operation = Task { @MainActor in
            try await self.round(leasedRepository, transport, check: { if model.isSyncEditing { throw CloudSyncError.editing } })
        }
        defer { transport.releaseDownload() }
        try await waitUntil { transport.downloadEntered }
        let token = try XCTUnwrap(model.acquireSyncEditing())
        XCTAssertTrue(model.isSyncEditing)
        transport.releaseDownload()
        do { _ = try await operation.value; XCTFail("Editing must reject the in-flight apply") }
        catch { XCTAssertEqual(error as? CloudSyncError, .editing) }
        XCTAssertFalse(leasedRepository.document.tasks.contains { $0.id == remote.id })
        XCTAssertTrue(leasedRepository.syncSession?.acknowledgedObjects.isEmpty == true)
        XCTAssertTrue(leasedRepository.syncSession?.legacyETags.isEmpty == true)
        XCTAssertEqual(transport.uploadCalls, 0)
        model.releaseSyncEditing(token)
        XCTAssertFalse(model.isSyncEditing)
        let retried = try await round(leasedRepository, transport)
        XCTAssertTrue(retried); XCTAssertTrue(leasedRepository.document.tasks.contains { $0.id == remote.id })
    }

    @MainActor func testAHundredLegacyWritersAndTheMarkerRemainSynchronizable() async throws {
        let (repository, cleanup) = try makeRepository()
        defer { cleanup() }
        let encryption = try SyncEncryption(recoveryKey: recoveryKey), transport = MemoryCloudTransport()
        for index in 1...100 {
            let actor = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index)))
            let bytes = try encryption.seal(DocumentCodec.encode(payload([TodoItem(title: "Legacy \(index)")], version: 1, actor: actor)))
            transport.objects[SyncEncryption.headKey(vaultID: encryption.vaultID, deviceID: actor)] = bytes
        }
        let migrated = try await round(repository, transport, allowCreate: false)
        XCTAssertTrue(migrated); XCTAssertEqual(repository.document.tasks.count, 100)
        let firstUploads = transport.immutableUploads.count
        let heads = try await transport.listHeads(vaultID: encryption.vaultID)
        XCTAssertEqual(heads.count, 101)
        let repeated = try await round(repository, transport, allowCreate: false)
        XCTAssertTrue(repeated); XCTAssertEqual(repository.document.tasks.count, 100)
        XCTAssertEqual(transport.immutableUploads.count, firstUploads)
    }

    @MainActor func testARacedLegacyReadCannotAdvanceTheDurableETagCache() async throws {
        let (repository, cleanup) = try makeRepository()
        defer { cleanup() }
        let encryption = try SyncEncryption(recoveryKey: recoveryKey), transport = MemoryCloudTransport()
        let actor = UUID(), original = TodoItem(title: "Old remote title")
        var replica = SyncReplica(deviceID: actor)
        try replica.capture(tasks: [original], groups: [])
        let key = SyncEncryption.headKey(vaultID: encryption.vaultID, deviceID: actor)
        transport.objects[key] = try encryption.seal(DocumentCodec.encode(replica.payload))
        let listedETag = try XCTUnwrap(transport.etag(for: key))
        var raced = false
        transport.beforeDownload = { requested in
            guard requested == key, !raced else { return }
            raced = true
            var changed = original; changed.title = "New remote title"
            try replica.capture(tasks: [changed], groups: [])
            transport.objects[key] = try encryption.seal(DocumentCodec.encode(replica.payload))
        }
        defer { transport.beforeDownload = nil }
        do { _ = try await round(repository, transport); XCTFail("An object that changed after LIST must be retried") }
        catch { XCTAssertEqual(error as? SyncTransportError, .remoteChanged) }
        XCTAssertTrue(repository.document.tasks.isEmpty)
        XCTAssertTrue(repository.syncSession?.legacyETags.isEmpty == true)
        XCTAssertEqual(transport.uploadCalls, 0)
        transport.beforeDownload = nil
        let retried = try await round(repository, transport)
        XCTAssertTrue(retried)
        XCTAssertEqual(repository.document.tasks.first?.title, "New remote title")
        XCTAssertEqual(repository.syncSession?.legacyETags[key], transport.etag(for: key))
        XCTAssertNotEqual(repository.syncSession?.legacyETags[key], listedETag)
    }

    @MainActor func testAMalformedLaterInputCannotCommitAnEarlierPayloadOrItsCache() async throws {
        let (repository, cleanup) = try makeRepository()
        defer { cleanup() }
        let encryption = try SyncEncryption(recoveryKey: recoveryKey), transport = MemoryCloudTransport()
        let firstActor = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let lastActor = try XCTUnwrap(UUID(uuidString: "ffffffff-ffff-ffff-ffff-fffffffffff0"))
        let firstKey = SyncEncryption.headKey(vaultID: encryption.vaultID, deviceID: firstActor)
        let lastKey = SyncEncryption.headKey(vaultID: encryption.vaultID, deviceID: lastActor)
        transport.objects[firstKey] = try encryption.seal(DocumentCodec.encode(payload([TodoItem(title: "Must remain staged")], version: 1, actor: firstActor)))
        transport.objects[lastKey] = Data("malformed encrypted object".utf8)
        do { _ = try await round(repository, transport); XCTFail("Invalid input must leave the whole candidate batch uncommitted") }
        catch { XCTAssertEqual(error as? SyncTransportError, .invalidEncryptedData) }
        XCTAssertEqual(Array(transport.downloads.prefix(2)), [firstKey, lastKey])
        XCTAssertTrue(repository.document.tasks.isEmpty)
        XCTAssertTrue(repository.syncSession?.legacyETags.isEmpty == true)
        XCTAssertTrue(repository.syncSession?.acknowledgedObjects.isEmpty == true)
        XCTAssertEqual(transport.uploadCalls, 0)
    }
}
