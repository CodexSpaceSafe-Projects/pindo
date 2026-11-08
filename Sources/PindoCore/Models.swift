import Foundation

public struct DayKey: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(_ date: Date = Date(), calendar: Calendar = .current) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        year = parts.year!; month = parts.month!; day = parts.day!
    }

    public init(year: Int, month: Int, day: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { throw PindoError.invalidDay }
        self.year = year; self.month = month; self.day = day
    }

    public func date(calendar: Calendar = .current) -> Date {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    public func adding(days: Int, calendar: Calendar = .current) -> DayKey {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return DayKey(gregorian.date(byAdding: .day, value: days, to: date(calendar: calendar))!, calendar: gregorian)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.description < rhs.description }
}

public enum TaskPhase: String, Codable, CaseIterable, Sendable {
    case pending, inProgress, completed

    public var next: Self {
        switch self {
        case .pending: return .inProgress
        case .inProgress: return .completed
        case .completed: return .pending
        }
    }
}

public enum TaskBatchAction: Sendable {
    case delete
    case setPhase(TaskPhase)
    case setGroup(UUID?)
}

public struct TodoItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var note: String
    public var plannedDay: DayKey
    public var groupID: UUID?
    public var phase: TaskPhase
    public var order: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var startedAt: Date?
    public var completedAt: Date?

    public init(id: UUID = UUID(), title: String, note: String = "", plannedDay: DayKey = DayKey(), groupID: UUID? = nil, order: Int = 0, now: Date = Date()) {
        self.id = id; self.title = title; self.note = note; self.plannedDay = plannedDay
        self.groupID = groupID; phase = .pending; self.order = order
        createdAt = now; updatedAt = now
    }

}

public struct TaskGroup: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public init(id: UUID = UUID(), name: String, colorHex: String) {
        self.id = id; self.name = name; self.colorHex = colorHex
    }
    public var isValidColor: Bool {
        colorHex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
    }
}

public struct HotkeyModifiers: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1)
    public static let option = Self(rawValue: 2)
    public static let control = Self(rawValue: 4)
    public static let shift = Self(rawValue: 8)
}

public struct HotkeyBinding: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var keyCode: UInt32
    public var modifiers: HotkeyModifiers
    public var keyLabel: String
    public init(enabled: Bool = true, keyCode: UInt32, modifiers: HotkeyModifiers, keyLabel: String) {
        self.enabled = enabled; self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel
    }
    public var display: String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "") +
        (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") + keyLabel
    }
    public func matches(_ other: Self) -> Bool { enabled && other.enabled && keyCode == other.keyCode && modifiers == other.modifiers }
    public var isValid: Bool {
        if !enabled { return true }
        if modifiers.intersection([.command, .option, .control]).isEmpty || keyCode >= 128 || keyLabel.isEmpty || (54...63).contains(keyCode) { return false }
        if modifiers.contains(.command), modifiers.intersection([.option, .control]).isEmpty,
           [0, 6, 7, 8, 9, 12, 13, 15, 17, 31, 35, 37, 45, 46, 48, 49].contains(keyCode) { return false }
        return true
    }
    public static let quickAdd = Self(keyCode: 49, modifiers: [.control, .option], keyLabel: "Space")
    public static let showList = Self(keyCode: 35, modifiers: [.control, .option], keyLabel: "P")
}

public enum Appearance: String, Codable, CaseIterable, Sendable { case system, light, dark }
public struct Preferences: Codable, Equatable, Sendable {
    public var appearance: Appearance = .system
    public var showTodayCount = true
    public var expandCompleted = false
    public var launchAtLogin = false
    public var defaultGroupID: UUID? = nil
    public var quickAddHotkey = HotkeyBinding.quickAdd
    public var listHotkey = HotkeyBinding.showList
    public init() {}
}

