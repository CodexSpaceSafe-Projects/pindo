import AppKit
import Combine
import SwiftUI
import XCTest
import PindoCore
@testable import Pindo

@MainActor private final class EditingVisibility: ObservableObject {
    @Published var visible = true
}

private final class EditingReadyView: NSView {}
private struct EditingReadyMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> EditingReadyView { EditingReadyView() }
    func updateNSView(_ view: EditingReadyView, context: Context) {}
}

private struct EditingWindowFixture: View {
    @ObservedObject var model: AppModel
    @ObservedObject var visibility: EditingVisibility
    var body: some View {
        if visibility.visible {
            SyncEditingScope(model: model, onUnavailable: {}) { EditingReadyMarker().frame(width: 10, height: 10) }
        } else { Text("Closed") }
    }
}

final class SyncEditingTests: XCTestCase {
    @MainActor private func makeModel() throws -> (AppModel, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PindoSyncEditing-\(UUID().uuidString)")
        let suite = "PindoSyncEditing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = try AppModel(directory: directory, defaults: defaults)
        model.playFeedback = { _ in }
        return (model, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    @MainActor private func host<Content: View>(_ content: Content, width: CGFloat = 500) -> (NSWindow, NSHostingView<Content>) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    @MainActor private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if type == NSTextView.self { return NoteEditor.Coordinator.findTextView(in: view) as? T }
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    @MainActor private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the native editing scope", file: file, line: line)
        throw CancellationError()
    }

    @MainActor func testReleasingOneNestedLeaseOrReleasingItTwiceCannotUnlockAnotherEditor() throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        let first = try XCTUnwrap(model.acquireSyncEditing())
        let second = try XCTUnwrap(model.acquireSyncEditing())
        XCTAssertTrue(model.isSyncEditing)
        model.releaseSyncEditing(first)
        XCTAssertTrue(model.isSyncEditing)
        model.releaseSyncEditing(first)
        model.releaseSyncEditing(UUID())
        XCTAssertTrue(model.isSyncEditing)
        model.releaseSyncEditing(second)
        XCTAssertFalse(model.isSyncEditing)
    }

