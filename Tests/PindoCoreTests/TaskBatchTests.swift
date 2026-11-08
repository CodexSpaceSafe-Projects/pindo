import XCTest
@testable import PindoCore

final class TaskBatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_491_200)

    private func makeDocument() throws -> PindoDocument {
        var document = PindoDocument()
        let day = try DayKey(year: 2026, month: 11, day: 8)
        document.preferences.defaultGroupID = document.groups[0].id
        document.tasks = (0..<4).map { index in
            TodoItem(title: "事项 \(index)", note: "备注 \(index)", plannedDay: day.adding(days: index),
                     groupID: document.groups[index == 3 ? 1 : 0].id, order: index, now: now)
        }
        try document.setPhase(.inProgress, for: document.tasks[1].id, now: now.addingTimeInterval(5))
        try document.setPhase(.completed, for: document.tasks[2].id, now: now.addingTimeInterval(10))
        return document
    }

    func testBatchCompletionAndReopeningPreserveOtherFieldsAndSkipUnchangedTasks() throws {
        var document = try makeDocument()
        let original = document
        let ids = Set(document.tasks.prefix(3).map(\.id)).union([UUID()])
        let completedAt = now.addingTimeInterval(60)
        XCTAssertEqual(try document.applyBatch(.setPhase(.completed), to: ids, now: completedAt), 2)
        for index in 0..<2 {
            XCTAssertEqual(document.tasks[index].phase, .completed)
            XCTAssertEqual(document.tasks[index].completedAt, completedAt)
            XCTAssertEqual(document.tasks[index].note, original.tasks[index].note)
            XCTAssertEqual(document.tasks[index].plannedDay, original.tasks[index].plannedDay)
            XCTAssertEqual(document.tasks[index].groupID, original.tasks[index].groupID)
            XCTAssertEqual(document.tasks[index].order, original.tasks[index].order)
        }
        XCTAssertEqual(document.tasks[2], original.tasks[2])
        XCTAssertEqual(document.tasks[3], original.tasks[3])
        let completed = document
        XCTAssertEqual(try document.applyBatch(.setPhase(.completed), to: ids, now: now.addingTimeInterval(90)), 0)
        XCTAssertEqual(document, completed)

        XCTAssertEqual(try document.applyBatch(.setPhase(.pending), to: ids, now: now.addingTimeInterval(120)), 3)
        for task in document.tasks.prefix(3) { XCTAssertEqual(task.phase, .pending); XCTAssertNil(task.completedAt) }
        XCTAssertEqual(document.tasks[3], original.tasks[3])
        XCTAssertEqual(document.preferences, original.preferences)
        XCTAssertEqual(try document.validated(), document)
    }

    func testBatchGroupingSupportsUngroupedAndRejectsMissingGroupsBeforeAnyChanges() throws {
        var document = try makeDocument()
        let original = document
        let ids = Set([document.tasks[0].id, document.tasks[2].id])
        let group = document.groups[1].id
        XCTAssertEqual(try document.applyBatch(.setGroup(group), to: ids, now: now.addingTimeInterval(60)), 2)
        for index in [0, 2] {
            XCTAssertEqual(document.tasks[index].groupID, group)
            XCTAssertEqual(document.tasks[index].phase, original.tasks[index].phase)
            XCTAssertEqual(document.tasks[index].note, original.tasks[index].note)
            XCTAssertEqual(document.tasks[index].plannedDay, original.tasks[index].plannedDay)
        }
        XCTAssertEqual(document.tasks[1], original.tasks[1])
        XCTAssertEqual(document.tasks[3], original.tasks[3])
        XCTAssertEqual(try document.applyBatch(.setGroup(nil), to: ids, now: now.addingTimeInterval(120)), 2)
        XCTAssertTrue(document.tasks.filter { ids.contains($0.id) }.allSatisfy { $0.groupID == nil })
        XCTAssertEqual(document.preferences.defaultGroupID, original.preferences.defaultGroupID)
        let beforeInvalid = document
        XCTAssertThrowsError(try document.applyBatch(.setGroup(UUID()), to: ids))
        XCTAssertEqual(document, beforeInvalid)
        XCTAssertEqual(try document.applyBatch(.setGroup(UUID()), to: []), 0)
    }

    func testBatchDeleteOnlyRemovesSelectedIDsAndDoesNotChangeGroupsOrOtherTasks() throws {
        var document = try makeDocument()
        let original = document
        let ids = Set([document.tasks[0].id, document.tasks[2].id, UUID()])
        XCTAssertEqual(try document.applyBatch(.delete, to: ids), 2)
        XCTAssertEqual(document.tasks, [original.tasks[1], original.tasks[3]])
        XCTAssertEqual(document.groups, original.groups)
        XCTAssertEqual(document.preferences, original.preferences)
        let remaining = document
        XCTAssertEqual(try document.applyBatch(.delete, to: ids), 0)
        XCTAssertEqual(document, remaining)
    }

    func testBatchWritesOnePrimaryDocumentAndRollsBackCompletelyOnWriteFailure() throws {
        let io = MemoryStorage()
        let directory = URL(fileURLWithPath: "/tmp/pindo-batch-\(UUID().uuidString)")
        let repository = try PindoRepository(directory: directory, io: io, now: now)
        let document = try makeDocument()
        try repository.update { $0 = document }
        let ids = Set(document.tasks.prefix(3).map(\.id))
        try repository.stageNote(taskID: document.tasks[0].id, text: "尚未补存的备注")
        let primaryWrites = io.writes.filter { $0 == repository.dataURL }.count
        let backupWrites = io.writes.filter { $0 == repository.backupURL }.count
        try repository.update { _ = try $0.applyBatch(.setPhase(.completed), to: ids, now: now.addingTimeInterval(60)) }
        XCTAssertEqual(io.writes.filter { $0 == repository.dataURL }.count, primaryWrites + 1)
        XCTAssertEqual(io.writes.filter { $0 == repository.backupURL }.count, backupWrites)
        XCTAssertEqual(repository.document.tasks[0].note, "尚未补存的备注")
        XCTAssertFalse(repository.hasUnsavedChanges)
        let saved = repository.document, bytes = io.files[repository.dataURL]

        io.failNextWriteTo = repository.dataURL
        XCTAssertThrowsError(try repository.update { _ = try $0.applyBatch(.delete, to: ids) })
        XCTAssertEqual(repository.document, saved)
        XCTAssertEqual(io.files[repository.dataURL], bytes)
        XCTAssertEqual(try PindoRepository(directory: directory, io: io).document, saved)
    }
}
