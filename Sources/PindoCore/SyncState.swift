import Foundation

/// The v1 wire format deliberately uses Foundation's reference-date seconds
/// (2001-01-01 UTC), matching existing TodoItem JSON. UUID strings are lowercase.
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
    public init(version: Int = 1, seen: [String: Int64] = [:], records: [String: SyncRecord] = [:]) {
        self.version = version; self.seen = seen; self.records = records
    }

    public func validated() throws -> Self {
        guard version == 1 || version == 2 else { throw PindoError.unsupportedVersion }
        guard records.count <= 200_000 else { throw invalidSync() }
        try validateVector(seen)
        var activeTasks = 0, activeGroups = 0
        for (key, record) in records {
            let (kind, id) = try parseRecordKey(key)
            let allowed = kind == "task" ? taskFields.union(version == 2 ? ["$alive", "lifecycle"] : ["$alive"]) : groupFields.union(["$alive"])
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
                if version == 2 {
                    let lifecycle = record.fields["lifecycle"]!
                    try validateLifecycle(lifecycle.value)
                    if case .object(let event) = lifecycle.value {
                        for field in ["phase", "startedAt", "completedAt"] where record.fields[field]!.stamp == lifecycle.stamp {
                            guard record.fields[field]!.value == event[field] else { throw invalidSync() }
                        }
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
                if version == 2 { _ = try decodeTask(id: id, record: record, version: version) }
            } else {
                guard record.notes.isEmpty else { throw invalidSync() }
                _ = try decodeGroup(id: id, record: record)
            }
        }
        return self
    }

    public func merging(_ other: Self) throws -> Self {
        _ = try validated(); _ = try other.validated()
        if version != other.version { return try upgraded().merging(other.upgraded()) }
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
                    if field == "lifecycle", version == 2 {
                        record.fields[field] = try mergeLifecycle(current, value)
                        continue
                    }
                    if current.stamp == value.stamp, current.value != value.value { throw invalidSync() }
                    if current.stamp < value.stamp { record.fields[field] = value }
                } else { record.fields[field] = value }
            }
            record.notes = try mergedNotes(record.notes + incoming.notes)
            result.records[key] = record
        }
        return try result.validated()
    }

    /// Legacy registers retain their original provenance. The null lifecycle is
    /// bottom, not a fabricated event assembled from independent old fields.
    public func upgraded() throws -> Self {
        _ = try validated()
        guard version == 1 else { return self }
        var next = self
        next.version = 2
        for key in next.records.keys where key.hasPrefix("task:") {
            next.records[key]!.fields["lifecycle"] = SyncRegister(value: .null, stamp: next.records[key]!.fields["phase"]!.stamp)
        }
        return try next.validated()
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
            if kind == "task" { tasks.append(try decodeTask(id: id, record: record, version: version)) }
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
            if version == 2 {
                let indices = children[tasks[i].id] ?? []
                let explicit = tasks[i].phase == .inProgress && tasks[i].isProgressExplicit == true
                let phase: TaskPhase
                if indices.isEmpty { phase = tasks[i].phase == .inProgress && !explicit ? .pending : tasks[i].phase }
                else if indices.allSatisfy({ tasks[$0].phase == .completed }) { phase = .completed }
                else if explicit || indices.contains(where: { tasks[$0].phase != .pending }) { phase = .inProgress }
                else { phase = .pending }
                if phase != tasks[i].phase {
                    let date = max(tasks[i].updatedAt, indices.map { tasks[$0].updatedAt }.max() ?? tasks[i].updatedAt)
                    tasks[i].phase = phase; tasks[i].updatedAt = date
                    tasks[i].completedAt = phase == .completed ? date : nil
                    if phase == .inProgress && tasks[i].startedAt == nil { tasks[i].startedAt = date }
                }
                tasks[i].isProgressExplicit = phase == .inProgress && explicit
                if phase == .pending { tasks[i].startedAt = nil; tasks[i].completedAt = nil }
                if phase == .inProgress { tasks[i].completedAt = nil; tasks[i].startedAt = tasks[i].startedAt ?? tasks[i].updatedAt }
                if phase == .completed { tasks[i].completedAt = tasks[i].completedAt ?? tasks[i].updatedAt }
                continue
            }
            guard let indices = children[tasks[i].id], !indices.isEmpty else { continue }
            let phase: TaskPhase
            if indices.allSatisfy({ tasks[$0].phase == .completed }) { phase = .completed }
            else if indices.contains(where: { tasks[$0].phase != .pending }) { phase = .inProgress }
            else { phase = tasks[i].phase == .completed ? .pending : tasks[i].phase }
            if phase != tasks[i].phase {
                let date = max(tasks[i].updatedAt, indices.map { tasks[$0].updatedAt }.max()!)
                tasks[i].phase = phase; tasks[i].updatedAt = date
                tasks[i].completedAt = phase == .completed ? date : nil
                if phase == .inProgress && tasks[i].startedAt == nil { tasks[i].startedAt = date }
            }
        }
        tasks.sort {
            if $0.order != $1.order { return $0.order < $1.order }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return canonicalID($0.id) < canonicalID($1.id)
        }
        return (tasks, groups)
    }
}

