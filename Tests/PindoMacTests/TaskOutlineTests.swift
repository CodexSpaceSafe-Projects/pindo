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
        let document = model.document
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
    @MainActor private func model(defaults: UserDefaults = .standard) throws -> AppModel {
        let model = try AppModel(directory: FileManager.default.temporaryDirectory.appendingPathComponent("PindoOutline-\(UUID().uuidString)"),
                                 defaults: defaults)
        model.playFeedback = { _ in }
        return model
    }

    @MainActor private func host(_ model: AppModel, matching: Set<UUID>? = nil, batch: Bool = false, sectioned: Bool = false, width: CGFloat = 420, mainPanel: Bool = false) async throws -> (NSPanel, TaskNativeOutlineView, TaskOutlineCoordinator) {
        _ = NSApplication.shared
        let window = NSPanel(contentRect: NSRect(x: 200, y: 200, width: width, height: 520), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isMovableByWindowBackground = true
        if mainPanel {
            window.contentView = NSHostingView(rootView: TaskPanelView(model: model))
        } else {
            window.contentView = NSHostingView(rootView: OutlineFixture(model: model, matching: matching, batch: batch, sectioned: sectioned))
        }
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

    @MainActor private func point(in outline: NSOutlineView, on node: TaskOutlineNode,
                                  x: CGFloat = 120, fraction: CGFloat = 0.5) -> NSPoint {
        let rect = outline.rect(ofRow: outline.row(forItem: node))
        return NSPoint(x: x, y: rect.minY + rect.height * fraction)
    }

    @MainActor func testCompletedPreferenceUpdatesExistingSectionBothWays() async throws {
        let model = try model()
        XCTAssertTrue(model.addTask(title: "已完成待办", day: model.selectedDay, groupID: nil))
        model.setPhase(try XCTUnwrap(model.document.tasks.first), .completed)
        let (window, outline, coordinator) = try await host(model, mainPanel: true)
        defer { window.orderOut(nil); window.contentView = nil }
        let section = try XCTUnwrap(coordinator.roots.first { $0.key == "section.completed" })
        XCTAssertFalse(outline.isItemExpanded(section))

        model.setPreferences { $0.expandCompleted = true }
        try await settle()
        XCTAssertTrue(outline.isItemExpanded(section))
        model.setPreferences { $0.expandCompleted = false }
        try await settle()
        XCTAssertFalse(outline.isItemExpanded(section))
    }

    @MainActor func testManagementMenuMovesOneVisibleSiblingAcrossDates() async throws {
        let model = try model(), day = DayKey()
        XCTAssertTrue(model.addTask(title: "今天 A", day: day, groupID: nil))
        XCTAssertTrue(model.addTask(title: "昨天 X", day: day.adding(days: -1), groupID: nil))
        XCTAssertTrue(model.addTask(title: "今天 B", day: day, groupID: nil))
        // 导入的数据可能有并列顺序。移动时，创建时间不能让事项越过两个位置。
        XCTAssertTrue(model.commit {
            $0.tasks[0].order = 0; $0.tasks[0].createdAt = Date(timeIntervalSince1970: 10)
            $0.tasks[1].order = 0; $0.tasks[1].createdAt = Date(timeIntervalSince1970: 20)
            $0.tasks[2].order = 1; $0.tasks[2].createdAt = Date(timeIntervalSince1970: 0)
        })
        let original = model.document.tasks
        let (window, outline, coordinator) = try await host(model)
        defer { window.orderOut(nil); window.contentView = nil }
        func rowIDs() -> [UUID] {
            (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? TaskOutlineNode)?.row?.id }
        }
        XCTAssertEqual(rowIDs(), original.map(\.id))
        let first = try XCTUnwrap(coordinator.taskNode(original[0].id))
        let last = try XCTUnwrap(coordinator.taskNode(original[2].id))
        let up = model.localization("上移")
        XCTAssertEqual(coordinator.menu(for: first)?.item(withTitle: up)?.isEnabled, false)
        let item = try XCTUnwrap(coordinator.menu(for: last)?.item(withTitle: up))
        XCTAssertTrue(item.isEnabled)
        let action = try XCTUnwrap(item.target as? TaskOutlineMenuAction)
        action.run()
        try await settle()

        XCTAssertEqual(rowIDs(), [original[0].id, original[2].id, original[1].id])
        XCTAssertEqual(model.document.tasks.map(\.plannedDay), original.map(\.plannedDay))
    }

    @MainActor func testNestedDropFeedbackKeepsMainListColumnFitted() async throws {
        let model = try model(), day = DayKey()
        XCTAssertTrue(model.addTask(title: "父项", day: day, groupID: nil))
        XCTAssertTrue(model.addTask(title: "拖动目标", day: day, groupID: nil))
        XCTAssertTrue(model.addTask(title: "同级待办", day: day, groupID: nil))
        let parent = model.document.tasks[0], source = model.document.tasks[1]
        XCTAssertTrue(model.addTask(title: "第二层待办", day: day, groupID: nil, parentID: parent.id))
        let child = try XCTUnwrap(model.document.tasks.first { $0.parentID == parent.id })
        let (window, outline, coordinator) = try await host(model, width: 360, mainPanel: true)
        defer { window.orderOut(nil); window.contentView = nil }
        let column = try XCTUnwrap(outline.outlineTableColumn)
        let initialWidth = outline.visibleRect.width
        XCTAssertGreaterThan(initialWidth, 300)
        XCTAssertEqual(column.width, initialWidth, accuracy: 1)

        let originalLevel = outline.level(forItem: coordinator.taskNode(source.id))
        coordinator.beginDrag(source.id, atX: 120)
        for (offset, destination) in [parent, child].enumerated() {
            let node = try XCTUnwrap(coordinator.taskNode(destination.id))
            let location = point(in: outline, on: node, x: 144 + CGFloat(offset) * 20)
            let feedback = try XCTUnwrap(coordinator.indicateDrop(at: location))
            XCTAssertEqual(feedback.drop.parent, destination.id)
            try await settle()
            XCTAssertEqual(outline.level(forItem: coordinator.taskNode(source.id)), originalLevel)
            XCTAssertEqual(column.width, initialWidth, accuracy: 1, "跨层级指示时列宽应填满列表")
        }
        coordinator.cancelDrag()
        try await settle()
        XCTAssertEqual(column.width, initialWidth, accuracy: 1, "取消拖动后列宽应填满列表")

        window.setContentSize(NSSize(width: 480, height: 520))
        try await settle()
        XCTAssertGreaterThan(outline.visibleRect.width, initialWidth)
        XCTAssertEqual(column.width, outline.visibleRect.width, accuracy: 1, "列宽仍应跟随窗口")
    }

    @MainActor func testDraggedSubtaskImageIncludesBothEdgesInNarrowWindow() async throws {
        let model = try model(), day = DayKey()
        XCTAssertTrue(model.addTask(title: "父项", day: day, groupID: nil))
        let parent = try XCTUnwrap(model.document.tasks.first)
        XCTAssertTrue(model.addTask(title: "标题较长的子项，缩窄窗口后应当保留换行和两边的内容",
                                    note: "备注", day: day, groupID: model.document.groups.first?.id, parentID: parent.id))
        let child = try XCTUnwrap(model.document.tasks.first { $0.parentID == parent.id })
        let (window, outline, coordinator) = try await host(model, width: 360)
        defer { window.orderOut(nil); window.contentView = nil }
        let node = try XCTUnwrap(coordinator.taskNode(child.id))
        let row = outline.row(forItem: node)
        XCTAssertGreaterThanOrEqual(row, 0)
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? TaskOutlineCell)
        let image = try XCTUnwrap(cell.dragImage())
        XCTAssertEqual(image.size, cell.bounds.size)
        let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        let scale = CGFloat(bitmap.pixelsWide) / image.size.width
        func alpha(_ x: Int, _ y: Int) -> CGFloat { bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
        let dotX = Int((cell.groupLabel.frame.minX - 7) * scale)
        let dotY = Int(cell.groupLabel.frame.midY * scale)
        XCTAssertGreaterThan(alpha(dotX, dotY), 0.9, "右侧分组色点应出现在拖动图像中")
        let note = cell.note.frame
        let noteContainsInk = (Int(note.minX * scale)..<Int(note.maxX * scale)).contains { x in
            (Int(note.minY * scale)..<Int(note.maxY * scale)).contains { y in alpha(x, y) > 0.25 }
        }
        XCTAssertTrue(noteContainsInk, "右侧备注图标应出现在拖动图像中")
    }

    @MainActor func testLongTitlesRemainVisibleAcrossThreeLevelsAndAccessories() async throws {
        let model = try model(), day = DayKey()
        let title = String(repeating: "这是一条用来检查换行的待办", count: 4)
        XCTAssertTrue(model.addTask(title: title, day: day, groupID: nil))
        let root = try XCTUnwrap(model.document.tasks.last)
        XCTAssertTrue(model.addTask(title: title, day: day, groupID: nil, parentID: root.id))
        let child = try XCTUnwrap(model.document.tasks.last)
        XCTAssertTrue(model.addTask(title: title, note: "备注", day: day, groupID: nil, parentID: child.id))
        let grandchild = try XCTUnwrap(model.document.tasks.last)
        let (window, outline, coordinator) = try await host(model, width: 360, mainPanel: true)
        defer { window.orderOut(nil); window.contentView = nil }

        var previousTitleX: CGFloat?
        for task in [root, child, grandchild] {
            let node = try XCTUnwrap(coordinator.taskNode(task.id))
            let row = outline.row(forItem: node)
            let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? TaskOutlineCell)
            cell.layoutSubtreeIfNeeded()
            let titleX = cell.convert(cell.titleLabel.frame, to: outline).minX
            if let previousTitleX {
                XCTAssertEqual(titleX - previousTitleX, 8, accuracy: 1)
            } else {
                XCTAssertLessThanOrEqual(titleX, 55, "首层标题应靠近列表左边缘")
            }
            previousTitleX = titleX
            let disclosure = outline.frameOfOutlineCell(atRow: row)
            if task.id != grandchild.id {
                XCTAssertFalse(disclosure.isEmpty)
                XCTAssertLessThanOrEqual(disclosure.maxX, cell.convert(cell.status.frame, to: outline).minX)
            }
            let required = cell.titleLabel.attributedStringValue.boundingRect(
                with: NSSize(width: cell.titleLabel.frame.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            XCTAssertGreaterThanOrEqual(cell.titleLabel.frame.height, ceil(required), "长标题换行后应完整显示")
            let accessories = [cell.progressLabel, cell.groupLabel, cell.note].filter { !$0.isHidden }
            if let firstAccessory = accessories.map(\.frame.minX).min() {
                let gap = firstAccessory - cell.titleLabel.frame.maxX
                XCTAssertGreaterThanOrEqual(gap, 0, "标题不能遮住右侧标记")
                XCTAssertLessThanOrEqual(gap, 15, "标题应充分利用标记左侧的空间")
            } else {
                XCTAssertLessThanOrEqual(cell.bounds.maxX - cell.titleLabel.frame.maxX, 8)
            }
        }
    }

    @MainActor func testFontPreferencesResizeVisibleTaskTitlesAndNotePreviews() async throws {
        let suite = "PindoOutlineFonts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = try model(defaults: defaults), day = model.selectedDay
        XCTAssertTrue(model.addTask(title: "Title of the branch", note: "Note preview 中文", day: day, groupID: nil))
        let parent = try XCTUnwrap(model.document.tasks.last)
        XCTAssertTrue(model.addTask(title: "子项", day: day, groupID: nil, parentID: parent.id))
        let (window, outline, coordinator) = try await host(model, width: 360, mainPanel: true)
        defer { window.orderOut(nil); window.contentView = nil }
        let node = try XCTUnwrap(coordinator.taskNode(parent.id))
        let row = outline.row(forItem: node)
        let oldHeight = outline.rect(ofRow: row).height

        var preferences = model.fontPreferences
        preferences.task = PindoFontChoice(primaryFamily: "Menlo", pointSize: 32)
        preferences.note = PindoFontChoice(primaryFamily: "Helvetica", fallbackFamily: "Hiragino Sans", pointSize: 26)
        model.setFontPreferences(preferences)
        try await settle()

        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? TaskOutlineCell)
        cell.layoutSubtreeIfNeeded()
        let title = cell.titleLabel.attributedStringValue
        let titleFont = try XCTUnwrap(title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(titleFont.familyName, "Menlo")
        XCTAssertEqual(titleFont.pointSize, 32)
        XCTAssertEqual(cell.metadata.font?.familyName, "Helvetica")
        XCTAssertEqual(cell.metadata.font?.pointSize, 22)
        XCTAssertGreaterThan(outline.rect(ofRow: row).height, oldHeight)
        let required = title.boundingRect(with: NSSize(width: cell.titleLabel.frame.width, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        XCTAssertGreaterThanOrEqual(cell.titleLabel.frame.height, ceil(required))
        XCTAssertGreaterThan(cell.metadata.frame.minY, cell.titleLabel.frame.maxY)
        XCTAssertLessThanOrEqual(cell.metadata.frame.maxY, cell.bounds.maxY)
    }

    @MainActor func testBranchCardFollowsDisclosureAndUpdatesAncestorProgress() async throws {
        let model = try model(), day = model.selectedDay
        let group = try XCTUnwrap(model.document.groups.first)
        XCTAssertTrue(model.addTask(title: "整理新版发布清单", note: "打包、发布说明和上线后复查。\n第二行不显示",
                                    day: day, groupID: group.id))
        let parent = try XCTUnwrap(model.document.tasks.last)
        XCTAssertTrue(model.addTask(title: "补齐发布说明", day: day, groupID: group.id, parentID: parent.id))
        let child = try XCTUnwrap(model.document.tasks.last)
        XCTAssertTrue(model.addTask(title: "补一张显示分组筛选的设置页截图", day: day, groupID: group.id, parentID: child.id))
        let grandchild = try XCTUnwrap(model.document.tasks.last)
        XCTAssertTrue(model.addTask(title: "核对构建产物", note: "核对签名", day: day, groupID: group.id, parentID: parent.id))
        model.setPhase(try XCTUnwrap(model.document.tasks.last), .inProgress)
        XCTAssertTrue(model.addTask(title: "归档桌面上的截图、安装包和临时文件", day: day, groupID: nil))
        let single = try XCTUnwrap(model.document.tasks.last)
        let (window, outline, coordinator) = try await host(model, mainPanel: true)
        defer { window.orderOut(nil); window.contentView = nil }

        let parentNode = try XCTUnwrap(coordinator.taskNode(parent.id))
        let childNode = try XCTUnwrap(coordinator.taskNode(child.id))
        let rootRow = outline.row(forItem: parentNode)
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: rootRow, makeIfNecessary: true) as? TaskOutlineCell)
        cell.layoutSubtreeIfNeeded()
        XCTAssertEqual(outline.branchRows(containing: rootRow + 2), rootRow...(rootRow + 3))
        XCTAssertNil(outline.branchRows(containing: outline.row(forItem: coordinator.taskNode(single.id))))
        XCTAssertEqual(cell.metadata.stringValue, "打包、发布说明和上线后复查。")
        XCTAssertEqual(cell.groupLabel.stringValue, group.name)
        XCTAssertGreaterThanOrEqual(cell.groupLabel.frame.width, cell.groupLabel.intrinsicContentSize.width)
        XCTAssertNil(childNode.branchStyle?.groupName)
        XCTAssertEqual(cell.progressLabel.stringValue, "0/3")

        outline.collapseItem(parentNode)
        try await settle()
        XCTAssertEqual(outline.branchRows(containing: rootRow), rootRow...rootRow)
        XCTAssertEqual(cell.progressLabel.stringValue, "0/3")

        model.setPhase(grandchild, .completed)
        try await settle()
        let updated = try XCTUnwrap(outline.view(atColumn: 0, row: rootRow, makeIfNecessary: true) as? TaskOutlineCell)
        XCTAssertEqual(updated.progressLabel.stringValue, "2/3")
        XCTAssertEqual(outline.branchRows(containing: rootRow), rootRow...rootRow)

        outline.expandItem(parentNode)
        try await settle()
        XCTAssertEqual(outline.branchRows(containing: rootRow), rootRow...(rootRow + 3))
    }

    @MainActor func testClickingBeforeStatusTogglesDisclosureWithoutOpeningNote() async throws {
        let model = try model(), day = model.selectedDay
        XCTAssertTrue(model.addTask(title: "父项", day: day, groupID: nil))
        let parent = try XCTUnwrap(model.document.tasks.last)
        XCTAssertTrue(model.addTask(title: "子项", day: day, groupID: nil, parentID: parent.id))
        XCTAssertTrue(model.addTask(title: "独立事项", day: day, groupID: nil))
        let single = try XCTUnwrap(model.document.tasks.last)
        let (window, outline, coordinator) = try await host(model, mainPanel: true)
        defer { window.orderOut(nil); window.contentView = nil }
        let branch = try XCTUnwrap(coordinator.taskNode(parent.id))
        let leaf = try XCTUnwrap(coordinator.taskNode(single.id))

        func cell(for node: TaskOutlineNode) throws -> TaskOutlineCell {
            let index = outline.row(forItem: node)
            let cell = try XCTUnwrap(outline.view(atColumn: 0, row: index, makeIfNecessary: true) as? TaskOutlineCell)
            cell.layoutSubtreeIfNeeded()
            return cell
        }

        func click(_ point: NSPoint) async throws {
            let location = outline.convert(point, to: nil)
            let timestamp = ProcessInfo.processInfo.systemUptime
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                timestamp: timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                timestamp: timestamp + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
            NSApp.postEvent(up, atStart: true)
            window.sendEvent(down)
            try await Task.sleep(nanoseconds: 80_000_000)
        }

        func clickGutter(of node: TaskOutlineNode) async throws {
            let rowCell = try cell(for: node)
            let x = rowCell.convert(rowCell.status.frame, to: outline).minX - 2
            try await click(point(in: outline, on: node, x: x))
        }

        XCTAssertTrue(outline.isItemExpanded(branch))
        try await clickGutter(of: branch)
        XCTAssertFalse(outline.isItemExpanded(branch))
        XCTAssertNil(model.noteID)

        try await clickGutter(of: branch)
        XCTAssertTrue(outline.isItemExpanded(branch))
        XCTAssertNil(model.noteID)

        let triangle = outline.frameOfOutlineCell(atRow: outline.row(forItem: branch))
        let arrowPoint = outline.convert(NSPoint(x: triangle.midX, y: triangle.midY), to: outline.superview)
        XCTAssertTrue(outline.hitTest(arrowPoint) is NSButton, "箭头应交给 AppKit 的原生按钮")

        try await clickGutter(of: leaf)
        XCTAssertNil(model.noteID)
        XCTAssertEqual(model.task(single.id)?.phase, .pending)

        let leafCell = try cell(for: leaf)
        let status = leafCell.convert(leafCell.status.frame, to: outline)
        let statusPoint = outline.convert(NSPoint(x: status.midX, y: status.midY), to: outline.superview)
        XCTAssertTrue(outline.hitTest(statusPoint) === leafCell.status)
        leafCell.status.performClick(nil)
        XCTAssertEqual(model.task(single.id)?.phase, .inProgress)
        XCTAssertNil(model.noteID)

        try await clickGutter(of: branch)
        XCTAssertFalse(outline.isItemExpanded(branch))
        let updatedCell = try cell(for: leaf)
        let title = updatedCell.convert(updatedCell.titleLabel.frame, to: outline)
        try await click(NSPoint(x: title.minX + 8, y: title.midY))
        XCTAssertEqual(model.noteID, single.id)
        model.leaveNote()
        try await settle()
        XCTAssertTrue(outline.window === window, "返回清单时应复用原生列表")
        XCTAssertFalse(outline.isItemExpanded(branch))
    }

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
        XCTAssertEqual(cell.groupLabel.frame.maxX, cell.note.frame.maxX, accuracy: 0.5)
        XCTAssertLessThan(cell.groupLabel.frame.maxY, cell.note.frame.minY)
        XCTAssertNil(model.noteID)
        model.saveGroup(id: group.id, name: "改名后的分组", color: "#33AA66")
        try await settle()
        let refreshed = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? TaskOutlineCell)
        XCTAssertEqual(refreshed.groupLabel.stringValue, "改名后的分组")
        XCTAssertEqual(model.document.tasks[0], task)
    }

    @MainActor func testScrollingRecomputesTheOnlyHoveredTaskWithoutSelectingRows() async throws {
        let model = try model(), day = DayKey()
        XCTAssertTrue(model.commit { document in
            for index in 0..<30 {
                try document.insertTask(TodoItem(title: "事项 \(index)", plannedDay: day, order: index))
            }
        })
        let (window, outline, coordinator) = try await host(model)
        defer { window.orderOut(nil); window.contentView = nil }
        let selection = outline.selectedRowIndexes
        let scroll = try XCTUnwrap(outline.enclosingScrollView)

        func moveOverTask(_ index: Int) throws -> TaskOutlineCell {
            let node = try XCTUnwrap(coordinator.taskNode(model.document.tasks[index].id))
            let row = outline.row(forItem: node)
            let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? TaskOutlineCell)
            let location = outline.convert(point(in: outline, on: node), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0))
            outline.mouseMoved(with: event)
            return cell
        }

        let first = try moveOverTask(0)
        XCTAssertTrue(first.isHovered)
        let second = try moveOverTask(1)
        XCTAssertFalse(first.isHovered)
        XCTAssertTrue(second.isHovered)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        let pointer = outline.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let pointerRow = outline.visibleRect.contains(pointer) ? outline.row(at: pointer) : -1
        let cellUnderPointer = pointerRow >= 0 ? outline.view(atColumn: 0, row: pointerRow, makeIfNecessary: false) : nil
        for cell in [first, second] where cell !== cellUnderPointer { XCTAssertFalse(cell.isHovered) }
        XCTAssertEqual(outline.selectedRowIndexes, selection)
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

    @MainActor func testRightDragShowsIndentedLineAndParentWithoutMovingOrExpandingRows() async throws {
        let model = try model(), day = DayKey()
        for title in ["目标", "拖动事项"] { XCTAssertTrue(model.addTask(title: title, day: day, groupID: nil)) }
        let target = model.document.tasks[0], source = model.document.tasks[1]
        XCTAssertTrue(model.addTask(title: "隐藏的子项", day: day, groupID: nil, parentID: target.id))
        let original = model.document, bytes = try Data(contentsOf: model.repository.dataURL)
        let (window, outline, coordinator) = try await host(model)
        defer { window.orderOut(nil); window.contentView = nil }
        let targetNode = try XCTUnwrap(coordinator.taskNode(target.id))
        let sourceNode = try XCTUnwrap(coordinator.taskNode(source.id))
        outline.collapseItem(targetNode)
        try await settle()
        let row = outline.row(forItem: sourceNode)
        coordinator.beginDrag(source.id, atX: 120)
        let vertical = try XCTUnwrap(coordinator.indicateDrop(at: point(in: outline, on: targetNode, x: 139)))
        XCTAssertNil(vertical.drop.parent)
        XCTAssertNil(vertical.feedback.parent)
        let right = point(in: outline, on: targetNode, x: 144)
        let nested = try XCTUnwrap(coordinator.indicateDrop(at: right))
        XCTAssertEqual(nested.drop.parent, target.id)
        XCTAssertNotNil(nested.feedback.parent)
        XCTAssertEqual(nested.feedback.line.minX - vertical.feedback.line.minX, outline.indentationPerLevel, accuracy: 1)
        try await settle()
        XCTAssertFalse(outline.isItemExpanded(targetNode))
        XCTAssertEqual(outline.row(forItem: sourceNode), row)
        XCTAssertEqual(model.document, original)
        XCTAssertEqual(try Data(contentsOf: model.repository.dataURL), bytes)
        XCTAssertTrue(coordinator.acceptDrop(at: right))
        try await settle()
        XCTAssertTrue(outline.isItemExpanded(targetNode))
        XCTAssertEqual(model.task(source.id)?.parentID, target.id)
        XCTAssertNil(coordinator.displayedDrop)
        XCTAssertNil(model.draggedTaskID)
    }

    @MainActor func testVerticalDragReordersAndOnlyCommitsTheIndicatedBoundary() async throws {
        let model = try model(), day = DayKey()
        for title in ["A", "B", "C"] { XCTAssertTrue(model.addTask(title: title, day: day, groupID: nil)) }
        let a = model.document.tasks[0], b = model.document.tasks[1], c = model.document.tasks[2]
        let (window, outline, coordinator) = try await host(model)
        defer { window.orderOut(nil); window.contentView = nil }
        let aNode = try XCTUnwrap(coordinator.taskNode(a.id))
        let bNode = try XCTUnwrap(coordinator.taskNode(b.id))
        let beforeA = point(in: outline, on: aNode, fraction: 0.25)
        let beforeB = point(in: outline, on: bNode, fraction: 0.25)
        coordinator.beginDrag(c.id, atX: 120)
        XCTAssertEqual(coordinator.indicateDrop(at: beforeA)?.drop.before, a.id)
        XCTAssertFalse(coordinator.acceptDrop(at: beforeB))
        XCTAssertEqual(model.document.siblingTasks(of: a.id).map(\.id), [a.id, b.id, c.id])
        coordinator.beginDrag(c.id, atX: 120)
        XCTAssertEqual(coordinator.indicateDrop(at: beforeA)?.drop.before, a.id)
        XCTAssertTrue(coordinator.acceptDrop(at: beforeA))
        XCTAssertEqual(model.document.siblingTasks(of: a.id).map(\.id), [c.id, a.id, b.id])
        XCTAssertNil(model.task(c.id)?.parentID)
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document, model.document)
    }

    @MainActor func testVerticalDragKeepsParentAndLeftDragMovesAfterWholeParentBranch() async throws {
        let model = try model(), day = DayKey()
        for title in ["父项 A", "父项 B"] { XCTAssertTrue(model.addTask(title: title, day: day, groupID: nil)) }
        let a = model.document.tasks[0], b = model.document.tasks[1]
        XCTAssertTrue(model.addTask(title: "拖动项", day: day, groupID: nil, parentID: a.id))
        XCTAssertTrue(model.addTask(title: "同级子项", day: day, groupID: nil, parentID: a.id))
        XCTAssertTrue(model.addTask(title: "另一分支子项", day: day, groupID: nil, parentID: b.id))
        let source = model.document.tasks[2], sibling = model.document.tasks[3], other = model.document.tasks[4]
        let (window, outline, coordinator) = try await host(model)
        defer { window.orderOut(nil); window.contentView = nil }
        let sourceNode = try XCTUnwrap(coordinator.taskNode(source.id))
        let otherNode = try XCTUnwrap(coordinator.taskNode(other.id))
        let siblingNode = try XCTUnwrap(coordinator.taskNode(sibling.id))
        coordinator.beginDrag(source.id, atX: 120)
        XCTAssertNil(coordinator.indicateDrop(at: point(in: outline, on: otherNode)))
        let left = point(in: outline, on: sourceNode, x: 96)
        let target = try XCTUnwrap(coordinator.indicateDrop(at: left))
        XCTAssertNil(target.drop.parent)
        XCTAssertEqual(target.drop.before, b.id)
        XCTAssertGreaterThanOrEqual(target.feedback.line.midY, outline.rect(ofRow: outline.row(forItem: siblingNode)).maxY)
        XCTAssertTrue(coordinator.acceptDrop(at: left))
        XCTAssertEqual(model.document.siblingTasks(of: a.id).map(\.id), [a.id, source.id, b.id])
        XCTAssertEqual(model.task(sibling.id)?.parentID, a.id)
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
        let childNode = try XCTUnwrap(coordinator.taskNode(child.id))
        coordinator.beginDrag(root.id, atX: 120)
        XCTAssertNil(coordinator.indicateDrop(at: point(in: outline, on: childNode, x: 164)))
        coordinator.cancelDrag()
        let otherNode = try XCTUnwrap(coordinator.taskNode(other.id))
        coordinator.beginDrag(root.id, atX: 120)
        XCTAssertNil(coordinator.indicateDrop(at: point(in: outline, on: otherNode, x: 144)))
        coordinator.cancelDrag()
        // Inspect a second native instance configured for filtered bulk operations.
        let (batchWindow, batchOutline, batchCoordinator) = try await host(model, matching: [grandchild.id], batch: true)
        defer { batchWindow.orderOut(nil); batchWindow.contentView = nil }
        let contextNode = try XCTUnwrap(batchCoordinator.taskNode(root.id))
        let contextCell = try XCTUnwrap(batchOutline.view(atColumn: 0, row: batchOutline.row(forItem: contextNode), makeIfNecessary: true) as? TaskOutlineCell)
        XCTAssertFalse(contextCell.checkbox.isHidden); XCTAssertFalse(contextCell.checkbox.isEnabled)
        XCTAssertNil(batchCoordinator.outlineView(batchOutline, pasteboardWriterForItem: contextNode))
        XCTAssertNil(coordinator.displayedDrop)
        XCTAssertEqual(model.task(child.id)?.parentID, root.id)
        XCTAssertEqual(model.task(grandchild.id)?.parentID, child.id)
        XCTAssertEqual(outline.registeredDraggedTypes, [TaskOutlineCoordinator.pasteboardType])
    }

    @MainActor func testDragCannotOverwriteConcurrentChangesAndFailedAcceptanceEndsDrag() async throws {
        let model = try model(), day = DayKey()
        for title in ["目标", "事项"] { XCTAssertTrue(model.addTask(title: title, day: day, groupID: nil)) }
        let target = model.document.tasks[0], source = model.document.tasks[1]
        XCTAssertTrue(model.beginTaskDrag(source.id))
        XCTAssertTrue(model.canAcceptTaskDrag(parent: target.id, before: nil, completed: false))
        // A note staged after the drag started must not be replaced by its old snapshot.
        model.updateNote(source.id, text: "拖动过程中更新的备注")
        XCTAssertFalse(model.acceptTaskDrag(parent: target.id, before: nil))
        XCTAssertEqual(model.task(source.id)?.note, "拖动过程中更新的备注")
        XCTAssertNil(model.task(source.id)?.parentID)
        XCTAssertNil(model.draggedTaskID)
        XCTAssertTrue(model.flush())
        let before = model.document, bytes = try Data(contentsOf: model.repository.dataURL)
        XCTAssertTrue(model.beginTaskDrag(source.id))
        XCTAssertTrue(model.canAcceptTaskDrag(parent: target.id, before: nil, completed: false))
        try FileManager.default.removeItem(at: model.repository.dataURL)
        try FileManager.default.createDirectory(at: model.repository.dataURL, withIntermediateDirectories: false)
        XCTAssertFalse(model.acceptTaskDrag(parent: target.id, before: nil))
        XCTAssertEqual(model.document, before)
        XCTAssertNil(model.draggedTaskID)
        try FileManager.default.removeItem(at: model.repository.dataURL)
        try bytes.write(to: model.repository.dataURL, options: .atomic)
    }

    @MainActor func testNativeCompletedAndUnfinishedRegionsRejectCrossDropsAndAcceptRevalidates() async throws {
        let model = try model(), day = DayKey()
        for title in ["未完成", "进行中", "已完成 A", "已完成 B"] { XCTAssertTrue(model.addTask(title: title, day: day, groupID: nil)) }
        let pending = model.document.tasks[0], running = model.document.tasks[1], doneA = model.document.tasks[2], doneB = model.document.tasks[3]
        model.setPhase(running, .inProgress); model.setPhase(doneA, .completed); model.setPhase(doneB, .completed)
        let original = model.document, bytes = try Data(contentsOf: model.repository.dataURL)
        let (window, outline, coordinator) = try await host(model, sectioned: true)
        defer { window.orderOut(nil); window.contentView = nil }
        let pendingHeader = try XCTUnwrap(coordinator.roots.first { $0.completed == false })
        let doneHeader = try XCTUnwrap(coordinator.roots.first { $0.completed == true })
        let doneANode = try XCTUnwrap(coordinator.taskNode(doneA.id))
        let pendingNode = try XCTUnwrap(coordinator.taskNode(pending.id))
        let onDone = point(in: outline, on: doneANode, x: 144)
        let onPending = point(in: outline, on: pendingNode, x: 144)
        for source in [pending, running] {
            coordinator.beginDrag(source.id, atX: 120)
            XCTAssertNil(coordinator.indicateDrop(at: point(in: outline, on: doneHeader)))
            XCTAssertNil(coordinator.indicateDrop(at: onDone))
            XCTAssertFalse(coordinator.acceptDrop(at: onDone))
        }
        coordinator.beginDrag(doneA.id, atX: 120)
        XCTAssertNil(coordinator.indicateDrop(at: point(in: outline, on: pendingHeader)))
        XCTAssertNil(coordinator.indicateDrop(at: onPending))
        XCTAssertFalse(coordinator.acceptDrop(at: onPending))
        XCTAssertEqual(model.document, original)
        XCTAssertEqual(try Data(contentsOf: model.repository.dataURL), bytes)
        XCTAssertNil(coordinator.displayedDrop)
        coordinator.beginDrag(doneB.id, atX: 120)
        XCTAssertEqual(coordinator.indicateDrop(at: onDone)?.drop.parent, doneA.id)
        XCTAssertTrue(coordinator.acceptDrop(at: onDone))
        XCTAssertEqual(model.task(doneB.id)?.parentID, doneA.id)
        XCTAssertEqual(model.task(doneA.id)?.phase, .completed)
        XCTAssertEqual(model.task(doneB.id)?.phase, .completed)
    }

    @MainActor func testRapidDropFeedbackKeepsCellsRowsAndScrollPosition() async throws {
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
        let rows = (0..<outline.numberOfRows).map { (outline.item(atRow: $0) as? TaskOutlineNode)?.row?.id }
        coordinator.beginDrag(source.id, atX: 120)
        for index in 0..<20 {
            let node = try XCTUnwrap(coordinator.taskNode(tasks[14 + index % 5].id))
            let location = point(in: outline, on: node, fraction: 0.25)
            XCTAssertNotNil(coordinator.indicateDrop(at: location))
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        XCTAssertEqual((0..<outline.numberOfRows).map { (outline.item(atRow: $0) as? TaskOutlineNode)?.row?.id }, rows)
        XCTAssertTrue(outline.view(atColumn: 0, row: outline.row(forItem: stableNode), makeIfNecessary: true) === stableCell)
        XCTAssertEqual(clip.bounds.origin.y, origin.y, accuracy: 1)
        coordinator.cancelDrag()
        try await settle()
        XCTAssertEqual(model.document.tasks, tasks)
        XCTAssertEqual(outline.numberOfRows, tasks.count)
        XCTAssertEqual(clip.bounds.origin.y, origin.y, accuracy: 1)
    }
}
