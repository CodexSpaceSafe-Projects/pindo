import AppKit
import SwiftUI
import XCTest
@testable import Pindo

final class NoteEditorTests: XCTestCase {
    @MainActor func testPastingChineseDrawsGlyphsUsingTheConfiguredFallback() throws {
        _ = NSApplication.shared
        let manager = NSFontManager.shared
        let primary = try XCTUnwrap(manager.font(withFamily: "Lucida Grande", traits: [], weight: 5, size: 18))
        let fallback = try XCTUnwrap(["Source Han Serif SC", "PingFang SC"].lazy.compactMap {
            manager.font(withFamily: $0, traits: [], weight: 5, size: 18)
        }.first)
        let choice = PindoFontChoice(primaryFamily: primary.familyName, fallbackFamily: fallback.familyName, pointSize: 18)
        var stored = ""
        let coordinator = NoteEditor(text: Binding(get: { stored }, set: { stored = $0 }), fontChoice: choice).makeCoordinator()
        let view = ComposingTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        view.isRichText = false
        view.delegate = coordinator
        coordinator.render(view)

        let text = "这是粘贴的中文，检查 IP 地址和备用 IP 地址。 "
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.setString(text, forType: .string))
        XCTAssertTrue(view.readSelection(from: pasteboard))
        XCTAssertEqual(view.string, text)
        XCTAssertEqual(stored, text)

