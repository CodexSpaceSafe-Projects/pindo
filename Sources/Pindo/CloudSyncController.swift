import AppKit
import Combine
import Security
import PindoCore

protocol SyncSecretStorage {
    func load() throws -> Data?
    func save(_ data: Data?) throws
}

struct KeychainSyncSecretStorage: SyncSecretStorage {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.pindo.Pindo.sync",
         kSecAttrAccount as String: "bitiful-v1"]
    }
    func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CloudSyncError.keychain }
        return data
    }
    func save(_ data: Data?) throws {
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudSyncError.keychain }
            return
        }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw CloudSyncError.keychain }
        } else if status != errSecSuccess { throw CloudSyncError.keychain }
    }
}

enum CloudSyncError: LocalizedError {
    case keychain, editing
    var errorDescription: String? {
        switch self {
        case .keychain: return "无法访问同步凭据，请解锁系统钥匙串后重试。"
        case .editing: return "当前正在编辑或拖动，结束后会继续同步。"
        }
    }
}

private struct SavedSyncConnection: Codable {
    var configuration: BitifulConfiguration
    var credentials: BitifulCredentials
    var recoveryKey: String
}

protocol CloudSyncTransport {
    func listHeads(vaultID: String) async throws -> [SyncRemoteHead]
    func download(key: String) async throws -> Data
    func upload(data: Data, key: String) async throws
}
extension BitifulTransport: CloudSyncTransport {}

/// Coordinates network awaits without allowing stale connections to apply results.
/// The repository writes the CRDT replica and visible document in one atomic file.
@MainActor final class CloudSyncController: ObservableObject {
    @Published private(set) var configuration: BitifulConfiguration?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var errorMessage: String?
    var isConfigured: Bool { connection != nil }

    private weak var model: AppModel?
    private let storage: SyncSecretStorage
    private let makeTransport: (BitifulConfiguration, BitifulCredentials) throws -> any CloudSyncTransport
    private var connection: SavedSyncConnection?
    private var timer: Timer?
    private var operation: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var generation = UUID()
    private var knownETags: [String: String] = [:]
    private var lastUploaded: Data?
    private var failureCount = 0
    private var nextAttempt = Date.distantPast
    private var lastAttempt = Date.distantPast
    private var pendingChanges = false

    init(model: AppModel, storage: SyncSecretStorage = KeychainSyncSecretStorage(),
         makeTransport: @escaping (BitifulConfiguration, BitifulCredentials) throws -> any CloudSyncTransport = {
             try BitifulTransport(configuration: $0, credentials: $1)
         }) {
        self.model = model; self.storage = storage; self.makeTransport = makeTransport
    }

    /// Only called at app launch, not by model tests or while constructing views.
    func start() {
        do {
            if let data = try storage.load() {
                let saved = try DocumentCodec.decode(SavedSyncConnection.self, from: data)
                _ = try SyncEncryption(recoveryKey: saved.recoveryKey)
                _ = try makeTransport(saved.configuration, saved.credentials)
                try model?.repository.enableSync()
                model?.refreshAfterCloudSync()
                connection = saved; configuration = saved.configuration
                installTimer(); syncNow()
            }
        } catch { errorMessage = model?.localization.error(error) ?? error.localizedDescription }
    }

    func configure(configuration: BitifulConfiguration, credentials: BitifulCredentials, recoveryKey: String) throws {
        let encryption = try SyncEncryption(recoveryKey: recoveryKey)
        _ = try makeTransport(configuration, credentials)
        let old = connection
        let oldVaultID = try old.map { try SyncEncryption(recoveryKey: $0.recoveryKey).vaultID }
        let changedVault = old?.configuration != configuration ||
            oldVaultID != encryption.vaultID
        guard let model, model.flush() else { throw PindoError.recoveryRequired }
        let saved = SavedSyncConnection(configuration: configuration, credentials: credentials, recoveryKey: recoveryKey)
        // A failed keychain write leaves the old connection intact and starts no request.
        try storage.save(DocumentCodec.encode(saved))
        do { try model.repository.enableSync(reset: changedVault) }
        catch {
            try? storage.save(old.map { try DocumentCodec.encode($0) })
            throw error
        }
        cancelConnection()
        connection = saved; self.configuration = configuration; errorMessage = nil; lastSyncDate = nil
        model.refreshAfterCloudSync(); installTimer(); syncNow()
    }