/// Persisted beside the current tasks in the same atomic data.json replacement.
/// Baselines reflect the last captured/projected document, not the last upload.
public struct SyncReplica: Codable, Equatable, Sendable {
    public var payload: SyncPayload
    public var deviceID: String
    public var clock: Int64
    public var baselineTasks: [TodoItem]
    public var baselineGroups: [TaskGroup]

    public init(deviceID: UUID = UUID(), version: Int = 1) {
        payload = SyncPayload(version: version); self.deviceID = canonicalID(deviceID); clock = 0
        baselineTasks = []; baselineGroups = []
    }

    public func validated() throws -> Self {
        guard isCanonicalID(deviceID), clock >= 0, clock <= maximumCounter,
              clock == (payload.seen.values.max() ?? 0) else { throw invalidSync() }
        _ = try payload.validated()
        var baseline = PindoDocument()
        baseline.tasks = baselineTasks; baseline.groups = baselineGroups
        _ = try baseline.validated()
        return self
    }

    public func upgraded() throws -> Self {
        if payload.version == 2 { _ = try validated(); return self }
        var next = self
        next.payload = try payload.upgraded()
        for index in next.baselineTasks.indices {
            next.baselineTasks[index].isProgressExplicit = next.baselineTasks[index].phase == .inProgress
        }
        _ = try next.validated()
        return next
    }

    /// A process epoch owns only future stamps. Old causal history is immutable.
    public mutating func rotateActor(_ id: UUID = UUID()) throws {
        _ = try validated()
        let actor = canonicalID(id)
        guard actor == deviceID || payload.seen[actor] == nil else { throw invalidSync() }
        deviceID = actor
    }

