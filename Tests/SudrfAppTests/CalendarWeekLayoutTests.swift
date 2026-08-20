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
        XCTAssertLessThanOrEqual(blocks[0].top + blocks[0].height, blocks[1].top)
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

    func testIsWithinWindowAcceptsOnlyGridStartTimes() {
        XCTAssertFalse(CalendarWeekLayout.isWithinWindow("07:30"))
        XCTAssertTrue(CalendarWeekLayout.isWithinWindow("09:30"))
        XCTAssertFalse(CalendarWeekLayout.isWithinWindow("19:00"))
        XCTAssertFalse(CalendarWeekLayout.isWithinWindow("20:00"))
    }

    func testGridHeightExpandsForLateBlock() {
        let blocks = CalendarWeekLayout.blocks(for: [
            hearing("2-1/2026", time: "18:30")
        ])

        XCTAssertEqual(CalendarWeekLayout.baseGridHeight, 1320)
        XCTAssertEqual(CalendarWeekLayout.gridHeight(for: [blocks]), 1380)
    }

    /// Контракт, на который опирается вид (#83): блок 10:00 заканчивается ровно
    /// там, где начинается следующий, и `height` — это высота слота, которую
    /// карточка берёт за нижнюю границу. Сам баг жил в SwiftUI-геометрии
    /// `weekSingleCard` и этим тестом не ловится — здесь закреплены только
    /// входные данные вида.
    func testAdjacentBlocksMeetExactlyAtHourBoundary() {
        let blocks = CalendarWeekLayout.blocks(for: [
            hearing("2-3685/2026", time: "10:00"),
            hearing("2-1/2026", time: "11:00", court: "Сыктывкарский городской суд"),
            hearing("12-1/2026", time: "11:00", court: "Верховный суд Республики Коми")
        ])
        let gridHeight = CalendarWeekLayout.gridHeight(for: [blocks])

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].kind, .single)
        XCTAssertEqual(blocks[0].height, 120)
        XCTAssertEqual(blocks[0].top + blocks[0].height, blocks[1].top)
        XCTAssertLessThan(blocks[0].top + blocks[0].height, gridHeight)
        // Конфликтная группа получает высоту по числу заседаний, а не по остатку дня.
        XCTAssertEqual(blocks[1].kind, .conflict)
        XCTAssertEqual(blocks[1].height, 228)   // 2 × 66 + 96
        XCTAssertLessThan(blocks[1].top + blocks[1].height, gridHeight)
    }

    func testWeekTitleAcrossMonthBoundary() {
        let start = DateUtil.parse("29.06.2026")!
        XCTAssertEqual(DateUtil.weekTitle(starting: start), "29 июня – 5 июля")
    }

    func testWeekTitleAcrossYearBoundary() {
        let start = DateUtil.parse("29.12.2025")!
        XCTAssertEqual(DateUtil.weekTitle(starting: start), "29 декабря 2025 – 4 января 2026")
    }
}
