import XCTest
import AppKit
import SwiftUI
import PindoCore
@testable import Pindo

final class AppModelTests: XCTestCase {
    @MainActor private func makeModel() throws -> AppModel {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("PindoMacTests-\(UUID().uuidString)")
        return try AppModel(directory: path)
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

    @MainActor func testSettingsAndTaskViewsConstructAtDocumentedSizes() async throws {
        _ = NSApplication.shared
        let model = try makeModel()
        let panel = NSHostingView(rootView: TaskPanelView(model: model))
        panel.frame = NSRect(x: 0, y: 0, width: 390, height: 610)
        panel.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(panel.fittingSize.width, 390)
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
        let wasActive = app.isActive
        let panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 610),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { panel.orderOut(nil) }
        panel.hidesOnDeactivate = false
        panel.level = .normal

        panel.showInFront()

        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertEqual(app.isActive, wasActive)
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

    @MainActor func testSavingDoesNotReplaceMarkedChineseInput() async throws {
        _ = NSApplication.shared
        var stored = "已有"
        let editor = NoteEditor(text: Binding(get: { stored }, set: { stored = $0 }))
        let coordinator = editor.makeCoordinator()
        let view = ComposingTextView()
        view.string = stored; view.delegate = coordinator
        view.didCommitText = { [weak view] in if let view { coordinator.publish(view) } }
        view.setSelectedRange(NSRange(location: (stored as NSString).length, length: 0))
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        let composingText = view.string, selection = view.selectedRange()
        coordinator.publish(view)
        XCTAssertEqual(stored, "已有")
        coordinator.synchronize(view, text: stored)
        XCTAssertEqual(view.string, composingText)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertTrue(view.hasMarkedText())
        view.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        coordinator.publish(view)
        XCTAssertEqual(stored, "已有中文")
        view.setSelectedRange(NSRange(location: 1, length: 1))
        coordinator.synchronize(view, text: stored)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 1))
    }
}
