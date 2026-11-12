import Foundation
import XCTest
import PindoCore
@testable import Pindo

private final class MemorySyncSecrets: SyncSecretStorage {
    var data: Data?
    var rejectWrites = false

    func load() throws -> Data? { data }
    func save(_ data: Data?) throws {
        if rejectWrites { throw CloudSyncError.keychain }
        self.data = data
    }
}

@MainActor private final class MemoryCloudTransport: CloudSyncTransport {
    var heads: [SyncRemoteHead] = []
    var objects: [String: Data] = [:]
    var rejectUploads = false
    var holdDownload = false
    var downloadEntered = false
    var downloadReturned = false
    private var downloadContinuation: CheckedContinuation<Void, Never>?
    private(set) var listCalls = 0
    private(set) var uploadCalls = 0
    private(set) var uploads: [(key: String, data: Data)] = []

    func listHeads(vaultID: String) async throws -> [SyncRemoteHead] {
        listCalls += 1
        return heads
    }

    func download(key: String) async throws -> Data {
        downloadEntered = true
        if holdDownload {
            await withCheckedContinuation { downloadContinuation = $0 }
        }
        downloadReturned = true
        guard let data = objects[key] else { throw SyncTransportError.bucketNotFound }
        return data
    }

    func upload(data: Data, key: String) async throws {
        uploadCalls += 1
        if rejectUploads { throw SyncTransportError.networkUnavailable }
        uploads.append((key, data))
    }

    func releaseDownload() {
        let continuation = downloadContinuation
        downloadContinuation = nil
        continuation?.resume()
    }
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

        try controller.configure(configuration: configuration, credentials: credentials, recoveryKey: recoveryKey)
        try await waitUntil { !controller.isSyncing }
        let savedCredentials = try XCTUnwrap(storage.data)
        let deviceID = try XCTUnwrap(model.repository.syncState?.deviceID)
        let requests = transport.listCalls
        storage.rejectWrites = true

        XCTAssertThrowsError(try controller.configure(configuration: BitifulConfiguration(bucket: "other-bucket"),
                                                     credentials: credentials, recoveryKey: recoveryKey))
        XCTAssertTrue(controller.isConfigured)
        XCTAssertEqual(controller.configuration, configuration)
        XCTAssertEqual(storage.data, savedCredentials)
        XCTAssertEqual(model.repository.syncState?.deviceID, deviceID)
        XCTAssertEqual(transport.listCalls, requests)
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

        try controller.configure(configuration: configuration, credentials: credentials, recoveryKey: recoveryKey)
        try await waitUntil { !controller.isSyncing }
        XCTAssertEqual(transport.uploadCalls, 1)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertNil(controller.lastSyncDate)
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document.tasks.map(\.title), ["First offline task"])

        XCTAssertTrue(model.addTask(title: "Second offline task", day: DayKey(), groupID: nil))
        let expectedPayload = try XCTUnwrap(model.repository.syncPayload)
        transport.rejectUploads = false
        controller.syncNow()
        try await waitUntil { !controller.isSyncing }

        XCTAssertEqual(transport.uploadCalls, 2)
        XCTAssertNil(controller.errorMessage)
        XCTAssertNotNil(controller.lastSyncDate)
        let upload = try XCTUnwrap(transport.uploads.last)
        let plaintext = try SyncEncryption(recoveryKey: recoveryKey).open(upload.data)
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
        transport.heads = [SyncRemoteHead(key: key, etag: "remote-v1")]
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
        transport.heads = [SyncRemoteHead(key: key, etag: "remote-v1")]
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
}
