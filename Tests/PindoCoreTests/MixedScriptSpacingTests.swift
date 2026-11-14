import XCTest
@testable import PindoCore

final class MixedScriptSpacingTests: XCTestCase {
    func testSharedUnicodeBoundaryVectors() throws {
        struct Vector: Decodable { let text: String; let ranges: [[Int]] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vectors = try DocumentCodec.decode([Vector].self, from: Data(contentsOf: root.appendingPathComponent("sync-vectors/mixed-script-spacing.json")))
        for vector in vectors {
            XCTAssertEqual(MixedScriptSpacing.kerningRanges(in: vector.text), vector.ranges.map { NSRange(location: $0[0], length: $0[1]) }, vector.text)
        }
    }

    func testHiddenMarkdownDelimitersDoNotInterruptVisibleBoundaries() {
        XCTAssertEqual(MixedScriptSpacing.kerningRanges(in: "你好**abc**再见", hidden: [NSRange(location: 2, length: 2), NSRange(location: 7, length: 2)]),
                       [NSRange(location: 1, length: 1), NSRange(location: 6, length: 1)])
    }

    func testCodeKeepsItsInternalAdvancesButSeparatesFromSurroundingProse() {
        XCTAssertEqual(MixedScriptSpacing.kerningRanges(in: "前abc中文def后", verbatim: [NSRange(location: 1, length: 8)]),
                       [NSRange(location: 0, length: 1), NSRange(location: 8, length: 1)])
        XCTAssertTrue(MixedScriptSpacing.kerningRanges(in: "abc中文def", verbatim: [NSRange(location: 0, length: 8)]).isEmpty)
    }
}
