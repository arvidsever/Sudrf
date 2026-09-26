import XCTest
@testable import SudrfApp

final class CalendarMonthLayoutTests: XCTestCase {
    private let day = DateUtil.parse("08.09.2026")!
    private let otherDay = DateUtil.parse("09.09.2026")!

    private func hearing(_ id: String, date: Date? = nil, time: String,
                         caseNumber: String? = nil,
                         courtKey: String = "A", courtShort: String = "Суд А") -> CalendarMonthHearingInput {
        CalendarMonthHearingInput(id: id, date: date ?? day, time: time,
                                  caseNumber: caseNumber ?? id,
                                  courtKey: courtKey, courtShort: courtShort)
    }

    // MARK: - Overlaps

    func testNearestPartnersAcrossTwoCourts() {
        let hearings = [
            hearing("h1", time: "14:00", courtKey: "A", courtShort: "Суд А"),
            hearing("h2", time: "14:15", courtKey: "B", courtShort: "Суд Б"),
            hearing("h3", time: "14:20", courtKey: "A", courtShort: "Суд А"),
            hearing("h4", time: "14:30", courtKey: "A", courtShort: "Суд А")
        ]
        let overlaps = CalendarMonthLayout.overlaps(hearings)

        XCTAssertEqual(overlaps["h1"]?.otherID, "h2")
        XCTAssertEqual(overlaps["h1"]?.deltaMinutes, 15)
        XCTAssertEqual(overlaps["h2"]?.otherID, "h3")
        XCTAssertEqual(overlaps["h2"]?.deltaMinutes, 5)
        XCTAssertEqual(overlaps["h3"]?.otherID, "h2")
        XCTAssertEqual(overlaps["h3"]?.deltaMinutes, 5)
        XCTAssertEqual(overlaps["h4"]?.otherID, "h2")
        XCTAssertEqual(overlaps["h4"]?.deltaMinutes, 15)
    }

    func testSameCourtSimultaneousIsNeverOverlap() {
        let hearings = [
            hearing("h1", time: "10:00", courtKey: "A"),
            hearing("h2", time: "10:00", courtKey: "A")
        ]
        XCTAssertTrue(CalendarMonthLayout.overlaps(hearings).isEmpty)
    }

    func test59MinutesIsOverlapAnd60IsNot() {
        let hearings59 = [
            hearing("h1", time: "10:00", courtKey: "A"),
            hearing("h2", time: "10:59", courtKey: "B")
        ]
        let overlaps59 = CalendarMonthLayout.overlaps(hearings59)
        XCTAssertEqual(overlaps59["h1"]?.otherID, "h2")
        XCTAssertEqual(overlaps59["h1"]?.deltaMinutes, 59)

        let hearings60 = [
            hearing("h1", time: "10:00", courtKey: "A"),
            hearing("h2", time: "11:00", courtKey: "B")
        ]
        XCTAssertTrue(CalendarMonthLayout.overlaps(hearings60).isEmpty)
    }

    func testUnparsedTimeExcludedFromOverlaps() {
        let hearings = [
            hearing("h1", time: "—", courtKey: "A"),
            hearing("h2", time: "10:00", courtKey: "B")
        ]
        XCTAssertTrue(CalendarMonthLayout.overlaps(hearings).isEmpty)
    }

    func testDifferentDaysSameTimeNoOverlap() {
        let hearings = [
            hearing("h1", date: day, time: "10:00", courtKey: "A"),
            hearing("h2", date: otherDay, time: "10:00", courtKey: "B")
        ]
        XCTAssertTrue(CalendarMonthLayout.overlaps(hearings).isEmpty)
    }

    func testSeveralOverlapsInADay() {
        let hearings = [
            hearing("h1", time: "09:00", courtKey: "A"),
            hearing("h2", time: "09:10", courtKey: "B"),
            hearing("h3", time: "15:00", courtKey: "A"),
            hearing("h4", time: "15:20", courtKey: "B")
        ]
        let overlaps = CalendarMonthLayout.overlaps(hearings)
        XCTAssertEqual(overlaps.count, 4)
        XCTAssertEqual(overlaps["h1"]?.otherID, "h2")
        XCTAssertEqual(overlaps["h3"]?.otherID, "h4")
    }

    func testOverlapDaysCount() {
        let hearings = [
            hearing("h1", date: day, time: "09:00", courtKey: "A"),
            hearing("h2", date: day, time: "09:10", courtKey: "B"),
            hearing("h3", date: otherDay, time: "12:00", courtKey: "A")
        ]
        let days = CalendarMonthLayout.overlapDays(hearings)
        XCTAssertEqual(days, [DateUtil.startOfDay(day)])
    }

    func testNextOverlapDayAtOrAfterToday() {
        let d1 = DateUtil.startOfDay(day)
        let d2 = DateUtil.startOfDay(otherDay)
        let days = [d1, d2]

        XCTAssertEqual(CalendarMonthLayout.nextOverlapDay(after: DateUtil.addDays(day, -1), in: days), d1)
        XCTAssertEqual(CalendarMonthLayout.nextOverlapDay(after: day, in: days), d1)
        XCTAssertEqual(CalendarMonthLayout.nextOverlapDay(after: otherDay, in: days), d2)
    }