    /// Capture actual field differences, including mutations which do not change
    /// TodoItem.updatedAt. Metadata and document are subsequently saved together.
    public mutating func capture(tasks: [TodoItem], groups: [TaskGroup]) throws {
        _ = try validated()
        var input = PindoDocument(); input.tasks = tasks; input.groups = groups
        _ = try input.validated()
        let beforeTasks = Dictionary(uniqueKeysWithValues: baselineTasks.map { ($0.id, $0) })
        let afterTasks = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let beforeGroups = Dictionary(uniqueKeysWithValues: baselineGroups.map { ($0.id, $0) })
        let afterGroups = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        guard beforeTasks != afterTasks || beforeGroups != afterGroups else {
            baselineTasks = tasks; baselineGroups = groups; return
        }
        guard clock < maximumCounter else { throw invalidSync() }
        let context = payload.seen
        clock += 1
        let stamp = SyncStamp(counter: clock, deviceID: deviceID)
        payload.seen[deviceID] = clock
        for id in Set(beforeTasks.keys).union(afterTasks.keys).sorted(by: { canonicalID($0) < canonicalID($1) }) {
            let key = "task:\(canonicalID(id))"
            if let item = afterTasks[id] {
                let old = beforeTasks[id]
                guard old != item else { continue }
                let values = try taskValues(item), previous = try old.map(taskValues) ?? [:]
                var record = payload.records[key] ?? SyncRecord()
                for field in taskFields where values[field] != previous[field] || record.fields[field] == nil {
                    record.fields[field] = SyncRegister(value: values[field]!, stamp: stamp)
                }
                if payload.version == 2 {
                    let lifecycle = lifecycleValue(item)
                    if old.map(lifecycleValue) != lifecycle || record.fields["lifecycle"] == nil {
                        record.fields["lifecycle"] = SyncRegister(value: lifecycle, stamp: stamp)
                        for field in ["phase", "startedAt", "completedAt"] {
                            if case .object(let fields) = lifecycle { record.fields[field] = SyncRegister(value: fields[field]!, stamp: stamp) }
                        }
                    }
                }
                if old == nil { record.fields["$alive"] = SyncRegister(value: .bool(true), stamp: stamp) }
                if old?.note != item.note || record.notes.isEmpty {
                    record.notes = [SyncNote(value: item.note, stamp: stamp, seen: context)]
                }
                payload.records[key] = record
            } else if var record = payload.records[key] {
                record.fields["$alive"] = SyncRegister(value: .bool(false), stamp: stamp)
                payload.records[key] = record
            }
        }
        for id in Set(beforeGroups.keys).union(afterGroups.keys).sorted(by: { canonicalID($0) < canonicalID($1) }) {
            let key = "group:\(canonicalID(id))"
            if let group = afterGroups[id] {
                let old = beforeGroups[id]
                guard old != group else { continue }
                let values = try groupValues(group), previous = try old.map(groupValues) ?? [:]
                var record = payload.records[key] ?? SyncRecord()
                for field in groupFields where values[field] != previous[field] || record.fields[field] == nil {
                    record.fields[field] = SyncRegister(value: values[field]!, stamp: stamp)
                }
                if old == nil { record.fields["$alive"] = SyncRegister(value: .bool(true), stamp: stamp) }
                payload.records[key] = record
            } else if var record = payload.records[key] {
                record.fields["$alive"] = SyncRegister(value: .bool(false), stamp: stamp)
                payload.records[key] = record
            }
        }
        baselineTasks = tasks; baselineGroups = groups
        _ = try validated()
    }

