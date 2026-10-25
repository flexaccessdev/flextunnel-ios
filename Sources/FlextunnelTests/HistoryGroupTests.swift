import XCTest
@testable import Flextunnel

final class HistoryGroupTests: XCTestCase {
    private let calendar = Calendar.current
    /// Mid-afternoon, so "an hour ago" is still today.
    private lazy var now: Date = calendar.date(
        bySettingHour: 15, minute: 0, second: 0, of: Date())!

    func testBucketsByDayNewestFirst() {
        let entries = [
            entry("today", hoursAgo: 1),
            entry("yesterday", daysAgo: 1),
            entry("this week", daysAgo: 6),
            entry("older", daysAgo: 30),
        ]

        let groups = HistoryGroup.grouping(entries, now: now)

        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday", "Last 7 Days", "Older"])
        XCTAssertEqual(groups.map { $0.entries.map(\.title) }, [["today"], ["yesterday"], ["this week"], ["older"]])
    }

    func testDayBoundaries() {
        let startOfToday = calendar.startOfDay(for: now)
        let entries = [
            HistoryEntry(title: "midnight", url: url, lastVisited: startOfToday),
            HistoryEntry(title: "just before", url: url, lastVisited: startOfToday.addingTimeInterval(-1)),
            HistoryEntry(title: "seven days", url: url,
                         lastVisited: calendar.date(byAdding: .day, value: -7, to: startOfToday)!),
            HistoryEntry(title: "past seven", url: url,
                         lastVisited: calendar.date(byAdding: .day, value: -7, to: startOfToday)!.addingTimeInterval(-1)),
        ]

        let groups = HistoryGroup.grouping(entries, now: now)

        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday", "Last 7 Days", "Older"])
        XCTAssertEqual(groups.map { $0.entries.map(\.title) },
                       [["midnight"], ["just before"], ["seven days"], ["past seven"]])
    }

    func testDropsEmptyBucketsAndKeepsOrderWithinOne() {
        let entries = [entry("first", hoursAgo: 1), entry("second", hoursAgo: 2), entry("old", daysAgo: 40)]

        let groups = HistoryGroup.grouping(entries, now: now)

        XCTAssertEqual(groups.map(\.title), ["Today", "Older"])
        XCTAssertEqual(groups.first?.entries.map(\.title), ["first", "second"])
    }

    func testNoEntriesNoGroups() {
        XCTAssertTrue(HistoryGroup.grouping([], now: now).isEmpty)
    }

    // MARK: - Helpers

    private let url = URL(string: "https://wiki.corp.example/")!

    private func entry(_ title: String, hoursAgo: Int = 0, daysAgo: Int = 0) -> HistoryEntry {
        var date = calendar.date(byAdding: .hour, value: -hoursAgo, to: now)!
        date = calendar.date(byAdding: .day, value: -daysAgo, to: date)!
        return HistoryEntry(title: title, url: url, lastVisited: date)
    }
}
