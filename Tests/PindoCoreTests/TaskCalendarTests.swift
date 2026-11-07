import XCTest
@testable import PindoCore

final class TaskCalendarTests: XCTestCase {
    func testCalendarCoversLeapMonthAndYearBoundaryInCompleteMondayWeeks() throws {
        let february = try DayKey(year: 2024, month: 2, day: 29)
        let days = CalendarMonth.days(containing: february)
        XCTAssertEqual(days.count, 42)
        XCTAssertEqual(Set(days).count, 42)
        XCTAssertEqual(days.first, try DayKey(year: 2024, month: 1, day: 29))
        XCTAssertTrue(days.contains(february))
        XCTAssertEqual(CalendarMonth.shifting(try DayKey(year: 2026, month: 12, day: 31), months: 1), try DayKey(year: 2027, month: 1, day: 1))
        XCTAssertEqual(CalendarMonth.shifting(february, months: -1), try DayKey(year: 2024, month: 1, day: 1))
    }

    func testMonthDaysRemainConsecutiveAcrossDaylightSavingChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let days = CalendarMonth.days(containing: try DayKey(year: 2026, month: 3, day: 8), calendar: calendar)
        for pair in zip(days, days.dropFirst()) { XCTAssertEqual(pair.0.adding(days: 1, calendar: calendar), pair.1) }
        XCTAssertEqual(calendar.component(.weekday, from: days[0].date(calendar: calendar)), 2)
    }

    func testCountsIncludeAllStatesOnceOnTheirPlannedDate() throws {
        let day = try DayKey(year: 2026, month: 11, day: 7)
        var tasks = (0..<4).map { TodoItem(title: "\($0)", plannedDay: day) }
        tasks[1].phase = .inProgress
        tasks[2].phase = .completed
        tasks[3].plannedDay = day.adding(days: 1)
        let counts = DayTaskCount.grouped(tasks)
        XCTAssertEqual(counts[day]?.unfinished, 2)
        XCTAssertEqual(counts[day]?.completed, 1)
        XCTAssertEqual(counts[day.adding(days: 1)]?.unfinished, 1)
        XCTAssertEqual(counts.count, 2)
    }
}
