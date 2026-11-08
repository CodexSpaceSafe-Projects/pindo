import XCTest
import AppKit
import SwiftUI
import PindoCore
@testable import Pindo

final class AppModelTests: XCTestCase {
    @MainActor private func makeModel() throws -> AppModel {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("PindoMacTests-\(UUID().uuidString)")
        let model = try AppModel(directory: path)
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
        XCTAssertGreaterThanOrEqual(panel.fittingSize.width, 360)
        XCTAssertLessThanOrEqual(panel.fittingSize.width, 390)
        panel.frame.size = NSSize(width: 720, height: 850)
        panel.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame.size, NSSize(width: 720, height: 850))
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
        let composingAttributes = NSAttributedString(attributedString: view.textStorage!)
        coordinator.publish(view)
        coordinator.render(view)
        XCTAssertEqual(stored, "已有")
        coordinator.synchronize(view, text: stored)
        XCTAssertEqual(view.string, composingText)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertTrue(view.textStorage!.isEqual(to: composingAttributes))
        view.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        coordinator.publish(view)
        XCTAssertEqual(stored, "已有中文")
        view.setSelectedRange(NSRange(location: 1, length: 1))
        coordinator.synchronize(view, text: stored)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 1))
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

    @MainActor func testLiveMarkdownChangesAppearanceWithoutChangingSourceSelectionOrUndo() async throws {
        _ = NSApplication.shared
        var stored = "# 标题\n**粗体** 和 `代码`\n最后一行"
        let editor = NoteEditor(text: Binding(get: { stored }, set: { stored = $0 }))
        let coordinator = editor.makeCoordinator()
        let view = ComposingTextView()
        view.isRichText = false; view.allowsUndo = true; view.string = stored; view.delegate = coordinator
        // Text views obtain undo from their responder/window chain in the app.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: .titled, backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = view; window.contentView = scroll
        XCTAssertTrue(window.makeFirstResponder(view))
        let undo = try XCTUnwrap(view.undoManager)
        undo.removeAllActions()
        let source = stored as NSString
        view.setSelectedRange(NSRange(location: source.length, length: 0))
        let selection = view.selectedRange()
        coordinator.render(view)
        XCTAssertEqual(view.string, stored)
        XCTAssertEqual(view.selectedRange(), selection)
        let titleFont = try XCTUnwrap(view.textStorage?.attribute(.font, at: source.range(of: "标题").location, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(titleFont.pointSize, 14)
        let bold = try XCTUnwrap(view.textStorage?.attribute(.font, at: source.range(of: "粗体").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        let hidden = try XCTUnwrap(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertLessThan(hidden.pointSize, 1)
        // Entering a formatted paragraph reveals its Markdown delimiters.
        view.setSelectedRange(NSRange(location: 2, length: 1)); coordinator.render(view)
        let visible = try XCTUnwrap(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(visible.pointSize, 1)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 1))
        XCTAssertEqual(view.string, stored)
        view.setSelectedRange(NSRange(location: source.length, length: 0))
        view.insertText("新", replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.publish(view)
        XCTAssertTrue(stored.hasSuffix("新"))
        view.breakUndoCoalescing()
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        coordinator.publish(view)
        XCTAssertEqual(view.string, source as String)
        XCTAssertEqual(stored, source as String)
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

    @MainActor func testFeedbackPlaysOnlyForSuccessfulAddsAndCompletionTransitions() async throws {
        let model = try makeModel()
        var feedback: [TaskFeedback] = []
        model.playFeedback = { feedback.append($0) }
        XCTAssertFalse(model.addTask(title: "  ", day: DayKey(), groupID: nil))
        XCTAssertTrue(feedback.isEmpty)
        XCTAssertTrue(model.addTask(title: "事项", day: DayKey(), groupID: nil))
        let task = model.document.tasks[0]
        model.setPhase(task, .completed)
        model.setPhase(task, .completed) // Stale row callbacks must not play twice.
        XCTAssertEqual(feedback, [.added, .completed])
        model.setPhase(task, .pending)
        XCTAssertEqual(feedback, [.added, .completed])
        // A failed disk write must never sound like a successful action.
        try FileManager.default.removeItem(at: model.repository.dataURL)
        try FileManager.default.createDirectory(at: model.repository.dataURL, withIntermediateDirectories: false)
        XCTAssertFalse(model.addTask(title: "写入失败", day: DayKey(), groupID: nil))
        model.setPhase(task, .completed)
        XCTAssertEqual(feedback, [.added, .completed])
        XCTAssertEqual(model.task(task.id)?.phase, .pending)
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
            XCTAssertEqual(menu.items.map(\.title), ["添加事项", "设置", "退出"].map { model.localization($0) })
            XCTAssertTrue(menu.items.allSatisfy { $0.submenu == nil && $0.action != nil })
        }
        XCTAssertNil(delegate.listPanel)
        delegate.handleStatusClick(button, event: try click(.leftMouseDown))
        XCTAssertEqual(menus.count, 2)
        XCTAssertEqual(delegate.listPanel?.isVisible, true)
    }

    @MainActor func testComposerTopAndBottomPaddingClicksAcceptTyping() async throws {
        _ = NSApplication.shared
        let model = try makeModel()
        let panel = QuickPanel.quickAddPanel()
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

    @MainActor func testComposerReturnSubmitsCommittedTextAndLeavesChineseCompositionAlone() async throws {
        _ = NSApplication.shared
        var draft = "已有", submitted: [String] = []
        let input = ComposerTextField(text: Binding(get: { draft }, set: { draft = $0 }), placeholder: "",
                                      focus: ComposerInputFocus(), submit: { submitted.append(draft) })
        let coordinator = input.makeCoordinator()
        let field = NSTextField(string: draft)
        field.delegate = coordinator
        let panel = QuickPanel.quickAddPanel()
        defer { panel.orderOut(nil) }
        panel.contentView = field
        panel.showInFront(); panel.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: (draft as NSString).length, length: 0))
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(draft, "已有")
        XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(submitted.isEmpty)
        editor.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.unmarkText()
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(draft, "已有中")
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(submitted, ["已有中"])
    }
}
