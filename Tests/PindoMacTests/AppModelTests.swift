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

    @MainActor func testHandoffCopiesFullNotePersistsProgressAndActivatesOnlyAfterSave() async throws {
        let model = try makeModel()
        XCTAssertTrue(model.addTask(title: "确认首页方案", note: "先给两个方向", day: DayKey(), groupID: nil))
        let item = model.document.tasks[0]
        var steps: [String] = []
        model.writeClipboard = { text in XCTAssertEqual(text, "任务：确认首页方案\n\n说明：\n先给两个方向"); steps.append("copy"); return true }
        model.codexApplicationURL = { URL(fileURLWithPath: "/Applications/Codex.app") }
        model.hideList = { steps.append("hide") }
        model.launchCodex = { _, completion in
            XCTAssertEqual(model.document.tasks[0].phase, .inProgress)
            steps.append("activate"); completion(nil)
        }
        model.startInCodex(item)
        XCTAssertEqual(steps, ["copy", "hide", "activate"])
        let reopened = try PindoRepository(directory: model.repository.directory)
        XCTAssertEqual(reopened.document.tasks[0].phase, .inProgress)
    }

    @MainActor func testCopyFailureAndMissingCodexDoNotStartTask() async throws {
        let model = try makeModel()
        XCTAssertTrue(model.addTask(title: "任务", day: DayKey(), groupID: nil))
        let item = model.document.tasks[0]
        var launched = false
        model.launchCodex = { _, _ in launched = true }
        model.writeClipboard = { _ in false }
        model.startInCodex(item)
        XCTAssertEqual(model.document.tasks[0].phase, .pending)
        XCTAssertNotNil(model.errorMessage)
        model.writeClipboard = { _ in true }; model.codexApplicationURL = { nil }
        model.startInCodex(item)
        XCTAssertEqual(model.document.tasks[0].phase, .pending)
        XCTAssertFalse(launched)
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
        panel.frame = NSRect(x: 0, y: 0, width: 370, height: 610)
        panel.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(panel.fittingSize.width, 370)
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
}
