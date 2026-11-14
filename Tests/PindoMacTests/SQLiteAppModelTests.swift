import Foundation
import XCTest
import PindoCore
@testable import Pindo

final class SQLiteAppModelTests: XCTestCase {
    @MainActor func testProductionModelPersistsEditsInSQLiteAndReloadsThem() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite="PindoSQLiteModel.\(UUID().uuidString)", defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer {defaults.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:directory)}
        let model=try AppModel(directory:directory,defaults:defaults)
        model.playFeedback={_ in}
        XCTAssertNotNil(model.repository.sqlite)
        XCTAssertTrue(model.addTask(title:"Production SQLite",day:model.today,groupID:nil))
        XCTAssertTrue(model.flush())
        let loaded=try AppModel(directory:directory,defaults:defaults)
        XCTAssertEqual(loaded.repository.document.tasks.first?.title,"Production SQLite")
        XCTAssertTrue(FileManager.default.fileExists(atPath:directory.appendingPathComponent("pindo.sqlite").path))
    }
}
