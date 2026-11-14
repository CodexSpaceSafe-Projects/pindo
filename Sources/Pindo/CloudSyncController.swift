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

enum CloudSyncError: LocalizedError, Equatable {
    case keychain, editing, vaultNotFound, migrationCollision, bindingMismatch, configurationRecovery
    var errorDescription: String? {
        switch self {
        case .keychain: return "无法访问同步凭据，请解锁系统钥匙串后重试。"
        case .editing: return "当前正在编辑或拖动，结束后会继续同步。"
        case .vaultNotFound: return "No existing sync vault was found. Check the recovery key, or explicitly create a new vault."
        case .migrationCollision: return "The sync upgrade checkpoint is invalid or its reserved path is occupied. Local data is preserved."
        case .bindingMismatch: return "The saved connection does not match this local vault. Reconnect explicitly before syncing."
        case .configurationRecovery: return "The sync configuration transaction could not be completed. Sync is paused; reconnect to recover."
        }
    }
}

private struct SavedSyncConnection: Codable {
    var configuration: BitifulConfiguration
    var credentials: BitifulCredentials
    var recoveryKey: String
    var createIfMissing: Bool? = nil
}

private struct SavedSyncJournal: Codable {
    var version = 2
    var active: SavedSyncConnection?
    var pending: SavedSyncConnection?
    var transactionID: String?
}

enum CloudSyncPhase: String {
    case disconnected = "仅保存在本机", waiting = "等待同步", editing = "等待编辑结束"
    case downloading = "正在读取云端变化…", uploading = "正在上传本机变化…"
    case confirming = "正在确认云端保存…", migrating = "正在升级同步资料库…"
    case validating = "正在验证同步连接…"
    case synced = "已同步", failed = "同步失败，本机修改已保留。", recovering = "正在恢复同步配置…"
}

protocol CloudSyncTransport {
    func listHeads(vaultID: String) async throws -> [SyncRemoteHead]
    func listObjects(vaultID: String) async throws -> [SyncRemoteHead]
    func download(key: String) async throws -> Data
    func download(key: String, expectedETag: String) async throws -> Data
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
    @Published private(set) var phase = CloudSyncPhase.disconnected
    var isConfigured: Bool { connection != nil }

    private weak var model: AppModel?
    private let storage: SyncSecretStorage
    private let makeTransport: (BitifulConfiguration, BitifulCredentials) throws -> any CloudSyncTransport
    private var connection: SavedSyncConnection?
    private var timer: Timer?
    private var operation: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var generation = UUID()
    private var failureCount = 0
    private var nextAttemptUptime: TimeInterval = 0
    private var lastAttemptUptime: TimeInterval = -.infinity
    private var pendingChanges = false
    private var validatingConnection = false
    private let now: () -> Date
    private let jitter: () -> Double
    private let uptime: () -> TimeInterval

    init(model: AppModel, storage: SyncSecretStorage = KeychainSyncSecretStorage(),
         makeTransport: @escaping (BitifulConfiguration, BitifulCredentials) throws -> any CloudSyncTransport = {
             try BitifulTransport(configuration: $0, credentials: $1)
         }, now: @escaping () -> Date = Date.init, jitter: @escaping () -> Double = { Double.random(in: 0.8...1.2) },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.model = model; self.storage = storage; self.makeTransport = makeTransport
        self.now = now; self.jitter = jitter; self.uptime = uptime
    }

    /// Only called at app launch, not by model tests or while constructing views.
    func start() {
        do {
            guard let model, let journal = try loadJournal() else { return }
            var saved = journal.active
            if let pending = journal.pending, let transaction = journal.transactionID {
                phase = .recovering
                let encryption = try SyncEncryption(recoveryKey: pending.recoveryKey)
                let channel = ImmutableCloudSync.channelID(configuration: pending.configuration, encryption: encryption)
                if model.repository.syncSession?.connectionTransaction == transaction && model.repository.syncSession?.channelID == channel {
                    saved = pending
                }
                try saveJournal(active: saved)
            }
            guard let saved else { phase = .disconnected; return }
            let encryption = try SyncEncryption(recoveryKey: saved.recoveryKey)
            _ = try makeTransport(saved.configuration, saved.credentials)
            let channel = ImmutableCloudSync.channelID(configuration: saved.configuration, encryption: encryption)
            if let bound = model.repository.syncSession?.channelID, bound != channel { throw CloudSyncError.bindingMismatch }
            try model.repository.prepareSync(channelID: channel, preserveLegacy: true, actorID: UUID(),
                                             transactionID: model.repository.syncSession?.connectionTransaction)
            model.refreshAfterCloudSync()
            connection = saved; configuration = saved.configuration; phase = .waiting
            installTimer(); syncNow()
        } catch {
            phase = .failed
            errorMessage = model?.localization.error(error) ?? error.localizedDescription
        }
    }

