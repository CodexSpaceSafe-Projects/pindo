import AppKit
import Combine
import Security
import PindoCore

protocol V3SecretStorage { func load() throws -> Data?; func save(_ data: Data) throws }
struct V3KeychainStorage: V3SecretStorage {
    private var query: [String: Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.pindo.Pindo.sync",kSecAttrAccount as String:"cloudflare-v3"] }
    func load() throws -> Data? {
        var request=query;request[kSecReturnData as String]=true;request[kSecMatchLimit as String]=kSecMatchLimitOne
        var value:CFTypeRef?;let status=SecItemCopyMatching(request as CFDictionary,&value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,let data=value as? Data else { throw SyncV3Error.storageUnavailable };return data
    }
    func save(_ data: Data) throws {
        let status=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound { var q=query;q[kSecValueData as String]=data;q[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly;guard SecItemAdd(q as CFDictionary,nil)==errSecSuccess else { throw SyncV3Error.storageUnavailable } }
        else if status != errSecSuccess { throw SyncV3Error.storageUnavailable }
    }
}
struct V3Invitation: Codable {
    var version=3;var endpoint:String;var serviceID:String;var vaultID:String;var epoch:String;var pairingID:String;var code:String;var recoveryKey:String
}
private struct PendingV3Connection: Codable {
    var connection:SyncV3Connection;var operation:String;var bootstrapSecret:String?;var keyCheck:SyncV3KeyCheck?;var invitation:V3Invitation?;var importLocal=true
}
private struct V3SecretJournal: Codable {
    var version=3;var active:SyncV3Connection?;var pending:PendingV3Connection?;var enabled=false;var archived:[String:SyncV3Connection]=[:]
}
struct V3Device: Decodable, Identifiable { var id:String;var revoked_at:Int64? }

@MainActor final class CloudSyncController: ObservableObject {
    @Published private(set) var isConfigured=false
    @Published private(set) var isSyncing=false
    @Published private(set) var status="仅保存在本机"
    @Published private(set) var errorMessage:String?
    @Published private(set) var lastSyncDate:Date?
    @Published private(set) var deviceList:[V3Device]=[]
    @Published private(set) var invitation:String?
    @Published private(set) var endpoint="https://pindo-sync-v3-staging.zhchain.workers.dev"
    @Published private(set) var hasPendingConnection=false
    private weak var model:AppModel?
    private let secrets:any V3SecretStorage
    private let factory:(String)throws->any SyncV3Transport
    private var journal=V3SecretJournal()
    private var generation=UUID()
    private var job:Task<Void,Never>?
    private var debounce:Task<Void,Never>?
    private var timer:Timer?
    private var failures=0
    private var retryAfter=Date.distantPast
    init(model:AppModel,secrets:any V3SecretStorage=V3KeychainStorage(),transport:@escaping(String)throws->any SyncV3Transport={try SyncV3HTTP(endpoint:$0)}) {self.model=model;self.secrets=secrets;self.factory=transport}
    private func save() throws {try secrets.save(DocumentCodec.encode(journal));hasPendingConnection=journal.pending != nil}
    private func localize(_ text:String)->String {model?.localization(text) ?? text}
    private func failure(_ error:Error) {
        if error is CancellationError {status=localize(model?.isSyncEditing == true ? "等待编辑结束" : "等待同步");return}
        let text:String
        switch error as? SyncV3Error {
        case .authenticationRequired: text="设备授权已失效；本机资料和离线修改已保留。"
        case .pairingInvalid:text="配对信息已过期、已使用或尝试次数过多。请重新生成。"
        case .corruptData:text="云端资料校验失败，请核对恢复密钥；本机资料已保留。"
        case .epochMismatch,.cursorMismatch:text="服务恢复轮次或回执不一致，同步已暂停。请检查服务恢复状态。"
        case .quotaUnavailable:text="同步暂时超出资源预算，待上传内容已保留，将稍后重试。"
        case .bootstrapClosed:text="服务已完成初始化，请使用已连接设备生成配对信息。"
        case .unsupportedVersion:text="同步协议版本不兼容，请升级所有设备。"
        default:text="同步失败，本机资料和待上传内容已保留。"
        }
        errorMessage=localize(text);status=localize("同步失败，本机修改已保留。")
        failures=min(failures+1,6);retryAfter=Date().addingTimeInterval(min(1800,pow(2,Double(failures))*15))
    }
    func start() {
        do {
            if let bytes=try secrets.load(){journal=try DocumentCodec.decode(V3SecretJournal.self,from:bytes);guard journal.version==3 else{throw SyncV3Error.unsupportedVersion}}
            if let pending=journal.pending,try model?.repository.sqlite?.binding?.transactionID == pending.connection.transactionID {
                journal.active=pending.connection;journal.pending=nil;journal.enabled=true;try save()
            }
            isConfigured=journal.enabled && journal.active != nil;endpoint=journal.active?.endpoint ?? endpoint;hasPendingConnection=journal.pending != nil
            if journal.pending != nil && journal.enabled {resumePending()}
            else if isConfigured {installTimer();syncNow()}
        }catch{failure(error)}
    }
    private func installTimer(){timer?.invalidate();timer=Timer.scheduledTimer(withTimeInterval:30,repeats:true){[weak self]_ in Task{@MainActor in self?.syncNow(manual:false)}};RunLoop.main.add(timer!,forMode:.common)}
    func documentDidChange(){guard isConfigured else{return};debounce?.cancel();debounce=Task{[weak self]in try? await Task.sleep(nanoseconds:1_000_000_000);guard !Task.isCancelled else{return};self?.syncNow(manual:false)}}
    func editingDidBegin(){generation=UUID();job?.cancel();job=nil;isSyncing=false}
    func editingDidEnd(){if isConfigured{syncNow(manual:false)}}
    private func check(_ token:UUID)throws{guard generation==token,let model,!model.isSyncEditing,!model.repository.needsRecovery else{throw CancellationError()};guard model.flush() else{throw SyncV3Error.storageUnavailable}}
    private func refresh()throws{guard let model else{throw CancellationError()};try model.repository.reloadCurrentDocument();model.refreshAfterCloudSync()}
    func create(endpoint:String,bootstrapSecret:String,recoveryKey:String="") {
        guard !isSyncing else{return};cancelRuntime()
        let token=generation
        job=Task{[weak self]in guard let self else{return};isSyncing=true;status=localize("正在验证同步连接…");defer{if generation==token{isSyncing=false;job=nil}}
            do{
                struct Health:Decodable{var version:Int;var serviceID:String;var clientSyncAvailable:Bool}
                let transport=try factory(endpoint);let data=try await transport.request(method:"GET",path:"/health",body:nil,token:nil);try check(token)
                let health=try DocumentCodec.decode(Health.self,from:data);guard health.version==3,health.clientSyncAvailable else{throw SyncV3Error.unsupportedFeature}
                let key=recoveryKey.isEmpty ? try SyncEncryption.generateKey() : recoveryKey
                let c=SyncV3Connection(endpoint:endpoint,serviceID:health.serviceID,vaultID:UUID().uuidString.lowercased(),epoch:UUID().uuidString.lowercased(),deviceID:UUID().uuidString.lowercased(),token:try SyncEncryption.deviceToken(),recoveryKey:key)
                let cipher=try SyncEncryption(recoveryKey:key),checkID=UUID().uuidString.lowercased()
                let context=SyncV3EnvelopeContext(identity:try .init(serviceID:c.serviceID,vaultID:c.vaultID),epoch:c.epoch,kind:.checkpoint,objectID:checkID)
                let probe=try cipher.sealV3(Data("PindoSync/v3/key-check".utf8),context:context)
                try stage(.init(connection:c,operation:"create",bootstrapSecret:bootstrapSecret,keyCheck:.init(id:checkID,epoch:c.epoch,ciphertext:probe.base64EncodedString())))
                try await commitPending(token);installTimer();documentDidChange()
            }catch{if generation==token{failure(error)}}
        }
    }
    func join(invitation text:String){
        do{let invitation=try DocumentCodec.decode(V3Invitation.self,from:Data(text.utf8));guard invitation.version==3 else{throw SyncV3Error.unsupportedVersion};_ = try SyncEncryption(recoveryKey:invitation.recoveryKey)
            let c=SyncV3Connection(endpoint:invitation.endpoint,serviceID:invitation.serviceID,vaultID:invitation.vaultID,epoch:invitation.epoch,deviceID:UUID().uuidString.lowercased(),token:try SyncEncryption.deviceToken(),recoveryKey:invitation.recoveryKey)
            try stage(.init(connection:c,operation:"join",invitation:invitation));resumePending()
        }catch{failure(error)}
    }
    private func stage(_ pending:PendingV3Connection)throws{
        guard !isSyncing || job != nil else{throw CancellationError()}
        if let old=journal.active {journal.archived[try old.binding.channel]=old}
        if let old=journal.pending?.connection {journal.archived[try old.binding.channel]=old}
        guard journal.archived.count<=8 else{throw SyncV3Error.quotaUnavailable}
        journal.pending=pending;journal.enabled=true;try save()
    }
    func resumePending(){
        guard journal.pending != nil else{return};cancelRuntime();let token=generation;isSyncing=true;status=localize("正在验证同步连接…")
        job=Task{[weak self]in guard let self else{return};do{try await commitPending(token)}catch{if generation==token{failure(error)}};if generation==token{isSyncing=false;job=nil;if isConfigured{installTimer();documentDidChange()}}}
    }
    private func commitPending(_ token:UUID)async throws{
        guard let pending=journal.pending,let model,let store=model.repository.sqlite else{throw SyncV3Error.storageUnavailable}
        var c=pending.connection;let transport=try factory(c.endpoint),cipher=try SyncEncryption(recoveryKey:c.recoveryKey)
        let engine=SyncV3Engine(store:store,transport:transport,cipher:cipher,check:{try self.check(token)})
        if (try? await engine.info(c)) == nil {
            switch pending.operation{
            case "create":
                struct Bootstrap:Encodable{var version=3;var vaultID:String;var epoch:String;var deviceID:String;var deviceToken:String;var keyCheck:SyncV3KeyCheck?}
                let body=Bootstrap(vaultID:c.vaultID,epoch:c.epoch,deviceID:c.deviceID,deviceToken:c.token,keyCheck:pending.keyCheck)
                _ = try await transport.request(method:"POST",path:"/v3/bootstrap",body:DocumentCodec.encode(body),token:pending.bootstrapSecret)
            case "join":
                guard let invitation=pending.invitation else{throw SyncV3Error.invalidRequest}
                let body:JSONValue = .object(["epoch":.string(c.epoch),"deviceID":.string(c.deviceID),"deviceToken":.string(c.token),"code":.string(invitation.code)])
                _ = try await transport.request(method:"POST",path:"/v3/vaults/\(c.vaultID)/pairings/\(invitation.pairingID)/consume",body:DocumentCodec.encode(body),token:nil)
            case "rotate":
                guard let old=journal.active else{throw SyncV3Error.authenticationRequired}
                let body:JSONValue = .object(["epoch":.string(old.epoch),"deviceToken":.string(c.token)])
                _ = try await transport.request(method:"POST",path:"/v3/vaults/\(c.vaultID)/devices/\(c.deviceID)/rotate",body:DocumentCodec.encode(body),token:old.token)
            default:throw SyncV3Error.invalidRequest
            }
        }
        try check(token);_ = try await engine.info(c);try check(token)
        // The SQL marker is the connection commit point. Keychain promotion may
        // fail afterwards; startup resolves that ambiguity without rebinding.
        try store.bind(c.binding,importingLocal:pending.importLocal)
        if let installed=try store.binding{c.epoch=installed.epoch;c.transactionID=installed.transactionID}
        try refresh();journal.active=c;journal.pending=nil;journal.enabled=true;try save()
        endpoint=c.endpoint;isConfigured=true;errorMessage=nil;status=localize("等待同步");failures=0;retryAfter = .distantPast
    }
    private func cancelRuntime(){generation=UUID();job?.cancel();job=nil;debounce?.cancel();debounce=nil;timer?.invalidate();timer=nil;isSyncing=false}
    func disconnect(){cancelRuntime();journal.enabled=false;do{try save();isConfigured=false;status=localize("仅保存在本机");errorMessage=nil}catch{failure(error)}}
    func reconnect(){guard journal.active != nil else{return};journal.enabled=true;do{try save();isConfigured=true;installTimer();syncNow()}catch{failure(error)}}
    func syncNow(manual:Bool=true){
        guard isConfigured,!isSyncing,journal.pending==nil,let model,!model.isSyncEditing,let store=model.repository.sqlite,var c=journal.active else{return}
        if !manual,Date()<retryAfter{return};let token=generation;isSyncing=true;status=localize("正在同步…")
        job=Task{[weak self]in guard let self else{return};defer{if generation==token{isSyncing=false;job=nil}}
            do{
                try check(token)
                let channel=try c.binding.channel
                if let b=try store.binding,b.channel == channel{c.epoch=b.epoch;c.transactionID=b.transactionID;journal.active=c;try save()}
                let engine=SyncV3Engine(store:store,transport:try factory(c.endpoint),cipher:try SyncEncryption(recoveryKey:c.recoveryKey),check:{try self.check(token)},applied:{try self.refresh()})
                let result=try await engine.synchronize(c);try check(token)
                journal.active=result.connection;try save();failures=0;retryAfter = .distantPast;errorMessage=nil
                status=localize(result.waitingForCreate ? "等待依赖记录到达；离线修改已保留。" : result.hasMore ? "继续同步剩余变化…" : "已同步")
                if !result.hasMore && !result.waitingForCreate{lastSyncDate=Date()}
                if result.hasMore{documentDidChange()}
            }catch{if generation==token{failure(error)}}
        }
    }
    func createInvitation(){
        guard !isSyncing,let c=journal.active,journal.enabled else{return};let token=generation;isSyncing=true
        job=Task{[weak self]in guard let self else{return};defer{if generation==token{isSyncing=false;job=nil}}
            do{let id=UUID().uuidString.lowercased(),code=try SyncEncryption.deviceToken(),transport=try factory(c.endpoint)
                let body:JSONValue = .object(["id":.string(id),"code":.string(code),"epoch":.string(c.epoch)])
                _ = try await transport.request(method:"POST",path:"/v3/vaults/\(c.vaultID)/pairings",body:DocumentCodec.encode(body),token:c.token);try check(token)
                invitation=String(data:try DocumentCodec.encode(V3Invitation(endpoint:c.endpoint,serviceID:c.serviceID,vaultID:c.vaultID,epoch:c.epoch,pairingID:id,code:code,recoveryKey:c.recoveryKey)),encoding:.utf8)
            }catch{if generation==token{failure(error)}}
        }
    }
    func loadDevices(){guard let c=journal.active,journal.enabled else{return};let token=generation
        Task{do{struct Devices:Decodable{var devices:[V3Device]};let data=try await factory(c.endpoint).request(method:"GET",path:"/v3/vaults/\(c.vaultID)/devices",body:nil,token:c.token);try check(token);deviceList=try DocumentCodec.decode(Devices.self,from:data).devices}catch{if generation==token{failure(error)}}}
    }
    func revokeDevice(_ id:String){guard let c=journal.active else{return};let token=generation
        Task{do{let body=try DocumentCodec.encode(JSONValue.object(["epoch":.string(c.epoch)]));_ = try await factory(c.endpoint).request(method:"POST",path:"/v3/vaults/\(c.vaultID)/devices/\(id)/revoke",body:body,token:c.token);try check(token);if id==c.deviceID{disconnect()}else{loadDevices()}}catch{if generation==token{failure(error)}}}
    }
    func rotateToken(){guard !isSyncing,var c=journal.active else{return};do{c.token=try SyncEncryption.deviceToken();c.transactionID=UUID().uuidString.lowercased();try stage(.init(connection:c,operation:"rotate"));resumePending()}catch{failure(error)}}
    func copyInvitation(){guard let invitation else{return};NSPasteboard.general.clearContents();NSPasteboard.general.setString(invitation,forType:.string);NSPasteboard.general.setData(Data(),forType:NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))}
}
