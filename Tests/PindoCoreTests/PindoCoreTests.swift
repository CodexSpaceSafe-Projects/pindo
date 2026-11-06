import XCTest
@testable import PindoCore

final class MemoryStorage: StorageIO {
    var files: [URL: Data] = [:]
    var writes: [URL] = []
    var failNextWriteTo: URL?
    func createDirectory(_ url: URL) throws {}
    func read(_ url: URL) throws -> Data? { files[url] }
    func write(_ data: Data, to url: URL) throws {
        if url == failNextWriteTo { failNextWriteTo = nil; throw CocoaError(.fileWriteNoPermission) }
        files[url] = data; writes.append(url)
    }
    func remove(_ url: URL) throws { files.removeValue(forKey: url) }
}

final class PindoCoreTests: XCTestCase {
    let directory = URL(fileURLWithPath: "/tmp/pindo-test-\(UUID().uuidString)")
    let now = Date(timeIntervalSince1970: 1_793_491_200)

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

    func testPrimaryAutosaveNeverWritesArchiveAndIdleCaptureSkips() throws {
        let io = MemoryStorage(); let repo = try PindoRepository(directory: directory, io: io, now: now)
        let item = task(); try repo.update { $0.tasks.append(item) }
        _ = try repo.captureIfChanged(now: now)
        let count = repo.archive.count, writes = io.writes.filter { $0 == repo.backupURL }.count
        for text in ["一", "一二", "一二三", "一二三四", "一二三四五"] { try repo.stageNote(taskID: item.id, text: text) }
        XCTAssertTrue(repo.hasUnsavedChanges)
        XCTAssertEqual(io.writes.filter { $0 == repo.backupURL }.count, writes)
        try repo.flush()
        XCTAssertEqual(repo.archive.count, count)
        XCTAssertTrue(try repo.captureIfChanged(now: now.addingTimeInterval(30)))
        XCTAssertEqual(repo.archive.count, count + 1)
        XCTAssertFalse(try repo.captureIfChanged(now: now.addingTimeInterval(60)))
        let reopened = try PindoRepository(directory: directory, io: io, now: now)
        XCTAssertEqual(reopened.document.tasks[0].note, "一二三四五")
        XCTAssertEqual(reopened.archive.count, repo.archive.count)
    }

    func testFailedPrimaryWriteKeepsDocumentAndUnsavedNoteCanRetry() throws {
        let io = MemoryStorage(); let repo = try PindoRepository(directory: directory, io: io, now: now)
        let before = repo.document
        io.failNextWriteTo = repo.dataURL
        XCTAssertThrowsError(try repo.update { $0.tasks.append(self.task()) })
        XCTAssertEqual(repo.document, before)
        let item = task(); try repo.update { $0.tasks.append(item) }
        try repo.stageNote(taskID: item.id, text: "不能丢")
        io.failNextWriteTo = repo.dataURL
        XCTAssertThrowsError(try repo.flush())
        XCTAssertTrue(repo.hasUnsavedChanges)
        XCTAssertEqual(repo.document.tasks[0].note, "不能丢")
        try repo.flush(); XCTAssertFalse(repo.hasUnsavedChanges)
    }

    func testCorruptPrimaryIsNeverOverwritten() throws {
        let io = MemoryStorage(), url = directory.appendingPathComponent("data.json")
        let corrupt = Data("not json".utf8); io.files[url] = corrupt
        XCTAssertThrowsError(try PindoRepository(directory: directory, io: io))
        XCTAssertEqual(io.files[url], corrupt)
        XCTAssertTrue(io.writes.isEmpty)
    }

    func testCorruptBackupDoesNotBlockPrimarySaveOrGetOverwritten() throws {
        let io = MemoryStorage(); let first = try PindoRepository(directory: directory, io: io, now: now)
        let corrupt = Data("broken".utf8); io.files[first.backupURL] = corrupt
        let repo = try PindoRepository(directory: directory, io: io, now: now)
        XCTAssertNotNil(repo.backupWarning)
        try repo.update { $0.tasks.append(self.task()) }
        XCTAssertFalse(try repo.captureIfChanged(now: now))
        XCTAssertEqual(io.files[repo.backupURL], corrupt)
    }

    func testRestoreGuardsUnsnapshottedCurrentContentAndPreservesLaterVersions() throws {
        let io = MemoryStorage(); let repo = try PindoRepository(directory: directory, io: io, now: now)
        let item = task(); try repo.update { $0.tasks.append(item) }; _ = try repo.captureIfChanged(now: now)
        let selected = repo.archive.records.last!.id
        try repo.stageNote(taskID: item.id, text: "新想法"); try repo.flush()
        try repo.restore(snapshotID: selected, now: now)
        XCTAssertEqual(repo.document.tasks[0].note, "")
        let guardRecord = repo.archive.records.first { $0.label == "恢复前的保护快照" }!
        try repo.restore(snapshotID: guardRecord.id, now: now)
        XCTAssertEqual(repo.document.tasks[0].note, "新想法")
        XCTAssertNil(io.files[repo.journalURL])
    }

