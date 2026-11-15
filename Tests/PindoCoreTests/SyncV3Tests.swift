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
}
