import Foundation

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
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
    private let io: StorageIO
    private var backupIsReadable = true
    private var lastSnapshotState: JSONValue

    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Pindo", isDirectory: true)
    }

    public init(directory: URL, io: StorageIO = FileStorage(), now: Date = Date(), initialDocument: @autoclosure () -> PindoDocument = PindoDocument()) throws {
        self.directory = directory; self.io = io
        try io.createDirectory(directory)
        try io.createDirectory(directory.appendingPathComponent("Backups"))
        let dataURL = directory.appendingPathComponent("data.json")
        let backupURL = directory.appendingPathComponent("Backups/snapshots.json")
        let journalURL = directory.appendingPathComponent("recovery.json")
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
        _ = try next.validated()
        try next.captureSyncChanges()
        try io.write(DocumentCodec.encode(next), to: dataURL)
        document = next; hasUnsavedChanges = false
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
        try next.captureSyncChanges()
        try io.write(DocumentCodec.encode(next), to: dataURL)
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
        try next.captureSyncChanges()
        _ = try next.validated()
        try io.write(DocumentCodec.encode(next), to: dataURL)
        document = next; hasUnsavedChanges = false
    }

    /// Pending committed note edits are captured before merging. The new CRDT
    /// and its projection are one data.json replacement, with no cursor window
    /// in which a crash could turn stale data back into new local edits.
    public func applySync(_ payload: SyncPayload) throws {
        guard !needsRecovery else { throw PindoError.recoveryRequired }
        _ = try payload.validated()
        var next = document
        guard next.syncState != nil else { throw PindoError.invalidData("请先配置同步") }
        try next.captureSyncChanges()
        let projection = try next.syncState!.merge(payload)
        next.tasks = projection.tasks; next.groups = projection.groups
        if let id = next.preferences.defaultGroupID, !next.groups.contains(where: { $0.id == id }) { next.preferences.defaultGroupID = nil }
        _ = try next.validated()
        if next != document || hasUnsavedChanges { try io.write(DocumentCodec.encode(next), to: dataURL) }
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
        try target.captureSyncChanges()
        guard target != document else { return }
        let next = try protectedArchive(replacingWith: target, beforeLabel: "恢复前的保护快照", afterLabel: "恢复后的快照", now: now)
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
        var exported = document; exported.syncState = nil
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
        var imported = try DocumentCodec.decode(PindoDocument.self, from: DocumentCodec.encode(JSONValue.object(values))).validated()
        guard !needsRecovery else { throw PindoError.recoveryRequired }
        try flush()
        guard backupIsReadable else { throw PindoError.corruptFile("snapshots.json") }
        imported.syncState = document.syncState
        try imported.captureSyncChanges()
        let next = try protectedArchive(replacingWith: imported, beforeLabel: "导入前的保护快照", afterLabel: "导入后的快照")
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
