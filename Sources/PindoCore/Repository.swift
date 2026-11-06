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
    private let io: StorageIO
    private var backupIsReadable = true
    private var lastSnapshotState: JSONValue

    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Pindo", isDirectory: true)
    }

    public init(directory: URL, io: StorageIO = FileStorage(), now: Date = Date()) throws {
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
            document = PindoDocument()
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
        _ = try next.validated()
        try io.write(DocumentCodec.encode(next), to: dataURL)
        document = next; hasUnsavedChanges = false
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
        try io.write(DocumentCodec.encode(document.validated()), to: dataURL)
        hasUnsavedChanges = false
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
        let target = try PindoDocument.fromSnapshot(archive.state(at: snapshotID))
        guard target != document else { return }
        var next = archive
        _ = try next.append(document, label: "恢复前的保护快照", now: now)
        _ = try next.append(target, label: "恢复后的快照", now: now)
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
    public func exportDocument() throws -> Data { try flush(); return try DocumentCodec.encode(document) }
    public func exportSnapshots() throws -> Data {
        guard let bytes = try io.read(backupURL) else { throw PindoError.corruptFile("snapshots.json") }
        return bytes
    }
    public func importDocument(_ data: Data) throws {
        let imported = try DocumentCodec.decode(PindoDocument.self, from: data).validated()
        guard !needsRecovery else { throw PindoError.recoveryRequired }
        try flush()
        guard backupIsReadable else { throw PindoError.corruptFile("snapshots.json") }
        var next = archive
        _ = try next.append(document, label: "导入前的保护快照")
        _ = try next.append(imported, label: "导入后的快照")
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
}
