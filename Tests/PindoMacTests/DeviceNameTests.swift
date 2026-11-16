import Foundation
import XCTest
import PindoCore
@testable import Pindo

final class DeviceNameTests: XCTestCase {
    func testSharedDeviceNameValidation() throws {
        struct Fixture: Decodable {
            struct Valid: Decodable { var input: String; var name: String }
            var valid: [Valid]; var invalid: [String]
        }
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture=try DocumentCodec.decode(Fixture.self,from:Data(contentsOf:root.appendingPathComponent("sync-vectors/device-names.json")))
        for value in fixture.valid {XCTAssertEqual(try MacDeviceName.validated(value.input),value.name)}
        for value in fixture.invalid {XCTAssertThrowsError(try MacDeviceName.validated(value))}
    }

    @MainActor func testNameCanBeSavedBeforeConnectingAndIsIncludedInRegistration() async throws {
        let env=try environment()
        defer {env.controller.disconnect()}
        env.controller.saveDeviceName("  我的 MacBook Pro  ")
        XCTAssertEqual(env.controller.deviceName,"我的 MacBook Pro")
        XCTAssertEqual(env.defaults.string(forKey:MacDeviceName.defaultsKey),"我的 MacBook Pro")
        env.controller.create(endpoint:env.connection.endpoint,bootstrapSecret:"test-bootstrap",recoveryKey:env.connection.recoveryKey)
        try await waitUntil {env.controller.isConfigured && !env.controller.isSyncing}
        let registeredName=await env.server.registeredName
        XCTAssertEqual(registeredName,"我的 MacBook Pro")
        let reloaded=CloudSyncController(model:env.model,secrets:env.secrets,defaults:env.defaults,transport:{_ in env.server})
        XCTAssertEqual(reloaded.deviceName,"我的 MacBook Pro")
    }

    @MainActor func testDeviceListUsesServerNameAndDoesNotReplaceItWithSystemDefault() async throws {
        let env=try environment()
        try await connectExisting(env,name:"已经自定义的办公 Mac")
        defer {env.controller.disconnect()}
        env.controller.loadDevices()
        try await waitUntil {!env.controller.isSyncing}
        XCTAssertEqual(env.controller.deviceName,"已经自定义的办公 Mac")
        XCTAssertEqual(env.controller.deviceList.first?.name,"已经自定义的办公 Mac")
        XCTAssertTrue(env.controller.deviceList.contains {$0.name=="工作手机"})
        XCTAssertEqual(env.controller.currentDeviceID,env.connection.deviceID)
        let requests=await env.server.renameCalls
        XCTAssertEqual(requests,0)
    }

    @MainActor func testUnnamedCurrentDeviceIsFilledAndFailedRenameKeepsSavedName() async throws {
        let env=try environment()
        env.controller.saveDeviceName("客厅 Mac")
        try await connectExisting(env,name:"")
        defer {env.controller.disconnect()}
        env.controller.loadDevices()
        try await waitUntil {!env.controller.isSyncing}
        XCTAssertEqual(env.controller.deviceList.first?.name,"客厅 Mac")
        let initialRequests=await env.server.renameCalls
        XCTAssertEqual(initialRequests,1)
        env.controller.saveDeviceName("  办公 Mac  ")
        try await waitUntil {!env.controller.isSyncing}
        XCTAssertEqual(env.controller.deviceName,"办公 Mac")
        XCTAssertEqual(env.controller.deviceList.first?.name,"办公 Mac")
        await env.server.setRenameFailure(true)
        env.controller.saveDeviceName("未能保存的名称")
        try await waitUntil {!env.controller.isSyncing}
        XCTAssertEqual(env.controller.deviceName,"办公 Mac")
        XCTAssertEqual(env.defaults.string(forKey:MacDeviceName.defaultsKey),"办公 Mac")
        XCTAssertNotNil(env.controller.errorMessage)
        let beforeInvalid=await env.server.renameCalls
        env.controller.saveDeviceName("设备\n名称")
        let afterInvalid=await env.server.renameCalls
        XCTAssertEqual(beforeInvalid,afterInvalid)
    }

