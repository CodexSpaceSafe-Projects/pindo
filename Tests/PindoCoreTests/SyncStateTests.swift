import XCTest
@testable import PindoCore

final class SyncStateTests: XCTestCase {
    let aID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    let bID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    let itemID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    let date = Date(timeIntervalSinceReferenceDate: 0)
    var key: String { "task:\(itemID.uuidString.lowercased())" }

    func initial() -> PindoDocument {
        var document = PindoDocument()
        document.groups = [TaskGroup(id: UUID(uuidString: "20000000-0000-4000-8000-000000000001")!, name: "Work", colorHex: "#228833")]
        document.tasks = [TodoItem(id: itemID, title: "Initial", plannedDay: try! DayKey(year: 2026, month: 11, day: 12), groupID: document.groups[0].id, now: date)]
        return document
    }

    func repository(_ document: PindoDocument, io: MemoryStorage = MemoryStorage()) throws -> PindoRepository {
        try PindoRepository(directory: URL(fileURLWithPath: "/sync-\(UUID().uuidString)"), io: io, now: date, initialDocument: document)
    }

    func pair() throws -> (PindoRepository, PindoRepository) {
        let a = try repository(initial())
        var empty = PindoDocument(); empty.groups = []
        let b = try repository(empty)
        try a.enableSync(deviceID: aID); try b.enableSync(deviceID: bID)
        try b.applySync(XCTUnwrap(a.syncPayload))
        return (a, b)
    }

