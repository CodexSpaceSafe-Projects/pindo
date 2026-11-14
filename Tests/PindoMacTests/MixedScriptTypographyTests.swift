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
            XCTAssertEqual((display.attribute(.kern, at: index, effectiveRange: nil) as? NSNumber)?.doubleValue, 2.5)
            XCTAssertEqual((display.attribute(.strikethroughStyle, at: index, effectiveRange: nil) as? NSNumber)?.intValue, NSUnderlineStyle.single.rawValue)
        }
        for index in [0, 2, 3, 5, 6] { XCTAssertNil(display.attribute(.kern, at: index, effectiveRange: nil)) }
        XCTAssertGreaterThan(display.size().width, NSAttributedString(string: source, attributes: attributes).size().width)
    }

    @MainActor func testReapplyingSpacingDoesNotPublishAnyStorageEdit() throws {
        let storage = NSTextStorage(string: "你好abc再见", attributes: [.font: NSFont.systemFont(ofSize: 20)])
        let whole = NSRange(location: 0, length: storage.length)
        XCTAssertTrue(MixedScriptTypography.apply(to: storage, range: whole))
        var edits = 0
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: .main) { _ in
            MainActor.assumeIsolated { edits += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        storage.beginEditing()
        XCTAssertFalse(MixedScriptTypography.apply(to: storage, range: whole))
        storage.endEditing()
        XCTAssertEqual(edits, 0)
    }

    @MainActor func testSpacingRetainsEngineKernsAndRestoresTheBaseAfterABoundaryIsRemoved() throws {
        let text = NSMutableAttributedString(string: "#你好abc再见", attributes: [.font: NSFont.systemFont(ofSize: 20)])
        text.addAttributes([.font: NSFont.systemFont(ofSize: 0.1), .kern: -0.1], range: NSRange(location: 0, length: 1))
        text.addAttribute(.kern, value: 1.0, range: NSRange(location: 2, length: 1))
        let whole = NSRange(location: 0, length: text.length)
        MixedScriptTypography.apply(to: text, range: whole)
        XCTAssertEqual((text.attribute(.kern, at: 0, effectiveRange: nil) as? NSNumber)?.doubleValue, -0.1)
        XCTAssertEqual((text.attribute(.kern, at: 2, effectiveRange: nil) as? NSNumber)?.doubleValue, 3.5)
        XCTAssertFalse(MixedScriptTypography.apply(to: text, range: whole))
        text.insert(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 20)]), at: 3)
        MixedScriptTypography.apply(to: text, range: NSRange(location: 0, length: text.length))
        XCTAssertEqual((text.attribute(.kern, at: 2, effectiveRange: nil) as? NSNumber)?.doubleValue, 1.0)
        XCTAssertEqual((text.attribute(.kern, at: 0, effectiveRange: nil) as? NSNumber)?.doubleValue, -0.1)
    }

}
