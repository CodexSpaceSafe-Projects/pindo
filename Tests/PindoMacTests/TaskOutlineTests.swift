import XCTest
import AppKit
import SwiftUI
import PindoCore
@testable import Pindo

private struct OutlineFixture: View {
    @ObservedObject var model: AppModel
    var matching: Set<UUID>?
    var batch = false
    var sectioned = false
    var body: some View {
        let document = model.taskDragPreview ?? model.document
        let groups = model.outlineSections(in: document)
        let sections = sectioned ? [
            TaskOutlineSection(id: "unfinished", title: "未完成", rows: groups.unfinished, completed: false),
            TaskOutlineSection(id: "completed", title: "已完成", rows: groups.completed, completed: true)
        ] : [TaskOutlineSection(id: "test", rows: document.taskOutline(matching: matching ?? Set(document.tasks.map(\.id))))]
        TaskOutlineList(model: model,
                        sections: sections,
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

    @MainActor private func host(_ model: AppModel, matching: Set<UUID>? = nil, batch: Bool = false, sectioned: Bool = false) async throws -> (NSPanel, TaskNativeOutlineView, TaskOutlineCoordinator) {
        _ = NSApplication.shared
        let window = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 420, height: 520), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: OutlineFixture(model: model, matching: matching, batch: batch, sectioned: sectioned))
        window.orderFrontRegardless()
        try await settle()
        func find(_ view: NSView) -> TaskNativeOutlineView? {
            if let outline = view as? TaskNativeOutlineView { return outline }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let outline = try XCTUnwrap(find(try XCTUnwrap(window.contentView)))
        return (window, outline, try XCTUnwrap(outline.dataSource as? TaskOutlineCoordinator))
    }

    @MainActor private func settle() async throws { try await Task.sleep(nanoseconds: 320_000_000) }

    @MainActor func testTaskPanelBackgroundFollowsAppearanceAcrossWakeAndDayChange() async throws {
        let app = NSApplication.shared
        let previousAppearance = app.appearance
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let model = try model()
        let today = model.today
        let yesterday = today.adding(days: -1)
        model.today = yesterday
        model.selectedDay = yesterday
        XCTAssertTrue(model.addTask(title: "跨天继续进行", day: yesterday, groupID: nil))
        let active = try XCTUnwrap(model.document.tasks.first)
        model.setPhase(active, .inProgress)
        XCTAssertTrue(model.addTask(title: "昨天未完成", day: yesterday, groupID: nil))

        let delegate = AppDelegate(model: model)
        defer {
            delegate.listPanel?.orderOut(nil)
            delegate.listPanel?.contentView = nil
            app.appearance = previousAppearance
        }
        func findOutline(_ view: NSView) -> TaskNativeOutlineView? {
            if let outline = view as? TaskNativeOutlineView { return outline }
            return view.subviews.lazy.compactMap { findOutline($0) }.first
        }
        func checkBackground(of panel: QuickPanel, appearance: NSAppearance.Name) throws -> TaskNativeOutlineView {
            let outline = try XCTUnwrap(panel.contentView.flatMap(findOutline))
            XCTAssertEqual(outline.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), appearance)
            XCTAssertEqual(outline.backgroundColor.alphaComponent, 0, "空白区应透出清单容器的背景")
            let row = try XCTUnwrap(outline.rowView(atRow: 0, makeIfNecessary: true))
            XCTAssertEqual(row.backgroundColor.alphaComponent, 0, "有任务的区域应透出同一层背景")
            return outline
        }

        app.appearance = dark
        delegate.toggleList()
        let panel = try XCTUnwrap(delegate.listPanel)
        try await settle()
        let outline = try checkBackground(of: panel, appearance: .darkAqua)

        app.appearance = light
        try await settle()
        XCTAssertTrue(try checkBackground(of: panel, appearance: .aqua) === outline)

        delegate.toggleList()
        XCTAssertFalse(panel.isVisible)
        app.appearance = dark
        delegate.didWake()
        XCTAssertEqual(model.today, today)
        XCTAssertEqual(model.selectedDay, today)
        XCTAssertEqual(model.unfinished.map(\.id), [active.id])
        XCTAssertEqual(model.previous.count, 1)

        delegate.toggleList()
        try await settle()
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(delegate.listPanel === panel)
        _ = try checkBackground(of: panel, appearance: .darkAqua)

        app.appearance = light
        try await settle()
        _ = try checkBackground(of: panel, appearance: .aqua)
    }

    @MainActor func testNativeTitleOwnsMouseTrackingAndPasteboardWriterExportsTaskID() async throws {
        let model = try model(), day = DayKey()
        let group = model.document.groups[0]
        XCTAssertTrue(model.addTask(title: "可以拖动的标题", note: "说明", day: day, groupID: group.id))
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
        model.saveGroup(id: group.id, name: "改名后的分组", color: "#33AA66")
        try await settle()
        let refreshed = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? TaskOutlineCell)
        XCTAssertTrue(refreshed.metadata.stringValue.contains("改名后的分组"))
        XCTAssertEqual(model.document.tasks[0], task)
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
        for title in ["未完成的目标", "拖动事项"] { XCTAssertTrue(model.addTask(title: title, day: day, groupID: nil)) }
        let target = model.document.tasks[0], source = model.document.tasks[1]
        model.setPhase(source, .inProgress)
        let original = model.document, bytes = try Data(contentsOf: model.repository.dataURL)
        let (window, outline, coordinator) = try await host(model)
        defer { window.orderOut(nil); window.contentView = nil }
        let targetNode = try XCTUnwrap(coordinator.taskNode(target.id))
        coordinator.beginDrag(source.id)
        XCTAssertTrue(coordinator.validate(item: targetNode, index: -1))
        try await settle()
        let preview = try XCTUnwrap(model.taskDragPreview)
        XCTAssertEqual(preview.tasks.first { $0.id == source.id }?.parentID, target.id)
        XCTAssertEqual(preview.tasks.first { $0.id == target.id }?.phase, .inProgress)
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

