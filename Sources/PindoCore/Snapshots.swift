import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

public enum DocumentCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }
}

private struct SnapshotPayload: Codable {
    var tasks: [String: TodoItem]
    var taskOrder: [UUID]
    var groups: [String: TaskGroup]
    var groupOrder: [UUID]
    var preferences: Preferences

    init(_ document: PindoDocument) {
        tasks = Dictionary(uniqueKeysWithValues: document.tasks.map { ($0.id.uuidString, $0) })
        groups = Dictionary(uniqueKeysWithValues: document.groups.map { ($0.id.uuidString, $0) })
        taskOrder = document.tasks.map(\.id); groupOrder = document.groups.map(\.id)
        preferences = document.preferences
    }
    func document() throws -> PindoDocument {
        guard Set(taskOrder.map(\.uuidString)) == Set(tasks.keys), taskOrder.count == tasks.count,
              Set(groupOrder.map(\.uuidString)) == Set(groups.keys), groupOrder.count == groups.count,
              tasks.allSatisfy({ $0.key == $0.value.id.uuidString }),
              groups.allSatisfy({ $0.key == $0.value.id.uuidString }) else { throw PindoError.invalidData("快照顺序不完整") }
        var result = PindoDocument()
        result.tasks = taskOrder.compactMap { tasks[$0.uuidString] }
        result.groups = groupOrder.compactMap { groups[$0.uuidString] }
        result.preferences = preferences
        return try result.validated()
    }
}

public extension PindoDocument {
    func snapshotValue() throws -> JSONValue { try DocumentCodec.decode(JSONValue.self, from: DocumentCodec.encode(SnapshotPayload(self))) }
    static func fromSnapshot(_ value: JSONValue) throws -> Self {
        try DocumentCodec.decode(SnapshotPayload.self, from: DocumentCodec.encode(value)).document()
    }
}

public enum JSONPatch: Codable, Equatable, Sendable {
    case value(path: [String], before: JSONValue?, after: JSONValue?)
    case text(path: [String], prefix: Int, removed: String, inserted: String)

    public static func diff(_ before: JSONValue, _ after: JSONValue, path: [String] = []) -> [JSONPatch] {
        guard before != after else { return [] }
        if case .object(let a) = before, case .object(let b) = after {
            return Set(a.keys).union(b.keys).sorted().flatMap { key -> [JSONPatch] in
                if let av = a[key], let bv = b[key] { return diff(av, bv, path: path + [key]) }
                return [.value(path: path + [key], before: a[key], after: b[key])]
            }
        }
        if case .string(let a) = before, case .string(let b) = after {
            let av = Array(a), bv = Array(b)
            var prefix = 0, suffix = 0
            while prefix < min(av.count, bv.count), av[prefix] == bv[prefix] { prefix += 1 }
            while suffix < min(av.count - prefix, bv.count - prefix), av[av.count - 1 - suffix] == bv[bv.count - 1 - suffix] { suffix += 1 }
            return [.text(path: path, prefix: prefix, removed: String(av[prefix..<(av.count - suffix)]), inserted: String(bv[prefix..<(bv.count - suffix)]))]
        }
        return [.value(path: path, before: before, after: after)]
    }

    public static func applying(_ patches: [JSONPatch], to value: JSONValue, forward: Bool = true) throws -> JSONValue {
        var result = value
        for patch in (forward ? patches : patches.reversed()) { result = try apply(patch, to: result, forward: forward) }
        return result
    }

