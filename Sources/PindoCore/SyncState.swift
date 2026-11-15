import Foundation

/// Current synchronization values use Foundation reference-date seconds
/// (2001-01-01 UTC) and lowercase UUID strings on both clients.
public struct SyncStamp: Codable, Equatable, Comparable, Sendable {
    public var counter: Int64
    public var deviceID: String
    public init(counter: Int64, deviceID: String) { self.counter = counter; self.deviceID = deviceID }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.counter == rhs.counter ? lhs.deviceID < rhs.deviceID : lhs.counter < rhs.counter
    }
}

public struct SyncRegister: Codable, Equatable, Sendable {
    public var value: JSONValue
    public var stamp: SyncStamp
    public init(value: JSONValue, stamp: SyncStamp) { self.value = value; self.stamp = stamp }
}

public struct SyncNote: Codable, Equatable, Sendable {
    public var value: String
    public var stamp: SyncStamp
    public var seen: [String: Int64]
    public init(value: String, stamp: SyncStamp, seen: [String: Int64]) {
        self.value = value; self.stamp = stamp; self.seen = seen
    }
}

public struct SyncRecord: Codable, Equatable, Sendable {
    public var fields: [String: SyncRegister]
    public var notes: [SyncNote]
    public init(fields: [String: SyncRegister] = [:], notes: [SyncNote] = []) {
        self.fields = fields; self.notes = notes
    }
}

public struct SyncPayload: Codable, Equatable, Sendable {
    public var version: Int
    public var seen: [String: Int64]
    public var records: [String: SyncRecord]
    public init(version: Int = 2, seen: [String: Int64] = [:], records: [String: SyncRecord] = [:]) {
        self.version = version; self.seen = seen; self.records = records
    }

    public func validated() throws -> Self {
        guard version == 2 else { throw PindoError.unsupportedVersion }
        guard records.count <= 200_000 else { throw invalidSync() }
        try validateVector(seen)
        var activeTasks = 0, activeGroups = 0
        for (key, record) in records {
            let (kind, id) = try parseRecordKey(key)
            let allowed = kind == "task" ? taskFields.union(["$alive", "lifecycle"]) : groupFields.union(["$alive"])
            guard Set(record.fields.keys) == allowed else { throw invalidSync() }
            for field in record.fields.values {
                try validateStamp(field.stamp)
                guard (seen[field.stamp.deviceID] ?? 0) >= field.stamp.counter else { throw invalidSync() }
            }
            guard case .bool = record.fields["$alive"]?.value else { throw invalidSync() }
            if record.fields["$alive"]?.value == .bool(true) {
                if kind == "task" { activeTasks += 1 } else { activeGroups += 1 }
                guard activeTasks <= 10_000, activeGroups <= 1_000 else { throw invalidSync() }
            }
            if kind == "task" {
                let lifecycle = record.fields["lifecycle"]!
                try validateLifecycle(lifecycle.value)
                if case .object(let event) = lifecycle.value {
                    for field in ["phase", "startedAt", "completedAt"] {
                        guard record.fields[field]!.stamp == lifecycle.stamp,
                              record.fields[field]!.value == event[field] else { throw invalidSync() }
                    }
                }
                guard record.notes.count <= 10_000 else { throw invalidSync() }
                guard !record.notes.isEmpty else { throw invalidSync() }
                var stamps = Set<String>()
                for note in record.notes {
                    try validateStamp(note.stamp); try validateVector(note.seen)
                    guard (seen[note.stamp.deviceID] ?? 0) >= note.stamp.counter,
                          note.seen.allSatisfy({ $0.value < note.stamp.counter && $0.value <= (seen[$0.key] ?? 0) }),
                          stamps.insert(stampKey(note.stamp)).inserted else { throw invalidSync() }
                }
                _ = try decodeTask(id: id, record: record)
            } else {
                guard record.notes.isEmpty else { throw invalidSync() }
                _ = try decodeGroup(id: id, record: record)
            }
        }
        return self
    }

    public func merging(_ other: Self) throws -> Self {
        _ = try validated(); _ = try other.validated()
        var result = self
        for (device, counter) in other.seen { result.seen[device] = max(counter, result.seen[device] ?? 0) }
        for (key, incoming) in other.records {
            guard var record = result.records[key] else {
                var normalized = incoming
                normalized.notes = try mergedNotes(incoming.notes)
                result.records[key] = normalized
                continue
            }
            for (field, value) in incoming.fields {
                if let current = record.fields[field] {
                    if current.stamp == value.stamp, current.value != value.value { throw invalidSync() }
                    if current.stamp < value.stamp { record.fields[field] = value }
                } else { record.fields[field] = value }
            }
            record.notes = try mergedNotes(record.notes + incoming.notes)
            result.records[key] = record
        }
        return try result.validated()
    }

