import XCTest
@testable import PindoCore

final class PindoCoreTests: XCTestCase {
    let directory = URL(fileURLWithPath: "/tmp/pindo-test-\(UUID().uuidString)")
    let now = Date(timeIntervalSince1970: 1_793_491_200)

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func failNextCommit(_ repository: PindoRepository) {
        let database = repository.sqlite.database
        database.beforeCommit = { [weak database] in
            database?.beforeCommit = nil
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    func task(_ title: String = "事项", day: DayKey? = nil) -> TodoItem { TodoItem(title: title, plannedDay: day ?? DayKey(now), now: now) }
    func document() -> PindoDocument { var d = PindoDocument(); d.tasks = [task()]; return d }

    func testUnicodeTextDeltaPreservesChineseEmojiAndCombiningCharacters() throws {
        let a = JSONValue.object(["note": .string("中文👨‍👩‍👧‍👦 e\u{301}，旧内容")])
        let b = JSONValue.object(["note": .string("中文👨‍👩‍👧‍👦 e\u{301}，新内容✅")])
        let diff = JSONPatch.diff(a, b)
        XCTAssertEqual(try JSONPatch.applying(diff, to: a), b)
        XCTAssertEqual(try JSONPatch.applying(diff, to: b, forward: false), a)
        XCTAssertTrue(JSONPatch.diff(a, a).isEmpty)
    }

    func testTextDeltaDoesNotCopyUnchangedLongNote() throws {
        let text = String(repeating: "内容", count: 50_000)
        let diff = JSONPatch.diff(.string(text), .string(text + "下一步"))
        XCTAssertLessThan(try DocumentCodec.encode(diff).count, 300)
    }

    func testPatchRejectsMismatchedSource() throws {
        let diff = JSONPatch.diff(.string("abc"), .string("axc"))
        XCTAssertThrowsError(try JSONPatch.applying(diff, to: .string("def")))
    }

    func testSnapshotRestoresTaskNotePhaseGroupAndOrder() throws {
        var d = document(); d.tasks[0].note = "想法"; d.tasks[0].groupID = d.groups[0].id
        var archive = try SnapshotArchive(document: d, now: now)
        let baselineID = archive.baselineRecord.id
        d.tasks[0].note = "下一步"; try d.setPhase(.inProgress, for: d.tasks[0].id, now: now)
        d.removeGroup(d.groups[0].id)
        XCTAssertTrue(try archive.append(d, label: "自动快照", now: now))
        let restored = try PindoDocument.fromSnapshot(archive.state(at: baselineID))
        XCTAssertEqual(restored.tasks[0].note, "想法")
        XCTAssertEqual(restored.tasks[0].phase, .pending)
        XCTAssertEqual(restored.tasks[0].groupID, restored.groups[0].id)
        XCTAssertEqual(try PindoDocument.fromSnapshot(archive.state()), d)
        XCTAssertEqual(try archive.validated(), archive)
    }

    func testSnapshotRetentionIncludesBaselineAndKeepsNewest100() throws {
        var d = document(); var archive = try SnapshotArchive(document: d, now: now)
        for i in 0..<105 { d.tasks[0].note = "版本\(i)"; _ = try archive.append(d, label: "自动快照", now: now.addingTimeInterval(Double(i * 30))) }
        XCTAssertEqual(archive.count, 100)
        XCTAssertEqual(try PindoDocument.fromSnapshot(archive.baseline).tasks[0].note, "版本5")
        XCTAssertEqual(try PindoDocument.fromSnapshot(archive.state()).tasks[0].note, "版本104")
    }

    func testByteLimitCompactionAndOversizeKeepOriginalArchive() throws {
        var d = document(); var archive = try SnapshotArchive(document: d, now: now)
        for i in 0..<8 { d.tasks[0].note = String(repeating: "长", count: 200) + String(repeating: "\(i)", count: 60); _ = try archive.append(d, label: "快照", now: now) }
        let budget = try DocumentCodec.encode(archive).count * 3 / 4
        var compacted = archive
        try compacted.compact(maximumBytes: budget)
        XCTAssertLessThan(compacted.count, archive.count)
        XCTAssertLessThanOrEqual(try DocumentCodec.encode(compacted).count, budget)
        XCTAssertEqual(try compacted.state(), try archive.state())
        let before = archive
        d.tasks[0].note = String(repeating: "大", count: 5_000)
        XCTAssertThrowsError(try archive.append(d, label: "过大", maximumBytes: 1_000))
        XCTAssertEqual(archive, before)
    }

    func testAutosaveKeepsSnapshotHistorySeparateAndIdleCaptureSkips() throws {
        let repo = try PindoRepository(directory: directory, now: now)
        let item = task(); try repo.update { $0.tasks.append(item) }
        _ = try repo.captureIfChanged(now: now)
        let count = repo.archive.count, snapshotBytes = try repo.exportSnapshots()
        for text in ["一", "一二", "一二三", "一二三四", "一二三四五"] { try repo.stageNote(taskID: item.id, text: text) }
        XCTAssertTrue(repo.hasUnsavedChanges)
        XCTAssertEqual(try repo.sqlite.readDocument().tasks[0].note, "")
        try repo.flush()
        XCTAssertEqual(try repo.exportSnapshots(), snapshotBytes)
        XCTAssertEqual(repo.archive.count, count)
        XCTAssertTrue(try repo.captureIfChanged(now: now.addingTimeInterval(30)))
        XCTAssertEqual(repo.archive.count, count + 1)
        XCTAssertFalse(try repo.captureIfChanged(now: now.addingTimeInterval(60)))
        let reopened = try PindoRepository(directory: directory, now: now)
        XCTAssertEqual(reopened.document.tasks[0].note, "一二三四五")
        XCTAssertEqual(reopened.archive, repo.archive)
    }

    func testTitleAndNoteEditsCoalesceAndSurviveCommitFailure() throws {
        let repo = try PindoRepository(directory: directory, now: now)
        var item = task(); item.note = "原备注"; item.groupID = repo.document.groups.first?.id
        try repo.update { $0.tasks.append(item) }
        let snapshots = repo.archive.count, editedAt = now.addingTimeInterval(10)
        try repo.stageTitle(taskID: item.id, text: "修改", now: editedAt)
        try repo.stageTitle(taskID: item.id, text: "  修改后的事项 ✅  ", now: editedAt)
        try repo.stageNote(taskID: item.id, text: "修改后的备注", now: editedAt)
        var expected = item
        expected.title = "修改后的事项 ✅"; expected.note = "修改后的备注"; expected.updatedAt = editedAt
        XCTAssertEqual(repo.document.tasks.first, expected)
        XCTAssertEqual(try repo.sqlite.readDocument().tasks.first, item)
        XCTAssertThrowsError(try repo.stageTitle(taskID: item.id, text: " \n "))
        XCTAssertThrowsError(try repo.stageTitle(taskID: UUID(), text: "不存在"))
        failNextCommit(repo)
        XCTAssertThrowsError(try repo.flush())
        XCTAssertTrue(repo.hasUnsavedChanges)
        XCTAssertEqual(repo.document.tasks.first, expected)
        XCTAssertEqual(try repo.sqlite.readDocument().tasks.first, item)
        try repo.flush()
        XCTAssertFalse(repo.hasUnsavedChanges)
        XCTAssertEqual(repo.archive.count, snapshots)
        XCTAssertEqual(try PindoRepository(directory: directory).document.tasks.first, expected)
    }

    func testFailedCommitKeepsDocumentAndUnsavedNoteCanRetry() throws {
        let repo = try PindoRepository(directory: directory, now: now)
        let before = repo.document
        failNextCommit(repo)
        XCTAssertThrowsError(try repo.update { $0.tasks.append(self.task()) })
        XCTAssertEqual(repo.document, before)
        XCTAssertEqual(try repo.sqlite.readDocument(), before)
        let item = task(); try repo.update { $0.tasks.append(item) }
        try repo.stageNote(taskID: item.id, text: "不能丢")
        failNextCommit(repo)
        XCTAssertThrowsError(try repo.flush())
        XCTAssertTrue(repo.hasUnsavedChanges)
        XCTAssertEqual(repo.document.tasks[0].note, "不能丢")
        try repo.flush(); XCTAssertFalse(repo.hasUnsavedChanges)
    }

    func testCorruptDatabaseIsNeverReinitialized() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("pindo.sqlite"), corrupt = Data("not a SQLite database".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try PindoRepository(directory: directory))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testCorruptSnapshotDoesNotBlockSavingOrGetOverwritten() throws {
        let first = try PindoRepository(directory: directory, now: now), corrupt = Data("broken".utf8)
        try first.sqlite.database.execute("UPDATE app_meta SET value=? WHERE key='archive'", [.bytes(corrupt)])
        let repo = try PindoRepository(directory: directory, now: now)
        XCTAssertNotNil(repo.backupWarning)
        XCTAssertFalse(repo.canRestore)
        try repo.update { $0.tasks.append(self.task()) }
        XCTAssertFalse(try repo.captureIfChanged(now: now))
        XCTAssertEqual(try repo.exportSnapshots(), corrupt)
        XCTAssertEqual(try repo.sqlite.readDocument().tasks.count, 1)
    }

    func testRestoreGuardsUnsnapshottedCurrentContentAndPreservesLaterVersions() throws {
        let repo = try PindoRepository(directory: directory, now: now)
        let item = task(); try repo.update { $0.tasks.append(item) }; _ = try repo.captureIfChanged(now: now)
        let selected = repo.archive.records.last!.id
        try repo.stageNote(taskID: item.id, text: "新想法"); try repo.flush()
        try repo.restore(snapshotID: selected, now: now)
        XCTAssertEqual(repo.document.tasks[0].note, "")
        let guardRecord = repo.archive.records.first { $0.label == "恢复前的保护快照" }!
        try repo.restore(snapshotID: guardRecord.id, now: now)
        XCTAssertEqual(repo.document.tasks[0].note, "新想法")
    }

    func testRestoreRejectsCompactionThatWouldDiscardCurrentContent() throws {
        let repo = try PindoRepository(directory: directory, now: now)
        var item = task(); item.note = String(repeating: "甲", count: 3_400_000)
        try repo.update { $0.tasks.append(item) }
        _ = try repo.captureIfChanged(now: now)
        let target = repo.archive.records.last!.id
        try repo.stageNote(taskID: item.id, text: String(repeating: "乙", count: 3_400_000), now: now)
        try repo.flush()
        let documentBefore = repo.document, archiveBefore = repo.archive, diskBefore = try repo.sqlite.readDocument()

        XCTAssertThrowsError(try repo.restore(snapshotID: target, now: now)) { error in
            guard case PindoError.protectionSnapshotTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }

        XCTAssertTrue(repo.document == documentBefore, "Restore must preserve the current document when protection cannot fit")
        XCTAssertTrue(repo.archive == archiveBefore, "Restore must preserve the original archive")
        XCTAssertEqual(try repo.sqlite.readDocument(), diskBefore)
    }

    func testRestoreAtRetentionLimitPreservesTheExistingCurrentSnapshot() throws {
        let repo = try PindoRepository(directory: directory, now: now)
        try repo.update { $0.tasks.append(self.task()) }
        for i in 0..<SnapshotArchive.maximumCount {
            try repo.update { $0.tasks[0].note = "版本\(i)" }
            _ = try repo.captureIfChanged(now: now.addingTimeInterval(Double(i * 30)))
        }
        let targetID = repo.archive.baselineRecord.id
        let target = try PindoDocument.fromSnapshot(repo.archive.state(at: targetID))
        let documentBefore = repo.document, protectionID = repo.archive.records.last!.id

        try repo.restore(snapshotID: targetID, now: now)

        XCTAssertEqual(repo.document, target)
        XCTAssertEqual(repo.archive.count, SnapshotArchive.maximumCount)
        XCTAssertEqual(try PindoDocument.fromSnapshot(repo.archive.state(at: protectionID)), documentBefore)
        XCTAssertEqual(try repo.archive.validated(), repo.archive)
    }

    func testRestoreFailureRollsBackDataSnapshotsAndAllowsRetry() throws {
        let repo = try PindoRepository(directory: directory, now: now)
        let item = task(); try repo.update { $0.tasks.append(item) }; _ = try repo.captureIfChanged(now: now)
        let target = repo.archive.records.last!.id
        try repo.update { $0.tasks[0].note = "稍后修改" }
        let current = repo.document, snapshots = try repo.exportSnapshots()
        failNextCommit(repo)
        XCTAssertThrowsError(try repo.restore(snapshotID: target, now: now))
        XCTAssertEqual(repo.document, current)
        XCTAssertEqual(try repo.sqlite.readDocument(), current)
        XCTAssertEqual(try repo.exportSnapshots(), snapshots)
        let reopened = try PindoRepository(directory: directory, now: now)
        XCTAssertEqual(reopened.document, current)
        XCTAssertEqual(reopened.archive, repo.archive)
        try repo.restore(snapshotID: target, now: now)
        XCTAssertEqual(repo.document.tasks[0].note, "")
        XCTAssertTrue(repo.archive.records.contains { $0.label == "恢复前的保护快照" })
    }

    func testProgressPersistsAcrossDaysAndRolloverOnlyTouchesPendingScope() throws {
        var d = PindoDocument(); let today = try DayKey(year: 2026, month: 11, day: 6), yesterday = today.adding(days: -1)
        let group = d.groups[0].id
        d.tasks = [task("在跑", day: yesterday), task("未开始", day: yesterday), task("其他组", day: yesterday)]
        d.tasks[0].groupID = group; d.tasks[1].groupID = group
        try d.setPhase(.inProgress, for: d.tasks[0].id, now: now)
        d.rollover(to: today, groupID: group)
        XCTAssertEqual(d.tasks[0].plannedDay, yesterday)
        XCTAssertEqual(d.tasks[1].plannedDay, today)
        XCTAssertEqual(d.tasks[2].plannedDay, yesterday)
        let repo = try PindoRepository(directory: directory, now: now)
        try repo.update { $0 = d }
        XCTAssertEqual(try PindoRepository(directory: directory).document.tasks[0].phase, .inProgress)
    }

    func testGregorianNavigationHandlesLeapDayAndDST() throws {
        XCTAssertEqual(try DayKey(year: 2028, month: 2, day: 28).adding(days: 1).description, "2028-02-29")
        XCTAssertThrowsError(try DayKey(year: 2026, month: 2, day: 29))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let day = try DayKey(year: 2026, month: 3, day: 7)
        XCTAssertEqual(day.adding(days: 2, calendar: calendar).description, "2026-03-09")
    }

    func testImportValidatesBeforeReplacingAndAddsProtection() throws {
        let repo = try PindoRepository(directory: directory, now: now)
        let original = task(); try repo.update { $0.tasks.append(original) }
        let before = repo.document
        XCTAssertThrowsError(try repo.importDocument(Data("{}".utf8)))
        XCTAssertEqual(repo.document, before)
        var imported = PindoDocument(); imported.tasks = [task("导入的事项")]
        try repo.importDocument(DocumentCodec.encode(PindoExport(document: imported)))
        XCTAssertEqual(repo.document.tasks[0].title, "导入的事项")
        XCTAssertTrue(repo.archive.records.contains { $0.label == "导入前的保护快照" })
    }

    func testImportRejectsCompactionThatWouldDiscardTheExistingCurrentSnapshot() throws {
        let repo = try PindoRepository(directory: directory, now: now)
        var item = task(); item.note = String(repeating: "甲", count: 3_400_000)
        try repo.update { $0.tasks.append(item) }
        _ = try repo.captureIfChanged(now: now)
        var imported = repo.document
        imported.tasks[0].note = String(repeating: "乙", count: 3_400_000)
        let documentBefore = repo.document, archiveBefore = repo.archive, diskBefore = try repo.sqlite.readDocument()

        XCTAssertThrowsError(try repo.importDocument(DocumentCodec.encode(PindoExport(document: imported)))) { error in
            guard case PindoError.protectionSnapshotTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }

        XCTAssertTrue(repo.document == documentBefore, "Import must preserve the current document when protection cannot fit")
        XCTAssertTrue(repo.archive == archiveBefore, "Import must preserve the original archive")
        XCTAssertEqual(try repo.sqlite.readDocument(), diskBefore)
    }


    func testSnapshotFailurePreservesArchiveAndSavedCurrentData() throws {
        let repo = try PindoRepository(directory: directory, now: now)
        try repo.update { $0.tasks.append(self.task()) }
        let before = try repo.exportSnapshots()
        failNextCommit(repo)
        XCTAssertThrowsError(try repo.captureIfChanged(now: now))
        XCTAssertEqual(try repo.exportSnapshots(), before)
        XCTAssertEqual(repo.archive.count, 1)
        XCTAssertEqual(try repo.sqlite.readDocument().tasks.count, 1)
        XCTAssertTrue(repo.canRestore)
        XCTAssertTrue(try repo.captureIfChanged(now: now))
    }

    func testHotkeysRejectDuplicateReservedAndModifierOnlyBindings() throws {
        XCTAssertFalse(HotkeyBinding(keyCode: 12, modifiers: [.command], keyLabel: "Q").isValid)
        XCTAssertFalse(HotkeyBinding(keyCode: 58, modifiers: [.option], keyLabel: "Option").isValid)
        XCTAssertFalse(HotkeyBinding(keyCode: 35, modifiers: [.shift], keyLabel: "P").isValid)
        XCTAssertTrue(HotkeyBinding.showList.isValid)
        var doc = document(); doc.preferences.listHotkey = .quickAdd
        XCTAssertThrowsError(try doc.validated())
    }

    func testDefaultGroupPersistsAndRestoresWithSnapshots() throws {
        let repo = try PindoRepository(directory: directory, now: now)
        let firstGroup = repo.document.groups[0].id, secondGroup = repo.document.groups[1].id
        try repo.update { $0.preferences.defaultGroupID = firstGroup }
        _ = try repo.captureIfChanged(now: now)
        let target = repo.archive.records.last!.id
        try repo.update { $0.preferences.defaultGroupID = secondGroup }
        _ = try repo.captureIfChanged(now: now.addingTimeInterval(30))
        XCTAssertEqual(try PindoRepository(directory: directory).document.preferences.defaultGroupID, secondGroup)

        try repo.restore(snapshotID: target, now: now)

        XCTAssertEqual(repo.document.preferences.defaultGroupID, firstGroup)
        XCTAssertEqual(try PindoRepository(directory: directory).document.preferences.defaultGroupID, firstGroup)
    }


    func testRemovingDefaultGroupClearsPreferenceAndPreservesTaskContent() throws {
        var doc = document(); let group = doc.groups[0].id
        doc.preferences.defaultGroupID = group
        doc.tasks[0].groupID = group; doc.tasks[0].note = "保留的备注"
        doc.removeGroup(doc.groups[1].id)
        XCTAssertEqual(doc.preferences.defaultGroupID, group)

        doc.removeGroup(group)

        XCTAssertNil(doc.preferences.defaultGroupID)
        XCTAssertNil(doc.tasks[0].groupID)
        XCTAssertEqual(doc.tasks[0].title, "事项")
        XCTAssertEqual(doc.tasks[0].note, "保留的备注")
        XCTAssertEqual(try doc.validated(), doc)
    }

    func testPortableExportAndImportKeepDevicePreferencesLocal() throws {
        let repo = try PindoRepository(directory: directory, now: now)
        try repo.update {
            $0.tasks.append(self.task())
            $0.preferences.appearance = .dark
            $0.preferences.defaultGroupID = $0.groups[0].id
        }
        let exported = try repo.exportDocument()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["version", "tasks", "groups"]))
        var imported = document(); imported.groups = []
        try repo.importDocument(DocumentCodec.encode(PindoExport(document: imported)))
        XCTAssertEqual(repo.document.preferences.appearance, .dark)
        XCTAssertNil(repo.document.preferences.defaultGroupID)
        XCTAssertEqual(repo.document.tasks, imported.tasks)
        let before = repo.document
        XCTAssertThrowsError(try repo.importDocument(DocumentCodec.encode(imported)))
        var future = PindoExport(document: imported); future.version = 2
        XCTAssertThrowsError(try repo.importDocument(DocumentCodec.encode(future)))
        XCTAssertEqual(repo.document, before)
    }

