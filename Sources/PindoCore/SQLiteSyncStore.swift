import Foundation

public struct SyncV3Binding: Codable, Equatable, Sendable {
    public var serviceID: String
    public var vaultID: String
    public var epoch: String
    public var transactionID: String
    public var channel: String { "cloudflare-v3:\(serviceID):\(vaultID)" }
    public init(serviceID: String, vaultID: String, epoch: String, transactionID: String = UUID().uuidString.lowercased()) throws {
        try [serviceID, vaultID, epoch, transactionID].forEach(SyncV3.validateID)
        self.serviceID = serviceID; self.vaultID = vaultID; self.epoch = epoch; self.transactionID = transactionID
    }
}
public struct SyncV3QueueItem: Sendable {
    public var id: String
    public var epoch: String
    public var plaintext: Data
    public var wire: Data?
    public var digest: String?
    public var receipt: Int64?
}
public struct SyncV3Chunk: Codable, Equatable, Sendable {
    public var objectID: String
    public var digest: String
    public var ciphertext: Data
    public init(objectID: String, digest: String, ciphertext: Data) { self.objectID = objectID; self.digest = digest; self.ciphertext = ciphertext }
}
public struct SyncV3Anchor: Codable, Equatable, Sendable { public var batchID: String; public var revision: Int64; public var digest: String }