    /// Repairs references in the projection only. Raw registers remain unchanged
    /// so every device converges even if encrypted heads arrive in another order.
    public func projected() throws -> (tasks: [TodoItem], groups: [TaskGroup]) {
        _ = try validated()
        var tasks: [TodoItem] = [], groups: [TaskGroup] = []
        for key in records.keys.sorted() {
            let record = records[key]!
            guard record.fields["$alive"]?.value == .bool(true) else { continue }
            let (kind, id) = try parseRecordKey(key)
            if kind == "task" { tasks.append(try decodeTask(id: id, record: record)) }
            else { groups.append(try decodeGroup(id: id, record: record)) }
        }
        groups.sort { canonicalID($0.id) < canonicalID($1.id) }
        let names = Dictionary(grouping: groups, by: \.name).mapValues(\.count)
        var usedNames = Set<String>()
        for i in groups.indices {
            let suffix = " [\(canonicalID(groups[i].id))]"
            if (names[groups[i].name] ?? 0) > 1 { groups[i].name += suffix }
            while !usedNames.insert(groups[i].name).inserted { groups[i].name += suffix }
        }
        tasks.sort { canonicalID($0.id) < canonicalID($1.id) }
        let positions = Dictionary(uniqueKeysWithValues: tasks.indices.map { (tasks[$0].id, $0) })
        let groupIDs = Set(groups.map(\.id))
        for i in tasks.indices {
            if let group = tasks[i].groupID, !groupIDs.contains(group) { tasks[i].groupID = nil }
            if let parent = tasks[i].parentID, parent == tasks[i].id || positions[parent] == nil { tasks[i].parentID = nil }
        }
        for i in tasks.indices {
            var visited = Set<UUID>(), current: UUID? = tasks[i].id
            while let id = current, let index = positions[id] {
                guard visited.insert(id).inserted, visited.count <= PindoDocument.maximumTaskDepth else {
                    tasks[i].parentID = nil
                    break
                }
                current = tasks[index].parentID
            }
        }
        func depth(_ id: UUID) -> Int {
            var count = 0, current = positions[id].flatMap { tasks[$0].parentID }
            while let id = current, let index = positions[id] { count += 1; current = tasks[index].parentID }
            return count
        }
        let children = Dictionary(grouping: tasks.indices.filter { tasks[$0].parentID != nil }, by: { tasks[$0].parentID! })
        let bottomUp = tasks.indices.sorted {
            let a = depth(tasks[$0].id), b = depth(tasks[$1].id)
            return a == b ? canonicalID(tasks[$0].id) < canonicalID(tasks[$1].id) : a > b
        }
        for i in bottomUp {
            let indices = children[tasks[i].id] ?? []
            let explicit = tasks[i].phase == .inProgress && tasks[i].isProgressExplicit
            let phase: TaskPhase
            if indices.isEmpty { phase = tasks[i].phase == .inProgress && !explicit ? .pending : tasks[i].phase }
            else if indices.allSatisfy({ tasks[$0].phase == .completed }) { phase = .completed }
            else if explicit || indices.contains(where: { tasks[$0].phase != .pending }) { phase = .inProgress }
            else { phase = .pending }
            if phase != tasks[i].phase {
                let date = max(tasks[i].updatedAt, indices.map { tasks[$0].updatedAt }.max() ?? tasks[i].updatedAt)
                tasks[i].phase = phase; tasks[i].updatedAt = date
                if phase == .completed {
                    guard let completion = indices.compactMap({ tasks[$0].completedAt }).max() else { throw invalidSync() }
                    tasks[i].completedAt = completion
                } else { tasks[i].completedAt = nil }
                if phase == .inProgress && tasks[i].startedAt == nil {
                    let events = indices.compactMap { index -> Date? in
                        switch tasks[index].phase {
                        case .inProgress: return tasks[index].startedAt
                        case .completed: return tasks[index].completedAt
                        case .pending: return nil
                        }
                    }
                    guard let start = events.max() else { throw invalidSync() }
                    tasks[i].startedAt = start
                }
            }
            tasks[i].isProgressExplicit = phase == .inProgress && explicit
            if phase == .pending { tasks[i].startedAt = nil; tasks[i].completedAt = nil }
            if phase == .inProgress { tasks[i].completedAt = nil; tasks[i].startedAt = tasks[i].startedAt ?? tasks[i].updatedAt }
            if phase == .completed { tasks[i].completedAt = tasks[i].completedAt ?? tasks[i].updatedAt }
        }
        tasks.sort {
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return canonicalID($0.id) < canonicalID($1.id)
        }
        return (tasks, groups)
    }
}