        let storage = try XCTUnwrap(view.textStorage)
        let layout = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        let chinese = (text as NSString).range(of: "这是粘贴的中文")
        let english = (text as NSString).range(of: "IP")
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: chinese, actualCharacterRange: nil)
        XCTAssertGreaterThan(layout.boundingRect(forGlyphRange: glyphs, in: container).width, 3 * fallback.pointSize)
        let chineseFont = storage.attribute(.font, at: chinese.location, effectiveRange: nil) as? NSFont
        let englishFont = storage.attribute(.font, at: english.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(chineseFont?.familyName, fallback.familyName)
        XCTAssertEqual(englishFont?.familyName, primary.familyName)
    }

    @MainActor func testBasicMarkdownStylesTheOriginalText() throws {
        _ = NSApplication.shared
        let source = """
        # 一级标题 #

        二级标题
        ----

        - - -

        > > 引用
        - 项目
        2) 编号
        - [ ] 待做
        - [X] 完成

        普通 ***中文👩‍💻***、~~划掉~~、\\*原文*、[**网页**](https://example.com/a_(b))。
        ![图片说明](https://example.com/image.png) [其他地址](file:///tmp/example)

        ```markdown
        - [x] **code 代码原文**
        ```

        最后一行
        """
        let view = ComposingTextView()
        view.string = source
        let coordinator = NoteEditor(text: .constant(source)).makeCoordinator()
        let storage = try XCTUnwrap(view.textStorage)
        let raw = source as NSString
        view.setSelectedRange(NSRange(location: raw.length, length: 0))
        coordinator.render(view)

        func attribute(_ key: NSAttributedString.Key, at part: String, offset: Int = 0) -> Any? {
            storage.attribute(key, at: raw.range(of: part).location + offset, effectiveRange: nil)
        }

        for title in ["一级标题", "二级标题"] {
            XCTAssertGreaterThan(try XCTUnwrap(attribute(.font, at: title) as? NSFont).pointSize, 14)
        }
        XCTAssertLessThan(try XCTUnwrap(attribute(.font, at: "----") as? NSFont).pointSize, 1)
        XCTAssertEqual(attribute(.noteDecoration, at: "- - -") as? NoteDecoration, .divider)
        XCTAssertEqual(attribute(.noteDecoration, at: "> > 引用") as? NoteDecoration, .quote(2))
        XCTAssertEqual(attribute(.noteDecoration, at: "- 项目") as? NoteDecoration, .bullet)
        XCTAssertGreaterThan(try XCTUnwrap(attribute(.paragraphStyle, at: "编号") as? NSParagraphStyle).headIndent, 0)
        XCTAssertEqual(attribute(.noteDecoration, at: "- [ ] 待做") as? NoteDecoration, .checkbox(false))
        XCTAssertEqual(attribute(.noteDecoration, at: "- [X] 完成") as? NoteDecoration, .checkbox(true))

        let emphasis = try XCTUnwrap(attribute(.font, at: "中文👩‍💻") as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: emphasis).contains(.boldFontMask))
        XCTAssertGreaterThan(try XCTUnwrap(attribute(.obliqueness, at: "中文👩‍💻") as? Double), 0)
        XCTAssertEqual(attribute(.strikethroughStyle, at: "划掉") as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertLessThan(try XCTUnwrap(attribute(.font, at: "\\*原文") as? NSFont).pointSize, 1)
        XCTAssertGreaterThan(try XCTUnwrap(attribute(.font, at: "\\*原文", offset: 1) as? NSFont).pointSize, 1)
        XCTAssertEqual((attribute(.link, at: "网页") as? URL)?.absoluteString, "https://example.com/a_(b)")
        XCTAssertNil(attribute(.link, at: "图片说明"))
        XCTAssertNil(attribute(.attachment, at: "图片说明"))
        XCTAssertNil(attribute(.link, at: "其他地址"))
        XCTAssertNil(attribute(.noteDecoration, at: "- [x] **code"))
        XCTAssertTrue(try XCTUnwrap(attribute(.font, at: "code 代码原文") as? NSFont).isFixedPitch)
        XCTAssertNotNil(attribute(.backgroundColor, at: "代码原文"))

        let editing = raw.range(of: "- [ ] 待做")
        view.setSelectedRange(NSRange(location: editing.location, length: 0))
        coordinator.render(view)
        XCTAssertNil(attribute(.noteDecoration, at: "- [ ] 待做"))
        XCTAssertGreaterThan(try XCTUnwrap(attribute(.font, at: "- [ ] 待做") as? NSFont).pointSize, 1)
        XCTAssertEqual(view.string, source)
    }

    @MainActor func testDeletingUnderlineRestoresTheAdjacentParagraph() throws {
        let view = ComposingTextView()
        view.string = "单行标题\n---\n\n正文"
        let storage = try XCTUnwrap(view.textStorage)
        let coordinator = NoteEditor(text: .constant("")).makeCoordinator()
        coordinator.render(view)
        func size() throws -> CGFloat {
            try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).pointSize
        }
        XCTAssertGreaterThan(try size(), CGFloat(PindoFontPreferences.noteDefaultSize))
        storage.replaceCharacters(in: (view.string as NSString).range(of: "---"), with: "新的一行")
        coordinator.render(view)
        XCTAssertEqual(try size(), CGFloat(PindoFontPreferences.noteDefaultSize))
    }

    @MainActor func testFormattingShortcutAndMenuKeepSelectionUndoAndComposition() throws {
        _ = NSApplication.shared
        let original = "任务 👩‍💻"
        var stored = original
        let editor = NoteEditor(text: Binding(get: { stored }, set: { stored = $0 }))
        let coordinator = editor.makeCoordinator()
        let view = ComposingTextView()
        view.isRichText = false
        view.allowsUndo = true
        view.string = stored
        view.delegate = coordinator
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: .titled, backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = view
        window.contentView = scroll
        XCTAssertTrue(window.makeFirstResponder(view))
        let undo = try XCTUnwrap(view.undoManager)
        undo.removeAllActions()
        let range = NSRange(location: 0, length: (original as NSString).length)
        view.setSelectedRange(range)
        let bold = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "b",
            charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
        XCTAssertTrue(view.performKeyEquivalent(with: bold))
        XCTAssertEqual(stored, "**任务 👩‍💻**")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: range.length))
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        coordinator.publish(view)
        XCTAssertEqual(view.string, original)
        XCTAssertEqual(stored, original)

        view.setSelectedRange(range)
        let menuItem = NSMenuItem()
        menuItem.tag = NoteFormat.link.rawValue
        view.applyFormatMenuItem(menuItem)
        XCTAssertEqual(stored, "[任务 👩‍💻](https://)")
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "https://")

        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        let composing = view.string
        view.applyFormat(.italic)
        XCTAssertEqual(view.string, composing)
        XCTAssertTrue(view.hasMarkedText())
    }
}