    @MainActor func testPausedConnectionCannotSilentlyChangeTheSavedOrServerName() async throws {
        let env=try environment()
        try await connectExisting(env,name:"原设备名")
        env.controller.loadDevices()
        try await waitUntil {!env.controller.isSyncing}
        env.controller.disconnect()
        XCTAssertFalse(env.controller.canEditDeviceName)
        let requests=await env.server.renameCalls
        env.controller.saveDeviceName("暂停时不应保存的新名字")
        XCTAssertEqual(env.controller.deviceName,"原设备名")
        XCTAssertEqual(env.defaults.string(forKey:MacDeviceName.defaultsKey),"原设备名")
        XCTAssertNotNil(env.controller.errorMessage)
        let after=await env.server.renameCalls
        let remoteName=await env.server.registeredName
        XCTAssertEqual(after,requests)
        XCTAssertEqual(remoteName,"原设备名")
    }

    @MainActor func testDeletingPeerUsesSharedContractAndCannotDeleteCurrentDevice() async throws {
        let env=try environment()
        try await connectExisting(env,name:"主设备")
        defer {env.controller.disconnect()}
        env.controller.loadDevices()
        try await waitUntil {!env.controller.isSyncing}
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("sync-vectors/device-management.json"))) as! [String:Any]
        let peer=(fixture["response"] as! [String:Any])["deviceID"] as! String
        let document=try DocumentCodec.encode(env.model.repository.document)
        env.controller.deleteDevice(env.connection.deviceID)
        let callsBefore=await env.server.deleteCalls
        XCTAssertEqual(callsBefore,0)
        XCTAssertTrue(env.controller.isConfigured)
        XCTAssertEqual(env.controller.deviceList.count,2)
        env.controller.deleteDevice(peer)
        try await waitUntil {!env.controller.isSyncing}
        XCTAssertEqual(env.controller.deviceList.map(\.id),[env.connection.deviceID])
        let request=await env.server.lastDeletion
        XCTAssertEqual(request?.method,fixture["method"] as? String)
        XCTAssertEqual(request?.path,"/v3/vaults/"+env.connection.vaultID+"/"+(fixture["devicePath"] as! String))
        XCTAssertEqual(request?.epoch,env.connection.epoch)
        XCTAssertEqual(try DocumentCodec.encode(env.model.repository.document),document)
        XCTAssertTrue(env.controller.isConfigured)
        env.controller.loadDevices()
        try await waitUntil {!env.controller.isSyncing}
        XCTAssertEqual(env.controller.deviceList.count,1)
    }

    @MainActor func testFailedDeviceDeletionKeepsDeviceVisibleAndLocalDataIntact() async throws {
        let env=try environment()
        try await connectExisting(env,name:"主设备")
        defer {env.controller.disconnect()}
        env.controller.loadDevices()
        try await waitUntil {!env.controller.isSyncing}
        await env.server.setDeleteFailure(true)
        env.controller.deleteDevice("00000000-0000-4000-8000-000000000077")
        try await waitUntil {!env.controller.isSyncing}
        XCTAssertEqual(env.controller.deviceList.count,2)
        XCTAssertNotNil(env.controller.errorMessage)
        XCTAssertTrue(env.controller.isConfigured)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
        XCTFail("Device-name operation did not finish")
        throw SyncV3Error.storageUnavailable
    }
    @MainActor private func connectExisting(_ env: Environment,name:String) async throws {
        try await env.server.install(env.connection,name:name)
        try env.model.repository.sqlite.bind(env.connection.binding,importingLocal:false)
        let active=try JSONSerialization.jsonObject(with:DocumentCodec.encode(env.connection))
        env.secrets.bytes=try JSONSerialization.data(withJSONObject:["version":3,"enabled":true,"archived":[:],"active":active])
        env.controller.start()
        try await waitUntil {!env.controller.isSyncing}
        XCTAssertTrue(env.controller.isConfigured)
    }
    @MainActor private func environment() throws -> Environment {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("PindoDeviceNames-\(UUID().uuidString)")
        let suite="PindoDeviceNames.\(UUID().uuidString)",defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        addTeardownBlock {defaults.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:directory)}
        let model=try AppModel(directory:directory,defaults:defaults), secrets=DeviceNameSecrets()
        let c=SyncV3Connection(endpoint:"https://sync.test",serviceID:"00000000-0000-4000-8000-000000000001",vaultID:"00000000-0000-4000-8000-000000000002",epoch:"00000000-0000-4000-8000-000000000003",deviceID:"00000000-0000-4000-8000-000000000004",token:String(repeating:"A",count:43),recoveryKey:String(repeating:"01",count:32))
        let server=DeviceNameServer()
        let controller=CloudSyncController(model:model,secrets:secrets,defaults:defaults,transport:{_ in server})
        return Environment(model:model,controller:controller,secrets:secrets,defaults:defaults,connection:c,server:server)
    }
    @MainActor private struct Environment {
        var model:AppModel;var controller:CloudSyncController;var secrets:DeviceNameSecrets;var defaults:UserDefaults;var connection:SyncV3Connection;var server:DeviceNameServer
    }
}