private let maximumCounter: Int64 = 9_007_199_254_740_991
private let taskFields: Set<String> = ["title", "plannedDay", "groupID", "parentID", "phase", "order", "createdAt", "updatedAt", "startedAt", "completedAt"]
private let groupFields: Set<String> = ["name", "colorHex"]
private func invalidSync() -> PindoError { .invalidData("同步资料格式无效") }
private func canonicalID(_ id: UUID) -> String { id.uuidString.lowercased() }
private func isCanonicalID(_ value: String) -> Bool { UUID(uuidString: value).map(canonicalID) == value }
private func stampKey(_ stamp: SyncStamp) -> String { "\(stamp.deviceID):\(stamp.counter)" }
private func validateVector(_ seen: [String: Int64]) throws {
    guard seen.count <= 10_000, seen.allSatisfy({ isCanonicalID($0.key) && $0.value >= 0 && $0.value <= maximumCounter }) else { throw invalidSync() }
}
private func validateStamp(_ stamp: SyncStamp) throws {
    guard isCanonicalID(stamp.deviceID), stamp.counter > 0, stamp.counter <= maximumCounter else { throw invalidSync() }
}
private func parseRecordKey(_ key: String) throws -> (String, UUID) {
    let parts = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2, ["task", "group"].contains(parts[0]), isCanonicalID(parts[1]), let id = UUID(uuidString: parts[1]) else { throw invalidSync() }
    return (parts[0], id)
}
private func mergedNotes(_ notes: [SyncNote]) throws -> [SyncNote] {
    var unique: [String: SyncNote] = [:]
    for note in notes {
        let key = stampKey(note.stamp)
        if let existing = unique[key], existing != note { throw invalidSync() }
        unique[key] = note
    }
    return unique.values.filter { candidate in
        !unique.values.contains { other in other.stamp != candidate.stamp && (other.seen[candidate.stamp.deviceID] ?? 0) >= candidate.stamp.counter }
    }.sorted { $0.stamp > $1.stamp }
}
private func projectedNote(_ record: SyncRecord) throws -> String {
    var values = Set<String>()
    return try mergedNotes(record.notes).compactMap { values.insert($0.value).inserted ? $0.value : nil }.joined(separator: "\n\n[Sync conflict]\n\n")
}
private func decodeTask(id: UUID, record: SyncRecord) throws -> TodoItem {
    var values = record.fields.mapValues(\.value)
    values.removeValue(forKey: "$alive")
    values.removeValue(forKey: "lifecycle")
    guard case .object(let lifecycle) = record.fields["lifecycle"]?.value else { throw invalidSync() }
    for (field, value) in lifecycle { values[field] = value }
    values["id"] = .string(canonicalID(id)); values["note"] = .string(try projectedNote(record))
    for field in ["groupID", "parentID"] {
        if case .string(let value) = values[field], !isCanonicalID(value) { throw invalidSync() }
    }
    func string(_ field: String) throws -> String { guard case .string(let v) = values[field] else { throw invalidSync() }; return v }
    func number(_ value: JSONValue?) throws -> Double { guard case .number(let v) = value, v.isFinite else { throw invalidSync() }; return v }
    func identifier(_ field: String) throws -> UUID? { if values[field] == .null || values[field] == nil { return nil }; guard let id = UUID(uuidString: try string(field)) else { throw invalidSync() }; return id }
    func date(_ field: String) throws -> Date? { if values[field] == .null || values[field] == nil { return nil }; return Date(timeIntervalSinceReferenceDate: try number(values[field])) }
    guard case .object(let rawDay) = values["plannedDay"], let phase = TaskPhase(rawValue: try string("phase")) else { throw invalidSync() }
    func integer(_ value: JSONValue?) throws -> Int { let n = try number(value); guard n.rounded(.towardZero) == n, abs(n) <= Double(maximumCounter) else { throw invalidSync() }; return Int(n) }
    let day = try DayKey(year: integer(rawDay["year"]), month: integer(rawDay["month"]), day: integer(rawDay["day"]))
    var item = try TodoItem(id: id, title: string("title"), note: string("note"), plannedDay: day, groupID: identifier("groupID"), parentID: identifier("parentID"), order: integer(values["order"]), now: date("createdAt") ?? { throw invalidSync() }())
    guard let updatedAt = try date("updatedAt") else { throw invalidSync() }; item.updatedAt = updatedAt; item.phase = phase; item.startedAt = try date("startedAt"); item.completedAt = try date("completedAt")
    if case .bool(let explicit) = values["isProgressExplicit"] { item.isProgressExplicit = explicit }
    guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          item.order >= -9_007_199_254_740_991, item.order <= 9_007_199_254_740_991,
          item.createdAt.timeIntervalSinceReferenceDate.isFinite, item.updatedAt.timeIntervalSinceReferenceDate.isFinite,
          item.startedAt?.timeIntervalSinceReferenceDate.isFinite != false, item.completedAt?.timeIntervalSinceReferenceDate.isFinite != false else { throw invalidSync() }
    _ = try DayKey(year: item.plannedDay.year, month: item.plannedDay.month, day: item.plannedDay.day)
    return item
}