    func disconnect() throws {
        try storage.save(nil)
        cancelConnection(); connection = nil; configuration = nil; lastSyncDate = nil; errorMessage = nil
    }

    private func cancelConnection() {
        generation = UUID(); operation?.cancel(); operation = nil; debounce?.cancel(); debounce = nil
        timer?.invalidate(); timer = nil; knownETags = [:]; lastUploaded = nil
        isSyncing = false; failureCount = 0; nextAttempt = .distantPast; lastAttempt = .distantPast
        pendingChanges = false
    }

    func documentDidChange() {
        guard isConfigured else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            self?.requestSync(manual: false)
        }
    }

    func syncNow() { requestSync(manual: true) }

    private func installTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Idle menu-bar apps stay running all day. Reduce empty polls to
                // once a minute; active windows retain a 30-second cadence.
                let visible = NSApp?.windows.contains(where: { $0.isVisible }) ?? false
                if !visible && Date().timeIntervalSince(self.lastAttempt) < 60 { return }
                self.requestSync(manual: false)
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func requestSync(manual: Bool) {
        guard let saved = connection else { return }
        if isSyncing { pendingChanges = true; return }
        guard manual || Date() >= nextAttempt else { return }
        guard let model, model.noteID == nil, model.editingID == nil, model.draggedTaskID == nil else {
            if manual { errorMessage = model?.localization.error(CloudSyncError.editing) }
            return
        }
        let token = generation
        isSyncing = true; lastAttempt = Date()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                guard model.flush() else { throw PindoError.recoveryRequired }
                let encryption = try SyncEncryption(recoveryKey: saved.recoveryKey)
                let transport = try makeTransport(saved.configuration, saved.credentials)
                let heads = try await transport.listHeads(vaultID: encryption.vaultID)
                try checkCurrent(token)
                // Validate all downloaded payloads before applying any remote state.
                var incoming: [(SyncRemoteHead, SyncPayload)] = []
                for head in heads where knownETags[head.key] != head.etag {
                    let bytes = try await transport.download(key: head.key)
                    try checkCurrent(token)
                    let payload = try DocumentCodec.decode(SyncPayload.self, from: encryption.open(bytes)).validated()
                    incoming.append((head, payload))
                }
                try checkCurrent(token)
                var merged = model.repository.syncPayload ?? SyncPayload()
                for (_, payload) in incoming { merged = try merged.merging(payload) }
                if !incoming.isEmpty { try model.repository.applySync(merged) }
                for (head, _) in incoming {
                    knownETags[head.key] = head.etag
                }
                model.refreshAfterCloudSync()
                guard let payload = model.repository.syncPayload, let replica = model.repository.syncState else { throw PindoError.invalidData("同步状态不存在") }
                let bytes = try DocumentCodec.encode(payload)
                if bytes != lastUploaded {
                    let key = SyncEncryption.headKey(vaultID: encryption.vaultID, deviceID: replica.deviceID)
                    try await transport.upload(data: encryption.seal(bytes), key: key)
                    try checkCurrent(token)
                    lastUploaded = bytes
                    knownETags.removeValue(forKey: key)
                }
                lastSyncDate = Date(); errorMessage = nil; failureCount = 0; nextAttempt = .distantPast
            } catch {
                if generation == token && !Task.isCancelled {
                    model.refreshAfterCloudSync()
                    errorMessage = model.localization.error(error)
                    failureCount = min(failureCount + 1, 5)
                    nextAttempt = Date().addingTimeInterval(min(900, 30 * pow(2, Double(failureCount))))
                }
            }
            if generation == token {
                isSyncing = false; operation = nil
                if pendingChanges { pendingChanges = false; documentDidChange() }
            }
        }
    }

    private func checkCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        guard let model, model.noteID == nil, model.editingID == nil, model.draggedTaskID == nil else { throw CloudSyncError.editing }
    }
}
