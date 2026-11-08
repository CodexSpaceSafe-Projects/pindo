import XCTest
import AppKit
import SwiftUI
import PindoCore
@testable import Pindo

private struct OutlineFixture: View {
    @ObservedObject var model: AppModel
    var matching: Set<UUID>?
    var batch = false
    var body: some View {
        let document = model.taskDragPreview ?? model.document
        TaskOutlineList(model: model,
                        sections: [TaskOutlineSection(id: "test", rows: document.taskOutline(matching: matching ?? Set(document.tasks.map(\.id))))],
                        management: true, batchMode: batch, onSelect: { _ in }, onSelectNote: { _ in }, onEdit: { _ in },
                        onAddChild: { _ in }, onDelete: { _ in }, onMove: { _, _ in })
    }
}

final class TaskOutlineTests: XCTestCase {
    @MainActor private func model() throws -> AppModel {
        let model = try AppModel(directory: FileManager.default.temporaryDirectory.appendingPathComponent("PindoOutline-\(UUID().uuidString)"))
        model.playFeedback = { _ in }
        return model
    }

    @MainActor private func host(_ model: AppModel, matching: Set<UUID>? = nil, batch: Bool = false) async throws -> (NSPanel, TaskNativeOutlineView, TaskOutlineCoordinator) {
        _ = NSApplication.shared
        let window = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 420, height: 520), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: OutlineFixture(model: model, matching: matching, batch: batch))
        window.orderFrontRegardless()
        try await settle()
        func find(_ view: NSView) -> TaskNativeOutlineView? {
            if let outline = view as? TaskNativeOutlineView { return outline }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let outline = try XCTUnwrap(find(try XCTUnwrap(window.contentView)))
        return (window, outline, try XCTUnwrap(outline.dataSource as? TaskOutlineCoordinator))
    }

    @MainActor private func settle() async throws { try await Task.sleep(nanoseconds: 180_000_000) }

    @MainActor func testNativeTitleOwnsMouseTrackingAndPasteboardWriterExportsTaskID() async throws {
        let model = try model(), day = DayKey()
        XCTAssertTrue(model.addTask(title: "可以拖动的标题", note: "说明", day: day, groupID: nil))
        let task = model.document.tasks[0]
        let (window, outline, coordinator) = try await host(model)
        defer { window.orderOut(nil); window.contentView = nil }
        let node = try XCTUnwrap(coordinator.taskNode(task.id))
        let row = outline.row(forItem: node)
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? TaskOutlineCell)
        cell.layoutSubtreeIfNeeded()
        let point = cell.titleLabel.convert(NSPoint(x: 20, y: cell.titleLabel.bounds.midY), to: outline.superview)
        XCTAssertTrue(outline.hitTest(point) === outline, "The title must reach native mouse tracking, rather than a SwiftUI Button or window movement")
        let statusPoint = cell.status.convert(NSPoint(x: 12, y: 14), to: outline.superview)
        XCTAssertTrue(outline.hitTest(statusPoint) === cell.status)
        XCTAssertFalse(outline.mouseDownCanMoveWindow)
        XCTAssertTrue(outline.registeredDraggedTypes.contains(TaskOutlineCoordinator.pasteboardType))
        let writer = try XCTUnwrap(coordinator.outlineView(outline, pasteboardWriterForItem: node) as? NSPasteboardItem)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([writer]))
        XCTAssertEqual(pasteboard.string(forType: TaskOutlineCoordinator.pasteboardType), task.id.uuidString)
        XCTAssertFalse(cell.note.isHidden)
        XCTAssertEqual(cell.note.frame.maxX, cell.bounds.maxX - 7, accuracy: 0.5)
        XCTAssertNil(model.noteID)
    }

    @MainActor func testNativeDisclosureHidesWholeBranchAndSurvivesRefresh() async throws {
        let model = try model(), day = DayKey()
        XCTAssertTrue(model.addTask(title: "父项", day: day, groupID: nil))
        let parent = model.document.tasks[0]
        XCTAssertTrue(model.addTask(title: "子项", day: day, groupID: nil, parentID: parent.id))
        let child = model.document.tasks[1]
        XCTAssertTrue(model.addTask(title: "孙项", day: day, groupID: nil, parentID: child.id))
        let (window, outline, coordinator) = try await host(model)
        defer { window.orderOut(nil); window.contentView = nil }
        let parentNode = try XCTUnwrap(coordinator.taskNode(parent.id))
        let childNode = try XCTUnwrap(coordinator.taskNode(child.id))
        XCTAssertEqual(outline.numberOfRows, 3)
        outline.collapseItem(parentNode)
        XCTAssertEqual(outline.numberOfRows, 1)
        XCTAssertTrue(model.edit(child.id, title: "修改子项", day: day, groupID: nil))
        try await settle()
        XCTAssertEqual(outline.numberOfRows, 1)
        outline.expandItem(parentNode)
        try await settle()
        XCTAssertEqual(outline.numberOfRows, 3)
        outline.collapseItem(childNode)
        XCTAssertEqual(outline.numberOfRows, 2)
        outline.expandItem(childNode)
        try await settle()
        XCTAssertEqual(outline.numberOfRows, 3)
    }

    @MainActor func testHoverShowsProjectedHierarchyAndParentStatusThenCancelRestoresWithoutWriting() async throws {
        let model = try model(), day = DayKey()
        for title in ["已完成的目标", "拖动事项"] { XCTAssertTrue(model.addTask(title: title, day: day, groupID: nil)) }
        let target = model.document.tasks[0], source = model.document.tasks[1]
        model.setPhase(target, .completed)
        let original = model.document, bytes = try Data(contentsOf: model.repository.dataURL)
        let (window, outline, coordinator) = try await host(model)
        defer { window.orderOut(nil); window.contentView = nil }
        let targetNode = try XCTUnwrap(coordinator.taskNode(target.id))
        coordinator.beginDrag(source.id)
        XCTAssertTrue(coordinator.validate(item: targetNode, index: -1))
        try await settle()
        let preview = try XCTUnwrap(model.taskDragPreview)
        XCTAssertEqual(preview.tasks.first { $0.id == source.id }?.parentID, target.id)
        XCTAssertEqual(preview.tasks.first { $0.id == target.id }?.phase, .pending)
        XCTAssertEqual(outline.level(forItem: coordinator.taskNode(source.id)), 1)
        XCTAssertEqual(model.document, original)
        XCTAssertEqual(try Data(contentsOf: model.repository.dataURL), bytes)
        coordinator.cancelDrag()
        try await settle()
        XCTAssertNil(model.taskDragPreview); XCTAssertNil(model.draggedTaskID)
        XCTAssertEqual(outline.level(forItem: coordinator.taskNode(source.id)), 0)
        XCTAssertEqual(model.document, original)
        XCTAssertEqual(try Data(contentsOf: model.repository.dataURL), bytes)
    }

    @MainActor func testInsertionUsesVisibleSiblingBoundaryAndAcceptsLatestHoverBeforeTimerFires() async throws {
        let model = try model(), day = DayKey()
        for title in ["A", "B", "C"] { XCTAssertTrue(model.addTask(title: title, day: day, groupID: nil)) }
        let a = model.document.tasks[0], b = model.document.tasks[1], c = model.document.tasks[2]
        let (window, _, coordinator) = try await host(model)
        defer { window.orderOut(nil); window.contentView = nil }
        coordinator.beginDrag(c.id)
        XCTAssertTrue(coordinator.validate(item: nil, index: 0))
        try await settle()
        XCTAssertEqual(model.taskDragPreview?.siblingTasks(of: a.id).map(\.id), [c.id, a.id, b.id])
        // Moving over the newly projected source must not bounce back to its old place.
        XCTAssertTrue(coordinator.validate(item: coordinator.taskNode(c.id), index: -1))
        XCTAssertTrue(coordinator.accept(item: coordinator.taskNode(b.id), index: -1))
        XCTAssertEqual(model.task(c.id)?.parentID, b.id)
        XCTAssertNil(model.taskDragPreview); XCTAssertNil(model.draggedTaskID)
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document, model.document)
    }

    @MainActor func testInvalidHoverRejectsCyclesAndFourthLevelsAndBatchContextCannotBeSelected() async throws {
        let model = try model(), day = DayKey()
        XCTAssertTrue(model.addTask(title: "父项", day: day, groupID: nil))
        let root = model.document.tasks[0]
        XCTAssertTrue(model.addTask(title: "子项", day: day, groupID: nil, parentID: root.id))
        let child = model.document.tasks[1]
        XCTAssertTrue(model.addTask(title: "匹配孙项", day: day, groupID: nil, parentID: child.id))
        let grandchild = model.document.tasks[2]
        XCTAssertTrue(model.addTask(title: "另一个主项", day: day, groupID: nil))
        let other = model.document.tasks[3]
        let (window, outline, coordinator) = try await host(model)
        defer { window.orderOut(nil); window.contentView = nil }
        coordinator.beginDrag(root.id)
        XCTAssertFalse(coordinator.validate(item: coordinator.taskNode(grandchild.id), index: -1))
        coordinator.cancelDrag(); coordinator.beginDrag(other.id)
        XCTAssertFalse(coordinator.validate(item: coordinator.taskNode(grandchild.id), index: -1))
        coordinator.cancelDrag()
        // Inspect a second native instance configured for filtered bulk operations.
        let (batchWindow, batchOutline, batchCoordinator) = try await host(model, matching: [grandchild.id], batch: true)
        defer { batchWindow.orderOut(nil); batchWindow.contentView = nil }
        let contextNode = try XCTUnwrap(batchCoordinator.taskNode(root.id))
        let contextCell = try XCTUnwrap(batchOutline.view(atColumn: 0, row: batchOutline.row(forItem: contextNode), makeIfNecessary: true) as? TaskOutlineCell)
        XCTAssertFalse(contextCell.checkbox.isHidden); XCTAssertFalse(contextCell.checkbox.isEnabled)
        XCTAssertNil(batchCoordinator.outlineView(batchOutline, pasteboardWriterForItem: contextNode))
        XCTAssertNil(model.taskDragPreview)
        XCTAssertEqual(model.task(child.id)?.parentID, root.id)
        XCTAssertEqual(model.task(grandchild.id)?.parentID, child.id)
        XCTAssertEqual(outline.registeredDraggedTypes, [TaskOutlineCoordinator.pasteboardType])
    }

    @MainActor func testDragCannotOverwriteConcurrentChangesAndFailedAcceptanceClearsPreview() async throws {
        let model = try model(), day = DayKey()
        for title in ["目标", "事项"] { XCTAssertTrue(model.addTask(title: title, day: day, groupID: nil)) }
        let target = model.document.tasks[0], source = model.document.tasks[1]
        XCTAssertTrue(model.beginTaskDrag(source.id))
        XCTAssertTrue(model.previewTaskDrag(parent: target.id, before: nil))
        // A note staged after the drag started must not be replaced by its old snapshot.
        model.updateNote(source.id, text: "拖动过程中更新的备注")
        XCTAssertFalse(model.acceptTaskDrag(parent: target.id, before: nil))
        XCTAssertEqual(model.task(source.id)?.note, "拖动过程中更新的备注")
        XCTAssertNil(model.task(source.id)?.parentID)
        XCTAssertNil(model.draggedTaskID); XCTAssertNil(model.taskDragPreview)
        XCTAssertTrue(model.flush())
        let before = model.document, bytes = try Data(contentsOf: model.repository.dataURL)
        XCTAssertTrue(model.beginTaskDrag(source.id))
        XCTAssertTrue(model.previewTaskDrag(parent: target.id, before: nil))
        try FileManager.default.removeItem(at: model.repository.dataURL)
        try FileManager.default.createDirectory(at: model.repository.dataURL, withIntermediateDirectories: false)
        XCTAssertFalse(model.acceptTaskDrag(parent: target.id, before: nil))
        XCTAssertEqual(model.document, before)
        XCTAssertNil(model.draggedTaskID); XCTAssertNil(model.taskDragPreview)
        try FileManager.default.removeItem(at: model.repository.dataURL)
        try bytes.write(to: model.repository.dataURL, options: .atomic)
    }
}