    func testEnableUsesExplicitWireTypesAndNoPreferences() throws {
        let repo = try repository(initial())
        try repo.enableSync(deviceID: aID)
        let payload = try XCTUnwrap(repo.syncPayload)
        XCTAssertEqual(payload.version, 1)
        XCTAssertEqual(payload.records[key]?.fields["createdAt"]?.value, .number(0))
        XCTAssertEqual(payload.records[key]?.fields["parentID"]?.value, .null)
        XCTAssertEqual(payload.records[key]?.fields["completedAt"]?.value, .null)
        XCTAssertEqual(payload.records[key]?.fields["groupID"]?.value, .string(initial().groups[0].id.uuidString.lowercased()))
        XCTAssertNil(payload.records[key]?.fields["note"])
        let bytes = try DocumentCodec.encode(payload)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("preferences"))
        XCTAssertEqual(try DocumentCodec.decode(SyncPayload.self, from: bytes).validated(), payload)
        let before = payload
        try repo.update { $0.preferences.appearance = .dark; $0.preferences.launchAtLogin = true }
        XCTAssertEqual(repo.syncPayload, before)
    }

    func testConcurrentDifferentFieldsAndRepeatedHeadsConverge() throws {
        let (a, b) = try pair()
        try a.update { $0.tasks[0].title = "Renamed" }
        try b.update { $0.tasks[0].plannedDay = try DayKey(year: 2026, month: 11, day: 13); $0.tasks[0].order = 8 }
        let aPayload = try XCTUnwrap(a.syncPayload), bPayload = try XCTUnwrap(b.syncPayload)
        XCTAssertEqual(try aPayload.merging(bPayload), try bPayload.merging(aPayload))
        try a.applySync(bPayload); try b.applySync(aPayload)
        XCTAssertEqual(a.document.tasks, b.document.tasks)
        XCTAssertEqual(a.document.tasks[0].title, "Renamed")
        XCTAssertEqual(a.document.tasks[0].plannedDay.description, "2026-11-13")
        XCTAssertEqual(a.document.tasks[0].order, 8)
        let merged = a.document
        try a.applySync(aPayload); try a.applySync(bPayload)
        XCTAssertEqual(a.document, merged)
    }

    func testAllLocalMutationsAreCapturedWithoutUpdatedAtChanges() throws {
        let repo = try repository(initial())
        try repo.enableSync(deviceID: aID)
        let oldDate = repo.document.tasks[0].updatedAt
        try repo.update { $0.tasks[0].order = 23; $0.groups[0].name = "New group" }
        XCTAssertEqual(repo.document.tasks[0].updatedAt, oldDate)
        XCTAssertEqual(repo.syncPayload?.records[key]?.fields["order"]?.value, .number(23))
        let groupKey = "group:\(repo.document.groups[0].id.uuidString.lowercased())"
        XCTAssertEqual(repo.syncPayload?.records[groupKey]?.fields["name"]?.value, .string("New group"))
    }

    func testDeletionDoesNotResurrectFromLaterOfflineEdits() throws {
        let (a, b) = try pair()
        try a.update { _ = try $0.applyBatch(.delete, to: [self.itemID]) }
        for n in 0..<4 { try b.update { $0.tasks[0].title = "Offline \(n)" } }
        let aPayload = try XCTUnwrap(a.syncPayload), bPayload = try XCTUnwrap(b.syncPayload)
        try a.applySync(bPayload); try b.applySync(aPayload)
        XCTAssertTrue(a.document.tasks.isEmpty)
        XCTAssertTrue(b.document.tasks.isEmpty)
        XCTAssertEqual(a.syncPayload?.records[key]?.fields["$alive"]?.value, .bool(false))
    }

    func testConcurrentNotesArePreservedAndEditingAcknowledgesAllVersions() throws {
        let (a, b) = try pair()
        try a.stageNote(taskID: itemID, text: "A's note", now: date); try a.flush()
        try b.stageNote(taskID: itemID, text: "B's note", now: date); try b.flush()
        let oldA = try XCTUnwrap(a.syncPayload), oldB = try XCTUnwrap(b.syncPayload)
        try a.applySync(oldB); try b.applySync(oldA)
        XCTAssertEqual(a.document.tasks[0].note, "B's note\n\n[Sync conflict]\n\nA's note")
        XCTAssertEqual(a.document.tasks, b.document.tasks)
        XCTAssertEqual(a.syncPayload?.records[key]?.notes.count, 2)
        try a.stageNote(taskID: itemID, text: "Resolved notes", now: date); try a.flush()
        try a.applySync(oldA); try a.applySync(oldB)
        XCTAssertEqual(a.document.tasks[0].note, "Resolved notes")
        XCTAssertEqual(a.syncPayload?.records[key]?.notes.count, 1)
    }

    func testApplyCapturesPendingNotesAndKeepsIdentityAndLocalPreferences() throws {
        let (a, b) = try pair()
        try a.update { $0.preferences.appearance = .dark; $0.preferences.launchAtLogin = true }
        try a.stageNote(taskID: itemID, text: "Not uploaded yet", now: date)
        try b.update { $0.tasks[0].title = "Remote title" }
        try a.applySync(XCTUnwrap(b.syncPayload))
        XCTAssertEqual(a.document.tasks[0].title, "Remote title")
        XCTAssertEqual(a.document.tasks[0].note, "Not uploaded yet")
        XCTAssertEqual(a.syncState?.deviceID, aID.uuidString.lowercased())
        XCTAssertEqual(a.document.preferences.appearance, .dark)
        XCTAssertTrue(a.document.preferences.launchAtLogin)
        XCTAssertFalse(a.hasUnsavedChanges)
    }

    func testFailedAtomicSyncWriteLeavesMetadataAndPendingLocalNoteUntouched() throws {
        let io = MemoryStorage(), a = try repository(initial(), io: io)
        try a.enableSync(deviceID: aID)
        var empty = PindoDocument(); empty.groups = []
        let remote = try repository(empty); try remote.enableSync(deviceID: bID)
        try remote.applySync(XCTUnwrap(a.syncPayload))
        try a.stageNote(taskID: itemID, text: "Pending local note", now: date)
        let before = a.document, disk = io.files[a.dataURL]
        io.failNextWriteTo = a.dataURL
        XCTAssertThrowsError(try a.applySync(XCTUnwrap(remote.syncPayload)))
        XCTAssertEqual(a.document, before)
        XCTAssertEqual(io.files[a.dataURL], disk)
        XCTAssertTrue(a.hasUnsavedChanges)
        try a.applySync(XCTUnwrap(remote.syncPayload))
        let reopened = try PindoRepository(directory: a.directory, io: io)
        XCTAssertEqual(reopened.document, a.document)
        XCTAssertEqual(reopened.document.tasks[0].note, "Pending local note")
    }

    func testRestoreAndImportKeepReplicaAndExplicitlyRestoreDeletedIDs() throws {
        let repo = try repository(initial())
        try repo.enableSync(deviceID: aID)
        _ = try repo.captureIfChanged(now: date)
        let snapshot = try XCTUnwrap(repo.archive.records.last?.id)
        try repo.update { _ = try $0.applyBatch(.delete, to: [self.itemID]) }
        let deleted = try XCTUnwrap(repo.syncPayload)
        try repo.restore(snapshotID: snapshot, now: date)
        XCTAssertEqual(repo.syncState?.deviceID, aID.uuidString.lowercased())
        XCTAssertEqual(repo.document.tasks[0].id, itemID)
        XCTAssertEqual(repo.syncPayload?.records[key]?.fields["$alive"]?.value, .bool(true))
        try repo.applySync(deleted)
        XCTAssertEqual(repo.document.tasks[0].id, itemID)
        var foreign = initial(); foreign.tasks[0].title = "Imported"
        foreign.syncState = SyncReplica(deviceID: bID)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: DocumentCodec.encode(foreign)) as? [String: Any])
        object["syncState"] = ["malformed": true]
        try repo.importDocument(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(repo.syncState?.deviceID, aID.uuidString.lowercased())
        XCTAssertEqual(repo.document.tasks[0].title, "Imported")
        let exported = String(decoding: try repo.exportDocument(), as: UTF8.self)
        let backup = String(decoding: try repo.exportSnapshots(), as: UTF8.self)
        XCTAssertFalse(exported.contains("syncState"))
        XCTAssertFalse(backup.contains("syncState"))
    }

    func testNewVaultResetsMetadataAndRetainsLocalTasks() throws {
        let repo = try repository(initial()); try repo.enableSync(deviceID: aID)
        try repo.enableSync(deviceID: bID)
        XCTAssertEqual(repo.syncState?.deviceID, aID.uuidString.lowercased())
        let tasks = repo.document.tasks
        try repo.enableSync(deviceID: bID, reset: true)
        XCTAssertEqual(repo.syncState?.deviceID, bID.uuidString.lowercased())
        XCTAssertEqual(repo.document.tasks, tasks)
        XCTAssertEqual(repo.syncState?.clock, 1)
        XCTAssertEqual(repo.syncPayload?.seen, [bID.uuidString.lowercased(): 1])
    }

    func testMalformedRemoteAndCorruptLocalMetadataFailClosed() throws {
        let io = MemoryStorage(), repo = try repository(initial(), io: io)
        try repo.enableSync(deviceID: aID)
        let before = repo.document, bytes = io.files[repo.dataURL]
        var bad = try XCTUnwrap(repo.syncPayload)
        bad.records[key]?.fields.removeValue(forKey: "phase")
        XCTAssertThrowsError(try repo.applySync(bad))
        XCTAssertEqual(repo.document, before)
        XCTAssertEqual(io.files[repo.dataURL], bytes)
        var local = repo.document; local.syncState?.clock = -1
        let corrupt = try DocumentCodec.encode(local)
        io.files[repo.dataURL] = corrupt
        XCTAssertThrowsError(try PindoRepository(directory: repo.directory, io: io))
        XCTAssertEqual(io.files[repo.dataURL], corrupt)
    }

    func testProjectionRepairsCyclesDepthAndMissingGroupsDeterministically() throws {
        var document = initial()
        document.tasks = (1...5).map { n in
            TodoItem(id: UUID(uuidString: String(format: "10000000-0000-4000-8000-%012d", n))!, title: "Task \(n)", plannedDay: try! DayKey(year: 2026, month: 11, day: 12), now: date)
        }
        let repo = try repository(document); try repo.enableSync(deviceID: aID)
        var payload = try XCTUnwrap(repo.syncPayload)
        let stamp = SyncStamp(counter: 2, deviceID: bID.uuidString.lowercased())
        payload.seen[bID.uuidString.lowercased()] = 2
        for n in 0..<4 {
            let key = "task:\(document.tasks[n].id.uuidString.lowercased())"
            payload.records[key]?.fields["parentID"] = SyncRegister(value: .string(document.tasks[n + 1].id.uuidString.lowercased()), stamp: stamp)
        }
        let lastKey = "task:\(document.tasks[4].id.uuidString.lowercased())"
        payload.records[lastKey]?.fields["parentID"] = SyncRegister(value: .string(document.tasks[3].id.uuidString.lowercased()), stamp: stamp)
        payload.records[lastKey]?.fields["groupID"] = SyncRegister(value: .string(UUID().uuidString.lowercased()), stamp: stamp)
        try repo.applySync(payload)
        _ = try repo.document.validated()
        for task in repo.document.tasks { XCTAssertLessThan(try XCTUnwrap(repo.document.taskDepth(task.id)), 3) }
        XCTAssertNil(repo.document.tasks.first(where: { $0.id == document.tasks[4].id })?.groupID)
        let again = try payload.projected()
        XCTAssertEqual(repo.document.tasks, again.tasks)
        XCTAssertEqual(repo.syncPayload?.records[lastKey]?.fields["groupID"]?.value, payload.records[lastKey]?.fields["groupID"]?.value)
    }

    func testParentCompletionDerivedAndConcurrentOrphanIsPreserved() throws {
        var document = initial()
        let child = TodoItem(title: "Child", plannedDay: document.tasks[0].plannedDay, parentID: itemID, now: date)
        try document.insertTask(child, now: date)
        let a = try repository(document)
        var empty = PindoDocument(); empty.groups = []
        let b = try repository(empty)
        try a.enableSync(deviceID: aID); try b.enableSync(deviceID: bID)
        try b.applySync(XCTUnwrap(a.syncPayload))
        try a.update { try $0.setPhase(.completed, for: child.id, now: self.date) }
        try b.applySync(XCTUnwrap(a.syncPayload))
        XCTAssertEqual(b.document.tasks.first(where: { $0.id == itemID })?.phase, .completed)
        let orphan = TodoItem(title: "Concurrent child", plannedDay: document.tasks[0].plannedDay, parentID: itemID, now: date)
        try b.update { try $0.insertTask(orphan, now: self.date) }
        try a.update { _ = try $0.applyBatch(.delete, to: [self.itemID]) }
        try a.applySync(XCTUnwrap(b.syncPayload))
        XCTAssertEqual(a.document.tasks.map(\.id), [orphan.id])
        XCTAssertNil(a.document.tasks[0].parentID)
    }

    func testRepeatedSyncPreservesExplicitParentProgress() throws {
        var document = initial()
        let child = TodoItem(title: "子项", parentID: itemID, now: date)
        try document.insertTask(child, now: date)
        try document.setPhase(.inProgress, for: itemID, now: date.addingTimeInterval(10))
        try document.setPhase(.inProgress, for: child.id, now: date.addingTimeInterval(20))
        let repo = try repository(document)
        try repo.enableSync(deviceID: aID)
        try repo.applySync(XCTUnwrap(repo.syncPayload))
        XCTAssertEqual(repo.document.tasks.first(where: { $0.id == itemID })?.isProgressExplicit, true)
        try repo.update { try $0.setPhase(.pending, for: child.id, now: self.date.addingTimeInterval(30)) }
        XCTAssertEqual(repo.document.tasks.first(where: { $0.id == itemID })?.phase, .inProgress)
        XCTAssertEqual(repo.document.tasks.first(where: { $0.id == itemID })?.startedAt, date.addingTimeInterval(10))
    }

    func testSyncPreservesProgressFromPartialCompletion() throws {
        var document = initial()
        let child = TodoItem(title: "已完成子项", parentID: itemID, now: date)
        let sibling = TodoItem(title: "未开始子项", parentID: itemID, now: date)
        try document.insertTask(child, now: date)
        try document.insertTask(sibling, now: date)
        try document.setPhase(.completed, for: child.id, now: date.addingTimeInterval(10))
        let repo = try repository(document)
        try repo.enableSync(deviceID: aID)
        try repo.applySync(XCTUnwrap(repo.syncPayload))
        let parent = try XCTUnwrap(repo.document.tasks.first(where: { $0.id == itemID }))
        XCTAssertEqual(parent.phase, .inProgress)
        XCTAssertEqual(parent.startedAt, date.addingTimeInterval(10))
    }

    func testConcurrentDuplicateGroupNamesNormalizeWithoutRewritingRegisters() throws {
        let (a, b) = try pair()
        try a.update { $0.groups.append(TaskGroup(name: "Concurrent", colorHex: "#228833")) }
        try b.update { $0.groups.append(TaskGroup(name: "Concurrent", colorHex: "#4477AA")) }
        let oldA = try XCTUnwrap(a.syncPayload), oldB = try XCTUnwrap(b.syncPayload)
        try a.applySync(oldB); try b.applySync(oldA)
        XCTAssertEqual(a.document.groups, b.document.groups)
        XCTAssertEqual(Set(a.document.groups.map(\.name)).count, 3)
        XCTAssertTrue(a.document.groups.filter { $0.name.hasPrefix("Concurrent [") }.count == 2)
        XCTAssertEqual(a.syncPayload?.records.values.filter { $0.fields["name"]?.value == .string("Concurrent") }.count, 2)
        _ = try a.document.validated()
    }

    func testContradictoryEqualStampsAndUncoveredClocksAreRejected() throws {
        let repo = try repository(initial()); try repo.enableSync(deviceID: aID)
        let before = repo.document
        var contradictory = try XCTUnwrap(repo.syncPayload)
        contradictory.records[key]?.fields["title"]?.value = .string("Impossible same operation")
        XCTAssertThrowsError(try repo.applySync(contradictory))
        var uncovered = try XCTUnwrap(repo.syncPayload)
        uncovered.seen = [:]
        XCTAssertThrowsError(try repo.applySync(uncovered))
        XCTAssertEqual(repo.document, before)
    }

    func testSharedWireVectorAndProjectionRoundTrip() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("sync-vectors")
        let payload = try DocumentCodec.decode(SyncPayload.self, from: Data(contentsOf: directory.appendingPathComponent("payload-v1.json"))).validated()
        XCTAssertEqual(try DocumentCodec.decode(SyncPayload.self, from: DocumentCodec.encode(payload)).validated(), payload)
        // This file is produced by the actual Kotlin JSONObject serializer in
        // SyncInteropTest, rather than manually reproducing Android's encoding.
        let kotlin = try DocumentCodec.decode(SyncPayload.self, from: Data(contentsOf: directory.appendingPathComponent("payload-v1-kotlin.json"))).validated()
        XCTAssertEqual(kotlin, payload)
        struct Projection: Decodable { let tasks: [TodoItem]; let groups: [TaskGroup] }
        let expected = try DocumentCodec.decode(Projection.self, from: Data(contentsOf: directory.appendingPathComponent("projected-v1.json")))
        let actual = try payload.projected()
        XCTAssertEqual(actual.tasks, expected.tasks)
        XCTAssertEqual(actual.groups, expected.groups)
        XCTAssertEqual(try kotlin.projected().tasks, expected.tasks)
        XCTAssertEqual(try kotlin.projected().groups, expected.groups)
        XCTAssertEqual(actual.tasks.count, 2)
        XCTAssertEqual(payload.records.count, 4)
        XCTAssertTrue(actual.tasks.contains { $0.note.contains("[Sync conflict]") })
        XCTAssertEqual(actual.tasks.first?.phase, .inProgress)
    }
}
