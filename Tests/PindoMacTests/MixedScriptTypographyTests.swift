import AppKit
import SwiftUI
import XCTest
import PindoCore
@testable import Pindo

final class MixedScriptTypographyTests: XCTestCase {
    @MainActor func testTitleSpacingAddsAdvanceAndPreservesRawTextAndCompletionStyle() throws {
        _ = NSApplication.shared
        let source = "你好abc再见"
        let font = NSFont.systemFont(ofSize: 20)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .strikethroughStyle: NSUnderlineStyle.single.rawValue]
        let display = MixedScriptTypography.attributed(source, attributes: attributes)
        XCTAssertEqual(display.string, source)
        for index in [1, 4] {
            XCTAssertEqual((display.attribute(.kern, at: index, effectiveRange: nil) as? NSNumber)?.doubleValue, 5)
            XCTAssertEqual((display.attribute(.strikethroughStyle, at: index, effectiveRange: nil) as? NSNumber)?.intValue, NSUnderlineStyle.single.rawValue)
        }
        for index in [0, 2, 3, 5, 6] { XCTAssertNil(display.attribute(.kern, at: index, effectiveRange: nil)) }
        XCTAssertGreaterThan(display.size().width, NSAttributedString(string: source, attributes: attributes).size().width)
    }

    @MainActor func testMarkdownSpacingUsesVisibleBoundariesAndEachRunFontSize() throws {
        _ = NSApplication.shared
        let source = "# 你好abc再见\n\n你好**abc**再见\n\n```\n中文abc代码\n```\n"
        let view = ComposingTextView()
        view.string = source
        let selection = NSRange(location: (source as NSString).length, length: 0)
        view.setSelectedRange(selection)
        LiveMarkdown.apply(to: view, editingParagraph: NSRange(location: (source as NSString).length, length: 0), fontChoice: PindoFontChoice())
        let storage = try XCTUnwrap(view.textStorage)
        for word in ["好abc", "好**abc", "c**再"] {
            let index = (source as NSString).range(of: word).location
            let font = try XCTUnwrap(storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
            XCTAssertEqual((storage.attribute(.kern, at: index, effectiveRange: nil) as? NSNumber)?.doubleValue, Double(font.pointSize) * 0.25)
        }
        let code = (source as NSString).range(of: "中文abc代码")
        storage.enumerateAttribute(.kern, in: code) { value, _, _ in XCTAssertNil(value) }
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selection)
    }

    @MainActor func testEditingABoundaryRemovesOldSpacingWithoutChangingTheSelectionOrUndo() throws {
        _ = NSApplication.shared
        var stored = "你好abc再见"
        let coordinator = NoteEditor(text: Binding(get: { stored }, set: { stored = $0 })).makeCoordinator()
        let view = ComposingTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        view.isRichText = false; view.allowsUndo = true
        view.string = stored; view.delegate = coordinator
        let window = NSWindow(contentRect: view.bounds, styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view))
        coordinator.render(view)
        let undo = try XCTUnwrap(view.undoManager)
        undo.removeAllActions()
        view.insertText(" ", replacementRange: NSRange(location: 2, length: 0))
        coordinator.publish(view)
        XCTAssertEqual(stored, "你好 abc再见")
        XCTAssertNil(view.textStorage?.attribute(.kern, at: 1, effectiveRange: nil))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 0))
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        coordinator.publish(view)
        XCTAssertEqual(stored, "你好abc再见")
        XCTAssertNotNil(view.textStorage?.attribute(.kern, at: 1, effectiveRange: nil))
    }

    @MainActor func testCompositionLeavesTextAndAttributesUntouched() throws {
        _ = NSApplication.shared
        let view = ComposingTextView()
        view.string = "你好abc"
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let before = NSAttributedString(attributedString: try XCTUnwrap(view.textStorage))
        let selection = view.selectedRange()
        MixedScriptTypography.styleEditor(view)
        LiveMarkdown.apply(to: view, editingParagraph: NSRange(location: 0, length: (view.string as NSString).length), fontChoice: PindoFontChoice())
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertTrue(try XCTUnwrap(view.textStorage).isEqual(to: before))
    }
}