    @MainActor func testNativeCompletedAndUnfinishedRegionsRejectCrossDropsAndAcceptRevalidates() async throws {
        let model = try model(), day = DayKey()
        for title in ["未完成", "进行中", "已完成 A", "已完成 B"] { XCTAssertTrue(model.addTask(title: title, day: day, groupID: nil)) }
        let pending = model.document.tasks[0], running = model.document.tasks[1], doneA = model.document.tasks[2], doneB = model.document.tasks[3]
        model.setPhase(running, .inProgress); model.setPhase(doneA, .completed); model.setPhase(doneB, .completed)
        let original = model.document, bytes = try Data(contentsOf: model.repository.dataURL)
        let (window, _, coordinator) = try await host(model, sectioned: true)
        defer { window.orderOut(nil); window.contentView = nil }
        let pendingHeader = try XCTUnwrap(coordinator.roots.first { $0.completed == false })
        let doneHeader = try XCTUnwrap(coordinator.roots.first { $0.completed == true })
        for source in [pending, running] {
            coordinator.beginDrag(source.id)
            for index in [-1, 0, doneHeader.children.count] { XCTAssertFalse(coordinator.validate(item: doneHeader, index: index)) }
            XCTAssertFalse(coordinator.validate(item: coordinator.taskNode(doneA.id), index: -1))
            XCTAssertFalse(coordinator.accept(item: doneHeader, index: -1))
        }
        coordinator.beginDrag(doneA.id)
        for index in [-1, 0, pendingHeader.children.count] { XCTAssertFalse(coordinator.validate(item: pendingHeader, index: index)) }
        XCTAssertFalse(coordinator.validate(item: coordinator.taskNode(pending.id), index: -1))
        XCTAssertFalse(coordinator.accept(item: coordinator.taskNode(pending.id), index: -1))
        try await settle()
        XCTAssertEqual(model.document, original)
        XCTAssertEqual(try Data(contentsOf: model.repository.dataURL), bytes)
        XCTAssertNil(model.taskDragPreview)
        // Same-class nesting is still available for completed tasks.
        coordinator.beginDrag(doneB.id)
        XCTAssertTrue(coordinator.validate(item: coordinator.taskNode(doneA.id), index: -1))
        XCTAssertTrue(coordinator.accept(item: coordinator.taskNode(doneA.id), index: -1))
        XCTAssertEqual(model.task(doneB.id)?.parentID, doneA.id)
        XCTAssertEqual(model.task(doneA.id)?.phase, .completed)
        XCTAssertEqual(model.task(doneB.id)?.phase, .completed)
    }

    @MainActor func testRapidReorderPreviewsKeepCellsAndScrollPositionAndDoNotStarve() async throws {
        let model = try model(), day = DayKey()
        XCTAssertTrue(model.commit { document in
            for index in 0..<50 { try document.insertTask(TodoItem(title: "事项 \(index)", plannedDay: day, order: index)) }
        })
        let tasks = model.document.tasks, source = tasks[16], unchanged = tasks[14]
        let (window, outline, coordinator) = try await host(model)
        defer { window.orderOut(nil); window.contentView = nil }
        let clip = try XCTUnwrap(outline.enclosingScrollView?.contentView)
        clip.scroll(to: NSPoint(x: 0, y: 600))
        outline.enclosingScrollView?.reflectScrolledClipView(clip)
        outline.layoutSubtreeIfNeeded()
        let stableNode = try XCTUnwrap(coordinator.taskNode(unchanged.id))
        let stableCell = try XCTUnwrap(outline.view(atColumn: 0, row: outline.row(forItem: stableNode), makeIfNecessary: true))
        let origin = clip.bounds.origin
        coordinator.beginDrag(source.id)
        var sawPreviewDuringMovement = false
        for index in 0..<20 {
            XCTAssertTrue(coordinator.validate(item: nil, index: 14 + index % 5))
            try await Task.sleep(nanoseconds: 15_000_000)
            sawPreviewDuringMovement = sawPreviewDuringMovement || model.taskDragPreview != nil
        }
        let final = try XCTUnwrap(coordinator.drop(item: nil, index: 15))
        XCTAssertTrue(coordinator.validate(item: nil, index: 15))
        try await settle()
        XCTAssertTrue(sawPreviewDuringMovement, "A continuously changing target must not defer every preview until the pointer stops")
        let order = try XCTUnwrap(model.taskDragPreview).siblingTasks(of: source.id).map(\.id)
        if let before = final.before { XCTAssertEqual(order.firstIndex(of: source.id)! + 1, order.firstIndex(of: before)) }
        XCTAssertTrue(outline.view(atColumn: 0, row: outline.row(forItem: stableNode), makeIfNecessary: true) === stableCell)
        XCTAssertEqual(clip.bounds.origin.y, origin.y, accuracy: 1)
        coordinator.cancelDrag()
        try await settle()
        XCTAssertEqual(model.document.tasks, tasks)
        XCTAssertEqual(outline.numberOfRows, tasks.count)
        XCTAssertEqual(clip.bounds.origin.y, origin.y, accuracy: 1)
    }
}