/// The sole document authority when enabled. JSON is an import/recovery source,
/// never a second writer. Notes and field registers have separate SQLite rows.
public final class SQLiteSyncStore {
    public let database: SQLiteDatabase
    public let actor = UUID().uuidString.lowercased()
    private let lock = NSRecursiveLock()
    public init(directory: URL) throws {
        database = try SQLiteDatabase(url: directory.appendingPathComponent("pindo.sqlite"))
        guard (Int(try database.string("PRAGMA user_version") ?? "0") ?? 0) <= 1 else { throw PindoError.unsupportedVersion }
        try database.transaction {
            for sql in [
                "CREATE TABLE IF NOT EXISTS app_meta(key TEXT PRIMARY KEY,value BLOB NOT NULL)",
                "CREATE TABLE IF NOT EXISTS app_entities(kind TEXT NOT NULL,id TEXT NOT NULL,position INTEGER NOT NULL,data BLOB NOT NULL,note BLOB,PRIMARY KEY(kind,id))",
                "CREATE TABLE IF NOT EXISTS v3_vaults(channel TEXT PRIMARY KEY,epoch TEXT NOT NULL,fetch_cursor INTEGER NOT NULL DEFAULT 0,apply_cursor INTEGER NOT NULL DEFAULT 0,anchor BLOB,pending_checkpoint BLOB,checkpoint_applied TEXT)",
                "CREATE TABLE IF NOT EXISTS v3_records(channel TEXT NOT NULL,layer TEXT NOT NULL,key TEXT NOT NULL,field TEXT NOT NULL,data BLOB NOT NULL,PRIMARY KEY(channel,layer,key,field))",
                "CREATE TABLE IF NOT EXISTS v3_seen(channel TEXT NOT NULL,layer TEXT NOT NULL,actor TEXT NOT NULL,counter INTEGER NOT NULL,PRIMARY KEY(channel,layer,actor))",
                "CREATE TABLE IF NOT EXISTS v3_queue(seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,channel TEXT NOT NULL,epoch TEXT NOT NULL,plain BLOB NOT NULL,wire BLOB,digest TEXT,receipt INTEGER)",
                "CREATE TABLE IF NOT EXISTS v3_chunks(batch_id TEXT NOT NULL REFERENCES v3_queue(id) ON DELETE CASCADE,object_id TEXT NOT NULL,digest TEXT NOT NULL,ciphertext BLOB NOT NULL,PRIMARY KEY(batch_id,digest))",
                "CREATE TABLE IF NOT EXISTS v3_inbox(channel TEXT NOT NULL,epoch TEXT NOT NULL,revision INTEGER NOT NULL,id TEXT NOT NULL,data BLOB NOT NULL,applied INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(channel,epoch,revision))",
                "CREATE TABLE IF NOT EXISTS v3_pending_checkpoints(channel TEXT PRIMARY KEY,epoch TEXT NOT NULL,id TEXT NOT NULL,covered INTEGER NOT NULL,expected TEXT,wire BLOB NOT NULL,digest TEXT NOT NULL)",
                "CREATE TABLE IF NOT EXISTS v3_checkpoint_chunks(channel TEXT NOT NULL,object_id TEXT NOT NULL,digest TEXT NOT NULL,ciphertext BLOB NOT NULL,PRIMARY KEY(channel,digest))",
                "CREATE TABLE IF NOT EXISTS v3_retired(id TEXT PRIMARY KEY,channel TEXT NOT NULL,epoch TEXT NOT NULL,plain BLOB NOT NULL,wire BLOB,digest TEXT,receipt INTEGER)",
                "CREATE TABLE IF NOT EXISTS v3_retired_chunks(batch_id TEXT NOT NULL,object_id TEXT NOT NULL,digest TEXT NOT NULL,ciphertext BLOB NOT NULL,PRIMARY KEY(batch_id,digest))",
                "PRAGMA user_version=1"
            ] { try database.execute(sql) }
        }
    }
    public var initialized: Bool { get throws { try database.string("SELECT key FROM app_meta WHERE key='document'") != nil } }
    public var binding: SyncV3Binding? { get throws { try value(SyncV3Binding.self, key: "active_v3") } }
    public func value<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        guard let data = try database.query("SELECT value FROM app_meta WHERE key=?", [.text(key)]).first?["value"] else { return nil }
        return try DocumentCodec.decode(type, from: data)
    }
    private func put<T: Encodable>(_ value: T?, key: String) throws {
        if let value { try database.execute("INSERT OR REPLACE INTO app_meta VALUES(?,?)", [.text(key), .bytes(try DocumentCodec.encode(value))]) }
        else { try database.execute("DELETE FROM app_meta WHERE key=?", [.text(key)]) }
    }
    public func initialize(_ document: PindoDocument) throws {
        try database.transaction { if try !initialized { try saveEntities(document, previous: nil); try put("json-migration-committed", key: "migration") } }
        _ = try readDocument().validated()
    }
    public func readDocument() throws -> PindoDocument {
        lock.lock(); defer { lock.unlock() }
        guard var result = try value(PindoDocument.self, key: "document") else { throw PindoError.corruptFile("pindo.sqlite") }
        result.tasks = try database.query("SELECT data,note FROM app_entities WHERE kind='task' ORDER BY position,id").map {
            var task = try DocumentCodec.decode(TodoItem.self, from: $0["data"]!)
            task.note = String(data: $0["note"] ?? Data(), encoding: .utf8) ?? ""
            return task
        }
        result.groups = try database.query("SELECT data FROM app_entities WHERE kind='group' ORDER BY position,id").map { try DocumentCodec.decode(TaskGroup.self, from: $0["data"]!) }
        return try result.validated()
    }
    private func shell(_ d: PindoDocument) -> PindoDocument { var d = d; d.tasks = []; d.groups = []; return d }
    private func saveEntities(_ document: PindoDocument, previous: PindoDocument?) throws {
        let oldTasks = Dictionary(uniqueKeysWithValues: (previous?.tasks ?? []).enumerated().map { ($0.element.id, ($0.offset, $0.element)) })
        let oldGroups = Dictionary(uniqueKeysWithValues: (previous?.groups ?? []).enumerated().map { ($0.element.id, ($0.offset, $0.element)) })
        let taskIDs = Set(document.tasks.map(\.id)), groupIDs = Set(document.groups.map(\.id))
        for id in Set(oldTasks.keys).subtracting(taskIDs) { try database.execute("DELETE FROM app_entities WHERE kind='task' AND id=?", [.text(id.uuidString.lowercased())]) }
        for id in Set(oldGroups.keys).subtracting(groupIDs) { try database.execute("DELETE FROM app_entities WHERE kind='group' AND id=?", [.text(id.uuidString.lowercased())]) }
        for (position, task) in document.tasks.enumerated() {
            let old = oldTasks[task.id]; var header = task; header.note = ""
            var oldHeader = old?.1; oldHeader?.note = ""
            let id = task.id.uuidString.lowercased()
            if old == nil {
                try database.execute("INSERT INTO app_entities VALUES('task',?,?,?,?)", [.text(id), .integer(Int64(position)), .bytes(try DocumentCodec.encode(header)), .bytes(Data(task.note.utf8))])
            } else {
                if header != oldHeader || old?.0 != position { try database.execute("UPDATE app_entities SET position=?,data=? WHERE kind='task' AND id=?", [.integer(Int64(position)), .bytes(try DocumentCodec.encode(header)), .text(id)]) }
                if old?.1.note != task.note { try database.execute("UPDATE app_entities SET note=? WHERE kind='task' AND id=?", [.bytes(Data(task.note.utf8)), .text(id)]) }
            }
        }
        for (position, group) in document.groups.enumerated() where oldGroups[group.id]?.1 != group || oldGroups[group.id]?.0 != position {
            try database.execute("INSERT OR REPLACE INTO app_entities VALUES('group',?,?,?,NULL)", [.text(group.id.uuidString.lowercased()), .integer(Int64(position)), .bytes(try DocumentCodec.encode(group))])
        }
        if previous == nil || shell(previous!) != shell(document) { try put(shell(document), key: "document") }
    }
    public func commit(_ next: PindoDocument, previous: PindoDocument, capture: Bool = true, recoveryArchive: SnapshotArchive? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        try database.transaction {
            if capture, let b = try binding, next.tasks != previous.tasks || next.groups != previous.groups {
                let known = Set(try database.query("SELECT key FROM v3_records WHERE channel=? AND layer='optimistic' AND field='$alive'", [.text(b.channel)]).compactMap { $0["key"].flatMap { String(data: $0, encoding: .utf8) } })
                let maxClock = Int64(try database.string("SELECT COALESCE(MAX(counter),0) FROM v3_seen WHERE channel=?", [.text(b.channel)]) ?? "0") ?? 0
                guard maxClock < SyncV3.maximumCounter else { throw SyncV3ApplyError.capacity }
                let batch = try SyncV3Delta.capture(before: previous, after: next, actor: actor, clock: maxClock + 1, known: known) { key in
                    guard let data = try self.database.query("SELECT data FROM v3_records WHERE channel=? AND layer='optimistic' AND key=? AND field='$notes'", [.text(b.channel), .text(key)]).first?["data"] else { return [] }
                    return try DocumentCodec.decode([SyncNote].self, from: data)
                }
                if !batch.operations.isEmpty {
                    try enqueue(batch, binding: b)
                    for op in batch.operations {
                        for (field, value) in op.fields { try recordValue(value, binding: b, layer: "optimistic", key: op.recordKey, field: field); try seen(value.stamp, binding: b, layer: "optimistic") }
                        if !op.notes.isEmpty { try recordValue(op.notes, binding: b, layer: "optimistic", key: op.recordKey, field: "$notes"); for n in op.notes { try seen(n.stamp, binding: b, layer: "optimistic") } }
                    }
                }
            }
            try saveEntities(next, previous: previous)
            if let recoveryArchive { try put(recoveryArchive, key: "pending_backup") }
        }
    }
    public func completeBackupRecovery() throws { try put(Optional<String>.none, key: "pending_backup") }
    public func pendingBackup() throws -> SnapshotArchive? { try value(SnapshotArchive.self, key: "pending_backup") }
    private func recordValue<T: Encodable>(_ value: T, binding: SyncV3Binding, layer: String, key: String, field: String) throws {
        try database.execute("INSERT OR REPLACE INTO v3_records VALUES(?,?,?,?,?)", [.text(binding.channel), .text(layer), .text(key), .text(field), .bytes(try DocumentCodec.encode(value))])
    }
    private func seen(_ stamp: SyncStamp, binding: SyncV3Binding, layer: String) throws {
        try database.execute("INSERT INTO v3_seen VALUES(?,?,?,?) ON CONFLICT(channel,layer,actor) DO UPDATE SET counter=MAX(counter,excluded.counter)", [.text(binding.channel), .text(layer), .text(stamp.deviceID), .integer(stamp.counter)])
    }
    public func state(_ b: SyncV3Binding, layer: String) throws -> SyncPayload {
        var result = SyncPayload(version: 2)
        for row in try database.query("SELECT key,field,data FROM v3_records WHERE channel=? AND layer=?", [.text(b.channel), .text(layer)]) {
            let key = String(data: row["key"]!, encoding: .utf8)!, field = String(data: row["field"]!, encoding: .utf8)!
            if result.records[key] == nil { result.records[key] = SyncRecord() }
            if field == "$notes" { result.records[key]!.notes = try DocumentCodec.decode([SyncNote].self, from: row["data"]!) }
            else { result.records[key]!.fields[field] = try DocumentCodec.decode(SyncRegister.self, from: row["data"]!) }
        }
        for row in try database.query("SELECT actor,counter FROM v3_seen WHERE channel=? AND layer=?", [.text(b.channel), .text(layer)]) {
            result.seen[String(data: row["actor"]!, encoding: .utf8)!] = Int64(String(data: row["counter"]!, encoding: .utf8)!)!
        }
        return try result.validated()
    }
    private func saveState(_ next: SyncPayload, previous: SyncPayload, binding: SyncV3Binding, layer: String) throws {
        for key in Set(previous.records.keys).subtracting(next.records.keys) { try database.execute("DELETE FROM v3_records WHERE channel=? AND layer=? AND key=?", [.text(binding.channel), .text(layer), .text(key)]) }
        for actor in Set(previous.seen.keys).subtracting(next.seen.keys) { try database.execute("DELETE FROM v3_seen WHERE channel=? AND layer=? AND actor=?", [.text(binding.channel), .text(layer), .text(actor)]) }
        for (key, record) in next.records {
            for (field, value) in record.fields where previous.records[key]?.fields[field] != value { try recordValue(value, binding: binding, layer: layer, key: key, field: field) }
            if previous.records[key]?.notes != record.notes { try recordValue(record.notes, binding: binding, layer: layer, key: key, field: "$notes") }
        }
        for (actor, counter) in next.seen where previous.seen[actor] != counter { try seen(.init(counter: counter, deviceID: actor), binding: binding, layer: layer) }
    }
    private func enqueue(_ batch: SyncV3Batch, binding: SyncV3Binding) throws {
        let plain = try DocumentCodec.encode(batch)
        guard plain.count <= 24 * 1024 * 1024 else { throw SyncV3ApplyError.capacity }
        try database.execute("INSERT INTO v3_queue(id,channel,epoch,plain) VALUES(?,?,?,?)", [.text(UUID().uuidString.lowercased()), .text(binding.channel), .text(binding.epoch), .bytes(plain)])
    }
    /// Called only after read-only service/key verification. The caller's encrypted
    /// active/pending credential journal uses the same transactionID as this row.
    public func bind(_ b: SyncV3Binding, importingLocal: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        let original = try readDocument()
        try database.transaction {
            let oldEpoch = try database.string("SELECT epoch FROM v3_vaults WHERE channel=?", [.text(b.channel)])
            let exists = try database.string("SELECT channel FROM v3_vaults WHERE channel=?", [.text(b.channel)]) != nil
            if !exists {
                let count = Int(try database.string("SELECT COUNT(*) FROM v3_vaults") ?? "0") ?? 0
                guard count < 8 else { throw SyncV3Error.quotaUnavailable }
                if try binding == nil { try put(original, key: "unbound_source") }
                try database.execute("INSERT INTO v3_vaults(channel,epoch) VALUES(?,?)", [.text(b.channel), .text(b.epoch)])
                if importingLocal {
                    var legacy = try binding == nil ? (original.syncState?.upgraded() ?? SyncReplica(version: 2)) : SyncReplica(version: 2)
                    // Reconcile visible offline edits once while retaining legacy provenance.
                    try legacy.rotateActor(); try legacy.capture(tasks: original.tasks, groups: original.groups)
                    if !legacy.payload.records.isEmpty {
                        try enqueue(.init(baseline: legacy.payload), binding: b)
                        try saveState(legacy.payload, previous: SyncPayload(version: 2), binding: b, layer: "optimistic")
                    }
                }
            }
            var installed = b
            if let oldEpoch { installed.epoch = oldEpoch }
            try put(installed, key: "active_v3")
            let projected = try state(b, layer: "optimistic").projected()
            var document = original; document.tasks = projected.tasks; document.groups = projected.groups
            if let g = document.preferences.defaultGroupID, !document.groups.contains(where: { $0.id == g }) { document.preferences.defaultGroupID = nil }
            try saveEntities(document, previous: original)
        }
    }
    // Pausing transport retains the binding so offline edits remain in this vault.
    public func disconnect() throws {}
    public func cursors(_ b: SyncV3Binding) throws -> (fetched: Int64, applied: Int64) {
        let r = try database.query("SELECT fetch_cursor,apply_cursor FROM v3_vaults WHERE channel=? AND epoch=?", [.text(b.channel), .text(b.epoch)]).first
        guard let r else { throw SyncV3Error.epochMismatch }
        return (Int64(String(data: r["fetch_cursor"]!, encoding: .utf8)!)!, Int64(String(data: r["apply_cursor"]!, encoding: .utf8)!)!)
    }
    public func queue(_ b: SyncV3Binding) throws -> [SyncV3QueueItem] {
        try database.query("SELECT id,epoch,plain,wire,digest,receipt FROM v3_queue WHERE channel=? AND epoch=? ORDER BY seq", [.text(b.channel), .text(b.epoch)]).map {
            .init(id: String(data: $0["id"]!, encoding: .utf8)!, epoch: String(data: $0["epoch"]!, encoding: .utf8)!, plaintext: $0["plain"]!, wire: $0["wire"],
                  digest: $0["digest"].flatMap { String(data: $0, encoding: .utf8) }, receipt: $0["receipt"].flatMap { Int64(String(data: $0, encoding: .utf8)!) })
        }
    }
    public func freeze(_ b: SyncV3Binding, id: String, wire: Data, digest: String, chunks: [SyncV3Chunk]) throws {
        try database.transaction {
            guard try binding == b else { throw SyncV3Error.epochMismatch }
            let current = try database.query("SELECT wire,digest FROM v3_queue WHERE id=? AND channel=? AND epoch=?", [.text(id), .text(b.channel), .text(b.epoch)]).first
            guard let current else { throw SyncV3Error.batchConflict }
            if let old = current["wire"], old != wire { throw SyncV3Error.batchConflict }
            for chunk in chunks { try database.execute("INSERT OR IGNORE INTO v3_chunks VALUES(?,?,?,?)", [.text(id), .text(chunk.objectID), .text(chunk.digest), .bytes(chunk.ciphertext)]) }
            try database.execute("UPDATE v3_queue SET wire=?,digest=? WHERE id=? AND channel=? AND epoch=?", [.bytes(wire), .text(digest), .text(id), .text(b.channel), .text(b.epoch)])
        }
    }
    public func chunks(id: String) throws -> [SyncV3Chunk] {
        try database.query("SELECT object_id,digest,ciphertext FROM v3_chunks WHERE batch_id=? ORDER BY digest", [.text(id)]).map { .init(objectID: String(data: $0["object_id"]!, encoding: .utf8)!, digest: String(data: $0["digest"]!, encoding: .utf8)!, ciphertext: $0["ciphertext"]!) }
    }
    public func acknowledge(_ b: SyncV3Binding, id: String, digest: String, revision: Int64) throws {
        try SyncV3.validateCounter(revision)
        guard revision > 0 else { throw SyncV3Error.corruptData }
        try database.transaction {
            guard try binding == b, let current = try queue(b).first(where: { $0.id == id }), current.wire != nil, current.digest == digest else { throw SyncV3Error.batchConflict }
            try database.execute("UPDATE v3_queue SET receipt=? WHERE id=? AND channel=? AND epoch=? AND digest=?", [.integer(revision), .text(id), .text(b.channel), .text(b.epoch), .text(digest)])
            let anchor = SyncV3Anchor(batchID: id, revision: revision, digest: digest)
            try database.execute("UPDATE v3_vaults SET anchor=? WHERE channel=? AND epoch=?", [.bytes(try DocumentCodec.encode(anchor)), .text(b.channel), .text(b.epoch)])
        }
    }
    public func anchor(_ b: SyncV3Binding) throws -> SyncV3Anchor? {
        guard let data = try database.query("SELECT anchor FROM v3_vaults WHERE channel=?", [.text(b.channel)]).first?["anchor"] else { return nil }
        return try DocumentCodec.decode(SyncV3Anchor.self, from: data)
    }
    public func receive(_ b: SyncV3Binding, entries: [(revision: Int64, id: String, batch: SyncV3Batch)]) throws {
        lock.lock(); defer { lock.unlock() }
        try database.transaction {
            guard try binding == b else { throw SyncV3Error.epochMismatch }
            let before = try readDocument(), oldConfirmed = try state(b, layer: "confirmed"), oldOptimistic = try state(b, layer: "optimistic")
            var cursor = try cursors(b)
            for entry in entries {
                guard entry.revision == cursor.fetched + 1 else { throw SyncV3Error.cursorMismatch }
                if let own = try queue(b).first(where: { $0.receipt == entry.revision }), own.id != entry.id { throw SyncV3Error.cursorMismatch }
                try database.execute("INSERT INTO v3_inbox VALUES(?,?,?,?,?,0)", [.text(b.channel), .text(b.epoch), .integer(entry.revision), .text(entry.id), .bytes(try DocumentCodec.encode(entry.batch))])
                cursor.fetched = entry.revision
            }
            var confirmed = oldConfirmed, progress = true
            while progress {
                progress = false
                for row in try database.query("SELECT revision,data FROM v3_inbox WHERE channel=? AND epoch=? AND applied=0 ORDER BY revision", [.text(b.channel), .text(b.epoch)]) {
                    do {
                        confirmed = try confirmed.applyingV3(DocumentCodec.decode(SyncV3Batch.self, from: row["data"]!))
                        try database.execute("UPDATE v3_inbox SET applied=1 WHERE channel=? AND epoch=? AND revision=?", [.text(b.channel), .text(b.epoch), .integer(Int64(String(data: row["revision"]!, encoding: .utf8)!)!)])
                        progress = true
                    } catch SyncV3ApplyError.missingCreate { continue }
                }
            }
            while try database.string("SELECT applied FROM v3_inbox WHERE channel=? AND epoch=? AND revision=?", [.text(b.channel), .text(b.epoch), .integer(cursor.applied + 1)]) == "1" { cursor.applied += 1 }
            try database.execute("UPDATE v3_vaults SET fetch_cursor=?,apply_cursor=? WHERE channel=? AND epoch=?", [.integer(cursor.fetched), .integer(cursor.applied), .text(b.channel), .text(b.epoch)])
            try database.execute("DELETE FROM v3_queue WHERE channel=? AND epoch=? AND receipt IS NOT NULL AND receipt<=?", [.text(b.channel), .text(b.epoch), .integer(cursor.applied)])
            var optimistic = confirmed
            for item in try queue(b) { optimistic = try optimistic.applyingV3(DocumentCodec.decode(SyncV3Batch.self, from: item.plaintext)) }
            try saveState(confirmed, previous: oldConfirmed, binding: b, layer: "confirmed")
            try saveState(optimistic, previous: oldOptimistic, binding: b, layer: "optimistic")
            let visible = try optimistic.projected(); var next = before; next.tasks = visible.tasks; next.groups = visible.groups
            if let g = next.preferences.defaultGroupID, !next.groups.contains(where: { $0.id == g }) { next.preferences.defaultGroupID = nil }
            try saveEntities(next, previous: before)
            try database.execute("DELETE FROM v3_inbox WHERE channel=? AND epoch=? AND revision<=?", [.text(b.channel), .text(b.epoch), .integer(cursor.applied)])
        }
    }
    public func installCheckpoint(_ b: SyncV3Binding, payload: SyncPayload, covered: Int64, checkpointID: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        _ = try payload.validated(); try SyncV3.validateCounter(covered)
        try database.transaction {
            guard try binding == b else { throw SyncV3Error.epochMismatch }
            let before = try readDocument(), oldOptimistic = try state(b, layer: "optimistic")
            try database.execute("DELETE FROM v3_records WHERE channel=? AND layer='confirmed'", [.text(b.channel)])
            try database.execute("DELETE FROM v3_seen WHERE channel=? AND layer='confirmed'", [.text(b.channel)])
            try saveState(payload, previous: SyncPayload(version: 2), binding: b, layer: "confirmed")
            try database.execute("UPDATE v3_vaults SET fetch_cursor=?,apply_cursor=?,checkpoint_applied=? WHERE channel=? AND epoch=?", [.integer(covered), .integer(covered), checkpointID.map(SQLiteDatabase.Value.text) ?? .null, .text(b.channel), .text(b.epoch)])
            try database.execute("DELETE FROM v3_inbox WHERE channel=? AND epoch=?", [.text(b.channel), .text(b.epoch)])
            try database.execute("DELETE FROM v3_queue WHERE channel=? AND epoch=? AND receipt IS NOT NULL AND receipt<=?", [.text(b.channel), .text(b.epoch), .integer(covered)])
            var optimistic = payload
            for item in try queue(b) { optimistic = try optimistic.applyingV3(DocumentCodec.decode(SyncV3Batch.self, from: item.plaintext)) }
            try saveState(optimistic, previous: oldOptimistic, binding: b, layer: "optimistic")
            let p = try optimistic.projected(); var next = before; next.tasks = p.tasks; next.groups = p.groups
            if let g = next.preferences.defaultGroupID, !next.groups.contains(where: { $0.id == g }) { next.preferences.defaultGroupID = nil }
            try saveEntities(next, previous: before)
        }
    }
    public func rebaseEpoch(_ old: SyncV3Binding, epoch: String) throws -> SyncV3Binding {
        var next = old; next.epoch = epoch; next.transactionID = UUID().uuidString.lowercased(); try SyncV3.validateID(epoch)
        try database.transaction {
            guard try binding == old else { throw SyncV3Error.epochMismatch }
            let optimistic = try state(old, layer: "optimistic")
            try clearCheckpoint(old)
            try database.execute("INSERT OR IGNORE INTO v3_retired SELECT id,channel,epoch,plain,wire,digest,receipt FROM v3_queue WHERE channel=?", [.text(old.channel)])
            try database.execute("INSERT OR IGNORE INTO v3_retired_chunks SELECT * FROM v3_chunks WHERE batch_id IN (SELECT id FROM v3_queue WHERE channel=?)", [.text(old.channel)])
            try database.execute("DELETE FROM v3_queue WHERE channel=?", [.text(old.channel)])
            try database.execute("DELETE FROM v3_records WHERE channel=? AND layer='confirmed'", [.text(old.channel)])
            try database.execute("DELETE FROM v3_seen WHERE channel=? AND layer='confirmed'", [.text(old.channel)])
            try database.execute("DELETE FROM v3_inbox WHERE channel=?", [.text(old.channel)])
            try database.execute("UPDATE v3_vaults SET epoch=?,fetch_cursor=0,apply_cursor=0,anchor=NULL,pending_checkpoint=NULL,checkpoint_applied=NULL WHERE channel=?", [.text(epoch), .text(old.channel)])
            if !optimistic.records.isEmpty { try enqueue(.init(baseline: optimistic), binding: next) }
            try put(next, key: "active_v3")
        }
        return next
    }
    public func installedCheckpoint(_ b: SyncV3Binding) throws -> String? {
        try database.string("SELECT checkpoint_applied FROM v3_vaults WHERE channel=? AND epoch=?", [.text(b.channel), .text(b.epoch)])
    }
    public func pendingCheckpoint(_ b: SyncV3Binding) throws -> SyncV3PendingCheckpoint? {
        guard let r = try database.query("SELECT id,covered,expected,wire,digest FROM v3_pending_checkpoints WHERE channel=? AND epoch=?", [.text(b.channel), .text(b.epoch)]).first else { return nil }
        return .init(id: String(data: r["id"]!, encoding: .utf8)!, covered: Int64(String(data: r["covered"]!, encoding: .utf8)!)!, expectedID: r["expected"].flatMap { String(data: $0, encoding: .utf8) }, wire: r["wire"]!, digest: String(data: r["digest"]!, encoding: .utf8)!)
    }
    public func freezeCheckpoint(_ b: SyncV3Binding, pending: SyncV3PendingCheckpoint, chunks: [SyncV3Chunk]) throws {
        try database.transaction {
            guard try binding == b, try pendingCheckpoint(b) == nil else { throw SyncV3Error.checkpointRequired }
            try database.execute("INSERT INTO v3_pending_checkpoints VALUES(?,?,?,?,?,?,?)", [.text(b.channel), .text(b.epoch), .text(pending.id), .integer(pending.covered), pending.expectedID.map(SQLiteDatabase.Value.text) ?? .null, .bytes(pending.wire), .text(pending.digest)])
            for c in chunks { try database.execute("INSERT INTO v3_checkpoint_chunks VALUES(?,?,?,?)", [.text(b.channel), .text(c.objectID), .text(c.digest), .bytes(c.ciphertext)]) }
        }
    }
    public func checkpointChunks(_ b: SyncV3Binding) throws -> [SyncV3Chunk] {
        try database.query("SELECT object_id,digest,ciphertext FROM v3_checkpoint_chunks WHERE channel=? ORDER BY digest", [.text(b.channel)]).map { .init(objectID: String(data: $0["object_id"]!, encoding: .utf8)!, digest: String(data: $0["digest"]!, encoding: .utf8)!, ciphertext: $0["ciphertext"]!) }
    }
    public func clearCheckpoint(_ b: SyncV3Binding) throws {
        try database.transaction { try database.execute("DELETE FROM v3_pending_checkpoints WHERE channel=?", [.text(b.channel)]); try database.execute("DELETE FROM v3_checkpoint_chunks WHERE channel=?", [.text(b.channel)]) }
    }

}
