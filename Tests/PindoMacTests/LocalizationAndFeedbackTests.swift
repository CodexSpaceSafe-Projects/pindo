import AppKit
import XCTest
import PindoCore
@testable import Pindo

final class LocalizationAndFeedbackTests: XCTestCase {
    func testSystemLanguageAndExplicitOverride() {
        XCTAssertEqual(PindoLocalization(.automatic, preferredLanguages: ["zh-Hant-HK"])("设置"), "设置")
        XCTAssertEqual(PindoLocalization(.automatic, preferredLanguages: ["ja-JP"])("设置"), "Settings")
        XCTAssertEqual(PindoLocalization(.english, preferredLanguages: ["zh-Hans-CN"])("设置"), "Settings")
        XCTAssertEqual(PindoLocalization(.simplifiedChinese, preferredLanguages: ["en-US"])("设置"), "设置")
        let english = PindoLocalization(.english)
        XCTAssertEqual(english("%@，未完成 %ld，已完成 %ld", "2026-11-07", 2, 1), "2026-11-07: 2 unfinished, 1 completed")
        XCTAssertEqual(english.error(PindoError.invalidData("默认分组不存在")), "Invalid data: The default group doesn't exist.")
    }

    @MainActor func testLanguagePersistsAndDoesNotRenameExistingGroups() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "PindoLanguageTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(InterfaceLanguage.english.rawValue, forKey: InterfaceLanguage.defaultsKey)
        let model = try AppModel(directory: directory, defaults: defaults)
        XCTAssertEqual(model.document.groups.map(\.name), ["Work", "Personal"])
        model.setInterfaceLanguage(.simplifiedChinese)
        XCTAssertEqual(model.localization("新待办默认分组"), "新待办默认分组")
        let reopened = try AppModel(directory: directory, defaults: defaults)
        XCTAssertEqual(reopened.interfaceLanguage, .simplifiedChinese)
        XCTAssertEqual(reopened.document.groups.map(\.name), ["Work", "Personal"])
    }

    @MainActor func testConsecutiveFeedbackUsesIndependentSoundInstances() async throws {
        for feedback in [TaskFeedback.added, .completed] {
            let first = try XCTUnwrap(feedback.makeSound())
            let next = try XCTUnwrap(feedback.makeSound())
            XCTAssertFalse(first === next)
            XCTAssertGreaterThan(first.duration, 0)
        }
    }
}
