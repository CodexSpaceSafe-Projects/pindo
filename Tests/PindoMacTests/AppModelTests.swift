import XCTest
import AppKit
import SwiftUI
import PindoCore
@testable import Pindo

final class AppModelTests: XCTestCase {
    @MainActor private func makeModel() throws -> AppModel {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("PindoMacTests-\(UUID().uuidString)")
        let model = try AppModel(useSQLite: false, directory: path)
        model.playFeedback = { _ in }
        return model
    }

    @MainActor func testCopyingTaskPreservesStatusAndCopiesPlainContent() async throws {
        let model = try makeModel()
        XCTAssertTrue(model.addTask(title: "确认首页方案", note: "先给两个方向", day: DayKey(), groupID: nil))
        let item = model.document.tasks[0]
        var copied = ""
        model.writeClipboard = { copied = $0; return true }
        XCTAssertTrue(model.copyTask(item))
        XCTAssertEqual(copied, "确认首页方案\n\n先给两个方向")
        XCTAssertEqual(model.document.tasks[0], item)
        model.writeClipboard = { _ in false }
        XCTAssertFalse(model.copyTask(item))
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor func testCopyingTaskMetadataUsesCurrentCycleAndStableRelationships() throws {
        let model = try makeModel(), day = model.today
        let creation = Date(timeIntervalSince1970: 0.125), group = try XCTUnwrap(model.document.groups.first)
        let parent = TodoItem(title: "父项", plannedDay: day, now: creation)
        let item = TodoItem(title: "事项", plannedDay: day, groupID: group.id, parentID: parent.id, now: creation)
        XCTAssertNotEqual(item.id, parent.id)
        XCTAssertTrue(model.commit { document in
            try document.insertTask(parent, now: creation)
            try document.insertTask(item, now: creation)
        })
        var copied = ""
        model.writeClipboard = { copied = $0; return true }
        func metadata() throws -> [String: JSONValue] {
            XCTAssertTrue(model.copyTaskMetadata(item.id))
            return try JSONDecoder().decode([String: JSONValue].self, from: Data(copied.utf8))
        }

        model.advancePhase(item, now: creation.addingTimeInterval(10))
        model.advancePhase(item, now: creation.addingTimeInterval(20))
        let first = try metadata()
        XCTAssertEqual(first["id"], .string(item.id.uuidString))
        XCTAssertEqual(first["createdAt"], .string("1970-01-01T00:00:00.125Z"))
        XCTAssertEqual(first["startedAt"], .string("1970-01-01T00:00:10.125Z"))
        XCTAssertEqual(first["completedAt"], .string("1970-01-01T00:00:20.125Z"))
        XCTAssertEqual(first["groupID"], .string(group.id.uuidString))
        XCTAssertEqual(first["groupName"], .string(group.name))
        XCTAssertEqual(first["parentID"], .string(parent.id.uuidString))
        XCTAssertEqual(first["parentTitle"], .string(parent.title))

        model.advancePhase(item, now: creation.addingTimeInterval(30))
        let reopened = try metadata()
        XCTAssertEqual(reopened["phase"], .string("pending"))
        XCTAssertEqual(reopened["startedAt"], .null)
        XCTAssertEqual(reopened["completedAt"], .null)
        model.advancePhase(item, now: creation.addingTimeInterval(40))
        XCTAssertEqual(model.managedTasks(query: "", status: .inProgress, group: .group(group.id)).map(\.id), [item.id])
        model.advancePhase(item, now: creation.addingTimeInterval(50))
        let second = try metadata()
        XCTAssertEqual(second["id"], first["id"])
        XCTAssertEqual(second["createdAt"], first["createdAt"])
        XCTAssertEqual(second["startedAt"], .string("1970-01-01T00:00:40.125Z"))
        XCTAssertEqual(second["completedAt"], .string("1970-01-01T00:00:50.125Z"))
        let saved = try PindoRepository(directory: model.repository.directory).document
        XCTAssertEqual(saved.tasks.first { $0.id == item.id }, model.task(item.id))
    }

    @MainActor func testNoteAutosavesAfterDebounceWithoutTakingSnapshot() async throws {
        let model = try makeModel()
        XCTAssertTrue(model.addTask(title: "备注", day: DayKey(), groupID: nil))
        let id = model.document.tasks[0].id
        let snapshots = model.repository.archive.count
        for text in ["一", "一二", "一二三四五"] { model.updateNote(id, text: text) }
        XCTAssertTrue(model.repository.hasUnsavedChanges)
        try await Task.sleep(nanoseconds: 850_000_000)
        XCTAssertFalse(model.repository.hasUnsavedChanges)
        XCTAssertEqual(model.repository.archive.count, snapshots)
        let reopened = try PindoRepository(directory: model.repository.directory)
        XCTAssertEqual(reopened.document.tasks[0].note, "一二三四五")
        model.captureSnapshot()
        XCTAssertEqual(model.repository.archive.count, snapshots + 1)
        model.captureSnapshot()
        XCTAssertEqual(model.repository.archive.count, snapshots + 1)
    }

    @MainActor func testNotePageAutosavesTitleAndNoteWithoutChangingTaskMetadata() async throws {
        let model = try makeModel()
        defer { try? FileManager.default.removeItem(at: model.repository.directory) }
        let group = model.document.groups.first?.id
        XCTAssertTrue(model.addTask(title: "原事项", note: "原备注", day: DayKey().adding(days: 2), groupID: group))
        let task = try XCTUnwrap(model.document.tasks.first)
        let snapshots = model.repository.archive.count
        model.updateTitle(task.id, text: "  修改后的事项  ")
        model.updateNote(task.id, text: "修改后的备注")
        // Invalid drafts must not cancel pending valid text saves.
        model.updateTitle(task.id, text: " \n ")
        XCTAssertTrue(model.repository.hasUnsavedChanges)
        try await Task.sleep(nanoseconds: 850_000_000)
        XCTAssertFalse(model.repository.hasUnsavedChanges)
        XCTAssertEqual(model.repository.archive.count, snapshots)
        var expected = task
        expected.title = "修改后的事项"; expected.note = "修改后的备注"
        expected.updatedAt = try XCTUnwrap(model.task(task.id)).updatedAt
        let reopened = try PindoRepository(directory: model.repository.directory)
        XCTAssertEqual(reopened.document.tasks.first, expected)

        model.noteID = task.id
        model.updateTitle(task.id, text: "返回前的修改")
        model.leaveNote()
        XCTAssertNil(model.noteID)
        XCTAssertFalse(model.repository.hasUnsavedChanges)
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document.tasks.first?.title, "返回前的修改")
    }

