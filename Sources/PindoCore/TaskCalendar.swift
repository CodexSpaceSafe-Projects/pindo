import Foundation

public struct DayTaskCount: Equatable, Sendable {
    public var unfinished = 0
    public var completed = 0
    public init() {}

    public static func grouped(_ tasks: [TodoItem]) -> [DayKey: DayTaskCount] {
        var result: [DayKey: DayTaskCount] = [:]
        for task in tasks {
            if task.phase == .completed { result[task.plannedDay, default: DayTaskCount()].completed += 1 }
            else { result[task.plannedDay, default: DayTaskCount()].unfinished += 1 }
        }
        return result
    }
}

public enum CalendarMonth {
    /// Six complete weeks, Monday first, including adjacent months.
    public static func days(containing day: DayKey, calendar: Calendar = .current) -> [DayKey] {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let first = try! DayKey(year: day.year, month: day.month, day: 1)
        let offset = (gregorian.component(.weekday, from: first.date(calendar: gregorian)) + 5) % 7
        return (0..<42).map { first.adding(days: $0 - offset, calendar: gregorian) }
    }

    public static func shifting(_ day: DayKey, months: Int) -> DayKey {
        let first = try! DayKey(year: day.year, month: day.month, day: 1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return DayKey(calendar.date(byAdding: .month, value: months, to: first.date(calendar: calendar))!, calendar: calendar)
    }
}