    func testSharedPortableDocumentPreservesCrossPlatformValues() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("sync-vectors/portable-document.json")
        let source = try Data(contentsOf: url)
        let repo = try PindoRepository(directory: directory, now: now)
        try repo.update { $0.preferences.appearance = .dark }
        try repo.importDocument(source)
        XCTAssertEqual(repo.document.preferences.appearance, .dark)
        XCTAssertEqual(repo.document.tasks[0].startedAt, Date(timeIntervalSinceReferenceDate: 37.5))
        XCTAssertEqual(repo.document.tasks[1].createdAt, Date(timeIntervalSinceReferenceDate: 12.5))
        XCTAssertEqual(repo.document.tasks[1].parentID, repo.document.tasks[0].id)
        XCTAssertTrue(repo.document.tasks[0].isProgressExplicit)
        XCTAssertFalse(repo.document.tasks[1].isProgressExplicit)
        XCTAssertTrue(repo.document.tasks[0].note.contains("Mac 离线备注"))
        XCTAssertTrue(repo.document.tasks[0].note.contains("Android 离线备注"))

        // Optional UUID/date fields may be absent or JSON null. UUID casing is
        // presentation-only; every other portable field must remain identical.
        let optional = Set(["groupID", "parentID", "startedAt", "completedAt"])
        func normalized(_ value: JSONValue, key: String = "") -> JSONValue {
            switch value {
            case .object(let fields):
                return .object(fields.reduce(into: [:]) { result, entry in
                    if optional.contains(entry.key), entry.value == .null { return }
                    result[entry.key] = normalized(entry.value, key: entry.key)
                })
            case .array(let values): return .array(values.map { normalized($0) })
            case .string(let text) where ["id", "groupID", "parentID"].contains(key):
                return .string(text.lowercased())
            default: return value
            }
        }
        let exported = try repo.exportDocument()
        XCTAssertEqual(normalized(try DocumentCodec.decode(JSONValue.self, from: exported)),
                       normalized(try DocumentCodec.decode(JSONValue.self, from: source)))
        let decoded = try DocumentCodec.decode(PindoExport.self, from: exported)
        XCTAssertEqual(try decoded.document(preserving: repo.document.preferences), repo.document)
    }
}
