import Foundation

public struct SyncV3Operation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case create, patch, delete, restore }
    public var recordKey: String
    public var kind: Kind
    public var fields: [String: SyncRegister]
    public var notes: [SyncNote]
    public init(recordKey: String, kind: Kind, fields: [String: SyncRegister], notes: [SyncNote] = []) {
        self.recordKey = recordKey; self.kind = kind; self.fields = fields; self.notes = notes
    }
}
public struct SyncV3Batch: Codable, Equatable, Sendable {
    public var version = 3
    public var type = "batch"
    public var operations: [SyncV3Operation]
    public var payload: SyncPayload?
    public init(operations: [SyncV3Operation]) { self.operations = operations }
    public init(baseline: SyncPayload) { type = "baseline"; operations = []; payload = baseline }
}
public enum SyncV3ApplyError: Error { case missingCreate(String), corrupt, capacity }

public enum SyncV3Delta {
    public static func capture(before: PindoDocument, after: PindoDocument, actor: String, clock: Int64,
                               known: Set<String>, notes: (String) throws -> [SyncNote]) throws -> SyncV3Batch {
        try SyncV3.validateID(actor); try SyncV3.validateCounter(clock)
        guard clock > 0 else { throw SyncV3ApplyError.corrupt }
        let stamp = SyncStamp(counter: clock, deviceID: actor)
        let oldTasks = Dictionary(uniqueKeysWithValues: before.tasks.map { ($0.id, $0) })
        let newTasks = Dictionary(uniqueKeysWithValues: after.tasks.map { ($0.id, $0) })
        let oldGroups = Dictionary(uniqueKeysWithValues: before.groups.map { ($0.id, $0) })
        let newGroups = Dictionary(uniqueKeysWithValues: after.groups.map { ($0.id, $0) })
        var operations: [SyncV3Operation] = []
        func registers(_ values: [String: JSONValue], _ old: [String: JSONValue]) -> [String: SyncRegister] {
            values.filter { old[$0.key] != $0.value }.mapValues { SyncRegister(value: $0, stamp: stamp) }
        }
        for id in Set(oldGroups.keys).union(newGroups.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
            let key = "group:\(id.uuidString.lowercased())"
            guard oldGroups[id] != newGroups[id] else { continue }
            if let group = newGroups[id] {
                let values: [String: JSONValue] = ["name": .string(group.name), "colorHex": .string(group.colorHex)]
                let old = oldGroups[id].map { ["name": JSONValue.string($0.name), "colorHex": .string($0.colorHex)] } ?? [:]
                var fields = registers(values, old)
                if oldGroups[id] == nil { fields["$alive"] = SyncRegister(value: .bool(true), stamp: stamp) }
                operations.append(.init(recordKey: key, kind: oldGroups[id] == nil ? (known.contains(key) ? .restore : .create) : .patch, fields: fields))
            } else { operations.append(.init(recordKey: key, kind: .delete, fields: ["$alive": .init(value: .bool(false), stamp: stamp)])) }
        }
        for id in Set(oldTasks.keys).union(newTasks.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
            let key = "task:\(id.uuidString.lowercased())"
            guard oldTasks[id] != newTasks[id] else { continue }
            if let item = newTasks[id] {
                let values = taskFields(item), previous = oldTasks[id].map(taskFields) ?? [:]
                var fields = registers(values, previous)
                if oldTasks[id] == nil { fields["$alive"] = .init(value: .bool(true), stamp: stamp) }
                if fields["lifecycle"] != nil, case .object(let event) = values["lifecycle"] {
                    for name in ["phase", "startedAt", "completedAt"] { fields[name] = .init(value: event[name]!, stamp: stamp) }
                }
                var versions: [SyncNote] = []
                if oldTasks[id]?.note != item.note {
                    // Only notes actually observed in this record, including their
                    // retained causal context. Global field clocks are excluded.
                    var seen: [String: Int64] = [:]
                    for note in try notes(key) {
                        seen[note.stamp.deviceID] = max(seen[note.stamp.deviceID] ?? 0, note.stamp.counter)
                        for (actor, value) in note.seen { seen[actor] = max(seen[actor] ?? 0, value) }
                    }
                    versions = [.init(value: item.note, stamp: stamp, seen: seen)]
                }
                operations.append(.init(recordKey: key, kind: oldTasks[id] == nil ? (known.contains(key) ? .restore : .create) : .patch, fields: fields, notes: versions))
            } else { operations.append(.init(recordKey: key, kind: .delete, fields: ["$alive": .init(value: .bool(false), stamp: stamp)])) }
        }
        guard operations.count <= 20_000 else { throw SyncV3ApplyError.capacity }
        return .init(operations: operations)
    }
    private static func taskFields(_ t: TodoItem) -> [String: JSONValue] {
        func identifier(_ value: UUID?) -> JSONValue { value.map { .string($0.uuidString.lowercased()) } ?? .null }
        func date(_ value: Date?) -> JSONValue { value.map { .number($0.timeIntervalSinceReferenceDate) } ?? .null }
        let lifecycle: JSONValue = .object(["phase": .string(t.phase.rawValue), "startedAt": date(t.startedAt),
            "completedAt": date(t.completedAt), "isProgressExplicit": .bool(t.isProgressExplicit ?? (t.phase == .inProgress))])
        return ["title": .string(t.title), "plannedDay": .object(["year": .number(Double(t.plannedDay.year)), "month": .number(Double(t.plannedDay.month)), "day": .number(Double(t.plannedDay.day))]),
            "groupID": identifier(t.groupID), "parentID": identifier(t.parentID), "phase": .string(t.phase.rawValue), "order": .number(Double(t.order)),
            "createdAt": date(t.createdAt), "updatedAt": date(t.updatedAt), "startedAt": date(t.startedAt), "completedAt": date(t.completedAt), "lifecycle": lifecycle]
    }
}
