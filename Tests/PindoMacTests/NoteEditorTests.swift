import AppKit
import SwiftUI
import XCTest
import MarkdownEngine
@testable import Pindo

final class NoteEditorTests: XCTestCase {
    @MainActor func testRepeatedChineseCompositionKeepsCommittedTextInAWrappedListStable() async throws {
        // Mirrors the recording: composition in the middle of a wrapped list
        // item must not remove spacing from the already committed prefix.
        let source = "1. 前项OpenWRT文字\n2. 本项abc正文；这里是输入位置，后文def文字" + String(repeating: "长句中文与text混排", count: 5)
        let editor = try await NoteEditorHarness.make(source)
        defer { editor.close() }
        let view = editor.view, storage = try XCTUnwrap(editor.view.textStorage)
        XCTAssertTrue(editor.window.makeFirstResponder(view))
        let firstAnchor = (source as NSString).range(of: "项abc").location
        let secondAnchor = (source as NSString).range(of: "c正文").location
        let anchors = [firstAnchor, secondAnchor]
        let baseline = anchors.map { (storage.attribute(.kern, at: $0, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0 }
        XCTAssertTrue(baseline.allSatisfy { $0 > 0 })
        let position = (source as NSString).range(of: "输入位置").location
        view.setSelectedRange(NSRange(location: position, length: 0))
        let referenceRect = view.firstRect(forCharacterRange: NSRange(location: secondAnchor + 1, length: 1), actualRange: nil)
        XCTAssertGreaterThan(referenceRect.width, 0)
        var unspacedCompositionPasses = 0
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: .main) { _ in
            MainActor.assumeIsolated {
                if view.hasMarkedText(), anchors.map({ (storage.attribute(.kern, at: $0, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0 }) != baseline {
                    unspacedCompositionPasses += 1
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var inserted = ""
        for _ in 0..<3 {
            let insertion = position + (inserted as NSString).length
            view.setSelectedRange(NSRange(location: insertion, length: 0))
            for pinyin in ["w", "wo", "wo'm", "wo'men"] {
                view.setMarkedText(pinyin, selectedRange: NSRange(location: (pinyin as NSString).length, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
                XCTAssertTrue(view.hasMarkedText())
                let marked = view.markedRange()
                XCTAssertEqual(marked, NSRange(location: insertion, length: (pinyin as NSString).length))
                XCTAssertEqual(view.selectedRange(), NSRange(location: NSMaxRange(marked), length: 0))
                XCTAssertEqual((view.string as NSString).substring(with: marked), pinyin)
                XCTAssertEqual((storage.attribute(.kern, at: insertion - 1, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0, 0,
                               "Uncommitted pinyin must not add a gap at the input-method insertion point")
                XCTAssertEqual(anchors.map { (storage.attribute(.kern, at: $0, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0 }, baseline)
                let rect = view.firstRect(forCharacterRange: NSRange(location: secondAnchor + 1, length: 1), actualRange: nil)
                XCTAssertEqual(rect.minX, referenceRect.minX, accuracy: 0.1)
                XCTAssertEqual(rect.minY, referenceRect.minY, accuracy: 0.1)
                let markedAttributes = storage.attributedSubstring(from: marked)
                editor.bridge.applyTypography(in: NSRange(location: 0, length: storage.length))
                XCTAssertTrue(storage.attributedSubstring(from: marked).isEqual(to: markedAttributes))
                editor.bridge.synchronize()
                await editor.settle()
                XCTAssertEqual(editor.buffer.text, (source as NSString).replacingCharacters(in: NSRange(location: position, length: 0), with: inserted))
                XCTAssertEqual(view.markedRange(), marked)
            }
            view.insertText("我们", replacementRange: NSRange(location: NSNotFound, length: 0))
            view.unmarkText()
            inserted += "我们"
            await editor.settle()
            XCTAssertEqual(view.selectedRange(), NSRange(location: position + (inserted as NSString).length, length: 0))
            XCTAssertEqual(editor.buffer.text, (source as NSString).replacingCharacters(in: NSRange(location: position, length: 0), with: inserted))
        }
        view.insertText("312321", replacementRange: NSRange(location: NSNotFound, length: 0))
        inserted += "312321"
        await editor.settle()
        XCTAssertEqual(view.string, (source as NSString).replacingCharacters(in: NSRange(location: position, length: 0), with: inserted))
        XCTAssertEqual(editor.buffer.text, view.string)
        XCTAssertEqual(unspacedCompositionPasses, 0)
        XCTAssertNotNil(view.textLayoutManager)
    }

    @MainActor func testCompositionPreservesFallbackFontsAndWikiIDsWithoutPublishingPreedit() async throws {
        let source = "1. 中文abc前缀这里输入点 [[资料|opaque-id]] 后文def结尾"
        let fallback = NSFontManager.shared.availableFontFamilies.contains("Songti SC") ? "Songti SC" : "PingFang SC"
        let font = PindoFontChoice(primaryFamily: "Menlo", fallbackFamily: fallback, pointSize: 18)
        let editor = try await NoteEditorHarness.make(source, font: font)
        defer { editor.close() }
        let view = editor.view, storage = try XCTUnwrap(editor.view.textStorage)
        XCTAssertTrue(editor.window.makeFirstResponder(view))
        let anchor = (view.string as NSString).range(of: "前缀").location
        let baselineFont = try XCTUnwrap(storage.attribute(.font, at: anchor, effectiveRange: nil) as? NSFont)
        let insertion = (view.string as NSString).range(of: "输入点").location
        let beforeCaretFont = try XCTUnwrap(storage.attribute(.font, at: insertion - 1, effectiveRange: nil) as? NSFont)
        let afterCaretFont = try XCTUnwrap(storage.attribute(.font, at: insertion, effectiveRange: nil) as? NSFont)
        XCTAssertNotEqual(baselineFont.fontName, try XCTUnwrap(NSFont(name: "Menlo", size: 18)).fontName)
        view.setSelectedRange(NSRange(location: insertion, length: 0))
        for pinyin in ["z", "zh", "zhong", "zhong'wen"] {
            view.setMarkedText(pinyin, selectedRange: NSRange(location: (pinyin as NSString).length, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(view.hasMarkedText())
            XCTAssertEqual(storage.attribute(.font, at: anchor, effectiveRange: nil) as? NSFont, baselineFont)
            XCTAssertEqual(storage.attribute(.font, at: insertion - 1, effectiveRange: nil) as? NSFont, beforeCaretFont)
            let suffix = (view.string as NSString).range(of: "输入点").location
            XCTAssertEqual(storage.attribute(.font, at: suffix, effectiveRange: nil) as? NSFont, afterCaretFont)
            await editor.settle()
            XCTAssertEqual(editor.buffer.text, source)
        }
        view.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        // Check before the asynchronous binding/save cycle can hide a font
        // flash on newly committed Chinese characters beside the caret.
        XCTAssertEqual(storage.attribute(.font, at: insertion, effectiveRange: nil) as? NSFont, baselineFont)
        await editor.settle()
        editor.bridge.commit()
        XCTAssertEqual(editor.buffer.text, (source as NSString).replacingCharacters(in: NSRange(location: insertion, length: 0), with: "中文"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: insertion + 2, length: 0))
        view.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual((storage.attribute(.font, at: insertion + 2, effectiveRange: nil) as? NSFont)?.fontName,
                       try XCTUnwrap(NSFont(name: "Menlo", size: 18)).fontName)
        view.setMarkedText("w", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(storage.attribute(.font, at: insertion + 1, effectiveRange: nil) as? NSFont, baselineFont)
        view.insertText("我", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        XCTAssertEqual(storage.attribute(.font, at: insertion + 3, effectiveRange: nil) as? NSFont, baselineFont)
        await editor.settle()
        editor.bridge.commit()
        XCTAssertEqual(editor.buffer.text, (source as NSString).replacingCharacters(in: NSRange(location: insertion, length: 0), with: "中文a我"))
        XCTAssertEqual(view.selectedRange(), NSRange(location: insertion + 4, length: 0))
    }

    @MainActor func testChineseCompositionAddsBoundarySpacingAfterCommitWithoutChangingTheSource() async throws {
        let editor = try await NoteEditorHarness.make("中文abc")
        defer { editor.close() }
        let view = editor.view
        XCTAssertTrue(editor.window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: 5, length: 0))
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let composing = NSAttributedString(attributedString: try XCTUnwrap(view.textStorage))
        editor.bridge.applyTypography()
        XCTAssertTrue(try XCTUnwrap(view.textStorage).isEqual(to: composing))
        XCTAssertEqual(editor.buffer.text, "中文abc")
        view.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        await editor.settle()
        XCTAssertEqual(editor.buffer.text, "中文abc中")
        XCTAssertGreaterThan((view.textStorage?.attribute(.kern, at: 4, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0, 0)
    }

    @MainActor func testSpacingIsStableBeforeLayoutWhileTypingOrMovingTheCaret() async throws {
        // Mirrors the recording: editing a numeric line must not make the
        // preceding OpenWRT line alternate between spaced and unspaced widths.
        let source = "第一段保持不变：\n示例中的OpenWRT文字\n中文前缀也是OpenWRT正文\n321123321123"
        let editor = try await NoteEditorHarness.make(source)
        defer { editor.close() }
        let view = editor.view, storage = try XCTUnwrap(editor.view.textStorage)
        XCTAssertTrue(editor.window.makeFirstResponder(view))
        let beforeLatin = (source as NSString).range(of: "是OpenWRT").location
        let afterLatin = (source as NSString).range(of: "T正文").location
        let anchors = [beforeLatin, afterLatin]
        let baseline = anchors.map { (storage.attribute(.kern, at: $0, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0 }
        XCTAssertTrue(baseline.allSatisfy { $0 > 0 })
        view.textLayoutManager?.ensureLayout(for: try XCTUnwrap(view.textLayoutManager).documentRange)
        let bounds = view.firstRect(forCharacterRange: NSRange(location: afterLatin + 1, length: 1), actualRange: nil)
        XCTAssertGreaterThan(bounds.width, 0)
        var unspacedPasses = 0
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: .main) { _ in
            MainActor.assumeIsolated {
                let current = anchors.map { (storage.attribute(.kern, at: $0, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0 }
                if current != baseline { unspacedPasses += 1 }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for digit in ["3", "2", "1", "1", "2", "3"] {
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            view.insertText(digit, replacementRange: NSRange(location: NSNotFound, length: 0))
            // Assert immediately, before an async correction could hide a flash.
            XCTAssertEqual(anchors.map { (storage.attribute(.kern, at: $0, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0 }, baseline)
            let rect = view.firstRect(forCharacterRange: NSRange(location: afterLatin + 1, length: 1), actualRange: nil)
            XCTAssertEqual(rect.minX, bounds.minX, accuracy: 0.1)
            view.setSelectedRange(NSRange(location: (view.string as NSString).length - 2, length: 0))
            await editor.settle()
        }
        XCTAssertEqual(unspacedPasses, 0)
        XCTAssertEqual(editor.buffer.text, source + "321123")
        XCTAssertNotNil(view.textLayoutManager)
    }

    @MainActor func testRemovingAScriptBoundaryImmediatelyClearsOnlyItsSpacingAndKeepsUndo() async throws {
        let source = "你好abc再见"
        let editor = try await NoteEditorHarness.make(source)
        defer { editor.close() }
        let view = editor.view, storage = try XCTUnwrap(editor.view.textStorage)
        XCTAssertTrue(editor.window.makeFirstResponder(view))
        let undo = try XCTUnwrap(view.undoManager)
        undo.removeAllActions()
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual((storage.attribute(.kern, at: 1, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0, 0)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 3, length: 0))
        await editor.settle()
        XCTAssertEqual(editor.buffer.text, "你好 abc再见")
        view.breakUndoCoalescing()
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(view.string, source)
        XCTAssertGreaterThan((storage.attribute(.kern, at: 1, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0, 0)
        await editor.settle()
        XCTAssertEqual(editor.buffer.text, source)
    }

    @MainActor func testRealEngineUsesTextKit2AndStylesMarkdownWithoutChangingStoredSource() async throws {
        let source = "# Heading\n\n**Bold** and ~~gone~~ and `code`\n\n- [ ] Task\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n正文"
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
        XCTAssertNotNil(attribute(.strikethroughStyle, "gone"))
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
        XCTAssertTrue(editor.window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: 0, length: 7))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 7))
        // MarkdownEngine overrides copy(_:), keeping raw Markdown as the plain
        // flavor alongside its rich formats. Exercise that real user command.
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { original in
            let item = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { item.setData(data, forType: type) }
            }
            return item
        }
        defer { pasteboard.clearContents(); pasteboard.writeObjects(saved) }
        view.copy(nil)
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
