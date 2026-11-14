import Foundation
import XCTest
@testable import PindoCore

final class SyncV3Tests: XCTestCase {
    private var fixture: [String: Any] {
        get throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("sync-vectors/v3-contract.json"))) as? [String: Any])
        }
    }
    func testSharedAADAndIntegerBoundary() throws {
        let vector = try fixture, c = try XCTUnwrap(vector["context"] as? [String: Any])
        let identity = try SyncV3Identity(serviceID: c["serviceID"] as! String, vaultID: c["vaultID"] as! String)
        let context = SyncV3EnvelopeContext(identity: identity, epoch: c["epoch"] as! String, kind: .batch, objectID: c["objectID"] as! String)
        let aad = try context.associatedData().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(aad, vector["aadHex"] as? String)
        try SyncV3.validateCounter(SyncV3.maximumCounter)
        XCTAssertThrowsError(try SyncV3.validateCounter(SyncV3.maximumCounter + 1))
        XCTAssertThrowsError(try SyncV3.validateCounter(-1))
        XCTAssertThrowsError(try SyncV3EnvelopeContext(identity: identity, epoch: c["epoch"] as! String, kind: .batch,
            objectID: c["objectID"] as! String, artifactIDs: [String(repeating: "a", count: 64), String(repeating: "a", count: 64)]).associatedData())
    }
    func testNoteWritesConvergeWhenObservedReplacementArrivesBeforeItsSource() throws {
        let vector = try fixture
        let writes = vector["noteWrites"] as! [[String: Any]]
        func dot(_ value: [String: Any]) throws -> SyncV3NoteDot {
            try SyncV3NoteDot(actorID: value["actorID"] as! String, counter: (value["counter"] as! NSNumber).int64Value)
        }
        for order in vector["noteOrders"] as! [[Int]] {
            var register = SyncV3NoteRegister()
            for index in order {
                let write = writes[index]
                try register.apply(dot: dot(write), value: write["value"] as! String,
                    observed: Set(try (write["observed"] as! [[String: Any]]).map(dot)))
            }
            XCTAssertEqual(Set(register.visible.values), Set(vector["visibleNotes"] as! [String]))
        }
    }
    func testTitleClockCannotAcknowledgeMissingNotesAndDuplicateIdentityMustMatchContext() throws {
        let actor = "00000000-0000-4000-8000-000000000101"
        var register = SyncV3NoteRegister()
        // A title at counter 100 does not appear in a note's observed set.
        let oldNote = try SyncV3NoteDot(actorID: actor, counter: 1)
        let concurrent = try SyncV3NoteDot(actorID: "00000000-0000-4000-8000-000000000102", counter: 101)
        try register.apply(dot: concurrent, value: "Concurrent", observed: [])
        try register.apply(dot: oldNote, value: "Delayed", observed: [])
        XCTAssertEqual(register.visible.count, 2)
        let original = register
        XCTAssertThrowsError(try register.apply(dot: concurrent, value: "Concurrent", observed: [oldNote]))
        XCTAssertEqual(register, original)
        var other = SyncV3NoteRegister()
        try other.apply(dot: oldNote, value: "Different bytes", observed: [])
        XCTAssertThrowsError(try register.merge(other))
        XCTAssertEqual(register, original)
    }
    func testConcurrentEmptyNoteIsARealVersionAndRegisterMergeIsCommutative() throws {
        let a = try SyncV3NoteDot(actorID: "00000000-0000-4000-8000-000000000101", counter: 1)
        let b = try SyncV3NoteDot(actorID: "00000000-0000-4000-8000-000000000102", counter: 1)
        var left = SyncV3NoteRegister(), right = SyncV3NoteRegister()
        try left.apply(dot: a, value: "", observed: [])
        try right.apply(dot: b, value: "Text", observed: [])
        var x = left, y = right
        try x.merge(right); try y.merge(left); try x.merge(x)
        XCTAssertEqual(x, y); XCTAssertEqual(x.visible.count, 2)
    }
}
