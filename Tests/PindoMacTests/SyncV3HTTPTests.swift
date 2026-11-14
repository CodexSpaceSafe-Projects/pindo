import Foundation
import XCTest
import PindoCore
@testable import Pindo

final class SyncV3HTTPTests: XCTestCase {
    let service="00000000-0000-4000-8000-000000000001"
    let vault="00000000-0000-4000-8000-000000000002"
    let epoch="00000000-0000-4000-8000-000000000003"
    let device="00000000-0000-4000-8000-000000000004"
    let taskID=UUID(uuidString:"00000000-0000-4000-8000-000000000020")!
    let key=String(repeating:"01",count:32)
    func token(_ byte:UInt8)->String { Data(repeating:byte,count:32).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") }
    @MainActor func testRealHTTPEncryptedSyncAndAndroidInteroperability() async throws {
        guard let endpoint=ProcessInfo.processInfo.environment["PINDO_SYNC_TEST_ENDPOINT"] else {throw XCTSkip("Loopback Worker test server is not running")}
        let http=try SyncV3HTTP(endpoint:endpoint,allowLoopbackHTTP:true), cipher=try SyncEncryption(recoveryKey:key)
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:dir)}
        let repo=try PindoRepository(directory:dir,useSQLite:true), store=try XCTUnwrap(repo.sqlite)
        let c=SyncV3Connection(endpoint:endpoint,serviceID:service,vaultID:vault,epoch:epoch,deviceID:device,token:token(7),recoveryKey:key)
        let engine=SyncV3Engine(store:store,transport:LostPushACK(base:http),cipher:cipher)
        if ProcessInfo.processInfo.environment["PINDO_INTEROP_PHASE"] == "verify" {
            try store.bind(c.binding,importingLocal:false)
            for _ in 0..<10 {if try await !engine.synchronize(c).hasMore {break}}
            try repo.reloadCurrentDocument()
            XCTAssertTrue(repo.document.tasks.contains{$0.title=="Android → Swift"})
            XCTAssertTrue(repo.document.tasks.contains{$0.title=="Swift → Android" && $0.note.utf8.count==210_000})
            return
        }
        let probeID="00000000-0000-4000-8000-000000000010"
        let probe=try cipher.sealV3(Data("PindoSync/v3/key-check".utf8),context:.init(identity:try .init(serviceID:service,vaultID:vault),epoch:epoch,kind:.checkpoint,objectID:probeID))
        let bootstrap:JSONValue = .object(["version":.number(3),"vaultID":.string(vault),"epoch":.string(epoch),"deviceID":.string(device),"deviceToken":.string(token(7)),"keyCheck":.object(["id":.string(probeID),"epoch":.string(epoch),"ciphertext":.string(probe.base64EncodedString())])])
        _ = try await http.request(method:"POST",path:"/v3/bootstrap",body:DocumentCodec.encode(bootstrap),token:"integration-bootstrap")
        try repo.update{$0.tasks=[TodoItem(id:taskID,title:"Swift → Android",note:String(repeating:"长",count:70_000))]}
        try store.bind(c.binding,importingLocal:true)
        for _ in 0..<10 {if try await !engine.synchronize(c).hasMore {break}}
        XCTAssertTrue(try store.queue(c.binding).isEmpty)
        XCTAssertGreaterThan(try store.cursors(c.binding).applied,0)
        let pair:JSONValue = .object(["id":.string("00000000-0000-4000-8000-000000000011"),"code":.string(token(9)),"epoch":.string(epoch)])
        _ = try await http.request(method:"POST",path:"/v3/vaults/\(vault)/pairings",body:DocumentCodec.encode(pair),token:c.token)
        // A second independent SQLite installation reads the encrypted chunks.
        let other=try PindoRepository(directory:dir.appendingPathComponent("other"),useSQLite:true), otherStore=try XCTUnwrap(other.sqlite)
        let c2=SyncV3Connection(endpoint:endpoint,serviceID:service,vaultID:vault,epoch:epoch,deviceID:"00000000-0000-4000-8000-000000000005",token:token(8),recoveryKey:key)
        let consume:JSONValue = .object(["epoch":.string(epoch),"deviceID":.string(c2.deviceID),"deviceToken":.string(c2.token),"code":.string(token(9))])
        _ = try await http.request(method:"POST",path:"/v3/vaults/\(vault)/pairings/00000000-0000-4000-8000-000000000011/consume",body:DocumentCodec.encode(consume),token:nil)
        try otherStore.bind(c2.binding,importingLocal:false)
        let e2=SyncV3Engine(store:otherStore,transport:http,cipher:cipher)
        _ = try await e2.synchronize(c2);try other.reloadCurrentDocument()
        XCTAssertEqual(other.document.tasks.first?.note,repo.document.tasks.first?.note)
        try repo.reloadCurrentDocument();try repo.update{$0.tasks[0].title="Swift → Android"}
        // Two offline edits to the same note must remain concurrent versions.
        try repo.update{$0.tasks[0].note="Swift offline"}
        try other.update{$0.tasks[0].note="Other offline"}
        _ = try await engine.synchronize(c);_ = try await e2.synchronize(c2);_ = try await engine.synchronize(c)
        let raw=try store.state(c.binding,layer:"confirmed")
        XCTAssertEqual(raw.records["task:\(taskID.uuidString.lowercased())"]?.notes.count,2)
        // Resolve intentionally before handing the common encrypted fixture to Kotlin.
        try repo.reloadCurrentDocument();try repo.update{$0.tasks[0].note=String(repeating:"长",count:70_000)}
        _ = try await engine.synchronize(c)
        let androidPair:JSONValue = .object(["id":.string("00000000-0000-4000-8000-000000000012"),"code":.string(token(10)),"epoch":.string(epoch)])
        _ = try await http.request(method:"POST",path:"/v3/vaults/\(vault)/pairings",body:DocumentCodec.encode(androidPair),token:c.token)
    }
}

private actor LostPushACK: SyncV3Transport {
    let base: any SyncV3Transport
    var lose=true
    init(base:any SyncV3Transport){self.base=base}
    func request(method:String,path:String,body:Data?,token:String?) async throws -> Data {
        let response=try await base.request(method:method,path:path,body:body,token:token)
        if path.hasSuffix("/push") && lose {lose=false;throw SyncV3Error.storageUnavailable}
        return response
    }
}