public struct PindoDocument: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var tasks: [TodoItem] = []
    public var groups: [TaskGroup] = [TaskGroup(name: "工作", colorHex: "#6D94C4"), TaskGroup(name: "生活", colorHex: "#C49A68")]
    public var preferences = Preferences()
    public init() {}

    public func validated() throws -> Self {
        guard schemaVersion == 1 else { throw PindoError.unsupportedVersion }
        guard Set(tasks.map(\.id)).count == tasks.count, Set(groups.map(\.id)).count == groups.count else { throw PindoError.invalidData("存在重复标识") }
        let groupIDs = Set(groups.map(\.id))
        if let id = preferences.defaultGroupID, !groupIDs.contains(id) { throw PindoError.invalidData("默认分组不存在") }
        for task in tasks {
            guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PindoError.emptyTitle }
            _ = try DayKey(year: task.plannedDay.year, month: task.plannedDay.month, day: task.plannedDay.day)
            if let id = task.groupID, !groupIDs.contains(id) { throw PindoError.invalidData("事项引用了不存在的分组") }
        }
        guard groups.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.isValidColor }),
              Set(groups.map(\.name)).count == groups.count else { throw PindoError.invalidData("分组名称或颜色无效") }
        guard preferences.quickAddHotkey.isValid, preferences.listHotkey.isValid,
              !preferences.quickAddHotkey.matches(preferences.listHotkey) else { throw PindoError.invalidHotkey }
        return self
    }

    public mutating func setPhase(_ phase: TaskPhase, for id: UUID, now: Date = Date()) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw PindoError.missingTask }
        setPhase(phase, at: index, now: now)
    }

    private mutating func setPhase(_ phase: TaskPhase, at index: Int, now: Date) {
        tasks[index].phase = phase; tasks[index].updatedAt = now
        tasks[index].completedAt = phase == .completed ? now : nil
        if phase == .inProgress && tasks[index].startedAt == nil { tasks[index].startedAt = now }
    }

    /// Applies a batch to explicit IDs. Unknown IDs are ignored; unchanged tasks keep their timestamps.
    @discardableResult public mutating func applyBatch(_ action: TaskBatchAction, to ids: Set<UUID>, now: Date = Date()) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        if case .setGroup(let id) = action, let id, !groups.contains(where: { $0.id == id }) {
            throw PindoError.invalidData("事项引用了不存在的分组")
        }
        var changed = 0
        switch action {
        case .delete:
            let before = tasks.count
            tasks.removeAll { ids.contains($0.id) }
            changed = before - tasks.count
        case .setPhase(let phase):
            for index in tasks.indices where ids.contains(tasks[index].id) && tasks[index].phase != phase {
                setPhase(phase, at: index, now: now)
                changed += 1
            }
        case .setGroup(let id):
            for index in tasks.indices where ids.contains(tasks[index].id) && tasks[index].groupID != id {
                tasks[index].groupID = id; tasks[index].updatedAt = now
                changed += 1
            }
        }
        return changed
    }

    public mutating func removeGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        if preferences.defaultGroupID == id { preferences.defaultGroupID = nil }
        for index in tasks.indices where tasks[index].groupID == id { tasks[index].groupID = nil }
    }

    public mutating func rollover(to day: DayKey, groupID: UUID? = nil, ungroupedOnly: Bool = false) {
        for index in tasks.indices where tasks[index].phase == .pending && tasks[index].plannedDay < day {
            if let groupID, tasks[index].groupID != groupID { continue }
            if ungroupedOnly && tasks[index].groupID != nil { continue }
            tasks[index].plannedDay = day
        }
    }
}

public enum PindoError: LocalizedError {
    case invalidDay, emptyTitle, missingTask, invalidHotkey, unsupportedVersion
    case invalidData(String), corruptFile(String), snapshotTooLarge, protectionSnapshotTooLarge, missingSnapshot, recoveryRequired
    public var errorDescription: String? {
        switch self {
        case .invalidDay: return "日期无效。"
        case .emptyTitle: return "请填写事项内容。"
        case .missingTask: return "找不到这条待办。"
        case .invalidHotkey: return "快捷键需要修饰键，且两个快捷键不能相同。"
        case .unsupportedVersion: return "资料来自不支持的版本，原文件已保留。"
        case .invalidData(let reason): return "资料无效：\(reason)。"
        case .corruptFile(let file): return "无法读取 \(file)，原文件已保留。"
        case .snapshotTooLarge: return "快照超过 30 MB 上限，当前资料仍会保存，旧备份已保留。"
        case .protectionSnapshotTooLarge: return "备份容量不足，无法保留操作前的保护快照。已取消替换，当前资料和原备份已保留。"
        case .missingSnapshot: return "这个快照已不存在，可能已达到上限被清理。"
        case .recoveryRequired: return "上次恢复尚未完成，请重试恢复或重新打开 Pindo。"
        }
    }
}
