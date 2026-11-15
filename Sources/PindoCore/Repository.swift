import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct FileStorage {
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

/// Own on one serial executor. Staged text is separate from the last durable
/// document; every save captures all changes in the same SQLite transaction.
public final class PindoRepository {
    public private(set) var document: PindoDocument
    public private(set) var archive: SnapshotArchive
    public private(set) var backupWarning: String?
    public private(set) var hasUnsavedChanges = false
    public var canRestore: Bool { backupIsReadable }
    public let directory: URL
    public let sqlite: SQLiteSyncStore
    private var committedDocument: PindoDocument
    private var backupIsReadable = true
    private var lastSnapshotState: JSONValue

    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Pindo", isDirectory: true)
    }

    public init(directory: URL, now: Date = Date(), initialDocument: @autoclosure () -> PindoDocument = PindoDocument()) throws {
        self.directory = directory
        let store = try SQLiteSyncStore(directory: directory)
        sqlite = store
        if try store.initialized { document = try store.readDocument() }
        else {
            document = try initialDocument().validated()
            try store.initialize(document)
        }
        committedDocument = document
        archive = try SnapshotArchive(document: document, now: now)
        lastSnapshotState = try document.snapshotValue()
        do {
            if let saved = try store.readArchive() {
                archive = try saved.validated()
                lastSnapshotState = try archive.state()
            } else { try store.saveArchive(archive) }
        } catch {
            backupIsReadable = false
            backupWarning = "无法读取备份，原资料已保留。当前资料仍可保存，请先导出原备份后检查。"
        }
    }

    public func update(_ change: (inout PindoDocument) throws -> Void) throws {
        var next = document
        try change(&next)
        try persist(try next.validated())
    }

    /// Explicitly discard the in-memory cache after the caller has settled drafts.
    public func reloadCurrentDocument() throws {
        let current = try sqlite.readDocument()
        document = current
        committedDocument = current
        hasUnsavedChanges = false
    }

    /// AppModel coalesces disk writes after editing pauses.
    public func stageTitle(taskID: UUID, text: String, now: Date = Date()) throws {
        guard let index = document.tasks.firstIndex(where: { $0.id == taskID }) else { throw PindoError.missingTask }
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw PindoError.emptyTitle }
        guard document.tasks[index].title != title else { return }
        document.tasks[index].title = title
        document.tasks[index].updatedAt = now
        hasUnsavedChanges = true
    }

    public func stageNote(taskID: UUID, text: String, now: Date = Date()) throws {
        guard let index = document.tasks.firstIndex(where: { $0.id == taskID }) else { throw PindoError.missingTask }
        guard document.tasks[index].note != text else { return }
        document.tasks[index].note = text
        document.tasks[index].updatedAt = now
        hasUnsavedChanges = true
    }

    public func flush() throws {
        guard hasUnsavedChanges else { return }
        try persist(try document.validated())
    }

    @discardableResult public func captureIfChanged(now: Date = Date()) throws -> Bool {
        try flush()
        guard backupIsReadable else { return false }
        let current = try document.snapshotValue()
        guard current != lastSnapshotState else { return false }
        do {
            var next = archive
            _ = try next.append(document, label: "自动快照", now: now)
            try sqlite.saveArchive(next)
            archive = next
            lastSnapshotState = current
            backupWarning = nil
            return true
        } catch {
            backupWarning = error.localizedDescription
            throw error
        }
    }

    public func restore(snapshotID: UUID, now: Date = Date()) throws {
        guard backupIsReadable else { throw PindoError.corruptFile("快照") }
        try flush()
        let target = try PindoDocument.fromSnapshot(archive.state(at: snapshotID))
        guard target != document else { return }
        let next = try protectedArchive(replacingWith: target, beforeLabel: "恢复前的保护快照", afterLabel: "恢复后的快照", now: now)
        try persist(target, archive: next)
    }

    /// Exports contain product data only. Sync identities live in separate SQL rows.
    public func exportDocument() throws -> Data {
        try flush()
        return try DocumentCodec.encode(PindoExport(document: document))
    }

    /// Preserve even unreadable backup bytes so users can inspect or recover them.
    public func exportSnapshots() throws -> Data {
        guard let data = try sqlite.archiveData() else { throw PindoError.corruptFile("快照") }
        return data
    }

    public func importDocument(_ data: Data) throws {
        let imported = try DocumentCodec.decode(PindoExport.self, from: data).document(preserving: document.preferences)
        guard backupIsReadable else { throw PindoError.corruptFile("快照") }
        try flush()
        let next = try protectedArchive(replacingWith: imported, beforeLabel: "导入前的保护快照", afterLabel: "导入后的快照")
        try persist(imported, archive: next)
    }

    private func persist(_ next: PindoDocument, archive nextArchive: SnapshotArchive? = nil) throws {
        let snapshot = try nextArchive.map { _ in try next.snapshotValue() }
        try sqlite.commit(next, previous: committedDocument, archive: nextArchive)
        document = next
        committedDocument = next
        hasUnsavedChanges = false
        if let nextArchive, let snapshot {
            archive = nextArchive
            lastSnapshotState = snapshot
            backupWarning = nil
        }
    }

    private func protectedArchive(replacingWith target: PindoDocument, beforeLabel: String, afterLabel: String, now: Date = Date()) throws -> SnapshotArchive {
        var next = archive
        _ = try next.append(document, label: beforeLabel, now: now)
        let protectionID = next.records.last!.id
        _ = try next.append(target, label: afterLabel, now: now)
        guard next.records.contains(where: { $0.id == protectionID }) else { throw PindoError.protectionSnapshotTooLarge }
        return next
    }
}
