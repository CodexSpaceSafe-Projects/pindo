import AppKit
import CoreText
import SwiftUI
import XCTest
@testable import Pindo

final class FontPreferencesTests: XCTestCase {
    @MainActor func testFallbackFontIsUsedOnlyForMissingGlyphs() throws {
        let choice = PindoFontChoice(primaryFamily: "Menlo", fallbackFamily: "Hiragino Sans", pointSize: 18)
        let font = choice.font(defaultSize: 16)
        let text = NSAttributedString(string: "A中文🙂", attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(text)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        func family(at index: Int) -> String? {
            let run = runs.first { run in
                let range = CTRunGetStringRange(run)
                return range.location <= index && index < range.location + range.length
            }
            guard let run else { return nil }
            return ((CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as? NSFont)?.familyName
        }
        XCTAssertEqual(font.pointSize, 18)
        XCTAssertEqual(family(at: 0), "Menlo")
        XCTAssertEqual(family(at: 1), "Hiragino Sans")
        XCTAssertEqual(family(at: 3), "Apple Color Emoji")
    }

    @MainActor func testFontPreferencesPersistIndependentlyFromTaskData() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "PindoFontPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let model = try AppModel(directory: folder, defaults: defaults)
        model.playFeedback = { _ in }
        XCTAssertTrue(model.addTask(title: "本地事项", note: "备注", day: model.selectedDay, groupID: nil))
        let taskData = try Data(contentsOf: model.repository.dataURL)
        XCTAssertEqual(model.fontPreferences, PindoFontPreferences())

        var preferences = model.fontPreferences
        preferences.task = PindoFontChoice(primaryFamily: "Menlo", fallbackFamily: "PingFang SC", pointSize: 22)
        preferences.note = PindoFontChoice(primaryFamily: "Helvetica", fallbackFamily: "Songti SC", pointSize: 19)
        model.setFontPreferences(preferences)
        let reopened = try AppModel(directory: folder, defaults: defaults)
        XCTAssertEqual(reopened.fontPreferences, preferences)
        preferences.task = PindoFontChoice()
        reopened.setFontPreferences(preferences)
        XCTAssertEqual(try AppModel(directory: folder, defaults: defaults).fontPreferences, preferences)
        XCTAssertEqual(try Data(contentsOf: reopened.repository.dataURL), taskData)
    }

}
