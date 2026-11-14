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

}