    func testInterruptedRestoreCompletesFromJournalOnReopen() throws {
        let io = MemoryStorage(); let repo = try PindoRepository(directory: directory, io: io, now: now)
        let item = task(); try repo.update { $0.tasks.append(item) }; _ = try repo.captureIfChanged(now: now)
        let target = repo.archive.records.last!.id
        try repo.update { $0.tasks[0].note = "稍后修改" }
        io.failNextWriteTo = repo.dataURL
        XCTAssertThrowsError(try repo.restore(snapshotID: target, now: now))
        XCTAssertTrue(repo.needsRecovery)
        XCTAssertNotNil(io.files[repo.journalURL])
        XCTAssertThrowsError(try repo.update { $0.tasks.removeAll() })
        let reopened = try PindoRepository(directory: directory, io: io, now: now)
        XCTAssertEqual(reopened.document.tasks[0].note, "")
        XCTAssertNil(io.files[repo.journalURL])
        XCTAssertTrue(reopened.archive.records.contains { $0.label == "恢复前的保护快照" })
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
        let io = MemoryStorage(); let repo = try PindoRepository(directory: directory, io: io, now: now)
        try repo.update { $0 = d }
        XCTAssertEqual(try PindoRepository(directory: directory, io: io).document.tasks[0].phase, .inProgress)
    }

    func testGregorianNavigationHandlesLeapDayAndDST() throws {
        XCTAssertEqual(try DayKey(year: 2028, month: 2, day: 28).adding(days: 1).description, "2028-02-29")
        XCTAssertThrowsError(try DayKey(year: 2026, month: 2, day: 29))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let day = try DayKey(year: 2026, month: 3, day: 7)
        XCTAssertEqual(day.adding(days: 2, calendar: calendar).description, "2026-03-09")
    }

    func testHandoffIncludesAttachedNoteWithoutInventingExecution() {
        var item = task("优化导航"); item.note = "先给两版方案\n保留登录入口"
        XCTAssertEqual(item.handoffText, "任务：优化导航\n\n说明：\n先给两版方案\n保留登录入口")
        XCTAssertEqual(item.phase, .pending)
    }

    func testImportValidatesBeforeReplacingAndAddsProtection() throws {
        let io = MemoryStorage(); let repo = try PindoRepository(directory: directory, io: io, now: now)
        let original = task(); try repo.update { $0.tasks.append(original) }
        let before = repo.document
        XCTAssertThrowsError(try repo.importDocument(Data("{}".utf8)))
        XCTAssertEqual(repo.document, before)
        var imported = PindoDocument(); imported.tasks = [task("导入的事项")]
        try repo.importDocument(DocumentCodec.encode(imported))
        XCTAssertEqual(repo.document.tasks[0].title, "导入的事项")
        XCTAssertTrue(repo.archive.records.contains { $0.label == "导入前的保护快照" })
    }

    func testRealFilesRoundTripWithSeparatePrimaryAndBackup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PindoRealIO-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try PindoRepository(directory: folder, now: now)
        let item = task(); try repo.update { $0.tasks.append(item) }
        let backupBefore = try Data(contentsOf: repo.backupURL)
        try repo.stageNote(taskID: item.id, text: "真实文件往返 ✅"); try repo.flush()
        XCTAssertEqual(try Data(contentsOf: repo.backupURL), backupBefore)
        XCTAssertTrue(try repo.captureIfChanged(now: now))
        let reopened = try PindoRepository(directory: folder)
        XCTAssertEqual(reopened.document.tasks[0].note, "真实文件往返 ✅")
        XCTAssertEqual(reopened.archive.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.journalURL.path))
    }

    func testBackupWriteFailurePreservesOldArchiveAndSavedCurrentData() throws {
        let io = MemoryStorage(); let repo = try PindoRepository(directory: directory, io: io, now: now)
        try repo.update { $0.tasks.append(self.task()) }
        let before = io.files[repo.backupURL]
        io.failNextWriteTo = repo.backupURL
        XCTAssertThrowsError(try repo.captureIfChanged(now: now))
        XCTAssertEqual(io.files[repo.backupURL], before)
        XCTAssertEqual(repo.archive.count, 1)
        XCTAssertEqual(repo.document.tasks.count, 1)
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
}
