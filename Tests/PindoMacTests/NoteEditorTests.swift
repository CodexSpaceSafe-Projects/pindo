import AppKit
import SwiftUI
import XCTest
import MarkdownEngine
@testable import Pindo

final class NoteEditorTests: XCTestCase {
    @MainActor func testRealEngineUsesTextKit2AndStylesMarkdownWithoutChangingStoredSource() async throws {
        let source = "# Heading\n\n**Bold** and ~~old~~ and `code`\n\n- [ ] Task\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n正文"
        let editor = try await NoteEditorHarness.make(source)
        defer { editor.close() }
        let view = editor.view, storage = try XCTUnwrap(editor.view.textStorage)
        XCTAssertTrue(view.delegate is NativeTextViewCoordinator)
        XCTAssertNotNil(view.textLayoutManager)
        XCTAssertTrue(editor.window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        await editor.settle()
        func attribute(_ key: NSAttributedString.Key, _ word: String) -> Any? {
            storage.attribute(key, at: (view.string as NSString).range(of: word).location, effectiveRange: nil)
        }
        XCTAssertGreaterThan(try XCTUnwrap(attribute(.font, "Heading") as? NSFont).pointSize, 14)
        XCTAssertTrue(NSFontManager.shared.traits(of: try XCTUnwrap(attribute(.font, "Bold") as? NSFont)).contains(.boldFontMask))
        XCTAssertNotNil(attribute(.strikethroughStyle, "old"))
        XCTAssertTrue(try XCTUnwrap(attribute(.font, "code") as? NSFont).isFixedPitch)
        XCTAssertEqual(editor.buffer.text, source)
        XCTAssertEqual(view.string, source)
    }

    @MainActor func testTypingAndExternalUpdatesKeepOneNativeEditor() async throws {
        let editor = try await NoteEditorHarness.make("原备注")
        defer { editor.close() }
        let view = editor.view
        XCTAssertTrue(editor.window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText("新增abc", replacementRange: NSRange(location: NSNotFound, length: 0))
        await editor.settle()
        XCTAssertEqual(editor.buffer.text, "原备注新增abc")
        editor.buffer.text = "外部更新后的备注"
        editor.bridge.synchronize()
        await editor.settle()
        XCTAssertTrue(editor.view === view)
        XCTAssertEqual(view.string, editor.buffer.text)
        XCTAssertNotNil(view.textLayoutManager)
    }

    @MainActor func testCompositionDefersDocumentAndFontUpdatesUntilCommit() async throws {
        let editor = try await NoteEditorHarness.make("已有")
        defer { editor.close() }
        let view = editor.view
        XCTAssertTrue(editor.window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let snapshot = NSAttributedString(attributedString: try XCTUnwrap(view.textStorage))
        let selection = view.selectedRange()
        editor.bridge.parent.fontChoice = PindoFontChoice(primaryFamily: "Menlo", fallbackFamily: "PingFang SC", pointSize: 23)
        editor.bridge.synchronize()
        editor.bridge.applyTypography()
        editor.bridge.commit()
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(editor.buffer.text, "已有")
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertTrue(try XCTUnwrap(view.textStorage).isEqual(to: snapshot))
        view.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        await editor.settle()
        editor.bridge.commit()
        XCTAssertEqual(editor.buffer.text, "已有中文")
        editor.bridge.synchronize()
        await editor.settle()
        XCTAssertTrue(editor.view === view)
        XCTAssertEqual((view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 23)
    }

    @MainActor func testFormattingAndUndoPreserveWikiIDsAndStayScopedToTheirEditor() async throws {
        let original = "你好abc [[资料|opaque-id]]"
        let first = try await NoteEditorHarness.make(original)
        let second = try await NoteEditorHarness.make("另一份备注")
        defer { first.close(); second.close() }
        XCTAssertTrue(first.window.makeFirstResponder(first.view))
        first.view.setSelectedRange(NSRange(location: 0, length: 5))
        first.view.undoManager?.removeAllActions()
        first.bridge.applyFormat(.bold)
        await first.settle()
        XCTAssertEqual(first.buffer.text, "**你好abc** [[资料|opaque-id]]")
        XCTAssertEqual(second.buffer.text, "另一份备注")
        first.view.breakUndoCoalescing()
        let undo = try XCTUnwrap(first.view.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        await first.settle()
        first.bridge.commit()
        XCTAssertEqual(first.buffer.text, original)
    }

    @MainActor func testClosingCommitsPendingTextBeforeAnyQueuedBindingCallback() async throws {
        let editor = try await NoteEditorHarness.make("[[资料|opaque-id]] 原文")
        defer { editor.close() }
        XCTAssertTrue(editor.window.makeFirstResponder(editor.view))
        editor.view.setSelectedRange(NSRange(location: (editor.view.string as NSString).length, length: 0))
        editor.view.insertText(" 最后一笔", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.window.makeFirstResponder(nil)
        editor.bridge.commit()
        XCTAssertEqual(editor.buffer.text, "[[资料|opaque-id]] 原文 最后一笔")
        await editor.settle()
        XCTAssertEqual(editor.buffer.text, "[[资料|opaque-id]] 原文 最后一笔")
    }

    @MainActor func testTypographyIsIdempotentAndPreservesCodeSelectionAndPlainCopy() async throws {
        let source = "你好abc再见\n\n你好**abc**再见\n\n```\n中文abc代码\n```\n\n结尾"
        let editor = try await NoteEditorHarness.make(source)
        defer { editor.close() }
        let view = editor.view, storage = try XCTUnwrap(editor.view.textStorage)
        view.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        await editor.settle()
        editor.bridge.applyTypography()
        let before = NSAttributedString(attributedString: storage)
        editor.bridge.applyTypography()
        XCTAssertTrue(storage.isEqual(to: before))
        XCTAssertGreaterThan((storage.attribute(.kern, at: 1, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0, 0)
        let emphasized = (source as NSString).range(of: "好**abc").location
        XCTAssertGreaterThan((storage.attribute(.kern, at: emphasized, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0, 0)
        let code = (source as NSString).range(of: "中文abc代码")
        storage.enumerateAttribute(.kern, in: code) { value, _, _ in
            XCTAssertEqual((value as? NSNumber)?.doubleValue ?? 0, 0)
        }
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(editor.buffer.text, source)
        view.setSelectedRange(NSRange(location: 0, length: 7))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), "你好abc再见")
        XCTAssertNotNil(view.textLayoutManager)
    }

    @MainActor func testConfiguredFallbackRendersChineseBesideThePrimaryLatinFont() async throws {
        let choice = PindoFontChoice(primaryFamily: "Lucida Grande", fallbackFamily: "PingFang SC", pointSize: 18)
        let editor = try await NoteEditorHarness.make("中文abc正文", font: choice)
        defer { editor.close() }
        editor.bridge.applyTypography()
        let storage = try XCTUnwrap(editor.view.textStorage)
        let chinese = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let latin = try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(chinese.familyName, "PingFang SC")
        XCTAssertEqual(latin.familyName, "Lucida Grande")
        XCTAssertEqual(editor.buffer.text, "中文abc正文")
    }
}
