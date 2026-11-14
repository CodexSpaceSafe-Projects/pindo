import Foundation
import XCTest
import PindoCore
@testable import Pindo

private struct SyncTestConnection: Codable {
    var configuration: BitifulConfiguration
    var credentials: BitifulCredentials
    var recoveryKey: String
    var createIfMissing: Bool? = true
}

private struct SyncTestJournal: Codable {
    var version = 2
    var active: SyncTestConnection?
    var pending: SyncTestConnection?
    var transactionID: String?
}

final class CloudSyncControllerTests: XCTestCase {
    private let recoveryKey = String(repeating: "01", count: 32)
    private let credentials = BitifulCredentials(accessKey: "test-access-key", secretKey: "test-secret-key")
    private let configuration = BitifulConfiguration(bucket: "test-bucket")

    @MainActor private func makeModel() throws -> (AppModel, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PindoSyncTests-\(UUID().uuidString)")
        let suite = "PindoSyncTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = try AppModel(directory: directory, defaults: defaults)
        model.playFeedback = { _ in }
        return (model, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    @MainActor private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the injected sync operation", file: file, line: line)
        throw CancellationError()
    }

    @MainActor private func remotePayload(in model: AppModel) throws -> (SyncPayload, UUID, String) {
        let repository = try PindoRepository(directory: model.repository.directory.appendingPathComponent("remote-fixture"))
        let item = TodoItem(title: "Remote task", note: "Remote note")
        try repository.update { $0.tasks.append(item) }
        try repository.enableSync()
        return (try XCTUnwrap(repository.syncPayload), item.id, try XCTUnwrap(repository.syncState?.deviceID))
    }

    @MainActor func testFailedCredentialSaveLeavesPreviousConnectionAndIdentityIntact() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        let storage = MemorySyncSecrets()
        let transport = MemoryCloudTransport()
        let controller = CloudSyncController(model: model, storage: storage, makeTransport: { _, _ in transport })
        defer { storage.rejectWrites = false; try? controller.disconnect() }

        try controller.configure(configuration: configuration, credentials: credentials, recoveryKey: recoveryKey, createIfMissing: true)
        try await waitUntil { !controller.isSyncing }
        let savedCredentials = try XCTUnwrap(storage.data)
        let deviceID = try XCTUnwrap(model.repository.syncState?.deviceID)
        let uploads = transport.uploadCalls
        storage.rejectWrites = true

        do {
            try controller.configure(configuration: BitifulConfiguration(bucket: "other-bucket"),
                                     credentials: credentials, recoveryKey: recoveryKey, createIfMissing: true)
        } catch { XCTAssertEqual(error as? CloudSyncError, .keychain) }
        try await waitUntil { !controller.isSyncing }
        XCTAssertTrue(controller.isConfigured)
        XCTAssertEqual(controller.configuration, configuration)
        XCTAssertEqual(storage.data, savedCredentials)
        XCTAssertEqual(model.repository.syncState?.deviceID, deviceID)
        XCTAssertEqual(transport.uploadCalls, uploads)
    }

    @MainActor func testOfflineUploadPreservesLocalEditsAndRetriesLatestPayload() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        XCTAssertTrue(model.addTask(title: "First offline task", day: DayKey(), groupID: nil))
        let storage = MemorySyncSecrets()
        let transport = MemoryCloudTransport()
        transport.rejectUploads = true
        let controller = CloudSyncController(model: model, storage: storage, makeTransport: { _, _ in transport })
        defer { try? controller.disconnect() }