    func configure(configuration: BitifulConfiguration, credentials: BitifulCredentials, recoveryKey: String,
                   createIfMissing: Bool = false) throws {
        let encryption = try SyncEncryption(recoveryKey: recoveryKey)
        _ = try makeTransport(configuration, credentials)
        guard let model, model.flush() else { throw PindoError.recoveryRequired }
        guard !model.isSyncEditing else { throw CloudSyncError.editing }
        let oldRuntime = connection
        let journal = try? loadJournal()
        let durableOld: SavedSyncConnection?
        if let pending = journal?.pending, journal?.transactionID == model.repository.syncSession?.connectionTransaction {
            durableOld = pending
        } else { durableOld = journal?.active }
        let old = oldRuntime ?? durableOld
        let saved = SavedSyncConnection(configuration: configuration, credentials: credentials, recoveryKey: recoveryKey,
                                        createIfMissing: createIfMissing)
        let transaction = UUID().uuidString.lowercased()
        let channel = ImmutableCloudSync.channelID(configuration: configuration, encryption: encryption)
        // Secrets prepare the transaction; the document's matching marker is its
        // commit point. A restart can distinguish rollback from completion.
        try storage.save(DocumentCodec.encode(SavedSyncJournal(active: old, pending: saved, transactionID: transaction)))
        cancelConnection()
        let token = generation
        validatingConnection = true; isSyncing = true; phase = .validating; errorMessage = nil
        operation = Task { [weak self] in
            guard let self else { return }
            var attemptedPreparation = false
            do {
                let transport = try makeTransport(configuration, credentials)
                try await ImmutableCloudSync.verifyTarget(encryption: encryption, transport: transport,
                    allowCreate: createIfMissing || (model.repository.syncSession?.channelID == channel &&
                        model.repository.syncSession?.acknowledgedPayloadDigest != nil),
                    check: { try self.checkEpoch(token) })
                try checkEpoch(token)
                while model.isSyncEditing {
                    phase = .editing
                    try await Task.sleep(nanoseconds: 200_000_000)
                    try checkEpoch(token)
                }
                guard model.flush() else { throw PindoError.recoveryRequired }
                attemptedPreparation = true
                try commitConfiguration(saved: saved, old: old, oldRuntime: oldRuntime, channel: channel, transaction: transaction)
                try checkCurrent(token)
                validatingConnection = false; isSyncing = false; operation = nil
                phase = .waiting; installTimer(); syncNow()
            } catch {
                guard generation == token else { return }
                if !attemptedPreparation {
                    do { try saveJournal(active: old); connection = oldRuntime; self.configuration = oldRuntime?.configuration }
                    catch { pauseConfigurationRecovery() }
                }
                validatingConnection = false; isSyncing = false; operation = nil
                if phase != .recovering {
                    phase = error as? CloudSyncError == .editing ? .editing : .failed
                    errorMessage = model.localization.error(error)
                    if connection != nil { installTimer() }
                }
            }
        }
    }

    private func commitConfiguration(saved: SavedSyncConnection, old: SavedSyncConnection?, oldRuntime: SavedSyncConnection?, channel: String,
                                     transaction: String) throws {
        guard let model else { throw CloudSyncError.configurationRecovery }
        let encryption = try SyncEncryption(recoveryKey: saved.recoveryKey)
        do {
            try model.repository.prepareSync(channelID: channel, preserveLegacy: old.map {
                $0.configuration.bucket.lowercased() == saved.configuration.bucket.lowercased() &&
                    (try? SyncEncryption(recoveryKey: $0.recoveryKey).vaultID) == encryption.vaultID
            } ?? (saved.createIfMissing != true), actorID: UUID(), transactionID: transaction)
        }
        catch let preparationFailure {
            // A StorageIO implementation can report an error after committing.
            // Resolve against the persisted marker, never the stale in-memory copy.
            do { try model.repository.reloadCurrentDocument() }
            catch { pauseConfigurationRecovery(); throw CloudSyncError.configurationRecovery }
            if model.repository.syncSession?.channelID != channel || model.repository.syncSession?.connectionTransaction != transaction {
                do { try saveJournal(active: old) }
                catch { pauseConfigurationRecovery(); throw CloudSyncError.configurationRecovery }
                connection = oldRuntime; configuration = oldRuntime?.configuration
                model.refreshAfterCloudSync()
                throw preparationFailure
            }
        }
        do { try saveJournal(active: saved) }
        catch {
            pauseConfigurationRecovery()
            configuration = saved.configuration
            model.refreshAfterCloudSync()
            throw CloudSyncError.configurationRecovery
        }
        connection = saved; configuration = saved.configuration; errorMessage = nil; lastSyncDate = nil
        model.refreshAfterCloudSync()
    }

