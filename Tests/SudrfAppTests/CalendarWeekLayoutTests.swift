import XCTest
@testable import SudrfApp

final class CalendarWeekLayoutTests: XCTestCase {
    private func hearing(_ number: String,
                         time: String,
                         court: String = "Сыктывкарский городской суд",
                         room: String = "каб. 605",
                         judge: String = "Колосова Н. Е.") -> CalendarWeekHearingLayoutInput {
        CalendarWeekHearingLayoutInput(id: number, caseNumber: number,
                                       parties: "Иванов А. А. ⚔ ООО «Ромашка»",
                                       court: court, room: room, judge: judge,
                                       time: time)
    }

    func testSingleHearingUsesGridPositionAndMinimumHeight() {
        let blocks = CalendarWeekLayout.blocks(for: [
            hearing("2-1/2026", time: "09:30")
        ])

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .single)
        XCTAssertEqual(blocks[0].startMinutes, 9 * 60 + 30)
        XCTAssertEqual(blocks[0].top, 180)
        XCTAssertEqual(blocks[0].height, 120)
    }

    func testNonOverlappingHearingsRemainSeparate() {
        let blocks = CalendarWeekLayout.blocks(for: [
            hearing("2-1/2026", time: "09:00"),
            hearing("2-2/2026", time: "10:00")
        ])

        XCTAssertEqual(blocks.map(\.kind), [.single, .single])
        XCTAssertEqual(blocks.map { $0.hearings.first?.caseNumber }, ["2-1/2026", "2-2/2026"])
    }

    func testSameStartSameCourtBecomesQueueStack() {
        let blocks = CalendarWeekLayout.blocks(for: [
            hearing("5-1/2026", time: "09:30"),
            hearing("5-2/2026", time: "09:30"),
            hearing("5-3/2026", time: "09:30")
        ])

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .stack)
        XCTAssertEqual(blocks[0].badge, "3 ДЕЛА · ПО ОЧЕРЕДИ")
    }

    func testOverlappingSameCourtDifferentStartBecomesOverlapStack() {
        let blocks = CalendarWeekLayout.blocks(for: [
            hearing("5-1/2026", time: "12:00"),
            hearing("5-2/2026", time: "12:30")
        ])

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .stack)
        XCTAssertEqual(blocks[0].badge, "2 ДЕЛА · НАКЛАДКА")
    }

    func testOverlappingDifferentCourtsBecomesConflict() {
        let blocks = CalendarWeekLayout.blocks(for: [
            hearing("5-1/2026", time: "12:00",
                    court: "Сыктывкарский городской суд"),
            hearing("А29-1/2026", time: "12:30",
                    court: "Арбитражный суд Республики Коми")
        ])

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .conflict)
        XCTAssertEqual(blocks[0].badge, "⚠ РАЗНЫЕ СУДЫ")
    }

    func testInvalidTimeIsIgnoredByTimedLayout() {
        let blocks = CalendarWeekLayout.blocks(for: [
            hearing("2-1/2026", time: "")
        ])

        XCTAssertTrue(blocks.isEmpty)
    }

    func testWeekTitleAcrossMonthBoundary() {
        let start = DateUtil.parse("29.06.2026")!
        XCTAssertEqual(DateUtil.weekTitle(starting: start), "29 июня – 5 июля")
    }
}