        try controller.configure(configuration: configuration, credentials: credentials, recoveryKey: recoveryKey, createIfMissing: true)
        try await waitUntil { !controller.isSyncing }
        XCTAssertEqual(transport.uploadCalls, 1)
        let frozen = try XCTUnwrap(model.repository.syncSession?.pendingObject)
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).syncSession?.pendingObject, frozen)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertNil(controller.lastSyncDate)
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document.tasks.map(\.title), ["First offline task"])

        XCTAssertTrue(model.addTask(title: "Second offline task", day: DayKey(), groupID: nil))
        let expectedPayload = try XCTUnwrap(model.repository.syncPayload)
        transport.rejectUploads = false
        controller.syncNow()
        try await waitUntil { !controller.isSyncing }

        XCTAssertEqual(transport.immutableUploads.count, 3)
        XCTAssertEqual(transport.immutableUploads[0].key, transport.immutableUploads[1].key)
        XCTAssertEqual(transport.immutableUploads[0].data, transport.immutableUploads[1].data)
        XCTAssertEqual(transport.immutableUploads[1].data, frozen.data)
        XCTAssertNotEqual(transport.immutableUploads[1].key, transport.immutableUploads[2].key)
        XCTAssertNil(controller.errorMessage)
        XCTAssertNotNil(controller.lastSyncDate)
        let upload = try XCTUnwrap(transport.uploads.last)
        let plaintext = try SyncEncryption(recoveryKey: recoveryKey).openV2(upload.data)
        XCTAssertEqual(try DocumentCodec.decode(SyncPayload.self, from: plaintext), expectedPayload)
        XCTAssertEqual(model.document.tasks.map(\.title), ["First offline task", "Second offline task"])
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document.tasks, model.document.tasks)
    }

    @MainActor func testWrongRecoveryKeyRejectsRemoteWithoutApplyingOrUploading() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        XCTAssertTrue(model.addTask(title: "Local task", day: DayKey(), groupID: nil))
        let localTasks = model.document.tasks
        let (payload, remoteID, deviceID) = try remotePayload(in: model)
        let encryption = try SyncEncryption(recoveryKey: recoveryKey)
        let key = SyncEncryption.headKey(vaultID: encryption.vaultID, deviceID: deviceID)
        let wrongEncryption = try SyncEncryption(recoveryKey: String(repeating: "02", count: 32))
        let transport = MemoryCloudTransport()
        transport.objects[key] = try wrongEncryption.seal(DocumentCodec.encode(payload))
        let controller = CloudSyncController(model: model, storage: MemorySyncSecrets(), makeTransport: { _, _ in transport })
        defer { try? controller.disconnect() }

        try controller.configure(configuration: configuration, credentials: credentials, recoveryKey: recoveryKey)
        try await waitUntil { !controller.isSyncing }

        XCTAssertNotNil(controller.errorMessage)
        XCTAssertNil(controller.lastSyncDate)
        XCTAssertEqual(model.document.tasks, localTasks)
        XCTAssertNil(model.task(remoteID))
        XCTAssertEqual(transport.uploadCalls, 0)
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document.tasks, localTasks)
    }

    @MainActor func testDisconnectDuringDownloadPreventsStaleApplyAndUpload() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        XCTAssertTrue(model.addTask(title: "Local task", day: DayKey(), groupID: nil))
        let localTasks = model.document.tasks
        let (payload, remoteID, deviceID) = try remotePayload(in: model)
        let encryption = try SyncEncryption(recoveryKey: recoveryKey)
        let key = SyncEncryption.headKey(vaultID: encryption.vaultID, deviceID: deviceID)
        let transport = MemoryCloudTransport()
        transport.objects[key] = try encryption.seal(DocumentCodec.encode(payload))
        transport.holdDownload = true
        let storage = MemorySyncSecrets()
        let controller = CloudSyncController(model: model, storage: storage, makeTransport: { _, _ in transport })
        defer { transport.releaseDownload(); try? controller.disconnect() }

        try controller.configure(configuration: configuration, credentials: credentials, recoveryKey: recoveryKey)
        try await waitUntil { transport.downloadEntered }
        try controller.disconnect()
        transport.releaseDownload()
        try await waitUntil { transport.downloadReturned }
        // Yield to the canceled controller after the deliberately uncooperative
        // fake network request returns. Generation checks must reject its result.
        await Task.yield()

        XCTAssertFalse(controller.isConfigured)
        XCTAssertFalse(controller.isSyncing)
        XCTAssertNil(controller.configuration)
        XCTAssertNil(controller.lastSyncDate)
        XCTAssertNil(storage.data)
        XCTAssertEqual(model.document.tasks, localTasks)
        XCTAssertNil(model.task(remoteID))
        XCTAssertEqual(transport.uploadCalls, 0)
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document.tasks, localTasks)
    }

    @MainActor func testJoiningAnEmptyOrWrongKeyVaultNeverCreatesCloudDataOrBindsTheLocalReplica() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        XCTAssertTrue(model.addTask(title: "Local task", day: DayKey(), groupID: nil))
        let original = model.document.tasks, transport = MemoryCloudTransport(), storage = MemorySyncSecrets()
        let controller = CloudSyncController(model: model, storage: storage, makeTransport: { _, _ in transport })
        defer { try? controller.disconnect() }
        for key in [recoveryKey, String(repeating: "02", count: 32)] {
            try controller.configure(configuration: configuration, credentials: credentials, recoveryKey: key)
            try await waitUntil { !controller.isSyncing }
            XCTAssertNotNil(controller.errorMessage); XCTAssertNil(controller.lastSyncDate)
            XCTAssertEqual(model.document.tasks, original); XCTAssertTrue(transport.objects.isEmpty)
            XCTAssertEqual(transport.uploadCalls, 0)
            XCTAssertNil(model.repository.syncSession)
            XCTAssertNil(model.repository.syncState)
        }
    }

    @MainActor func testDisconnectEditDeleteAndReconnectToTheSameVaultRetainsCausalHistory() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        XCTAssertTrue(model.addTask(title: "Rename offline", day: DayKey(), groupID: nil))
        XCTAssertTrue(model.addTask(title: "Delete offline", day: DayKey(), groupID: nil))
        let renamed = model.document.tasks[0], deleted = model.document.tasks[1]
        let transport = MemoryCloudTransport(), storage = MemorySyncSecrets()
        let controller = CloudSyncController(model: model, storage: storage, makeTransport: { _, _ in transport })
        defer { try? controller.disconnect() }
        try controller.configure(configuration: configuration, credentials: credentials, recoveryKey: recoveryKey, createIfMissing: true)
        try await waitUntil { !controller.isSyncing }
        XCTAssertNil(controller.errorMessage)
        let oldClock = try XCTUnwrap(model.repository.syncState?.clock)
        try controller.disconnect()
        XCTAssertTrue(model.edit(renamed.id, title: "Changed while disconnected", day: renamed.plannedDay, groupID: renamed.groupID))
        model.delete(deleted)
        let beforeReconnect = try XCTUnwrap(model.repository.syncPayload)
        XCTAssertGreaterThan(try XCTUnwrap(model.repository.syncState?.clock), oldClock)
        try controller.configure(configuration: configuration, credentials: credentials, recoveryKey: recoveryKey)
        try await waitUntil { !controller.isSyncing }
        XCTAssertNil(controller.errorMessage); XCTAssertNotNil(controller.lastSyncDate)
        XCTAssertEqual(model.task(renamed.id)?.title, "Changed while disconnected"); XCTAssertNil(model.task(deleted.id))
        let tombstone = "task:\(deleted.id.uuidString.lowercased())"
        XCTAssertEqual(model.repository.syncPayload?.records[tombstone]?.fields["$alive"], beforeReconnect.records[tombstone]?.fields["$alive"])
        XCTAssertEqual(model.repository.syncPayload?.records[tombstone]?.fields["$alive"]?.value, .bool(false))
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document.tasks, model.document.tasks)
    }

    @MainActor func testAWrongKeyCannotConsumeUnboundLegacyHistoryBeforeTheCorrectVaultIsJoined() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        XCTAssertTrue(model.addTask(title: "Legacy survivor", day: DayKey(), groupID: nil))
        XCTAssertTrue(model.addTask(title: "Legacy deleted offline", day: DayKey(), groupID: nil))
        try model.repository.enableSync()
        model.refreshAfterCloudSync()
        let survivor = model.document.tasks[0], deleted = model.document.tasks[1]
        let legacyCloudPayload = try XCTUnwrap(model.repository.syncPayload)
        let actor = try XCTUnwrap(model.repository.syncState?.deviceID)
        let encryption = try SyncEncryption(recoveryKey: recoveryKey), transport = MemoryCloudTransport()
        let legacyKey = SyncEncryption.headKey(vaultID: encryption.vaultID, deviceID: actor)
        transport.objects[legacyKey] = try encryption.seal(DocumentCodec.encode(legacyCloudPayload))
        model.delete(deleted)
        XCTAssertTrue(model.edit(survivor.id, title: "Legacy edit while disconnected", day: survivor.plannedDay, groupID: survivor.groupID))
        let unboundHistory = try XCTUnwrap(model.repository.syncState)
        XCTAssertNil(model.repository.syncSession)
        let controller = CloudSyncController(model: model, storage: MemorySyncSecrets(), makeTransport: { _, _ in transport })
        defer { try? controller.disconnect() }
        try controller.configure(configuration: configuration, credentials: credentials, recoveryKey: String(repeating: "03", count: 32))
        try await waitUntil { !controller.isSyncing }
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertNil(model.repository.syncSession)
        XCTAssertEqual(model.repository.syncState, unboundHistory)
        XCTAssertEqual(transport.uploadCalls, 0)
        try controller.configure(configuration: configuration, credentials: credentials, recoveryKey: recoveryKey)
        try await waitUntil { !controller.isSyncing }
        XCTAssertNil(controller.errorMessage); XCTAssertNotNil(controller.lastSyncDate)
        XCTAssertEqual(model.task(survivor.id)?.title, "Legacy edit while disconnected")
        XCTAssertNil(model.task(deleted.id))
        XCTAssertEqual(model.repository.syncPayload?.version, 2)
        XCTAssertEqual(model.repository.syncPayload?.records["task:\(deleted.id.uuidString.lowercased())"]?.fields["$alive"]?.value, .bool(false))
    }

    @MainActor func testStartupCommitsAPreparedConnectionAfterTheDocumentCommitPoint() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        let storage = MemorySyncSecrets(), transport = MemoryCloudTransport()
        let controller = CloudSyncController(model: model, storage: storage, makeTransport: { _, _ in transport })
        defer { storage.rejectedSaveNumbers = []; try? controller.disconnect() }
        storage.rejectedSaveNumbers.insert(2)
        do {
            try controller.configure(configuration: configuration, credentials: credentials, recoveryKey: recoveryKey, createIfMissing: true)
        } catch { XCTAssertEqual(error as? CloudSyncError, .configurationRecovery) }
        try await waitUntil { !controller.isSyncing }
        XCTAssertFalse(controller.isConfigured)
        let journal = try DocumentCodec.decode(SyncTestJournal.self, from: XCTUnwrap(storage.data))
        XCTAssertNotNil(journal.pending)
        XCTAssertEqual(journal.transactionID, model.repository.syncSession?.connectionTransaction)
        let restarted = CloudSyncController(model: model, storage: storage, makeTransport: { _, _ in transport })
        defer { try? restarted.disconnect() }
        restarted.start()
        try await waitUntil { !restarted.isSyncing }
        XCTAssertTrue(restarted.isConfigured); XCTAssertEqual(restarted.configuration, configuration)
        XCTAssertNil(restarted.errorMessage); XCTAssertNotNil(restarted.lastSyncDate)
        let recovered = try DocumentCodec.decode(SyncTestJournal.self, from: XCTUnwrap(storage.data))
        XCTAssertNotNil(recovered.active); XCTAssertNil(recovered.pending); XCTAssertNil(recovered.transactionID)
    }

    @MainActor func testStartupRollsBackAPendingConnectionBeforeTheDocumentCommitPoint() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        let storage = MemorySyncSecrets(), transport = MemoryCloudTransport()
        let controller = CloudSyncController(model: model, storage: storage, makeTransport: { _, _ in transport })
        defer { try? controller.disconnect() }
        try controller.configure(configuration: configuration, credentials: credentials, recoveryKey: recoveryKey, createIfMissing: true)
        try await waitUntil { !controller.isSyncing }
        let active = SyncTestConnection(configuration: configuration, credentials: credentials, recoveryKey: recoveryKey)
        storage.data = try DocumentCodec.encode(SyncTestJournal(active: active,
            pending: SyncTestConnection(configuration: BitifulConfiguration(bucket: "other-bucket"), credentials: credentials, recoveryKey: recoveryKey),
            transactionID: UUID().uuidString.lowercased()))
        let restarted = CloudSyncController(model: model, storage: storage, makeTransport: { _, _ in transport })
        defer { try? restarted.disconnect() }
        restarted.start()
        try await waitUntil { !restarted.isSyncing }
        XCTAssertTrue(restarted.isConfigured); XCTAssertEqual(restarted.configuration, configuration)
        XCTAssertNil(restarted.errorMessage)
        let recovered = try DocumentCodec.decode(SyncTestJournal.self, from: XCTUnwrap(storage.data))
        XCTAssertEqual(recovered.active?.configuration, configuration); XCTAssertNil(recovered.pending)
    }

    @MainActor func testAnExternallyMismatchedConnectionNeverRebindsOrUploadsAutomatically() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        XCTAssertTrue(model.addTask(title: "Bound local task", day: DayKey(), groupID: nil))
        let encryption = try SyncEncryption(recoveryKey: recoveryKey)
        let channel = ImmutableCloudSync.channelID(configuration: configuration, encryption: encryption)
        try model.repository.prepareSync(channelID: channel, transactionID: "committed")
        let original = model.repository.document
        let storage = MemorySyncSecrets(), transport = MemoryCloudTransport()
        storage.data = try DocumentCodec.encode(SyncTestJournal(active: SyncTestConnection(
            configuration: BitifulConfiguration(bucket: "other-bucket"), credentials: credentials, recoveryKey: recoveryKey)))
        let controller = CloudSyncController(model: model, storage: storage, makeTransport: { _, _ in transport })
        defer { try? controller.disconnect() }
        controller.start()
        XCTAssertFalse(controller.isConfigured); XCTAssertEqual(controller.phase, .failed)
        XCTAssertNotNil(controller.errorMessage); XCTAssertEqual(transport.listCalls, 0)
        XCTAssertEqual(transport.uploadCalls, 0); XCTAssertEqual(model.repository.document, original)
    }
}