    private static func apply(_ patch: JSONPatch, to root: JSONValue, forward: Bool) throws -> JSONValue {
        let path: [String]
        switch patch { case .value(let p, _, _): path = p; case .text(let p, _, _, _): path = p }
        func modify(_ current: JSONValue?, depth: Int) throws -> JSONValue? {
            if depth == path.count {
                switch patch {
                case .value(_, let before, let after):
                    guard current == (forward ? before : after) else { throw PindoError.invalidData("快照校验失败") }
                    return forward ? after : before
                case .text(_, let prefix, let removed, let inserted):
                    guard case .string(let text) = current else { throw PindoError.invalidData("快照文本无效") }
                    let a = Array(text), from = Array(forward ? removed : inserted), to = forward ? inserted : removed
                    guard prefix >= 0, prefix <= a.count, from.count <= a.count - prefix,
                          Array(a[prefix..<(prefix + from.count)]) == from else { throw PindoError.invalidData("快照文本校验失败") }
                    return .string(String(a[..<prefix]) + to + String(a[(prefix + from.count)...]))
                }
            }
            guard case .object(var object) = current else { throw PindoError.invalidData("快照路径无效") }
            object[path[depth]] = try modify(object[path[depth]], depth: depth + 1)
            return .object(object)
        }
        guard let result = try modify(root, depth: 0) else { throw PindoError.invalidData("缺少快照根节点") }
        return result
    }
}

public struct SnapshotRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var label: String
    public init(id: UUID = UUID(), date: Date, label: String) { self.id = id; self.date = date; self.label = label }
}
public struct SnapshotEntry: Codable, Equatable, Sendable {
    public var record: SnapshotRecord
    public var patches: [JSONPatch]
}
public struct SnapshotArchive: Codable, Equatable, Sendable {
    public static let maximumBytes = 30_000_000
    public static let maximumCount = 100
    public static let interval: TimeInterval = 30
    public var version = 1
    public var baseline: JSONValue
    public var baselineRecord: SnapshotRecord
    public var entries: [SnapshotEntry] = []

    public init(document: PindoDocument, now: Date = Date()) throws {
        baseline = try document.snapshotValue()
        baselineRecord = SnapshotRecord(date: now, label: "保留范围的起点")
    }
    public var records: [SnapshotRecord] { [baselineRecord] + entries.map(\.record) }
    public var count: Int { entries.count + 1 }
    public func state(at id: UUID? = nil) throws -> JSONValue {
        var value = baseline
        if id == baselineRecord.id { return value }
        for entry in entries {
            value = try JSONPatch.applying(entry.patches, to: value)
            if id == entry.record.id { return value }
        }
        if id != nil { throw PindoError.missingSnapshot }
        return value
    }
    public mutating func append(_ document: PindoDocument, label: String, now: Date = Date(), maximumBytes: Int = Self.maximumBytes, maximumCount: Int = Self.maximumCount) throws -> Bool {
        let patches = JSONPatch.diff(try state(), try document.snapshotValue())
        guard !patches.isEmpty else { return false }
        var candidate = self
        candidate.entries.append(SnapshotEntry(record: SnapshotRecord(date: now, label: label), patches: patches))
        try candidate.compact(maximumBytes: maximumBytes, maximumCount: maximumCount)
        self = candidate
        return true
    }
    public mutating func compact(maximumBytes: Int = Self.maximumBytes, maximumCount: Int = Self.maximumCount) throws {
        guard maximumCount > 0, maximumBytes > 0 else { throw PindoError.snapshotTooLarge }
        var next = self
        while true {
            let bytes = try DocumentCodec.encode(next).count
            guard next.count > maximumCount || bytes > maximumBytes else { break }
            guard let first = next.entries.first else { throw PindoError.snapshotTooLarge }
            next.baseline = try JSONPatch.applying(first.patches, to: next.baseline)
            next.baselineRecord = first.record
            next.entries.removeFirst()
        }
        self = next
    }
    public func validated() throws -> Self {
        guard version == 1, count <= Self.maximumCount,
              Set(records.map(\.id)).count == count,
              try DocumentCodec.encode(self).count <= Self.maximumBytes else { throw PindoError.invalidData("备份格式或容量无效") }
        _ = try PindoDocument.fromSnapshot(baseline)
        var value = baseline
        for entry in entries { value = try JSONPatch.applying(entry.patches, to: value); _ = try PindoDocument.fromSnapshot(value) }
        return self
    }
}
