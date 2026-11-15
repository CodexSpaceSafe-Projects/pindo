import XCTest
@testable import PindoCore

final class FileStorageCommitTests: XCTestCase {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PindoAtomicStorage-\(UUID().uuidString)", isDirectory: true)
    }

    func testRealFileReplacementIsAtomicAndHasOwnerOnlyPermissions() throws {
        let directory = folder(), storage = FileStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        try storage.createDirectory(directory)
        let url = directory.appendingPathComponent("data.json")
        try storage.write(Data("old document".utf8), to: url)
        let oldFile = try FileHandle(forReadingFrom: url)
        defer { try? oldFile.close() }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try storage.write(Data("new document".utf8), to: url)
        XCTAssertEqual(try storage.read(url), Data("new document".utf8))
        // An already-open descriptor continues reading the old inode, proving
        // replacement did not mutate the existing file in place.
        XCTAssertEqual(try oldFile.readToEnd(), Data("old document".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o777, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["data.json"])
    }

    func testRenameFailurePreservesTheDestinationAndCleansItsTemporaryFile() throws {
        let directory = folder(), storage = FileStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        try storage.createDirectory(directory)
        let destination = directory.appendingPathComponent("data.json", isDirectory: true)
        try storage.createDirectory(destination)
        let preserved = destination.appendingPathComponent("keep.txt")
        try storage.write(Data("keep me".utf8), to: preserved)
        // A regular file cannot atomically replace an existing directory.
        XCTAssertThrowsError(try storage.write(Data("replacement".utf8), to: destination))
        XCTAssertEqual(try storage.read(preserved), Data("keep me".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["data.json"])
        XCTAssertThrowsError(try storage.write(Data("missing parent".utf8), to: directory.appendingPathComponent("missing/data.json")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["data.json"])
    }

    func testReplacingASymbolicLinkDoesNotOverwriteItsOtherTarget() throws {
        let directory = folder(), storage = FileStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        try storage.createDirectory(directory)
        let original = directory.appendingPathComponent("original.json"), destination = directory.appendingPathComponent("data.json")
        try storage.write(Data("original target".utf8), to: original)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: original)
        try storage.write(Data("new document".utf8), to: destination)
        XCTAssertEqual(try storage.read(original), Data("original target".utf8))
        XCTAssertEqual(try storage.read(destination), Data("new document".utf8))
        let type = try FileManager.default.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeRegular)
    }


    func testReloadRejectsCorruptionWithoutDiscardingTheCurrentCache() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try PindoRepository(directory: directory)
        let item = TodoItem(title: "Task")
        try repository.update { $0.tasks.append(item) }
        try repository.stageNote(taskID: item.id, text: "Unflushed local note")
        let current = repository.document, database = repository.sqlite.database
        let shell = try XCTUnwrap(database.query("SELECT value FROM app_meta WHERE key='document'").first?["value"])
        try database.execute("UPDATE app_meta SET value=? WHERE key='document'", [.bytes(Data("invalid JSON".utf8))])
        XCTAssertThrowsError(try repository.reloadCurrentDocument())
        XCTAssertEqual(repository.document, current); XCTAssertTrue(repository.hasUnsavedChanges)
        try database.execute("UPDATE app_meta SET value=? WHERE key='document'", [.bytes(shell)])
        try repository.reloadCurrentDocument()
        XCTAssertEqual(repository.document.tasks.first?.note, "")
        XCTAssertFalse(repository.hasUnsavedChanges)
    }
}
