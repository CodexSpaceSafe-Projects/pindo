import AppKit
import CoreText
import XCTest
@testable import Pindo

/// Squirrel's show(preedit:selRange:caretPos:) sends attributed preedit,
/// including converted Chinese followed by an unconverted Latin segment.
final class SquirrelFontTests: XCTestCase {
    @MainActor private func choice() throws -> PindoFontChoice {
        if NSFont(name: "SourceHanSerifSC-Regular", size: 18) == nil {
            guard let path = ProcessInfo.processInfo.environment["PINDO_TEST_CJK_FONT_PATH"] else {
                throw XCTSkip("Install Source Han Serif SC or set PINDO_TEST_CJK_FONT_PATH; macOS CI supplies the pinned font")
            }
            var error: Unmanaged<CFError>?
            guard CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: path) as CFURL, .process, &error) else {
                throw NSError(domain: "PindoTests.FontFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot register Source Han Serif SC: \(String(describing: error?.takeRetainedValue()))"])
            }
        }
        XCTAssertNotNil(NSFont(name: "SourceHanSerifSC-Regular", size: 18))
        XCTAssertNotNil(NSFont(name: "LucidaGrande", size: 18))
        return PindoFontChoice(primaryFamily: "Lucida Grande", fallbackFamily: "Source Han Serif SC", pointSize: 18)
    }

    private func preedit(_ string: String, converted: Int) -> NSAttributedString {
        let value = NSMutableAttributedString(string: string, attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue, .markedClauseSegment: 0
        ])
        if converted < value.length {
            value.addAttributes([.underlineStyle: NSUnderlineStyle.double.rawValue, .markedClauseSegment: 1],
                                range: NSRange(location: converted, length: value.length - converted))
        }
        return value
    }

    @MainActor private func capture(_ editor: NoteEditorHarness, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["PINDO_TEST_SCREENSHOT_DIRECTORY"] else { return }
        editor.window.orderFrontRegardless()
        editor.host.layoutSubtreeIfNeeded()
        if let layout = editor.view.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
        let bitmap = try XCTUnwrap(editor.host.bitmapImageRepForCachingDisplay(in: editor.host.bounds))
        editor.host.cacheDisplay(in: editor.host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent(name + ".png"))
    }

    @MainActor private func assertFont(_ storage: NSTextStorage, at index: Int, family: String,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let font = try XCTUnwrap(storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont, file: file, line: line)
        XCTAssertEqual(font.familyName, family, file: file, line: line)
        XCTAssertEqual(font.pointSize, 18, file: file, line: line)
        // Inspect the rendered glyph font too: a Lucida font attribute over Han
        // can silently draw PingFang despite the preferred Source Han fallback.
        let fragment = storage.attributedSubstring(from: NSRange(location: index, length: 1))
        let runs = CTLineGetGlyphRuns(CTLineCreateWithAttributedString(fragment)) as! [CTRun]
        let rendered = runs.first.flatMap { (CTRunGetAttributes($0) as NSDictionary)[kCTFontAttributeName] as? NSFont }
        XCTAssertEqual(rendered?.familyName, family, file: file, line: line)
    }

    @MainActor func testAttributedConvertedChineseKeepsLucidaAndSourceHanFontsDuringComposition() async throws {
        let source = "1. 固定abc段落\n2. 前文def中文这里输入点后文ghi文字\n3. 不变的末项"
        let editor = try await NoteEditorHarness.make(source, font: choice())
        defer { editor.close() }
        let view = editor.view, storage = try XCTUnwrap(editor.view.textStorage)
        XCTAssertTrue(editor.window.makeFirstResponder(view))
        let insertion = (source as NSString).range(of: "输入点").location
        let prefix = (source as NSString).range(of: "前文").location
        try assertFont(storage, at: prefix, family: "Source Han Serif SC")
        try capture(editor, name: "01-lucida-source-han-before-composition")
        view.setSelectedRange(NSRange(location: insertion, length: 0))
        for (preview, converted, caret) in [("ni", 0, 2), ("你好shi", 2, 3), ("你好世界", 4, 2), ("你好世界hao", 4, 7)] {
            view.setMarkedText(preedit(preview, converted: converted),
                               selectedRange: NSRange(location: caret, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(view.hasMarkedText())
            XCTAssertEqual(view.markedRange(), NSRange(location: insertion, length: (preview as NSString).length))
            XCTAssertEqual(view.selectedRange(), NSRange(location: insertion + caret, length: 0))
            try assertFont(storage, at: prefix, family: "Source Han Serif SC")
            try assertFont(storage, at: insertion - 1, family: "Source Han Serif SC")
            if converted > 0 { try assertFont(storage, at: insertion, family: "Source Han Serif SC") }
            if converted < (preview as NSString).length { try assertFont(storage, at: insertion + converted, family: "Lucida Grande") }
            if preview == "你好世界hao" { try capture(editor, name: "02-squirrel-attributed-chinese-and-pinyin") }
            await editor.settle()
            XCTAssertEqual(editor.buffer.text, source)
        }
        view.insertText("你好世界好", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        try assertFont(storage, at: insertion, family: "Source Han Serif SC")
        await editor.settle()
        XCTAssertEqual(editor.buffer.text, (source as NSString).replacingCharacters(in: NSRange(location: insertion, length: 0), with: "你好世界好"))
        try capture(editor, name: "03-after-commit")
    }

    @MainActor func testSystemFontSubstitutionRecoversWithoutChangingIMEClausesOrSelection() async throws {
        let source = "前文abc中文；输入点后文def"
        let editor = try await NoteEditorHarness.make(source, font: choice())
        defer { editor.close() }
        let view = editor.view, storage = try XCTUnwrap(editor.view.textStorage)
        XCTAssertTrue(editor.window.makeFirstResponder(view))
        let insertion = (source as NSString).range(of: "输入点").location
        view.setSelectedRange(NSRange(location: insertion, length: 0))
        view.setMarkedText(preedit("你好ni", converted: 2), selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = view.markedRange(), selection = view.selectedRange(), text = view.string
        let systemChinese = try XCTUnwrap(NSFont(name: "PingFangSC-Regular", size: 18))
        // Exercise the attributed-input font-fixing path, rather than relying
        // on a plain String which inherits the engine's already-correct font.
        storage.beginEditing()
        storage.addAttribute(.font, value: systemChinese, range: NSRange(location: 0, length: storage.length))
        storage.addAttributes([.underlineStyle: NSUnderlineStyle.double.rawValue, .markedClauseSegment: 7,
                               .underlineColor: NSColor.red, .backgroundColor: NSColor.selectedTextBackgroundColor], range: marked)
        storage.endEditing()
        try assertFont(storage, at: 0, family: "Source Han Serif SC")
        try assertFont(storage, at: 2, family: "Lucida Grande")
        try assertFont(storage, at: insertion, family: "Source Han Serif SC")
        try assertFont(storage, at: insertion + 2, family: "Lucida Grande")
        XCTAssertEqual(storage.attribute(.underlineStyle, at: insertion, effectiveRange: nil) as? Int, NSUnderlineStyle.double.rawValue)
        XCTAssertEqual(storage.attribute(.markedClauseSegment, at: insertion, effectiveRange: nil) as? Int, 7)
        XCTAssertEqual(storage.attribute(.underlineColor, at: insertion, effectiveRange: nil) as? NSColor, .red)
        XCTAssertEqual(storage.attribute(.backgroundColor, at: insertion, effectiveRange: nil) as? NSColor, .selectedTextBackgroundColor)
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), marked)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertEqual(view.string, text)
        XCTAssertEqual(editor.buffer.text, source)
        try capture(editor, name: "04-font-recovery-preserves-ime-clauses")
    }

    @MainActor func testConfiguredFontRepairPreservesHeadingEmphasisAndCodeFonts() async throws {
        let source = "# Heading中文\n\n**Bold中文** and `code中文`\n\n```\nblock中文\n```\n\n结尾🙂"
        let editor = try await NoteEditorHarness.make(source, font: choice())
        defer { editor.close() }
        let view = editor.view, storage = try XCTUnwrap(editor.view.textStorage)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        await editor.settle()
        func font(_ word: String) throws -> NSFont {
            try XCTUnwrap(storage.attribute(.font, at: (view.string as NSString).range(of: word).location, effectiveRange: nil) as? NSFont)
        }
        XCTAssertGreaterThan(try font("Heading").pointSize, 18)
        XCTAssertTrue(NSFontManager.shared.traits(of: try font("Heading")).contains(.boldFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of: try font("Bold")).contains(.boldFontMask))
        XCTAssertTrue(try font("code").isFixedPitch)
        XCTAssertTrue(try font("block").isFixedPitch)
        XCTAssertEqual(try font("🙂").familyName, "Apple Color Emoji")
        let before = NSAttributedString(attributedString: storage), selection = view.selectedRange()
        editor.bridge.applyTypography()
        editor.bridge.applyTypography()
        XCTAssertTrue(storage.isEqual(to: before))
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertEqual(editor.buffer.text, source)
    }
}
