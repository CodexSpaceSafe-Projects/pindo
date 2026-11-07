import XCTest
@testable import PindoCore

final class NoteMarkdownTests: XCTestCase {
    func testBlocksPreserveChineseAndInlineMarkup() {
        let source = "# 中文标题\n\n普通 **加粗** 和 [链接](https://example.com)\n下一行\n\n> 引用\n- 项目\n- [ ] 待做\n- [x] 完成\n1. 顺序项\n---"
        XCTAssertEqual(NoteMarkdown.blocks(source), [
            .heading(level: 1, text: "中文标题"),
            .paragraph("普通 **加粗** 和 [链接](https://example.com)\n下一行"),
            .quote("引用"), .listItem(text: "项目", checked: nil),
            .listItem(text: "待做", checked: false), .listItem(text: "完成", checked: true),
            .listItem(text: "顺序项", checked: nil), .divider
        ])
    }
    func testCodeBlocksRemainLiteralAndUnclosedFencesKeepContent() {
        XCTAssertEqual(NoteMarkdown.blocks("```swift\n# 不是标题\n- 不是列表\n```"), [.code(language: "swift", text: "# 不是标题\n- 不是列表")])
        XCTAssertEqual(NoteMarkdown.blocks("~~~\n中文代码"), [.code(language: "", text: "中文代码")])
        XCTAssertEqual(NoteMarkdown.blocks("````markdown\r\n```swift\r\n中文\r\n```\r\n````"), [.code(language: "markdown", text: "```swift\n中文\n```")])
        XCTAssertEqual(NoteMarkdown.blocks("第一行\r\n第二行"), [.paragraph("第一行\n第二行")])
        XCTAssertEqual(NoteMarkdown.blocks(""), [])
        XCTAssertEqual(NoteMarkdown.blocks("#没有空格\n<script>原文</script>"), [.paragraph("#没有空格\n<script>原文</script>")])
    }
    func testHotkeyHoldDoesNotTogglePanelTwice() {
        var tracker = HotkeyPressTracker()
        XCTAssertTrue(tracker.update(id: 1, isDown: true))
        for _ in 0..<20 { XCTAssertFalse(tracker.update(id: 1, isDown: true)) }
        XCTAssertTrue(tracker.update(id: 2, isDown: true))
        XCTAssertFalse(tracker.update(id: 1, isDown: false))
        XCTAssertTrue(tracker.update(id: 1, isDown: true))
        tracker.reset()
        XCTAssertTrue(tracker.update(id: 1, isDown: true))
    }
}