    @MainActor func testTaskDraftsExcludeTheSameResourceButAllowDifferentTasks() throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        XCTAssertTrue(model.addTask(title: "First", day: model.today, groupID: nil))
        XCTAssertTrue(model.addTask(title: "Second", day: model.today, groupID: nil))
        let firstID = model.document.tasks[0].id, secondID = model.document.tasks[1].id
        let first = try XCTUnwrap(model.acquireSyncEditing(taskID: firstID))
        XCTAssertNil(model.acquireSyncEditing(taskID: firstID))
        let second = try XCTUnwrap(model.acquireSyncEditing(taskID: secondID))
        model.releaseSyncEditing(first)
        let replacement = try XCTUnwrap(model.acquireSyncEditing(taskID: firstID))
        model.releaseSyncEditing(second)
        XCTAssertTrue(model.isSyncEditing)
        model.releaseSyncEditing(replacement)
        XCTAssertFalse(model.isSyncEditing)
    }

    @MainActor func testScopesInTwoWindowsProtectSyncUntilBothEditorsDisappear() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        let firstVisibility = EditingVisibility(), secondVisibility = EditingVisibility()
        let (first, firstHost) = host(EditingWindowFixture(model: model, visibility: firstVisibility))
        let (second, secondHost) = host(EditingWindowFixture(model: model, visibility: secondVisibility))
        defer { first.orderOut(nil); first.contentView = nil; second.orderOut(nil); second.contentView = nil }
        try await waitUntil {
            self.find(EditingReadyView.self, in: firstHost) != nil && self.find(EditingReadyView.self, in: secondHost) != nil
        }
        XCTAssertTrue(model.isSyncEditing)
        firstVisibility.visible = false
        try await waitUntil { self.find(EditingReadyView.self, in: firstHost) == nil }
        XCTAssertTrue(model.isSyncEditing)
        secondVisibility.visible = false
        try await waitUntil { !model.isSyncEditing }
    }

    @MainActor func testManagementSelectionProtectsSyncBeforeTheNoteViewCanAppear() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        XCTAssertTrue(model.addTask(title: "Managed task", note: "Original note", day: model.today, groupID: nil))
        let task = try XCTUnwrap(model.document.tasks.first)
        let (window, nativeHost) = host(TodoManagementView(model: model), width: 740)
        defer { window.orderOut(nil); window.contentView = nil }
        try await waitUntil { self.find(TaskNativeOutlineView.self, in: nativeHost) != nil }
        let outline = try XCTUnwrap(find(TaskNativeOutlineView.self, in: nativeHost))
        let coordinator = try XCTUnwrap(outline.dataSource as? TaskOutlineCoordinator)
        XCTAssertFalse(model.isSyncEditing)
        coordinator.content.onSelect(task)
        // No yield: the click handler itself must close the remote-apply race.
        XCTAssertTrue(model.isSyncEditing)
        try await waitUntil { self.find(NSTextView.self, in: nativeHost) != nil }
        XCTAssertEqual(model.task(task.id)?.note, "Original note")
    }

    @MainActor func testASecondNoteOrTaskEditorCannotInstallEditableControlsForTheSameTask() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        XCTAssertTrue(model.addTask(title: "Shared task", note: "Committed note", day: model.today, groupID: nil))
        let task = try XCTUnwrap(model.document.tasks.first)
        let (first, firstHost) = host(NoteView(model: model, task: task))
        defer { first.orderOut(nil); first.contentView = nil }
        try await waitUntil { self.find(NSTextView.self, in: firstHost) != nil }
        XCTAssertNotNil(find(TaskTitleTextField.self, in: firstHost))
        let (second, secondHost) = host(NoteView(model: model, task: task, onBack: {}))
        let (form, formHost) = host(EditTaskView(model: model, task: task, dismiss: {}))
        defer { second.orderOut(nil); second.contentView = nil; form.orderOut(nil); form.contentView = nil }
        try await Task.sleep(nanoseconds: 250_000_000)
        secondHost.layoutSubtreeIfNeeded(); formHost.layoutSubtreeIfNeeded()
        XCTAssertNil(find(NSTextView.self, in: secondHost))
        XCTAssertNil(find(TaskTitleTextField.self, in: secondHost))
        func hasEditableField(_ view: NSView) -> Bool {
            if let field = view as? NSTextField, field.isEditable { return true }
            return view.subviews.contains(where: hasEditableField)
        }
        XCTAssertFalse(hasEditableField(formHost))
        XCTAssertTrue(model.isSyncEditing)
        XCTAssertEqual(model.task(task.id)?.note, "Committed note")
    }

    @MainActor func testSavingOnlyDirtyFieldsPreservesLaterLocalGroupDateAndNoteChanges() throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        let originalDay = try DayKey(year: 2026, month: 11, day: 14)
        let firstGroup = try XCTUnwrap(model.document.groups.first?.id)
        let secondGroup = try XCTUnwrap(model.document.groups.last?.id)
        XCTAssertNotEqual(firstGroup, secondGroup)
        XCTAssertTrue(model.addTask(title: "Original title", note: "Original note", day: originalDay, groupID: firstGroup))
        let original = try XCTUnwrap(model.document.tasks.first)
        let laterDay = originalDay.adding(days: 3)
        XCTAssertTrue(model.edit(original.id, title: original.title, day: laterDay, groupID: secondGroup))
        model.updateNote(original.id, text: "Later note")
        XCTAssertTrue(model.edit(original.id, title: "Changed title", day: originalDay, groupID: firstGroup, original: original))
        let afterTitle = try XCTUnwrap(model.task(original.id))
        XCTAssertEqual(afterTitle.title, "Changed title")
        XCTAssertEqual(afterTitle.plannedDay, laterDay)
        XCTAssertEqual(afterTitle.groupID, secondGroup)
        XCTAssertEqual(afterTitle.note, "Later note")

        // A later form changing only the group must preserve the newer title/date too.
        XCTAssertTrue(model.edit(original.id, title: "Newer title", day: laterDay.adding(days: 1), groupID: secondGroup))
        XCTAssertTrue(model.edit(original.id, title: afterTitle.title, day: afterTitle.plannedDay, groupID: firstGroup, original: afterTitle))
        let saved = try PindoRepository(directory: model.repository.directory).document.tasks.first
        XCTAssertEqual(saved?.title, "Newer title")
        XCTAssertEqual(saved?.plannedDay, laterDay.adding(days: 1))
        XCTAssertEqual(saved?.groupID, firstGroup)
        XCTAssertEqual(saved?.note, "Later note")
    }

    @MainActor func testHidingAndReshowingACachedPanelReleasesOnlyItsWindowScope() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        _ = NSApplication.shared
        let visibility = EditingVisibility()
        let window = QuickPanel(contentRect: NSRect(x: 100, y: 100, width: 400, height: 400),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let nativeHost = NSHostingView(rootView: EditingWindowFixture(model: model, visibility: visibility))
        window.contentView = nativeHost
        defer { window.orderOut(nil); window.contentView = nil }
        window.showInFront()
        try await waitUntil { self.find(EditingReadyView.self, in: nativeHost) != nil }
        let anotherWindow = try XCTUnwrap(model.acquireSyncEditing())
        let frame = window.frame
        window.orderOut(nil)
        XCTAssertTrue(model.isSyncEditing, "Hiding one window must keep the other window's lease")
        model.releaseSyncEditing(anotherWindow)
        try await waitUntil { !model.isSyncEditing }
        XCTAssertTrue(window.contentView === nativeHost)
        XCTAssertEqual(window.frame, frame)
        window.showInFront()
        try await waitUntil { model.isSyncEditing && self.find(EditingReadyView.self, in: nativeHost) != nil }
        window.orderOut(nil)
        try await waitUntil { !model.isSyncEditing }
    }

    @MainActor func testClosingTheListCommitsCompositionAndKeepsItsHostAndWindowSize() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        _ = NSApplication.shared
        XCTAssertTrue(model.addTask(title: "Close note", note: "Original", day: model.today, groupID: nil))
        let task = try XCTUnwrap(model.document.tasks.first)
        let delegate = AppDelegate(model: model)
        delegate.toggleList()
        let panel = try XCTUnwrap(delegate.listPanel)
        defer { panel.orderOut(nil); panel.contentView = nil }
        let originalHost = try XCTUnwrap(panel.contentView)
        panel.setContentSize(NSSize(width: 440, height: 580))
        model.noteID = task.id
        try await waitUntil { self.find(NSTextView.self, in: originalHost) != nil }
        let editor = try XCTUnwrap(find(NSTextView.self, in: originalHost))
        XCTAssertTrue(panel.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let expected = editor.string, size = panel.frame.size
        delegate.toggleList()
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(model.noteID); XCTAssertNil(model.editingID)
        try await waitUntil { !model.isSyncEditing }
        XCTAssertTrue(panel.contentView === originalHost)
        XCTAssertEqual(panel.frame.size, size)
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document.tasks.first?.note, expected)
        delegate.toggleList()
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.contentView === originalHost)
        XCTAssertEqual(panel.frame.size, size)
    }

    @MainActor private func openManagedNote(in window: NSWindow, model: AppModel, task: TodoItem) async throws {
        let nativeHost = NSHostingView(rootView: TodoManagementView(model: model))
        window.contentView = nativeHost
        try await waitUntil { self.find(TaskNativeOutlineView.self, in: nativeHost) != nil }
        let outline = try XCTUnwrap(find(TaskNativeOutlineView.self, in: nativeHost))
        let coordinator = try XCTUnwrap(outline.dataSource as? TaskOutlineCoordinator)
        coordinator.content.onSelect(task)
        try await waitUntil { self.find(NSTextView.self, in: nativeHost) != nil }
    }

    @MainActor func testClosingSettingsDiscardsCachedManagementLeasesAndReopensFreshContent() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        _ = NSApplication.shared
        XCTAssertTrue(model.addTask(title: "Managed note", note: "Saved", day: model.today, groupID: nil))
        let task = try XCTUnwrap(model.document.tasks.first)
        let delegate = AppDelegate(model: model)
        delegate.showSettings()
        let window = try XCTUnwrap(delegate.settingsWindow)
        defer { delegate.settingsWindow?.close(); window.orderOut(nil) }
        try await openManagedNote(in: window, model: model, task: task)
        XCTAssertTrue(model.isSyncEditing)
        model.updateNote(task.id, text: "Saved before closing settings")
        window.close()
        XCTAssertNil(delegate.settingsWindow)
        XCTAssertNil(window.contentView)
        try await waitUntil { !model.isSyncEditing }
        XCTAssertEqual(try PindoRepository(directory: model.repository.directory).document.tasks.first?.note, "Saved before closing settings")
        delegate.showSettings()
        let reopened = try XCTUnwrap(delegate.settingsWindow)
        XCTAssertFalse(reopened === window)
        XCTAssertNotNil(reopened.contentView)
        XCTAssertFalse(model.isSyncEditing)
    }

    @MainActor func testDestroyingTheHostingGraphReleasesItsLeaseBeforeAReplacementDraft() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        _ = NSApplication.shared
        XCTAssertTrue(model.addTask(title: "Teardown draft", note: "Committed", day: model.today, groupID: nil))
        let task = try XCTUnwrap(model.document.tasks.first)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        weak var destroyedHost: NSHostingView<NoteView>?
        func install() {
            let nativeHost = NSHostingView(rootView: NoteView(model: model, task: task))
            destroyedHost = nativeHost; window.contentView = nativeHost
        }
        install(); window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        try await waitUntil {
            window.contentView.map { self.find(NSTextView.self, in: $0) != nil } ?? false
        }
        XCTAssertTrue(model.isSyncEditing)
        // Keep the window alive while forcing NSHostingView/GraphHost deinit.
        window.contentView = nil
        try await waitUntil { destroyedHost == nil }
        XCTAssertFalse(model.isSyncEditing)
        let replacement = try XCTUnwrap(model.acquireSyncEditing(taskID: task.id))
        await Task.yield()
        XCTAssertTrue(model.isSyncEditing, "A queued callback from the old graph must not release the new draft")
        model.releaseSyncEditing(replacement)
        XCTAssertFalse(model.isSyncEditing)
    }

    @MainActor func testStaleNativeMountCallbacksCannotReleaseOrReacquireANewerTaskResource() async throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        let firstTask = UUID(), secondTask = UUID()
        let lease = SyncEditingLease(model: model, taskID: firstTask)
        let oldMount = UUID(), replacementMount = UUID()
        lease.attach(oldMount, model: model, taskID: firstTask)
        lease.visibilityChanged(true, owner: oldMount)
        XCTAssertTrue(lease.isGranted)
        lease.attach(replacementMount, model: model, taskID: secondTask)
        XCTAssertFalse(lease.isGranted)
        XCTAssertTrue(lease.matches(model: model, taskID: secondTask))
        lease.visibilityChanged(true, owner: replacementMount)
        lease.detach(oldMount)
        lease.visibilityChanged(false, owner: oldMount)
        XCTAssertNil(model.acquireSyncEditing(taskID: secondTask))
        let availableFirstTask = try XCTUnwrap(model.acquireSyncEditing(taskID: firstTask))
        model.releaseSyncEditing(availableFirstTask)
        XCTAssertTrue(model.isSyncEditing)
        lease.detach(replacementMount)
        XCTAssertFalse(model.isSyncEditing)
        lease.visibilityChanged(true, owner: replacementMount)
        await Task.yield()
        XCTAssertFalse(model.isSyncEditing, "A detached mount cannot reactivate itself")
    }
}