    private func pauseConfigurationRecovery() {
        connection = nil; configuration = nil; phase = .recovering
        errorMessage = model?.localization.error(CloudSyncError.configurationRecovery)
    }

    func disconnect() throws {
        try storage.save(nil)
        cancelConnection(); connection = nil; configuration = nil; lastSyncDate = nil; errorMessage = nil; phase = .disconnected
    }

    private func loadJournal() throws -> SavedSyncJournal? {
        guard let data = try storage.load() else { return nil }
        if let journal = try? DocumentCodec.decode(SavedSyncJournal.self, from: data) {
            guard journal.version == 2 else { throw PindoError.unsupportedVersion }
            guard (journal.pending == nil) == (journal.transactionID == nil),
                  journal.transactionID.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) ?? true else {
                throw CloudSyncError.configurationRecovery
            }
            return journal
        }
        return SavedSyncJournal(active: try DocumentCodec.decode(SavedSyncConnection.self, from: data))
    }

    private func saveJournal(active: SavedSyncConnection?) throws {
        try storage.save(try active.map { try DocumentCodec.encode(SavedSyncJournal(active: $0)) })
    }

    private func cancelConnection() {
        generation = UUID(); operation?.cancel(); operation = nil; debounce?.cancel(); debounce = nil
        timer?.invalidate(); timer = nil
        isSyncing = false; failureCount = 0; nextAttemptUptime = 0; lastAttemptUptime = -.infinity
        pendingChanges = false
        validatingConnection = false
    }

    func documentDidChange() {
        guard isConfigured else { return }
        if !isSyncing { phase = model?.isSyncEditing == true ? .editing : .waiting }
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            self?.requestSync(manual: false)
        }
    }

    func syncNow() { requestSync(manual: true) }

    func editingDidEnd() {
        guard isConfigured, model?.isSyncEditing == false else { return }
        if phase == .editing { nextAttemptUptime = 0 }
        requestSync(manual: false)
    }

    func editingDidBegin() {
        guard isConfigured else { return }
        pendingChanges = true; phase = .editing
        if !validatingConnection { operation?.cancel() }
    }

    private func installTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Idle menu-bar apps stay running all day. Reduce empty polls to
                // once a minute; active windows retain a 30-second cadence.
                let visible = NSApp?.windows.contains(where: { $0.isVisible }) ?? false
                if !visible && self.uptime() - self.lastAttemptUptime < 60 { return }
                self.requestSync(manual: false)
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func requestSync(manual: Bool) {
        guard let saved = connection else { return }
        if isSyncing { pendingChanges = true; return }
        guard manual || uptime() >= nextAttemptUptime else { return }
        guard let model, !model.isSyncEditing else {
            phase = .editing; pendingChanges = true
            if manual { errorMessage = model?.localization.error(CloudSyncError.editing) }
            return
        }
        let token = generation
        pendingChanges = false
        isSyncing = true; lastAttemptUptime = uptime()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                guard model.flush() else { throw PindoError.recoveryRequired }
                let encryption = try SyncEncryption(recoveryKey: saved.recoveryKey)
                let transport = try makeTransport(saved.configuration, saved.credentials)
                let complete = try await ImmutableCloudSync.run(repository: model.repository, encryption: encryption,
                    transport: transport, allowCreate: saved.createIfMissing == true,
                    check: { try self.checkCurrent(token) }, applied: { model.refreshAfterCloudSync() },
                    progress: { self.phase = $0 })
                try checkCurrent(token)
                model.refreshAfterCloudSync()
                if complete { lastSyncDate = now(); phase = .synced }
                else { phase = .waiting; pendingChanges = true }
                errorMessage = nil; failureCount = 0; nextAttemptUptime = 0
            } catch {
                if generation == token && !Task.isCancelled {
                    model.refreshAfterCloudSync()
                    if error as? CloudSyncError == .editing {
                        phase = .editing; pendingChanges = true
                    } else {
                        phase = .failed; errorMessage = model.localization.error(error)
                        failureCount = min(failureCount + 1, 5)
                        nextAttemptUptime = uptime() + min(900, 30 * pow(2, Double(failureCount))) * jitter()
                    }
                }
            }
            if generation == token {
                isSyncing = false; operation = nil
                if pendingChanges && !model.isSyncEditing { pendingChanges = false; documentDidChange() }
            }
        }
    }

    private func checkCurrent(_ token: UUID) throws {
        try checkEpoch(token)
        guard let model, !model.isSyncEditing else { throw CloudSyncError.editing }
    }

    private func checkEpoch(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }
}