    @MainActor func testInvalidTaskEditDoesNotCancelPendingNoteAutosave() async throws {
        let model = try makeModel(), day = DayKey()
        XCTAssertTrue(model.addTask(title: "备注", day: day, groupID: nil))
        let task = try XCTUnwrap(model.document.tasks.first)
        model.updateNote(task.id, text: "等待自动保存")
        XCTAssertFalse(model.edit(task.id, title: "", day: day, groupID: nil))

        try await Task.sleep(nanoseconds: 850_000_000)
        let reopened = try PindoRepository(directory: model.repository.directory)
        XCTAssertEqual(reopened.document.tasks.first?.title, task.title)
        XCTAssertEqual(reopened.document.tasks.first?.note, "等待自动保存")
        XCTAssertFalse(model.repository.hasUnsavedChanges)
    }

    @MainActor func testFlushPublishesDocumentOnlyWhenSyncMetadataChanges() throws {
        let model = try makeModel()
        defer { try? FileManager.default.removeItem(at: model.repository.directory) }
        XCTAssertTrue(model.addTask(title: "备注", day: DayKey(), groupID: nil))
        let id = try XCTUnwrap(model.document.tasks.first?.id)
        var publications = 0
        let observation = model.$document.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }

        XCTAssertTrue(model.flush())
        XCTAssertEqual(publications, 0)
        model.updateNote(id, text: "本地备注")
        XCTAssertEqual(publications, 1)
        XCTAssertTrue(model.flush())
        XCTAssertEqual(publications, 1)