private final class DeviceNameSecrets:V3SecretStorage {
    var bytes:Data?
    func load() throws -> Data? {bytes}
    func save(_ data:Data)throws {bytes=data}
}
private actor DeviceNameServer:SyncV3Transport {
    private var c:SyncV3Connection?
    private var keyCheck:[String:Any]?
    var registeredName=""
    var renameCalls=0
    private var peerExists=true
    private var failDelete=false
    var deleteCalls=0
    var lastDeletion:(method:String,path:String,epoch:String)?
    func setDeleteFailure(_ fail:Bool){failDelete=fail}
    private var failRename=false
    func setRenameFailure(_ fail:Bool){failRename=fail}
    func install(_ connection:SyncV3Connection,name:String) throws {
        c=connection;registeredName=name
        let id="00000000-0000-4000-8000-000000000010"
        let probe=try SyncEncryption(recoveryKey:connection.recoveryKey).sealV3(Data("PindoSync/v3/key-check".utf8),context:.init(identity:try .init(serviceID:connection.serviceID,vaultID:connection.vaultID),epoch:connection.epoch,kind:.checkpoint,objectID:id))
        keyCheck=["id":id,"epoch":connection.epoch,"ciphertext":probe.base64EncodedString()]
    }
    func request(method:String,path:String,body:Data?,token:String?) async throws -> Data {
        if path=="/health" {return try encode(["version":3,"serviceID":"00000000-0000-4000-8000-000000000001","clientSyncAvailable":true])}
        if path=="/v3/bootstrap" {
            let b=try object(body)
            c=SyncV3Connection(endpoint:"https://sync.test",serviceID:"00000000-0000-4000-8000-000000000001",vaultID:b["vaultID"] as! String,epoch:b["epoch"] as! String,deviceID:b["deviceID"] as! String,token:b["deviceToken"] as! String,recoveryKey:String(repeating:"01",count:32))
            registeredName=b["deviceName"] as! String;keyCheck=b["keyCheck"] as? [String:Any]
            return try encode([:])
        }
        guard let c,token==c.token else{throw SyncV3Error.authenticationRequired}
        if path.hasSuffix("/info") {
            return try encode(["version":3,"serviceID":c.serviceID,"vaultID":c.vaultID,"epoch":c.epoch,"head":0,"gcFloor":0,"checkpointID":NSNull(),"keyCheck":keyCheck!])
        }
        if path.hasSuffix("/devices") {
            let devices:[[String:Any]]=[["id":c.deviceID,"name":registeredName]]+(peerExists ? [["id":"00000000-0000-4000-8000-000000000077","name":"工作手机"]] : [])
            return try encode(["devices":devices])
        }
        if method=="DELETE",path.hasSuffix("/devices/00000000-0000-4000-8000-000000000077") {
            deleteCalls+=1
            if failDelete{throw SyncV3Error.storageUnavailable}
            lastDeletion=(method,path,try object(body)["epoch"] as! String)
            peerExists=false
            return try encode(["deleted":true,"deviceID":"00000000-0000-4000-8000-000000000077"])
        }
        if path.hasSuffix("/devices/\(c.deviceID)/name") {
            renameCalls+=1
            if failRename{throw SyncV3Error.storageUnavailable}
            registeredName=try MacDeviceName.validated(object(body)["name"] as! String)
            return try encode(["deviceID":c.deviceID,"name":registeredName])
        }
        throw SyncV3Error.storageUnavailable
    }
    private func object(_ data:Data?) throws -> [String:Any] {try JSONSerialization.jsonObject(with:XCTUnwrap(data)) as! [String:Any]}
    private func encode(_ object:[String:Any])throws->Data {try JSONSerialization.data(withJSONObject:object)}
}