    func testNextOverlapDayWrapsAroundWhenNoneLeft() {
        let d1 = DateUtil.startOfDay(day)
        let afterAll = DateUtil.addDays(otherDay, 5)

        XCTAssertEqual(CalendarMonthLayout.nextOverlapDay(after: afterAll, in: [d1]), d1)
        XCTAssertNil(CalendarMonthLayout.nextOverlapDay(after: day, in: []))
    }

    // MARK: - Series

    func testTwoHearingsSeriesAbsent() {
        let hearings = [
            hearing("h1", date: day, time: "10:00", caseNumber: "2-1/2026"),
            hearing("h2", date: otherDay, time: "10:00", caseNumber: "2-1/2026")
        ]
        XCTAssertTrue(CalendarMonthLayout.seriesPositions(hearings).isEmpty)
    }

    func testThreeHearingsSeriesOrderedByDateAndTime() {
        let thirdDay = DateUtil.addDays(day, 2)
        let hearings = [
            hearing("h3", date: thirdDay, time: "09:00", caseNumber: "2-1/2026"),
            hearing("h1", date: day, time: "10:00", caseNumber: "2-1/2026"),
            hearing("h2", date: day, time: "11:00", caseNumber: "2-1/2026")
        ]
        let positions = CalendarMonthLayout.seriesPositions(hearings)

        XCTAssertEqual(positions["h1"]?.index, 1)
        XCTAssertEqual(positions["h1"]?.total, 3)
        XCTAssertEqual(positions["h2"]?.index, 2)
        XCTAssertEqual(positions["h3"]?.index, 3)
    }

    // MARK: - Cell layout

    func testZeroItems() {
        let layout = CalendarMonthLayout.cellLayout(itemCount: 0, availableHeight: 100)
        XCTAssertEqual(layout, CalendarMonthCellLayout(mode: .twoLine, visibleCount: 0, hiddenCount: 0))
    }

    func testFewItemsFitTwoLine() {
        let layout = CalendarMonthLayout.cellLayout(itemCount: 2, availableHeight: 106)
        XCTAssertEqual(layout.mode, .twoLine)
        XCTAssertEqual(layout.visibleCount, 2)
        XCTAssertEqual(layout.hiddenCount, 0)
    }

    func testMoreItemsFitOneLine() {
        // 4 items one-line: 4*20 + 3*3 = 89, doesn't fit two-line (4*36+3*3=153)
        let layout = CalendarMonthLayout.cellLayout(itemCount: 4, availableHeight: 90)
        XCTAssertEqual(layout.mode, .oneLine)
        XCTAssertEqual(layout.visibleCount, 4)
        XCTAssertEqual(layout.hiddenCount, 0)
    }

    func testManyItemsUseMoreRow() {
        let layout = CalendarMonthLayout.cellLayout(itemCount: 10, availableHeight: 80)
        XCTAssertEqual(layout.mode, .oneLineWithMore)
        XCTAssertGreaterThanOrEqual(layout.hiddenCount, 1)
        XCTAssertEqual(layout.visibleCount + layout.hiddenCount, 10)
    }

    func testNegativeOrZeroHeightGivesAllHidden() {
        let zero = CalendarMonthLayout.cellLayout(itemCount: 5, availableHeight: 0)
        XCTAssertEqual(zero.mode, .oneLineWithMore)
        XCTAssertEqual(zero.visibleCount, 0)
        XCTAssertEqual(zero.hiddenCount, 5)

        let negative = CalendarMonthLayout.cellLayout(itemCount: 5, availableHeight: -20)
        XCTAssertEqual(negative.mode, .oneLineWithMore)
        XCTAssertEqual(negative.visibleCount, 0)
        XCTAssertEqual(negative.hiddenCount, 5)
    }

    func testCellLayoutInvariantSweep() {
        for count in 0...12 {
            var height = 0.0
            while height <= 300 {
                let layout = CalendarMonthLayout.cellLayout(itemCount: count, availableHeight: height)
                XCTAssertEqual(layout.visibleCount + layout.hiddenCount, count,
                               "count=\(count) height=\(height)")
                if layout.mode == .oneLineWithMore && count > 0 {
                    XCTAssertGreaterThanOrEqual(layout.hiddenCount, 1,
                                                 "count=\(count) height=\(height)")
                }
                if layout.visibleCount > 0 || layout.mode != .oneLineWithMore {
                    let perItem = layout.mode == .twoLine
                        ? CalendarMonthLayout.twoLineHeight
                        : CalendarMonthLayout.oneLineHeight
                    let renderedHeight = Double(layout.visibleCount) * perItem
                        + Double(max(0, layout.visibleCount - 1)) * CalendarMonthLayout.itemSpacing
                        + (layout.hiddenCount > 0
                           ? CalendarMonthLayout.moreHeight + CalendarMonthLayout.itemSpacing
                           : 0)
                    if height > 0 {
                        XCTAssertLessThanOrEqual(renderedHeight, height + 0.001,
                                                  "count=\(count) height=\(height)")
                    }
                }
                height += 7
            }
        }
    }

    // MARK: - Sort key

    func testSortKeyDeadlinesBeforeHearingsAndUnparsedTimeLast() {
        let deadline = CalendarMonthLayout.sortKey(isDeadline: true, time: "23:00")
        let hearing09 = CalendarMonthLayout.sortKey(isDeadline: false, time: "09:00")
        let hearingUnparsed = CalendarMonthLayout.sortKey(isDeadline: false, time: "—")

        XCTAssertTrue(deadline < hearing09)
        XCTAssertTrue(hearing09 < hearingUnparsed)
    }
}