        try model.repository.enableSync()
        model.refreshAfterCloudSync()
        publications = 0
        model.updateNote(id, text: "同步备注")
        XCTAssertEqual(publications, 1)
        XCTAssertTrue(model.flush())
        XCTAssertEqual(publications, 2)
        XCTAssertEqual(model.document, model.repository.document)
        XCTAssertTrue(model.flush())
        XCTAssertEqual(publications, 2)
    }

    @MainActor func testParallelTasksStayVisibleAcrossDatesAndRespectGroupFilter() async throws {
        let model = try makeModel(), day = DayKey().adding(days: -5)
        let group = model.document.groups[0].id
        XCTAssertTrue(model.addTask(title: "任务 A", day: day, groupID: group))
        XCTAssertTrue(model.addTask(title: "任务 B", day: day, groupID: nil))
        model.setPhase(model.document.tasks[0], .inProgress)
        model.setPhase(model.document.tasks[1], .inProgress)
        model.selectedDay = DayKey().adding(days: 8)
        XCTAssertEqual(model.inProgress.count, 2)
        model.groupFilter = .group(group)
        XCTAssertEqual(model.inProgress.map(\.title), ["任务 A"])
        model.setPhase(model.inProgress[0], .completed)
        XCTAssertTrue(model.inProgress.isEmpty)
    }

    @MainActor func testStatusClicksPersistTheCycleWithoutMovingAnActiveTaskToAnotherSection() async throws {
        let model = try makeModel()
        let day = model.today
        model.selectedDay = day
        XCTAssertTrue(model.addTask(title: "当前事项", day: day, groupID: nil))
        XCTAssertTrue(model.addTask(title: "下一件事", day: day, groupID: nil))
        let task = model.document.tasks[0]
        let originalOrder = model.unfinished.map(\.id)
        var feedback: [TaskFeedback] = []
        model.playFeedback = { feedback.append($0) }

        model.advancePhase(task)
        XCTAssertEqual(model.task(task.id)?.phase, .inProgress)
        XCTAssertNotNil(model.task(task.id)?.startedAt)
        XCTAssertEqual(model.unfinished.map(\.id), originalOrder)
        XCTAssertTrue(model.completed.isEmpty)
        XCTAssertEqual(feedback, [.started])
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document.tasks[0].phase, .inProgress)

        // Repeated clicks may still carry an older row value; advance from the stored state.
        model.advancePhase(task)
        XCTAssertEqual(model.task(task.id)?.phase, .completed)
        XCTAssertNotNil(model.task(task.id)?.completedAt)
        XCTAssertEqual(model.completed.map(\.id), [task.id])
        XCTAssertEqual(model.unfinished.count, 1)
        XCTAssertEqual(feedback, [.started, .completed])
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document.tasks[0].phase, .completed)

        model.advancePhase(task)
        XCTAssertEqual(model.task(task.id)?.phase, .pending)
        XCTAssertNil(model.task(task.id)?.completedAt)
        XCTAssertEqual(model.unfinished.map(\.id), originalOrder)
        XCTAssertTrue(model.completed.isEmpty)
        XCTAssertEqual(feedback, [.started, .completed])

        model.advancePhase(task)
        let before = model.document
        try FileManager.default.removeItem(at: model.repository.dataURL)
        try FileManager.default.createDirectory(at: model.repository.dataURL, withIntermediateDirectories: false)
        model.advancePhase(task)
        XCTAssertEqual(model.document, before)
        XCTAssertEqual(model.task(task.id)?.phase, .inProgress)
        XCTAssertEqual(feedback, [.started, .completed, .started])
        XCTAssertEqual(model.saveState, .failed)
    }

    @MainActor func testChildStatusClicksPersistPartialAncestorProgressAtomically() async throws {
        let model = try makeModel(), day = model.today
        XCTAssertTrue(model.addTask(title: "父项", day: day, groupID: nil))
        let root = try XCTUnwrap(model.document.tasks.last)
        XCTAssertTrue(model.addTask(title: "子项", day: day, groupID: nil, parentID: root.id))
        let child = try XCTUnwrap(model.document.tasks.last)
        XCTAssertTrue(model.addTask(title: "孙项", day: day, groupID: nil, parentID: child.id))
        let grandchild = try XCTUnwrap(model.document.tasks.last)
        XCTAssertTrue(model.addTask(title: "未开始子项", day: day, groupID: nil, parentID: root.id))
        let sibling = try XCTUnwrap(model.document.tasks.last)
        var feedback: [TaskFeedback] = []
        model.playFeedback = { feedback.append($0) }
        let start = root.createdAt.addingTimeInterval(1)

        model.advancePhase(grandchild, now: start)
        model.advancePhase(grandchild, now: start.addingTimeInterval(1))
        XCTAssertEqual(model.task(root.id)?.phase, .inProgress)
        XCTAssertEqual(model.task(root.id)?.startedAt, start)
        XCTAssertNil(model.task(root.id)?.completedAt)
        XCTAssertEqual(model.task(child.id)?.phase, .completed)
        XCTAssertEqual(model.task(sibling.id), sibling)
        XCTAssertEqual(feedback, [.started, .completed])
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document, model.document)

        let before = model.document
        try FileManager.default.removeItem(at: model.repository.dataURL)
        try FileManager.default.createDirectory(at: model.repository.dataURL, withIntermediateDirectories: false)
        XCTAssertFalse(model.applyBatch(.setPhase(.completed), to: [sibling.id]))
        XCTAssertEqual(model.document, before)
        XCTAssertEqual(feedback, [.started, .completed])
    }

    @MainActor func testParentStatusClickStartsThenCompletesAndReopensTheWholeBranch() async throws {
        let model = try makeModel(), day = model.today
        XCTAssertTrue(model.addTask(title: "父项", day: day, groupID: nil))
        let root = try XCTUnwrap(model.document.tasks.last)
        XCTAssertTrue(model.addTask(title: "子项", day: day, groupID: nil, parentID: root.id))
        let child = try XCTUnwrap(model.document.tasks.last)
        XCTAssertTrue(model.addTask(title: "孙项", day: day, groupID: nil, parentID: child.id))
        let grandchild = try XCTUnwrap(model.document.tasks.last)
        let branchIDs = Set(model.document.tasks.map(\.id))
        XCTAssertTrue(model.addTask(title: "独立事项", day: day, groupID: nil))
        let independent = try XCTUnwrap(model.document.tasks.last)
        var saves = 0, feedback: [TaskFeedback] = []
        model.preferencesChanged = { _ in saves += 1 }
        model.playFeedback = { feedback.append($0) }

        let startedAt = root.createdAt.addingTimeInterval(1)
        model.advancePhase(root, now: startedAt)
        XCTAssertEqual(model.task(root.id)?.phase, .inProgress)
        XCTAssertEqual(model.task(root.id)?.startedAt, startedAt)
        XCTAssertEqual(model.task(child.id), child)
        XCTAssertEqual(model.task(grandchild.id), grandchild)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(feedback, [.started])

        let completedAt = startedAt.addingTimeInterval(1)
        model.advancePhase(root, now: completedAt)
        let completed = model.document.tasks.filter { branchIDs.contains($0.id) }
        XCTAssertEqual(completed.map(\.phase), [.completed, .completed, .completed])
        XCTAssertTrue(completed.allSatisfy { $0.completedAt == completedAt })
        XCTAssertNil(model.task(child.id)?.startedAt)
        XCTAssertEqual(model.task(independent.id), independent)
        XCTAssertEqual(saves, 2)
        XCTAssertEqual(feedback, [.started, .completed])
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document, model.document)

        model.advancePhase(root, now: completedAt.addingTimeInterval(1))
        let reopened = model.document.tasks.filter { branchIDs.contains($0.id) }
        XCTAssertEqual(reopened.map(\.phase), [.pending, .pending, .pending])
        XCTAssertTrue(reopened.allSatisfy { $0.startedAt == nil && $0.completedAt == nil })
        XCTAssertEqual(model.task(independent.id), independent)
        XCTAssertEqual(saves, 3)
        XCTAssertEqual(feedback, [.started, .completed])
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document, model.document)

        model.advancePhase(grandchild)
        XCTAssertEqual(model.task(root.id)?.phase, .inProgress)
        model.advancePhase(root)
        XCTAssertEqual(model.document.tasks.filter { branchIDs.contains($0.id) }.map(\.phase), [.completed, .completed, .completed])
        XCTAssertEqual(saves, 5)
        XCTAssertEqual(feedback, [.started, .completed, .started, .completed])
    }

    @MainActor func testUnfinishedListMixesPhasesAndMovesAcrossThemWithGroupFiltering() async throws {
        let model = try makeModel(), today = DayKey()
        model.today = today; model.selectedDay = today
        let group = model.document.groups[0].id
        XCTAssertTrue(model.addTask(title: "跨日期进行中", day: today.adding(days: -2), groupID: group))
        XCTAssertTrue(model.addTask(title: "当前待办", day: today, groupID: group))
        XCTAssertTrue(model.addTask(title: "当前进行中", day: today, groupID: group))
        XCTAssertTrue(model.addTask(title: "其他分组", day: today, groupID: nil))
        XCTAssertTrue(model.addTask(title: "未来待办", day: today.adding(days: 2), groupID: group))
        for index in [0, 2, 3] { model.advancePhase(model.document.tasks[index]) }
        model.groupFilter = .group(group)
        XCTAssertEqual(model.unfinished.map(\.title), ["跨日期进行中", "当前待办", "当前进行中"])
        XCTAssertEqual(Set(model.unfinished.map(\.id)).count, model.unfinished.count)
        XCTAssertTrue(model.previous.isEmpty)

        let active = model.document.tasks[2], pending = model.document.tasks[1]
        model.move(active, offset: -1)
        XCTAssertEqual(model.unfinished.map(\.id), [model.document.tasks[0].id, active.id, pending.id])
        model.move(pending, offset: -1)
        XCTAssertEqual(model.unfinished.map(\.title), ["跨日期进行中", "当前待办", "当前进行中"])
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document, model.document)

        model.selectedDay = today.adding(days: 2)
        XCTAssertEqual(model.unfinished.map(\.title), ["跨日期进行中", "当前进行中", "未来待办"])
        model.groupFilter = .ungrouped
        XCTAssertEqual(model.unfinished.map(\.title), ["其他分组"])
    }

    @MainActor func testManagementReorderingOnlyChangesTheProvidedDayAndSearchResults() async throws {
        let model = try makeModel(), today = DayKey()
        XCTAssertTrue(model.addTask(title: "更早日期", day: today.adding(days: -1), groupID: nil))
        XCTAssertTrue(model.addTask(title: "匹配 A", day: today, groupID: nil))
        XCTAssertTrue(model.addTask(title: "隐藏事项", day: today, groupID: nil))
        XCTAssertTrue(model.addTask(title: "匹配 B", day: today, groupID: nil))
        let earlier = model.document.tasks[0], hidden = model.document.tasks[2]
        let visible = model.managedTasks(query: "匹配 ", status: .all, group: .all).filter { $0.plannedDay == today }
        XCTAssertEqual(visible.map(\.title), ["匹配 A", "匹配 B"])
        model.move(visible[1], offset: -1, within: visible)
        XCTAssertEqual(model.managedTasks(query: "匹配 ", status: .all, group: .all).map(\.title), ["匹配 B", "匹配 A"])
        XCTAssertEqual(model.task(earlier.id), earlier)
        XCTAssertEqual(model.task(hidden.id), hidden)
    }

    @MainActor func testBatchActionsUseFilteredIDsPersistOnceAndOnlyPlayOneCompletionSound() async throws {
        let model = try makeModel(), today = DayKey()
        let group = model.document.groups[0].id, otherGroup = model.document.groups[1].id
        for index in 0..<3 {
            XCTAssertTrue(model.addTask(title: "选择 \(index)", note: "备注 \(index)", day: today.adding(days: index), groupID: group))
        }
        XCTAssertTrue(model.addTask(title: "选择 其他分组", day: today, groupID: otherGroup))
        XCTAssertTrue(model.addTask(title: "未选事项", day: today, groupID: group))
        model.setPhase(model.document.tasks[1], .inProgress)
        model.setPhase(model.document.tasks[2], .completed)
        let untouched = Array(model.document.tasks.suffix(2))
        let selected = Set(model.managedTasks(query: "选择", status: .all, group: .group(group)).map(\.id))
        XCTAssertEqual(selected.count, 3)
        model.updateNote(model.document.tasks[0].id, text: "最新草稿")
        var saves = 0, feedback: [TaskFeedback] = []
        model.preferencesChanged = { _ in saves += 1 }
        model.playFeedback = { feedback.append($0) }
        let snapshots = model.repository.archive.count

        XCTAssertTrue(model.applyBatch(.setPhase(.completed), to: selected))
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(feedback, [.completed])
        XCTAssertTrue(model.document.tasks.filter { selected.contains($0.id) }.allSatisfy { $0.phase == .completed })
        XCTAssertEqual(model.document.tasks[0].note, "最新草稿")
        XCTAssertEqual(Array(model.document.tasks.suffix(2)), untouched)
        XCTAssertEqual(model.repository.archive.count, snapshots)
        XCTAssertTrue(model.applyBatch(.setPhase(.completed), to: selected))
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(feedback, [.completed])

        XCTAssertTrue(model.applyBatch(.setGroup(otherGroup), to: selected))
        XCTAssertTrue(model.document.tasks.filter { selected.contains($0.id) }.allSatisfy { $0.groupID == otherGroup })
        XCTAssertTrue(model.applyBatch(.setGroup(nil), to: selected))
        XCTAssertTrue(model.document.tasks.filter { selected.contains($0.id) }.allSatisfy { $0.groupID == nil })
        XCTAssertTrue(model.applyBatch(.setPhase(.pending), to: selected))
        XCTAssertTrue(model.document.tasks.filter { selected.contains($0.id) }.allSatisfy { $0.phase == .pending && $0.completedAt == nil })
        model.noteID = model.document.tasks[0].id; model.editingID = model.document.tasks[1].id
        XCTAssertTrue(model.applyBatch(.delete, to: selected))
        XCTAssertTrue(model.applyBatch(.delete, to: selected))
        XCTAssertEqual(saves, 5)
        XCTAssertEqual(feedback, [.completed, .deleted])
        XCTAssertNil(model.noteID); XCTAssertNil(model.editingID)
        XCTAssertEqual(model.document.tasks, untouched)
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document, model.document)
    }

    @MainActor func testBatchWriteFailureKeepsAllTasksAndCanBeRetried() async throws {
        let model = try makeModel()
        for title in ["事项 A", "事项 B"] { XCTAssertTrue(model.addTask(title: title, note: "保留备注", day: DayKey(), groupID: nil)) }
        let ids = Set(model.document.tasks.map(\.id))
        model.noteID = model.document.tasks[0].id; model.editingID = model.document.tasks[1].id
        let before = model.document
        let originalBytes = try Data(contentsOf: model.repository.dataURL)
        var feedback: [TaskFeedback] = []
        model.playFeedback = { feedback.append($0) }
        try FileManager.default.removeItem(at: model.repository.dataURL)
        try FileManager.default.createDirectory(at: model.repository.dataURL, withIntermediateDirectories: false)

        XCTAssertFalse(model.applyBatch(.setPhase(.completed), to: ids))
        XCTAssertFalse(model.applyBatch(.delete, to: ids))
        XCTAssertEqual(model.document, before)
        XCTAssertEqual(model.noteID, before.tasks[0].id)
        XCTAssertEqual(model.editingID, before.tasks[1].id)
        XCTAssertTrue(feedback.isEmpty)
        XCTAssertEqual(model.saveState, .failed)

        try FileManager.default.removeItem(at: model.repository.dataURL)
        try originalBytes.write(to: model.repository.dataURL, options: .atomic)
        XCTAssertTrue(model.applyBatch(.setPhase(.completed), to: ids))
        XCTAssertTrue(model.document.tasks.allSatisfy { $0.phase == .completed })
        XCTAssertEqual(feedback, [.completed])
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document, model.document)
    }

    @MainActor func testDropPositionsReorderAndReparentSubtreesAndRejectCyclesAndFourthLevels() async throws {
        let model = try makeModel(), day = DayKey()
        for title in ["主项 A", "主项 B", "原有事项"] {
            XCTAssertTrue(model.addTask(title: title, note: "保留说明", day: day, groupID: nil))
        }
        let a = model.document.tasks[0], b = model.document.tasks[1], source = model.document.tasks[2]
        XCTAssertTrue(model.dropTask(source.id, onto: a.id, position: .before))
        XCTAssertEqual(model.document.siblingTasks(of: a.id).map(\.id), [source.id, a.id, b.id])
        XCTAssertTrue(model.dropTask(source.id, onto: b.id, position: .after))
        XCTAssertEqual(model.document.siblingTasks(of: a.id).map(\.id), [a.id, b.id, source.id])
        XCTAssertTrue(model.dropTask(source.id, onto: a.id, position: .inside))
        XCTAssertTrue(model.addTask(title: "孙项", day: day.adding(days: 1), groupID: nil, parentID: source.id))
        let grandchild = model.document.tasks.last!
        let beforeInvalid = model.document
        XCTAssertFalse(model.canDropTask(a.id, onto: b.id, position: .inside))
        XCTAssertFalse(model.canDropTask(a.id, onto: grandchild.id, position: .inside))
        XCTAssertFalse(model.dropTask(a.id, onto: b.id, position: .inside))
        XCTAssertFalse(model.addTask(title: "第四层", day: day, groupID: nil, parentID: grandchild.id))
        XCTAssertEqual(model.document, beforeInvalid)
        XCTAssertTrue(model.dropTask(source.id, onto: b.id, position: .inside))
        XCTAssertEqual(model.task(source.id)?.parentID, b.id)
        XCTAssertEqual(model.task(source.id)?.note, source.note)
        XCTAssertEqual(model.task(source.id)?.plannedDay, source.plannedDay)
        XCTAssertEqual(model.task(grandchild.id)?.parentID, source.id)
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document, model.document)
    }

    @MainActor func testHierarchySectionsShowEachFamilyOnceAndKeepFilteredAncestorsOutOfSelection() async throws {
        let model = try makeModel(), day = DayKey()
        model.today = day; model.selectedDay = day
        XCTAssertTrue(model.addTask(title: "主项", day: day, groupID: nil))
        let root = model.document.tasks[0]
        XCTAssertTrue(model.addTask(title: "子项", day: day, groupID: nil, parentID: root.id))
        let child = model.document.tasks[1]
        XCTAssertTrue(model.addTask(title: "孙项", day: day.adding(days: 1), groupID: nil, parentID: child.id))
        XCTAssertTrue(model.addTask(title: "另一子项", day: day, groupID: nil, parentID: root.id))
        let grandchild = model.document.tasks[2], sibling = model.document.tasks[3]
        let matches = Set(model.managedTasks(query: "孙项", status: .all, group: .all).map(\.id))
        let context = model.document.taskOutline(matching: matches)
        XCTAssertEqual(matches, [grandchild.id])
        XCTAssertEqual(context.map(\.isContext), [true, true, false])
        XCTAssertEqual(model.outlineSections.unfinished.map(\.depth), [0, 1, 2, 1])
        XCTAssertTrue(model.applyBatch(.setPhase(.completed), to: matches))
        XCTAssertEqual(model.task(child.id)?.phase, .completed)
        XCTAssertEqual(model.task(root.id)?.phase, .inProgress)
        XCTAssertEqual(model.outlineSections.unfinished.count, 4)
        XCTAssertTrue(model.outlineSections.completed.isEmpty)

        var saves = 0, feedback: [TaskFeedback] = []
        model.preferencesChanged = { _ in saves += 1 }
        model.playFeedback = { feedback.append($0) }
        XCTAssertTrue(model.applyBatch(.setPhase(.completed), to: [root.id, child.id]))
        XCTAssertEqual(model.task(root.id)?.phase, .completed)
        XCTAssertEqual(model.task(sibling.id)?.phase, .completed)
        XCTAssertEqual(model.saveState, .saved)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(feedback, [.completed])
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document, model.document)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.outlineSections.unfinished.isEmpty)
        XCTAssertEqual(model.outlineSections.completed.count, 4)
        model.setPhase(grandchild, .pending)
        XCTAssertEqual(model.task(sibling.id)?.phase, .completed)
        XCTAssertEqual(model.outlineSections.unfinished.count, 4)
        XCTAssertTrue(model.outlineSections.completed.isEmpty)
        model.noteID = grandchild.id; model.editingID = child.id
        model.delete(root)
        XCTAssertTrue(model.document.tasks.isEmpty)
        XCTAssertNil(model.noteID); XCTAssertNil(model.editingID)
    }

    @MainActor func testOnlyFullyCompletedFamiliesAppearInCompletedSectionWhenFiltered() throws {
        let model = try makeModel(), day = model.today
        let group = try XCTUnwrap(model.document.groups.first?.id)
        model.selectedDay = day
        XCTAssertTrue(model.addTask(title: "父项", day: day.adding(days: 1), groupID: nil))
        let root = try XCTUnwrap(model.document.tasks.last)
        XCTAssertTrue(model.addTask(title: "子项", day: day, groupID: group, parentID: root.id))
        let child = try XCTUnwrap(model.document.tasks.last)
        XCTAssertTrue(model.addTask(title: "孙项", day: day, groupID: group, parentID: child.id))
        let grandchild = try XCTUnwrap(model.document.tasks.last)
        XCTAssertTrue(model.addTask(title: "明天的子项", day: day.adding(days: 1), groupID: nil, parentID: root.id))
        let sibling = try XCTUnwrap(model.document.tasks.last)
        XCTAssertTrue(model.addTask(title: "独立事项", day: day, groupID: group))
        let independent = try XCTUnwrap(model.document.tasks.last)

        model.setPhase(grandchild, .completed)
        model.setPhase(independent, .completed)
        model.groupFilter = .group(group)
        let family = [root.id, child.id, grandchild.id, sibling.id]
        XCTAssertEqual(model.outlineSections.unfinished.map(\.id), family)
        XCTAssertEqual(model.outlineSections.completed.map(\.id), [independent.id])

        model.setPhase(sibling, .completed)
        XCTAssertTrue(model.outlineSections.unfinished.isEmpty)
        XCTAssertEqual(model.outlineSections.completed.map(\.id), family + [independent.id])
    }

    @MainActor func testHierarchyMoveFailureRetainsParentLinksAndUnflushedNotesForRetry() async throws {
        let model = try makeModel(), day = DayKey()
        XCTAssertTrue(model.addTask(title: "父项", day: day, groupID: nil))
        XCTAssertTrue(model.addTask(title: "另一个父项", day: day, groupID: nil))
        let root = model.document.tasks[0], target = model.document.tasks[1]
        XCTAssertTrue(model.addTask(title: "子项", day: day, groupID: nil, parentID: root.id))
        let child = model.document.tasks[2]
        let bytes = try Data(contentsOf: model.repository.dataURL)
        model.updateNote(child.id, text: "尚未自动保存的备注")
        let before = model.document
        try FileManager.default.removeItem(at: model.repository.dataURL)
        try FileManager.default.createDirectory(at: model.repository.dataURL, withIntermediateDirectories: false)
        XCTAssertFalse(model.dropTask(child.id, onto: target.id, position: .inside))
        XCTAssertEqual(model.document, before)
        XCTAssertEqual(model.task(child.id)?.parentID, root.id)
        try FileManager.default.removeItem(at: model.repository.dataURL)
        try bytes.write(to: model.repository.dataURL, options: .atomic)
        XCTAssertTrue(model.dropTask(child.id, onto: target.id, position: .inside))
        XCTAssertEqual(model.task(child.id)?.parentID, target.id)
        XCTAssertEqual(model.task(child.id)?.note, "尚未自动保存的备注")
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document, model.document)
    }

    @MainActor func testSettingsAndTaskViewsConstructAtDocumentedSizes() async throws {
        _ = NSApplication.shared
        let model = try makeModel()
        XCTAssertTrue(model.addTask(title: "主待办", day: DayKey(), groupID: nil))
        let root = model.document.tasks[0]
        XCTAssertTrue(model.addTask(title: "子待办", day: DayKey(), groupID: nil, parentID: root.id))
        let child = model.document.tasks[1]
        XCTAssertTrue(model.addTask(title: "较长的孙待办标题需要在最小窗口宽度下自动换行，右侧备注标记仍然保持对齐", note: "备注", day: DayKey(), groupID: nil, parentID: child.id))
        model.setPhase(model.document.tasks[2], .inProgress)
        // An unconstrained fittingSize reports a long title's ideal width, not the window's
        // constrained width. Exercise the production panel and separately verify row wrapping.
        let delegate = AppDelegate(model: model)
        delegate.toggleList()
        let panel = try XCTUnwrap(delegate.listPanel)
        defer { panel.orderOut(nil) }
        panel.setContentSize(NSSize(width: 390, height: 610))
        try await Task.sleep(nanoseconds: 100_000_000)
        let content = try XCTUnwrap(panel.contentView)
        content.layoutSubtreeIfNeeded()
        let host = try XCTUnwrap(content.subviews.first)
        XCTAssertEqual(content.bounds.width, 390, accuracy: 1)
        XCTAssertEqual(host.bounds.width, 390, accuracy: 1)
        func findOutline(_ view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView { return outline }
            return view.subviews.lazy.compactMap { findOutline($0) }.first
        }
        let outline = try XCTUnwrap(findOutline(content))
        let coordinator = try XCTUnwrap(outline.dataSource as? TaskOutlineCoordinator)
        let node = try XCTUnwrap(coordinator.taskNode(model.document.tasks[2].id))
        let row = outline.row(forItem: node)
        XCTAssertGreaterThanOrEqual(row, 0)
        XCTAssertGreaterThan(outline.rect(ofRow: row).height, 36)
        panel.setContentSize(NSSize(width: 720, height: 850))
        try await Task.sleep(nanoseconds: 100_000_000)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.width, 720, accuracy: 1)
        let settings = NSHostingView(rootView: SettingsView(model: model))
        settings.frame = NSRect(x: 0, y: 0, width: 740, height: 570)
        settings.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(settings.fittingSize.width, 690)
    }

    @MainActor func testPreviousTasksMoveWithinTheirGroupAndPersistOrder() async throws {
        let model = try makeModel(), today = DayKey()
        model.today = today; model.selectedDay = today
        let group = model.document.groups[0].id
        XCTAssertTrue(model.addTask(title: "旧任务 A", day: today.adding(days: -3), groupID: group))
        XCTAssertTrue(model.addTask(title: "其他分组", day: today.adding(days: -2), groupID: nil))
        XCTAssertTrue(model.addTask(title: "今天的任务", day: today, groupID: group))
        XCTAssertTrue(model.addTask(title: "旧任务 B", day: today.adding(days: -1), groupID: group))
        model.groupFilter = .group(group)
        let original = model.document
        let first = model.previous[0], second = model.previous[1]

        model.move(second, offset: -1)

        XCTAssertEqual(model.previous.map(\.id), [second.id, first.id])
        XCTAssertEqual(model.pending.map(\.title), ["今天的任务"])
        XCTAssertEqual(model.document.tasks[1], original.tasks[1])
        XCTAssertEqual(model.document.tasks[2], original.tasks[2])
        let reopened = try PindoRepository(directory: model.repository.directory)
        XCTAssertEqual(reopened.document, model.document)

        let afterMove = model.document
        model.move(second, offset: -1)
        XCTAssertEqual(model.document, afterMove)
        model.move(second, offset: 1)
        XCTAssertEqual(model.document, original)
    }

    @MainActor func testPastDateSortingStaysWithinTheSelectedDate() async throws {
        let model = try makeModel(), today = DayKey()
        let selectedDay = today.adding(days: -2)
        model.today = today; model.selectedDay = selectedDay
        XCTAssertTrue(model.addTask(title: "旧任务 A", day: selectedDay, groupID: nil))
        XCTAssertTrue(model.addTask(title: "另一天的任务", day: today.adding(days: -1), groupID: nil))
        XCTAssertTrue(model.addTask(title: "旧任务 B", day: selectedDay, groupID: nil))
        let original = model.document
        let first = model.pending[0], second = model.pending[1]

        model.move(second, offset: -1)

        XCTAssertEqual(model.pending.map(\.id), [second.id, first.id])
        XCTAssertEqual(model.document.tasks[1], original.tasks[1])
        model.move(second, offset: 1)
        XCTAssertEqual(model.document, original)
    }

    @MainActor func testNewListTasksUseDefaultGroupAndRespectExplicitFilters() async throws {
        let model = try makeModel(), today = DayKey()
        let defaultGroup = model.document.groups[0].id, otherGroup = model.document.groups[1].id
        model.setPreferences { $0.defaultGroupID = defaultGroup }

        model.groupFilter = .all
        XCTAssertTrue(model.addTask(title: "默认分组", day: today, groupID: model.listEntryGroupID))
        model.groupFilter = .group(otherGroup)
        XCTAssertTrue(model.addTask(title: "当前分组", day: today, groupID: model.listEntryGroupID))
        model.groupFilter = .ungrouped
        XCTAssertTrue(model.addTask(title: "明确未分组", day: today, groupID: model.listEntryGroupID))
        model.setPreferences { $0.defaultGroupID = nil }
        model.groupFilter = .all
        XCTAssertTrue(model.addTask(title: "默认未分组", day: today, groupID: model.listEntryGroupID))

        XCTAssertEqual(model.document.tasks.map(\.groupID), [Optional(defaultGroup), Optional(otherGroup), nil, nil])
    }

    @MainActor func testComposerSelectionCanOverrideDefaultAndUseUngrouped() async throws {
        let model = try makeModel()
        let group = model.document.groups[0].id
        model.setPreferences { $0.defaultGroupID = group }
        model.listEntry = "使用默认分组"
        XCTAssertTrue(model.submitListEntry())
        XCTAssertEqual(model.document.tasks.last?.groupID, group)
        model.listEntryGroupID = nil
        model.listEntry = "手动未分组"
        XCTAssertTrue(model.submitListEntry())
        XCTAssertNil(model.document.tasks.last?.groupID)
        XCTAssertEqual(model.listEntry, "")
        model.listEntryGroupID = group
        model.removeGroup(group)
        XCTAssertNil(model.listEntryGroupID)
    }

    @MainActor func testPinChangesAreExplicitAndReversible() async throws {
        let model = try makeModel()
        var levels: [Bool] = []
        model.pinChanged = { levels.append($0) }
        model.togglePin(); XCTAssertTrue(model.isPinned)
        model.togglePin(); XCTAssertFalse(model.isPinned)
        XCTAssertEqual(levels, [true, false])
    }

    @MainActor func testUnpinnedPanelRetainsFloatingLevelAfterPinChanges() async throws {
        _ = NSApplication.shared
        let panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 610),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.configurePin(false)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.moveToActiveSpace))
        panel.configurePin(true)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        panel.configurePin(false)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    }

    @MainActor func testPanelPresentationRaisesItsLevelAndShowsItWithoutAppActivation() async throws {
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        XCTAssertTrue(app.setActivationPolicy(.accessory))
        // XCTest is not launched through PindoApp.main. Complete the same accessory-app
        // startup before measuring activation, rather than measuring the test host's launch.
        app.finishLaunching()
        defer { app.setActivationPolicy(previousPolicy) }
        let panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 610),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { panel.orderOut(nil) }
        panel.hidesOnDeactivate = false
        panel.level = .normal
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier

        panel.showInFront()
        // Let WindowServer activation notifications settle before checking foreground ownership.
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        // A key nonactivating panel can change NSApp.isActive without taking the foreground app.
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmostBefore)
    }

    @MainActor func testManagementSearchesAllDatesAndNotesAndCanEditAndDelete() async throws {
        let model = try makeModel()
        let group = model.document.groups[0].id
        XCTAssertTrue(model.addTask(title: "过去的事项", note: "搜索关键字", day: DayKey().adding(days: -20), groupID: group))
        XCTAssertTrue(model.addTask(title: "未来的事项", day: DayKey().adding(days: 20), groupID: nil))
        let past = model.document.tasks[0], future = model.document.tasks[1]
        model.setPhase(past, .completed)
        XCTAssertEqual(model.managedTasks(query: "", status: .all, group: .all).count, 2)
        XCTAssertEqual(model.managedTasks(query: "关键字", status: .completed, group: .group(group)).map(\.id), [past.id])
        XCTAssertEqual(model.managedTasks(query: "", status: .unfinished, group: .ungrouped).map(\.id), [future.id])
        XCTAssertTrue(model.edit(future.id, title: "修改后", day: DayKey(), groupID: group))
        XCTAssertEqual(model.task(future.id)?.title, "修改后")
        model.delete(past)
        XCTAssertEqual(model.managedTasks(query: "", status: .all, group: .all).map(\.id), [future.id])
    }

    @MainActor func testTaskPanelSupportsNativeResizingAndRetainsItsSizeWhenShown() async throws {
        _ = NSApplication.shared
        let panel = QuickPanel.taskPanel()
        defer { panel.orderOut(nil) }
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        XCTAssertTrue(panel.styleMask.contains(.titled))
        XCTAssertTrue(panel.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.contentMinSize, NSSize(width: 360, height: 420))
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        panel.setContentSize(NSSize(width: min(620, screen.width - 40), height: min(560, screen.height - 40)))
        let frame = panel.frame
        panel.configurePin(false); panel.showInFront(); panel.orderOut(nil); panel.showInFront()
        XCTAssertEqual(panel.frame.size, frame.size)
        XCTAssertEqual(panel.level, .floating)
    }

    @MainActor func testNoteOutsideHitTestingIgnoresEditorResizeBorderAndOtherWindows() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        let other = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 60, width: 460, height: 440))
        window.contentView?.addSubview(scroll)
        let coordinator = NoteEditor(text: .constant("")).makeCoordinator()
        func click(_ point: NSPoint, windowNumber: Int? = nil) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                              windowNumber: windowNumber ?? window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        XCTAssertFalse(coordinator.isOutsideEditor(click(NSPoint(x: 200, y: 250)), scroll: scroll))
        XCTAssertTrue(coordinator.isOutsideEditor(click(NSPoint(x: 200, y: 550)), scroll: scroll))
        let title = TaskTitleTextField(frame: NSRect(x: 20, y: 520, width: 460, height: 40))
        window.contentView?.addSubview(title)
        XCTAssertFalse(coordinator.isOutsideEditor(click(NSPoint(x: 200, y: 540)), scroll: scroll))
        XCTAssertFalse(coordinator.isOutsideEditor(click(NSPoint(x: 22, y: 540)), scroll: scroll))
        XCTAssertTrue(coordinator.isOutsideEditor(click(NSPoint(x: 200, y: 30)), scroll: scroll))
        XCTAssertFalse(coordinator.isOutsideEditor(click(NSPoint(x: 2, y: 250)), scroll: scroll))
        XCTAssertFalse(coordinator.isOutsideEditor(click(NSPoint(x: 200, y: 550), windowNumber: other.windowNumber), scroll: scroll))
    }

    @MainActor func testCalendarCountsRespectGroupAndIncludeCompletedTasks() async throws {
        let model = try makeModel(), day = DayKey()
        let group = model.document.groups[0].id
        XCTAssertTrue(model.addTask(title: "待完成", day: day, groupID: group))
        XCTAssertTrue(model.addTask(title: "已完成", day: day, groupID: group))
        XCTAssertTrue(model.addTask(title: "其他分组", day: day, groupID: nil))
        model.setPhase(model.document.tasks[1], .completed)
        model.groupFilter = .group(group)
        let counts = DayTaskCount.grouped(model.document.tasks.filter(model.matches))
        XCTAssertEqual(counts[day]?.unfinished, 1)
        XCTAssertEqual(counts[day]?.completed, 1)
    }

    @MainActor func testFeedbackPlaysOnlyForSuccessfulTaskChanges() async throws {
        let model = try makeModel()
        var feedback: [TaskFeedback] = []
        model.playFeedback = { feedback.append($0) }
        XCTAssertFalse(model.addTask(title: "  ", day: DayKey(), groupID: nil))
        XCTAssertTrue(feedback.isEmpty)
        XCTAssertTrue(model.addTask(title: "事项", day: DayKey(), groupID: nil))
        let task = try XCTUnwrap(model.document.tasks.first)
        model.setPhase(task, .inProgress)
        model.setPhase(task, .inProgress)
        model.setPhase(task, .completed)
        model.setPhase(task, .completed) // Stale row callbacks must not play twice.
        XCTAssertEqual(feedback, [.added, .started, .completed])
        model.setPhase(task, .pending)
        XCTAssertEqual(feedback, [.added, .started, .completed])
        // A failed disk write must never sound like a successful action.
        let originalBytes = try Data(contentsOf: model.repository.dataURL)
        try FileManager.default.removeItem(at: model.repository.dataURL)
        try FileManager.default.createDirectory(at: model.repository.dataURL, withIntermediateDirectories: false)
        XCTAssertFalse(model.addTask(title: "写入失败", day: DayKey(), groupID: nil))
        model.setPhase(task, .inProgress)
        model.setPhase(task, .completed)
        model.delete(task)
        XCTAssertEqual(feedback, [.added, .started, .completed])
        XCTAssertEqual(model.task(task.id)?.phase, .pending)

        try FileManager.default.removeItem(at: model.repository.dataURL)
        try originalBytes.write(to: model.repository.dataURL, options: .atomic)
        model.delete(task)
        model.delete(task)
        XCTAssertEqual(feedback, [.added, .started, .completed, .deleted])
        XCTAssertNil(model.task(task.id))
    }

    @MainActor func testQuickPositionPersistsTopLeftAndRecoversAfterDisplayRemoval() async throws {
        let suite = "PindoPositionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuickPanelPosition(defaults: defaults)
        let main = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let second = NSRect(x: -1440, y: 0, width: 1440, height: 900)
        XCTAssertNil(store.restoredOrigin(size: NSSize(width: 470, height: 260), visibleFrames: [main]))
        store.save(frame: NSRect(x: -1000, y: 540, width: 470, height: 260))
        let reopened = QuickPanelPosition(defaults: defaults)
        XCTAssertEqual(reopened.restoredOrigin(size: NSSize(width: 470, height: 400), visibleFrames: [main, second]), NSPoint(x: -1000, y: 400))
        XCTAssertEqual(reopened.restoredOrigin(size: NSSize(width: 470, height: 400), visibleFrames: [main]), NSPoint(x: 0, y: 400))
        store.save(frame: NSRect(x: 1430, y: 880, width: 470, height: 260))
        XCTAssertEqual(reopened.restoredOrigin(size: NSSize(width: 470, height: 260), visibleFrames: [main]), NSPoint(x: 970, y: 640))
    }

    @MainActor func testStatusToggleHidesVisiblePanelEvenWhenOcclusionInformationIsStale() async throws {
        _ = NSApplication.shared
        let model = try makeModel()
        let delegate = AppDelegate(model: model)
        delegate.toggleList(fromStatus: true)
        let panel = try XCTUnwrap(delegate.listPanel)
        defer { panel.orderOut(nil) }
        XCTAssertTrue(panel.isVisible)
        // Toggle immediately, without waiting for WindowServer occlusion updates.
        delegate.toggleList(fromStatus: true)
        XCTAssertFalse(panel.isVisible)
        delegate.toggleList(fromStatus: true)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(delegate.listPanel === panel)
    }

    @MainActor func testQuickAddUsesNativeCornersAndRestoresDraggedPosition() async throws {
        _ = NSApplication.shared
        let suite = "PindoQuickPanelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = try makeModel()
        let delegate = AppDelegate(model: model, quickPosition: QuickPanelPosition(defaults: defaults))
        delegate.toggleQuick()
        let panel = try XCTUnwrap(delegate.quickPanel)
        defer { panel.orderOut(nil) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(panel.styleMask.contains(.titled))
        XCTAssertTrue(panel.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        let screen = try XCTUnwrap(panel.screen).visibleFrame
        panel.setFrameOrigin(NSPoint(x: screen.minX + 30, y: screen.minY + 40))
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        delegate.toggleQuick()
        XCTAssertFalse(panel.isVisible)
        delegate.toggleQuick()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(panel.frame.minX, topLeft.x, accuracy: 1)
        XCTAssertEqual(panel.frame.maxY, topLeft.y, accuracy: 1)
    }

    @MainActor func testQuickAddFromFocusedNoteSavesAndClearsDraft() async throws {
        _ = NSApplication.shared
        let suite = "PindoQuickAddDraft.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let model = try AppModel(useSQLite: false, directory: folder, defaults: defaults)
        model.playFeedback = { _ in }
        model.quickTitle = "待提交事项"; model.quickNote = "已输入的备注"
        let delegate = AppDelegate(model: model, quickPosition: QuickPanelPosition(defaults: defaults))
        model.hideQuickAdd = { [weak delegate] in delegate?.toggleQuick() }
        delegate.toggleQuick()
        let panel = try XCTUnwrap(delegate.quickPanel)
        defer { panel.orderOut(nil); panel.contentView = nil }
        try await Task.sleep(nanoseconds: 300_000_000)
        func noteEditor(in view: NSView) -> NSTextView? {
            NoteEditor.Coordinator.findTextView(in: view)
        }
        let note = try XCTUnwrap(noteEditor(in: try XCTUnwrap(panel.contentView)))
        XCTAssertTrue(panel.makeFirstResponder(note))
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        if !panel.performKeyEquivalent(with: key) { panel.sendEvent(key) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.document.tasks.last?.note, "已输入的备注")
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(model.quickTitle.isEmpty)
        XCTAssertTrue(model.quickNote.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "quickNote"), "")
    }

    @MainActor func testSingleSecondaryClickAndControlClickOpenTheFlatStatusMenu() async throws {
        _ = NSApplication.shared
        let model = try makeModel()
        let delegate = AppDelegate(model: model)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item); delegate.listPanel?.orderOut(nil) }
        let button = try XCTUnwrap(item.button)
        var menus: [NSMenu] = []
        delegate.presentStatusMenu = { menu, source in
            XCTAssertTrue(source === button)
            menus.append(menu)
        }
        func click(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: modifiers,
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: button.window?.windowNumber ?? 0, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1))
        }

        // A trackpad secondary click has clickCount == 1, just like a mouse right-click.
        delegate.handleStatusClick(button, event: try click(.rightMouseUp))
        delegate.handleStatusClick(button, event: try click(.leftMouseDown, modifiers: .control))
        XCTAssertEqual(menus.count, 2)
        for menu in menus {
            let actions = menu.items.filter { !$0.isSeparatorItem }
            XCTAssertEqual(actions.map(\.title), ["添加事项", "设置", "退出"].map { model.localization($0) })
            XCTAssertTrue(actions.allSatisfy { $0.submenu == nil && $0.action != nil })
            XCTAssertEqual(actions.map(\.keyEquivalent), ["", ",", "q"])
        }
        XCTAssertNil(delegate.listPanel)
        delegate.handleStatusClick(button, event: try click(.leftMouseDown))
        XCTAssertEqual(menus.count, 2)
        XCTAssertEqual(delegate.listPanel?.isVisible, true)
    }

    @MainActor func testNativeStatusMenuRestoresButtonRoutingAfterSystemTracking() async throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)
        let target = NSObject()
        let action = NSSelectorFromString("statusClicked:")
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseUp]
        button.target = target; button.action = action; button.sendAction(on: clicks)
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings", action: nil, keyEquivalent: "")
        var tracked = false

        NativeStatusMenu.show(menu, on: item) { source in
            tracked = true
            XCTAssertTrue(source === button)
            XCTAssertTrue(item.menu === menu)
        }

        XCTAssertTrue(tracked)
        XCTAssertNil(item.menu)
        XCTAssertTrue(button.target === target)
        XCTAssertEqual(button.action, action)
        XCTAssertEqual(button.sendAction(on: clicks), Int(clicks.rawValue))
    }

    @MainActor func testComposerTopAndBottomPaddingClicksAcceptTyping() async throws {
        _ = NSApplication.shared
        let model = try makeModel()
        // Isolate input hit testing from the system title bar, which overlays a short titled panel.
        let panel = QuickPanel(contentRect: NSRect(x: 100, y: 100, width: 390, height: 82),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
        defer { panel.orderOut(nil) }
        let host = NSHostingView(rootView: TaskComposer(model: model).ignoresSafeArea())
        panel.contentView = host
        panel.setContentSize(NSSize(width: 390, height: 82))
        panel.showInFront()
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        var expected = ""

        // Both points are in the composer's padded background, outside the native text field.
        for (index, y) in [CGFloat(14), host.bounds.height - 14].enumerated() {
            panel.makeFirstResponder(nil)
            try await Task.sleep(nanoseconds: 100_000_000)
            let point = host.convert(NSPoint(x: 30, y: y), to: nil)
            let timestamp = ProcessInfo.processInfo.systemUptime
            for (offset, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                           timestamp: timestamp + Double(offset) * 0.05,
                                                           windowNumber: panel.windowNumber, context: nil,
                                                           eventNumber: index * 2 + offset, clickCount: 1, pressure: 1))
                panel.sendEvent(event)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            let target = host.hitTest(host.convert(point, from: nil))
            let editor = try XCTUnwrap(panel.firstResponder as? NSTextView,
                                      "Padding click at y=\(y), hit=\(String(describing: target)), responder=\(String(describing: panel.firstResponder))")
            let text = index == 0 ? "上" : "下"
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(nanoseconds: 100_000_000)
            expected += text
            XCTAssertEqual(model.listEntry, expected)
            XCTAssertTrue(model.document.tasks.isEmpty)
        }
    }

}
