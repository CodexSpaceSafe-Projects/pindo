import AppKit
import SwiftUI
import XCTest
@testable import Pindo

final class TaskTitleEditorTests: XCTestCase {
    @MainActor func testTitleSpacingKeepsTheRawDraftAndSelectionAndCanClearANewTaskDraft() throws {
        _ = NSApplication.shared
        var stored = "你好abc再见"
        let coordinator = TaskTitleEditor(text: Binding(get: { stored }, set: { stored = $0 }), allowsEmpty: true, onSubmit: {}).makeCoordinator()
        let field = EditingTitleField()
        let editor = NSTextView()
        editor.font = .systemFont(ofSize: 20)
        editor.string = stored
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        field.stringValue = stored; field.editor = editor
        coordinator.synchronize(field)
        XCTAssertEqual(stored, "你好abc再见")
        XCTAssertEqual(editor.string, stored)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertEqual((editor.textStorage?.attribute(.kern, at: 1, effectiveRange: nil) as? NSNumber)?.doubleValue, 5)
        editor.string = ""; field.stringValue = ""
        coordinator.publish(field)
        XCTAssertEqual(stored, "")
    }

    @MainActor func testTitleCompositionAndEmptyDraftPreserveTheLastCommittedTitle() throws {
        _ = NSApplication.shared
        var stored = "原事项"
        let coordinator = TaskTitleEditor(text: Binding(get: { stored }, set: { stored = $0 }), onSubmit: {}).makeCoordinator()
        let field = EditingTitleField()
        let editor = NSTextView()
        field.editor = editor
        editor.string = stored
        editor.setSelectedRange(NSRange(location: (stored as NSString).length, length: 0))
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        field.stringValue = editor.string
        let composing = field.stringValue, selection = editor.selectedRange()
        coordinator.publish(field)
        coordinator.synchronize(field)
        XCTAssertEqual(stored, "原事项")
        XCTAssertEqual(field.stringValue, composing)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertTrue(editor.hasMarkedText())

        editor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.unmarkText()
        field.stringValue = editor.string
        coordinator.publish(field)
        XCTAssertEqual(stored, "原事项中文")

        // While editing, NSTextField reads its value from the shared field editor.
        editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        XCTAssertEqual(editor.string, "")
        field.stringValue = editor.string
        coordinator.publish(field)
        coordinator.synchronize(field)
        XCTAssertEqual(field.stringValue, "")
        XCTAssertEqual(stored, "原事项中文")
        field.editor = nil
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertEqual(field.stringValue, stored)
    }
}

private final class EditingTitleField: NSTextField {
    var editor: NSTextView?
    override func currentEditor() -> NSText? { editor }
}