private func validateLifecycle(_ value: JSONValue) throws {
    guard case .object(let fields) = value,
          Set(fields.keys) == Set(["phase", "startedAt", "completedAt", "isProgressExplicit"]),
          case .string(let rawPhase) = fields["phase"], let phase = TaskPhase(rawValue: rawPhase),
          case .bool(let explicit) = fields["isProgressExplicit"] else { throw invalidSync() }
    func validDate(_ date: JSONValue?) -> Bool {
        if date == .null { return true }
        if case .number(let value) = date { return value.isFinite }
        return false
    }
    guard validDate(fields["startedAt"]), validDate(fields["completedAt"]) else { throw invalidSync() }
    switch phase {
    case .pending:
        guard fields["startedAt"] == .null, fields["completedAt"] == .null, !explicit else { throw invalidSync() }
    case .inProgress:
        guard fields["startedAt"] != .null, fields["completedAt"] == .null else { throw invalidSync() }
    case .completed:
        guard fields["completedAt"] != .null, !explicit else { throw invalidSync() }
    }
}

private func decodeGroup(id: UUID, record: SyncRecord) throws -> TaskGroup {
    var values = record.fields.mapValues(\.value)
    values.removeValue(forKey: "$alive"); values["id"] = .string(canonicalID(id))
    guard case .string(let name) = values["name"], case .string(let color) = values["colorHex"] else { throw invalidSync() }
    let group = TaskGroup(id: id, name: name, colorHex: color)
    guard !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, group.isValidColor else { throw invalidSync() }
    return group
}

extension SyncPayload {
    /// Partial operations become visible only after every create dependency in
    /// the logical batch is satisfied. The caller commits replica+projection.
    public func applyingV3(_ batch: SyncV3Batch, maximumOperations: Int = 20_000) throws -> Self {
        guard batch.version == 3, batch.operations.count <= maximumOperations else { throw SyncV3ApplyError.corrupt }
        if batch.type == "baseline" {
            guard batch.operations.isEmpty, let payload = batch.payload else { throw SyncV3ApplyError.corrupt }
            return try merging(payload)
        }
        guard batch.type == "batch", batch.payload == nil else { throw SyncV3ApplyError.corrupt }
        var next = try validated()
        for op in batch.operations {
            let (kind, _) = try parseRecordKey(op.recordKey)
            let allowed = kind == "task" ? taskFields.union(["$alive", "lifecycle"]) : groupFields.union(["$alive"])
            guard Set(op.fields.keys).isSubset(of: allowed), !op.fields.isEmpty || !op.notes.isEmpty,
                  kind == "task" || op.notes.isEmpty else { throw SyncV3ApplyError.corrupt }
            switch op.kind {
            case .patch: guard op.fields["$alive"] == nil else { throw SyncV3ApplyError.corrupt }
            case .delete: guard Set(op.fields.keys) == ["$alive"], op.fields["$alive"]?.value == .bool(false), op.notes.isEmpty else { throw SyncV3ApplyError.corrupt }
            case .create, .restore: guard Set(op.fields.keys) == allowed, op.fields["$alive"]?.value == .bool(true) else { throw SyncV3ApplyError.corrupt }
            }
            if next.records[op.recordKey] == nil, op.kind != .create, op.kind != .restore { throw SyncV3ApplyError.missingCreate(op.recordKey) }
            var record = next.records[op.recordKey] ?? SyncRecord()
            for (name, incoming) in op.fields {
                try validateStamp(incoming.stamp)
                next.seen[incoming.stamp.deviceID] = max(next.seen[incoming.stamp.deviceID] ?? 0, incoming.stamp.counter)
                if let current = record.fields[name] {
                    if current.stamp == incoming.stamp, current.value != incoming.value { throw SyncV3ApplyError.corrupt }
                    if current.stamp < incoming.stamp { record.fields[name] = incoming }
                } else { record.fields[name] = incoming }
            }
            for note in op.notes {
                try validateStamp(note.stamp); try validateVector(note.seen)
                guard note.seen.allSatisfy({ $0.value < note.stamp.counter }) else { throw SyncV3ApplyError.corrupt }
                next.seen[note.stamp.deviceID] = max(next.seen[note.stamp.deviceID] ?? 0, note.stamp.counter)
                for (actor, count) in note.seen { next.seen[actor] = max(next.seen[actor] ?? 0, count) }
            }
            record.notes = try mergedNotes(record.notes + op.notes)
            next.records[op.recordKey] = record
        }
        return try next.validated()
    }
}