    public mutating func merge(_ incoming: SyncPayload) throws -> (tasks: [TodoItem], groups: [TaskGroup]) {
        let previousPayload = payload
        let previousTasks = Dictionary(uniqueKeysWithValues: baselineTasks.map { ($0.id, $0) })
        payload = try payload.merging(incoming)
        clock = payload.seen.values.max() ?? 0
        var projection = try payload.projected()
        for index in projection.tasks.indices {
            let task = projection.tasks[index], key = "task:\(canonicalID(task.id))"
            // v1 不传输本机的进度来源标记；状态版本未变时，保留现有标记。
            if payload.version == 1, let previous = previousTasks[task.id], task.phase == .inProgress,
               previous.phase == task.phase, previous.startedAt == task.startedAt,
               previousPayload.records[key]?.fields["phase"] == payload.records[key]?.fields["phase"] {
                projection.tasks[index].isProgressExplicit = previous.isProgressExplicit
            }
        }
        baselineTasks = projection.tasks; baselineGroups = projection.groups
        return projection
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
private func taskValues(_ task: TodoItem) throws -> [String: JSONValue] {
    guard case .object(var values) = try DocumentCodec.decode(JSONValue.self, from: DocumentCodec.encode(task)) else { throw invalidSync() }
    values.removeValue(forKey: "id"); values.removeValue(forKey: "note")
    for field in ["groupID", "parentID", "startedAt", "completedAt"] where values[field] == nil { values[field] = .null }
    if let id = task.groupID { values["groupID"] = .string(canonicalID(id)) }
    if let id = task.parentID { values["parentID"] = .string(canonicalID(id)) }
    return values
}
private func groupValues(_ group: TaskGroup) throws -> [String: JSONValue] {
    guard case .object(var values) = try DocumentCodec.decode(JSONValue.self, from: DocumentCodec.encode(group)) else { throw invalidSync() }
    values.removeValue(forKey: "id")
    return values
}
private func decodeTask(id: UUID, record: SyncRecord, version: Int = 1) throws -> TodoItem {
    var values = record.fields.mapValues(\.value)
    values.removeValue(forKey: "$alive")
    values.removeValue(forKey: "lifecycle")
    if version == 2 {
        let lifecycle = record.fields["lifecycle"]!
        if case .object(let event) = lifecycle.value, lifecycle.stamp >= record.fields["phase"]!.stamp {
            for (field, value) in event { values[field] = value }
        } else {
            let phase = values["phase"]!
            values["isProgressExplicit"] = .bool(phase == .string(TaskPhase.inProgress.rawValue))
            if phase == .string(TaskPhase.pending.rawValue) { values["startedAt"] = .null; values["completedAt"] = .null }
            if phase == .string(TaskPhase.inProgress.rawValue) {
                if values["startedAt"] == .null { values["startedAt"] = values["updatedAt"] }
                values["completedAt"] = .null
            }
            if phase == .string(TaskPhase.completed.rawValue), values["completedAt"] == .null { values["completedAt"] = values["updatedAt"] }
        }
    }
    values["id"] = .string(canonicalID(id)); values["note"] = .string(try projectedNote(record))
    for field in ["groupID", "parentID"] {
        if case .string(let value) = values[field], !isCanonicalID(value) { throw invalidSync() }
    }
    let item = try DocumentCodec.decode(TodoItem.self, from: DocumentCodec.encode(JSONValue.object(values)))
    guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          item.order >= -9_007_199_254_740_991, item.order <= 9_007_199_254_740_991,
          item.createdAt.timeIntervalSinceReferenceDate.isFinite, item.updatedAt.timeIntervalSinceReferenceDate.isFinite,
          item.startedAt?.timeIntervalSinceReferenceDate.isFinite != false, item.completedAt?.timeIntervalSinceReferenceDate.isFinite != false else { throw invalidSync() }
    _ = try DayKey(year: item.plannedDay.year, month: item.plannedDay.month, day: item.plannedDay.day)
    return item
}

private func lifecycleValue(_ task: TodoItem) -> JSONValue {
    let started: JSONValue, completed: JSONValue
    switch task.phase {
    case .pending: started = .null; completed = .null
    case .inProgress: started = .number((task.startedAt ?? task.updatedAt).timeIntervalSinceReferenceDate); completed = .null
    case .completed:
        started = task.startedAt.map { .number($0.timeIntervalSinceReferenceDate) } ?? .null
        completed = .number((task.completedAt ?? task.updatedAt).timeIntervalSinceReferenceDate)
    }
    return .object(["phase": .string(task.phase.rawValue), "startedAt": started, "completedAt": completed,
                    "isProgressExplicit": .bool(task.phase == .inProgress && task.isProgressExplicit != false)])
}

private func validateLifecycle(_ value: JSONValue) throws {
    if value == .null { return }
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

private func mergeLifecycle(_ current: SyncRegister, _ incoming: SyncRegister) throws -> SyncRegister {
    if current.value == .null, incoming.value != .null { return incoming }
    if incoming.value == .null, current.value != .null { return current }
    if current.stamp == incoming.stamp, current.value != incoming.value { throw invalidSync() }
    return current.stamp < incoming.stamp ? incoming : current
}
private func decodeGroup(id: UUID, record: SyncRecord) throws -> TaskGroup {
    var values = record.fields.mapValues(\.value)
    values.removeValue(forKey: "$alive"); values["id"] = .string(canonicalID(id))
    let group = try DocumentCodec.decode(TaskGroup.self, from: DocumentCodec.encode(JSONValue.object(values)))
    guard !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, group.isValidColor else { throw invalidSync() }
    return group
}
