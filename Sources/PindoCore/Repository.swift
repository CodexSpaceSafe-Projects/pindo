import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public protocol StorageIO {
    func createDirectory(_ url: URL) throws
    func read(_ url: URL) throws -> Data?
    func write(_ data: Data, to url: URL) throws
    func remove(_ url: URL) throws
}

public struct FileStorage: StorageIO {
    public init() {}
    public func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
    public func write(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".pindo-write-\(UUID().uuidString).tmp")
        let descriptor = temporary.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600)) }
        guard descriptor >= 0 else { throw fileError(temporary) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        // Every operation which can report failure finishes before replacing the
        // destination. In particular a chmod error must not masquerade as rollback.
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw fileError(temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        let committed = temporary.path.withCString { source in url.path.withCString { destination in rename(source, destination) } }
        guard committed == 0 else { throw fileError(url) }

        // Best effort only: after rename, reporting failure would falsely claim
        // the old file survived. fsync does not promise power-loss durability on
        // every filesystem/device; the data file was synchronized before commit.
        let directory = parent.path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
        if directory >= 0 { _ = fsync(directory); _ = close(directory) }
    }
    private func fileError(_ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
    public func remove(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

private struct RecoveryTransaction: Codable {
    var version = 1
    var document: PindoDocument
    var archive: SnapshotArchive
}

/// Use on one serial executor. The macOS app owns this repository on MainActor.
/// Primary saves never encode or rewrite the snapshot archive.
public final class PindoRepository {
    public private(set) var document: PindoDocument
    public private(set) var archive: SnapshotArchive
    public private(set) var backupWarning: String?
    public private(set) var hasUnsavedChanges = false
    public private(set) var needsRecovery = false
    public var canRestore: Bool { backupIsReadable && !needsRecovery }
    public let directory: URL
    public var dataURL: URL { directory.appendingPathComponent("data.json") }
    public var backupURL: URL { directory.appendingPathComponent("Backups/snapshots.json") }
    public var journalURL: URL { directory.appendingPathComponent("recovery.json") }
    public var syncState: SyncReplica? { document.syncState }
    public var syncPayload: SyncPayload? { document.syncState?.payload }
    public var syncSession: SyncSessionState? { document.syncSession }
    public private(set) var sqlite: SQLiteSyncStore?
    private let io: StorageIO
    private var backupIsReadable = true
    private var lastSnapshotState: JSONValue

    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Pindo", isDirectory: true)
    }

    public init(directory: URL, io: StorageIO = FileStorage(), useSQLite: Bool = false, now: Date = Date(), initialDocument: @autoclosure () -> PindoDocument = PindoDocument()) throws {
        self.directory = directory; self.io = io
        try io.createDirectory(directory)
        try io.createDirectory(directory.appendingPathComponent("Backups"))
        let dataURL = directory.appendingPathComponent("data.json")
        let backupURL = directory.appendingPathComponent("Backups/snapshots.json")
        let journalURL = directory.appendingPathComponent("recovery.json")
        let store = useSQLite ? try SQLiteSyncStore(directory: directory) : nil
        self.sqlite = store
        if let store, try store.initialized {
            document = try store.readDocument()
            if let pending = try store.pendingBackup() {
                _ = try pending.validated()
                try io.write(DocumentCodec.encode(pending), to: backupURL)
                try store.completeBackupRecovery()
            }
        } else {
        if let journal = try io.read(journalURL) {
            let transaction: RecoveryTransaction
            do {
                transaction = try DocumentCodec.decode(RecoveryTransaction.self, from: journal)
                guard transaction.version == 1 else { throw PindoError.unsupportedVersion }
                _ = try transaction.document.validated(); _ = try transaction.archive.validated()
            } catch { throw PindoError.corruptFile("recovery.json") }
            try io.write(DocumentCodec.encode(transaction.archive), to: backupURL)
            try io.write(DocumentCodec.encode(transaction.document), to: dataURL)
            try io.remove(journalURL)
        }
        if let bytes = try io.read(dataURL) {
            do { document = try DocumentCodec.decode(PindoDocument.self, from: bytes).validated() }
            catch { throw PindoError.corruptFile("data.json") }
        } else {
            document = try initialDocument().validated()
            try io.write(DocumentCodec.encode(document), to: dataURL)
        }
            if let store {
                try store.initialize(document)
                guard try store.readDocument() == document else { throw PindoError.corruptFile("pindo.sqlite") }
                // Commit is durable before preserving the old authority as a recovery source.
                if io is FileStorage, FileManager.default.fileExists(atPath: dataURL.path),
                   !FileManager.default.fileExists(atPath: directory.appendingPathComponent("data.pre-sqlite.json").path) {
                    try? FileManager.default.moveItem(at: dataURL, to: directory.appendingPathComponent("data.pre-sqlite.json"))
                }
            }
        }
        archive = try SnapshotArchive(document: document, now: now)
        lastSnapshotState = try document.snapshotValue()
        if let bytes = try io.read(backupURL) {
            do {
                archive = try DocumentCodec.decode(SnapshotArchive.self, from: bytes).validated()
                lastSnapshotState = try archive.state()
            } catch {
                backupIsReadable = false
                backupWarning = "无法读取备份，原文件已保留。当前资料仍可保存，请先导出原备份后检查。"
            }
        } else { try io.write(DocumentCodec.encode(archive), to: backupURL) }
    }

    public func update(_ change: (inout PindoDocument) throws -> Void) throws {
        guard !needsRecovery else { throw PindoError.recoveryRequired }
        var next = document
        try change(&next)
        // A document replacement cannot adopt metadata belonging to an imported
        // file or another device. Every ordinary commit retains this identity.
        next.syncState = document.syncState
        next.syncSession = document.syncSession; next.syncChannels = document.syncChannels
        _ = try next.validated()
        try captureLegacyChanges(&next)
        try persistDocument(next)
        document = next; hasUnsavedChanges = false
    }

    /// Re-read the durable commit point after an ambiguous storage error.
    /// Callers must flush first when discarding in-memory edits is not intended.
    public func reloadCurrentDocument() throws {
        guard !needsRecovery else { throw PindoError.recoveryRequired }
        if let sqlite { document = try sqlite.readDocument(); hasUnsavedChanges = false; return }
        guard let bytes = try io.read(dataURL) else { throw PindoError.corruptFile("data.json") }
        let current: PindoDocument
        do { current = try DocumentCodec.decode(PindoDocument.self, from: bytes).validated() }
        catch { throw PindoError.corruptFile("data.json") }
        document = current; hasUnsavedChanges = false
    }

    /// Only stages text in memory. AppModel coalesces disk writes after 600 ms.
    public func stageTitle(taskID: UUID, text: String, now: Date = Date()) throws {
        guard !needsRecovery else { throw PindoError.recoveryRequired }
        guard let index = document.tasks.firstIndex(where: { $0.id == taskID }) else { throw PindoError.missingTask }
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw PindoError.emptyTitle }
        guard document.tasks[index].title != title else { return }
        document.tasks[index].title = title; document.tasks[index].updatedAt = now
        hasUnsavedChanges = true
    }

    /// Only stages text in memory. AppModel coalesces disk writes after 600 ms.
    public func stageNote(taskID: UUID, text: String, now: Date = Date()) throws {
        guard !needsRecovery else { throw PindoError.recoveryRequired }
        guard let index = document.tasks.firstIndex(where: { $0.id == taskID }) else { throw PindoError.missingTask }
        guard document.tasks[index].note != text else { return }
        document.tasks[index].note = text; document.tasks[index].updatedAt = now
        hasUnsavedChanges = true
    }

    public func flush() throws {
        guard !needsRecovery else { throw PindoError.recoveryRequired }
        guard hasUnsavedChanges else { return }
        var next = try document.validated()
        try captureLegacyChanges(&next)
        try persistDocument(next)
        document = next
        hasUnsavedChanges = false
    }

    /// Call reset only when moving this local document into a different vault.
    /// Existing replica identities remain stable through launches and retries.
    public func enableSync(deviceID: UUID = UUID(), reset: Bool = false) throws {
        guard !needsRecovery else { throw PindoError.recoveryRequired }
        if document.syncState != nil && !reset { try flush(); return }
        var next = document
        next.syncState = SyncReplica(deviceID: deviceID)
        try captureLegacyChanges(&next)
        _ = try next.validated()
        try persistDocument(next)
        document = next; hasUnsavedChanges = false
    }

    /// Called by the application before any edits, even when credentials are disconnected.
    public func beginSyncSession(actorID: UUID = UUID()) throws {
        if sqlite != nil { try flush(); return }
        guard !needsRecovery else { throw PindoError.recoveryRequired }
        guard document.syncState != nil else { return }
        var next = document
        try next.syncState!.rotateActor(actorID)
        try captureLegacyChanges(&next)
        try saveSyncDocument(next)
    }

    /// Connection identity and replica selection share one atomic data.json commit.
    public func prepareSync(channelID: String, preserveLegacy: Bool = true, actorID: UUID = UUID(), transactionID: String? = nil) throws {
        guard !needsRecovery else { throw PindoError.recoveryRequired }
        _ = try SyncSessionState(channelID: channelID, connectionTransaction: transactionID).validated()
        var next = document
        try captureLegacyChanges(&next)
        if next.syncSession?.channelID != channelID {
            var channels = next.syncChannels ?? [:]
            if let session = next.syncSession, let replica = next.syncState {
                channels[session.channelID] = SyncChannelArchive(tasks: next.tasks, groups: next.groups, syncState: replica, syncSession: session)
            }
            if let archived = channels.removeValue(forKey: channelID) {
                next.tasks = archived.tasks; next.groups = archived.groups
                next.syncState = archived.syncState; next.syncSession = archived.syncSession
            } else {
                guard channels.count < SyncSessionState.maximumChannels else { throw PindoError.invalidData("同步资料库归档已满") }
                if next.syncSession != nil || !preserveLegacy { next.syncState = nil }
                next.syncSession = SyncSessionState(channelID: channelID)
            }
            next.syncChannels = channels.isEmpty ? nil : channels
        }
        for index in next.tasks.indices {
            next.tasks[index].isProgressExplicit = next.tasks[index].phase == .inProgress ? (next.tasks[index].isProgressExplicit ?? true) : false
        }
        if next.syncState == nil {
            next.syncState = SyncReplica(deviceID: actorID, version: 2)
            try captureLegacyChanges(&next)
        } else {
            next.syncState = try next.syncState!.upgraded()
            try next.syncState!.rotateActor(actorID)
        }
        try captureLegacyChanges(&next)
        let projection = try next.syncState!.merge(SyncPayload(version: 2))
        next.tasks = projection.tasks; next.groups = projection.groups
        next.syncSession?.connectionTransaction = transactionID
        if let channels = next.syncChannels {
            guard try DocumentCodec.encode(channels).count <= 64 * 1024 * 1024 else { throw PindoError.invalidData("同步资料库归档超过 64 MiB 上限") }
        }
        if let group = next.preferences.defaultGroupID, !next.groups.contains(where: { $0.id == group }) { next.preferences.defaultGroupID = nil }
        try saveSyncDocument(next)
    }

    public func stageSyncUpload(key: String, data: Data, payloadDigest: String) throws {
        guard !needsRecovery, var session = document.syncSession else { throw PindoError.recoveryRequired }
        let pending = SyncPendingObject(key: key, data: data, payloadDigest: payloadDigest)
        if let existing = session.pendingObject {
            guard existing == pending else { throw PindoError.invalidData("尚有同步资料等待确认") }
            return
        }
        var next = document
        try captureLegacyChanges(&next)
        session.pendingObject = pending; next.syncSession = session
        try saveSyncDocument(next)
    }

    public func acknowledgeSyncUpload(key: String, payloadDigest: String) throws {
        guard !needsRecovery, var session = document.syncSession else { throw PindoError.recoveryRequired }
        guard let pending = session.pendingObject, pending.key == key, pending.payloadDigest == payloadDigest else {
            throw PindoError.invalidData("同步确认不匹配待上传资料")
        }
        var next = document
        try captureLegacyChanges(&next)
        session.pendingObject = nil
        session.acknowledgedObjects = Array(Set(session.acknowledgedObjects).union([key])).sorted()
        session.objectETags.removeValue(forKey: key)
        session.acknowledgedPayloadDigest = payloadDigest; session.acknowledgedObjectKey = key
        next.syncSession = session
        try saveSyncDocument(next)
    }

    private func saveSyncDocument(_ next: PindoDocument) throws {
        _ = try next.validated()
        try persistDocument(next)
        document = next; hasUnsavedChanges = false
    }

    /// Pending committed note edits are captured before merging. The new CRDT
    /// and its projection are one data.json replacement, with no cursor window
    /// in which a crash could turn stale data back into new local edits.
    public func applySync(_ payload: SyncPayload, acknowledgedObjects: [String]? = nil, legacyETags: [String: String]? = nil,
                          objectETags: [String: String]? = nil) throws {
        guard !needsRecovery else { throw PindoError.recoveryRequired }
        _ = try payload.validated()
        var next = document
        guard next.syncState != nil else { throw PindoError.invalidData("请先配置同步") }
        try captureLegacyChanges(&next)
        let projection = try next.syncState!.merge(payload)
        next.tasks = projection.tasks; next.groups = projection.groups
        if var session = next.syncSession {
            if let acknowledgedObjects { session.acknowledgedObjects = Array(Set(acknowledgedObjects)).sorted() }
            if let legacyETags { session.legacyETags = legacyETags }
            if let objectETags { session.objectETags = objectETags }
            next.syncSession = session
        } else if acknowledgedObjects != nil || legacyETags != nil || objectETags != nil { throw PindoError.invalidData("同步缓存缺少会话") }
        if let id = next.preferences.defaultGroupID, !next.groups.contains(where: { $0.id == id }) { next.preferences.defaultGroupID = nil }
        _ = try next.validated()
        if next != document || hasUnsavedChanges { try persistDocument(next) }
        document = next; hasUnsavedChanges = false
    }

    @discardableResult public func captureIfChanged(now: Date = Date()) throws -> Bool {
        try flush()
        guard backupIsReadable else { return false }
        let current = try document.snapshotValue()
        guard current != lastSnapshotState else { return false }
        do {
            var next = archive
            _ = try next.append(document, label: "自动快照", now: now)
            try io.write(DocumentCodec.encode(next), to: backupURL)
            archive = next; lastSnapshotState = current; backupWarning = nil
            return true
        } catch { backupWarning = error.localizedDescription; throw error }
    }

    public func restore(snapshotID: UUID, now: Date = Date()) throws {
        guard !needsRecovery else { throw PindoError.recoveryRequired }
        guard backupIsReadable else { throw PindoError.corruptFile("snapshots.json") }
        try flush()
        var target = try PindoDocument.fromSnapshot(archive.state(at: snapshotID))
        target.syncState = document.syncState
        target.syncSession = document.syncSession; target.syncChannels = document.syncChannels
        try captureLegacyChanges(&target)
        guard target != document else { return }
        let next = try protectedArchive(replacingWith: target, beforeLabel: "恢复前的保护快照", afterLabel: "恢复后的快照", now: now)
        if sqlite != nil { try commitSQLiteRecovery(target, archive: next); return }
        let transaction = RecoveryTransaction(document: target, archive: next)
        // The redo journal makes a crash between the two replacements recoverable.
        try io.write(DocumentCodec.encode(transaction), to: journalURL)
        needsRecovery = true
        do {
            try io.write(DocumentCodec.encode(next), to: backupURL)
            try io.write(DocumentCodec.encode(target), to: dataURL)
            try io.remove(journalURL)
            document = target; archive = next; lastSnapshotState = try target.snapshotValue()
            needsRecovery = false; hasUnsavedChanges = false; backupWarning = nil
        } catch { throw PindoError.recoveryRequired }
    }

    /// Export current data or the verified backup. Export never rewrites the originals.
    public func exportDocument() throws -> Data {
        try flush()
        var exported = document; exported.syncState = nil; exported.syncSession = nil; exported.syncChannels = nil
        return try DocumentCodec.encode(exported)
    }
    public func exportSnapshots() throws -> Data {
        guard let bytes = try io.read(backupURL) else { throw PindoError.corruptFile("snapshots.json") }
        return bytes
    }
    public func importDocument(_ data: Data) throws {
        // Ignore foreign replica state, even if malformed. Identity and causal
        // history always belong to this installation, not to an imported file.
        guard case .object(var values) = try DocumentCodec.decode(JSONValue.self, from: data) else { throw PindoError.invalidData("导入资料格式无效") }
        values.removeValue(forKey: "syncState")
        values.removeValue(forKey: "syncSession"); values.removeValue(forKey: "syncChannels")
        var imported = try DocumentCodec.decode(PindoDocument.self, from: DocumentCodec.encode(JSONValue.object(values))).validated()
        guard !needsRecovery else { throw PindoError.recoveryRequired }
        try flush()
        guard backupIsReadable else { throw PindoError.corruptFile("snapshots.json") }
        imported.syncState = document.syncState
        imported.syncSession = document.syncSession; imported.syncChannels = document.syncChannels
        try captureLegacyChanges(&imported)
        let next = try protectedArchive(replacingWith: imported, beforeLabel: "导入前的保护快照", afterLabel: "导入后的快照")
        if sqlite != nil { try commitSQLiteRecovery(imported, archive: next); return }
        let transaction = RecoveryTransaction(document: imported, archive: next)
        try io.write(DocumentCodec.encode(transaction), to: journalURL)
        needsRecovery = true
        do {
            try io.write(DocumentCodec.encode(next), to: backupURL)
            try io.write(DocumentCodec.encode(imported), to: dataURL)
            try io.remove(journalURL)
            document = imported; archive = next; lastSnapshotState = try imported.snapshotValue()
            needsRecovery = false; hasUnsavedChanges = false
        } catch { throw PindoError.recoveryRequired }
    }

    private func captureLegacyChanges(_ next: inout PindoDocument) throws {
        if sqlite == nil { try next.captureSyncChanges() }
    }
    private func persistDocument(_ next: PindoDocument) throws {
        if let sqlite { try sqlite.commit(next, previous: document) }
        else { try io.write(DocumentCodec.encode(next), to: dataURL) }
    }
    private func commitSQLiteRecovery(_ next: PindoDocument, archive nextArchive: SnapshotArchive) throws {
        guard let sqlite else { throw PindoError.recoveryRequired }
        needsRecovery = true
        do {
            try sqlite.commit(next, previous: document, recoveryArchive: nextArchive)
            try io.write(DocumentCodec.encode(nextArchive), to: backupURL)
            try sqlite.completeBackupRecovery()
            document = next; archive = nextArchive; lastSnapshotState = try next.snapshotValue()
            needsRecovery = false; hasUnsavedChanges = false; backupWarning = nil
        } catch { throw PindoError.recoveryRequired }
    }

    private func protectedArchive(replacingWith target: PindoDocument, beforeLabel: String, afterLabel: String, now: Date = Date()) throws -> SnapshotArchive {
        var next = archive
        _ = try next.append(document, label: beforeLabel, now: now)
        let protectionID = next.entries.last?.record.id ?? next.baselineRecord.id
        _ = try next.append(target, label: afterLabel, now: now)
        // Compaction must retain the previous document before we journal a replacement.
        guard next.records.contains(where: { $0.id == protectionID }) else { throw PindoError.protectionSnapshotTooLarge }
        return next
    }
}

private extension PindoDocument {
    mutating func captureSyncChanges() throws {
        guard syncState != nil else { return }
        try syncState!.capture(tasks: tasks, groups: groups)
    }
}
