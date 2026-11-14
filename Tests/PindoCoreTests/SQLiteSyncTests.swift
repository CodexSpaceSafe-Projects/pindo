import Foundation
import XCTest
@testable import PindoCore

final class SQLiteSyncTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PindoV3-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func binding() throws -> SyncV3Binding { try .init(serviceID: "00000000-0000-4000-8000-000000000001", vaultID: "00000000-0000-4000-8000-000000000002", epoch: "00000000-0000-4000-8000-000000000003") }
    func testJSONMigrationHasOneAuthorityAndSurvivesRestartWithoutReadingStaleJSON() throws {
        let dir = try directory(), legacy = try PindoRepository(directory: dir)
        try legacy.update { $0.tasks.append(TodoItem(title: "Legacy", note: "Keep", groupID: nil)) }
        let expected = legacy.document
        let migrated = try PindoRepository(directory: dir, useSQLite: true)
        XCTAssertEqual(migrated.document, expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("data.pre-sqlite.json").path))
        try FileStorage().write(Data("corrupt stale JSON".utf8), to: dir.appendingPathComponent("data.json"))
        try migrated.update { $0.tasks[0].title = "SQLite owns this" }
        XCTAssertEqual(try PindoRepository(directory: dir, useSQLite: true).document.tasks[0].title, "SQLite owns this")
    }
    func testTitleDeltaAndLocalWritesDoNotEncodeOrTransmitUnchangedMegabyteNote() throws {
        let dir = try directory(), repository = try PindoRepository(directory: dir, useSQLite: true)
        try repository.update { $0.tasks = [TodoItem(title: "Before", note: String(repeating: "长", count: 350_000))] }
        let db = try XCTUnwrap(repository.sqlite), b = try binding()
        try db.bind(b, importingLocal: true)
        let initial = try XCTUnwrap(db.queue(b).first)
        var state = SyncPayload(version: 2)
        state = try state.applyingV3(DocumentCodec.decode(SyncV3Batch.self, from: initial.plaintext))
        try db.freeze(b, id: initial.id, wire: Data("frozen".utf8), digest: String(repeating: "a", count: 64), chunks: [])
        try db.acknowledge(b, id: initial.id, digest: String(repeating: "a", count: 64), revision: 1)
        try db.receive(b, entries: [(1, initial.id, try DocumentCodec.decode(SyncV3Batch.self, from: initial.plaintext))])
        try repository.reloadCurrentDocument()
        try repository.update { $0.tasks[0].title = "After" }
        let delta = try XCTUnwrap(db.queue(b).first)
        XCTAssertLessThan(delta.plaintext.count, 4096)
        let batch = try DocumentCodec.decode(SyncV3Batch.self, from: delta.plaintext)
        XCTAssertTrue(batch.operations[0].notes.isEmpty)
        XCTAssertEqual(Set(batch.operations[0].fields.keys), ["title"])
        XCTAssertEqual(try PindoRepository(directory: dir, useSQLite: true).document.tasks[0].note.utf8.count, 1_050_000)
    }
    func testCommitFailureRollsVisibleDataRegistersAndOutboxBackTogether() throws {
        let dir = try directory(), repository = try PindoRepository(directory: dir, useSQLite: true)
        let store = try XCTUnwrap(repository.sqlite), b = try binding()
        try store.bind(b, importingLocal: true); try repository.reloadCurrentDocument()
        let old = repository.document, queued = try store.queue(b).count
        store.database.beforeCommit = { throw SyncV3Error.storageUnavailable }
        XCTAssertThrowsError(try repository.update { $0.tasks.append(TodoItem(title: "Must roll back")) })
        store.database.beforeCommit = nil
        XCTAssertEqual(repository.document, old)
        XCTAssertEqual(try store.readDocument(), old)
        XCTAssertEqual(try store.queue(b).count, queued)
    }
    func testUploadAckCannotConfirmNewerLocalEditsOrAdvanceDownloadCursor() throws {
        let dir = try directory(), repository = try PindoRepository(directory: dir, useSQLite: true)
        let store = try XCTUnwrap(repository.sqlite), b = try binding()
        try store.bind(b, importingLocal: true); try repository.reloadCurrentDocument()
        let frozen = try XCTUnwrap(store.queue(b).first)
        try store.freeze(b, id: frozen.id, wire: Data("fixed bytes".utf8), digest: String(repeating: "a", count: 64), chunks: [])
        try repository.update { $0.tasks.append(TodoItem(title: "New while uploading")) }
        try store.acknowledge(b, id: frozen.id, digest: String(repeating: "a", count: 64), revision: 1)
        XCTAssertEqual(try store.cursors(b).applied, 0)
        XCTAssertEqual(try store.queue(b).count, 2)
        try store.receive(b, entries: [(1, frozen.id, try DocumentCodec.decode(SyncV3Batch.self, from: frozen.plaintext))])
        XCTAssertEqual(try store.queue(b).count, 1)
        XCTAssertEqual(try store.readDocument().tasks.last?.title, "New while uploading")
    }
    func testPatchBeforeCreateWaitsDurablyAndOnlyAdvancesContiguousAppliedPrefix() throws {
        let dir = try directory(), repository = try PindoRepository(directory: dir, useSQLite: true), b = try binding()
        let store = try XCTUnwrap(repository.sqlite); try store.bind(b, importingLocal: false)
        var before = PindoDocument(); before.tasks = []; before.groups = []
        var created = before; let task = TodoItem(title: "Created"); created.tasks = [task]
        let actor = "00000000-0000-4000-8000-000000000010", key = "task:\(task.id.uuidString.lowercased())"
        let create = try SyncV3Delta.capture(before: before, after: created, actor: actor, clock: 1, known: []) { _ in [] }
        var edited = created; edited.tasks[0].title = "Patch arrived first"
        let patch = try SyncV3Delta.capture(before: created, after: edited, actor: actor, clock: 2, known: [key]) { _ in [] }
        try store.receive(b, entries: [(1, UUID().uuidString.lowercased(), patch)])
        XCTAssertEqual(try store.cursors(b).fetched, 1); XCTAssertEqual(try store.cursors(b).applied, 0)
        XCTAssertTrue(try store.readDocument().tasks.isEmpty)
        try store.receive(b, entries: [(2, UUID().uuidString.lowercased(), create)])
        XCTAssertEqual(try store.cursors(b).applied, 2)
        XCTAssertEqual(try store.readDocument().tasks.first?.title, "Patch arrived first")
    }
    func testEpochRebaseArchivesFrozenBytesAndKeepsOfflineProjection() throws {
        let dir = try directory(), repository = try PindoRepository(directory: dir, useSQLite: true), b = try binding()
        let store = try XCTUnwrap(repository.sqlite); try store.bind(b, importingLocal: true); try repository.reloadCurrentDocument()
        try repository.update { $0.tasks.append(TodoItem(title: "Offline")) }
        let old = try XCTUnwrap(store.queue(b).first)
        try store.freeze(b, id: old.id, wire: Data("old epoch wire".utf8), digest: String(repeating: "a", count: 64), chunks: [])
        let next = try store.rebaseEpoch(b, epoch: "00000000-0000-4000-8000-000000000099")
        XCTAssertNil(try store.queue(next).first?.wire)
        XCTAssertEqual(try store.readDocument().tasks.first?.title, "Offline")
        XCTAssertNotNil(try store.database.query("SELECT wire FROM v3_retired WHERE id=?", [.text(old.id)]).first?["wire"])
        XCTAssertThrowsError(try store.acknowledge(b, id: old.id, digest: String(repeating: "a", count: 64), revision: 1))
    }
    func testThousandAndTenThousandTaskTitleEditsRemainFieldSized() throws {
        for count in [1_000, 10_000] {
            let repository=try PindoRepository(directory:directory(),useSQLite:true)
            try repository.update { doc in doc.tasks=(0..<count).map { TodoItem(title:"Task \($0)",note:String(repeating:"内容",count:32)) } }
            let store=try XCTUnwrap(repository.sqlite), b=try binding()
            try store.bind(b,importingLocal:true)
            try repository.reloadCurrentDocument()
            try store.database.execute("CREATE TRIGGER forbid_note_rewrite BEFORE UPDATE OF note ON app_entities BEGIN SELECT RAISE(ABORT,'unchanged note rewrite'); END")
            let before=Int(try store.database.string("SELECT total_changes()")!)!
            let start=Date()
            try repository.update { $0.tasks[count/2].title="Only this title changed" }
            let milliseconds=Date().timeIntervalSince(start)*1000
            let delta=try XCTUnwrap(store.queue(b).last)
            let writes=Int(try store.database.string("SELECT total_changes()")!)!-before
            XCTAssertLessThan(delta.plaintext.count,4096)
            XCTAssertLessThan(writes,20)
            XCTAssertEqual(try DocumentCodec.decode(SyncV3Batch.self,from:delta.plaintext).operations.count,1)
            print("V3_PERFORMANCE tasks=\(count) titleBytes=\(delta.plaintext.count) changedRows=\(writes) elapsedMS=\(Int(milliseconds))")
        }
    }

}
