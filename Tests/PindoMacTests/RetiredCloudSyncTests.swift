import Foundation
import XCTest
import PindoCore
@testable import Pindo

final class RetiredCloudSyncTests: XCTestCase {
    @MainActor func testStartupAndEditingPreserveLegacyBindingAndFrozenOutbox() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PindoRetiredCloudTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, defaults: defaults)
        model.playFeedback = { _ in }
        XCTAssertTrue(model.addTask(title: "Offline", day: model.today, groupID: nil))
        XCTAssertTrue(model.flush())
        try model.repository.prepareSync(channelID: "legacy-library", transactionID: "pending-legacy-transaction")
        let frozen = Data("frozen legacy ciphertext".utf8)
        try model.repository.stageSyncUpload(key: "legacy-object", data: frozen, payloadDigest: String(repeating: "a", count: 64))
        let before = model.repository.document
        model.cloudSync.start()
        XCTAssertFalse(model.cloudSync.isConfigured)
        XCTAssertEqual(model.repository.document, before)
        let lease = try XCTUnwrap(model.acquireSyncEditing())
        model.releaseSyncEditing(lease)
        XCTAssertTrue(model.addTask(title: "Still local", day: model.today, groupID: nil))
        XCTAssertTrue(model.flush())
        XCTAssertEqual(model.repository.syncSession?.channelID, "legacy-library")
        XCTAssertEqual(model.repository.syncSession?.pendingObject?.data, frozen)
        XCTAssertEqual(model.repository.syncSession?.connectionTransaction, "pending-legacy-transaction")
        XCTAssertEqual(try PindoRepository(directory: directory).document.tasks.count, 2)
    }
}
