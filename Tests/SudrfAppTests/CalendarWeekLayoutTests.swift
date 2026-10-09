import XCTest
@testable import SudrfApp

final class CalendarWeekLayoutTests: XCTestCase {
    private func hearing(_ number: String,
                         time: String,
                         court: String = "Сыктывкарский городской суд",
                         room: String = "каб. 605",
                         judge: String = "Колосова Н. Е.",
                         displayNumber: String? = nil,
                         secondaryLabel: String? = nil) -> CalendarWeekHearingLayoutInput {
        CalendarWeekHearingLayoutInput(id: number, caseNumber: number,
                                       displayCaseNumber: displayNumber,
                                       secondaryLabel: secondaryLabel,
                                       parties: "Иванов А. А. ⚔ ООО «Ромашка»",
                                       court: court, room: room, judge: judge,
                                       time: time)
    }

    func testDisplayCaseNumberPreservesRawNumberForNavigation() {
        let raw = "7У-1077/2024 [77-762/2024]"
        let blocks = CalendarWeekLayout.blocks(for: [
            hearing(raw, time: "09:30", displayNumber: "77-762/2024")
        ])

        XCTAssertEqual(blocks.first?.hearings.first?.caseNumber, raw)
        XCTAssertEqual(blocks.first?.hearings.first?.displayCaseNumber, "77-762/2024")
    }

    func testDisclosureContentKeyTracksHearingUpdatesAndRemoval() {
        let date = DateUtil.parse("21.10.2026")!
        let hearing = TrackedHearing(
            recordKey: "synthetic-disclosure", date: date, time: "11:00",
            caseNumber: "2-4461/2026", parties: "Сторона А · сторона Б",
            court: "OBLSUD--MO.SUDRF.RU", displayCourt: "Московский областной суд",
            room: "Зал 4", dateLabel: DateUtil.dateLabel(date), judge: "Судья А. А.",
            identitySuffix: "appeal", instanceCaseNumber: "33-42895/2026",
            instanceLevel: .appeal)
        let original = CalendarWeekLayout.disclosureContentKey(for: [hearing])
        XCTAssertEqual(original, CalendarWeekLayout.disclosureContentKey(for: [hearing]))

        var updated = hearing
        updated.room = "Зал 5"
        XCTAssertNotEqual(original, CalendarWeekLayout.disclosureContentKey(for: [updated]))
        XCTAssertNotEqual(original, CalendarWeekLayout.disclosureContentKey(for: []))
    }

    func testMaterialCaptionSurvivesWeekLayout() {
        let blocks = CalendarWeekLayout.blocks(for: [
            hearing("2-8236/2025", time: "09:30",
                    secondaryLabel: "Материал № 13-2471/2026")
        ])

        XCTAssertEqual(blocks.first?.hearings.first?.caseNumber, "2-8236/2025")
        XCTAssertEqual(blocks.first?.hearings.first?.secondaryLabel,
                       "Материал № 13-2471/2026")
    }

    func testNormalHearingHasNoSecondaryCaption() {
        let blocks = CalendarWeekLayout.blocks(for: [hearing("2-8236/2025", time: "09:30")])

        XCTAssertNil(blocks.first?.hearings.first?.secondaryLabel)
    }

    func testSingleHearingUsesGridSlotAndCompactCardHeight() {
        let blocks = CalendarWeekLayout.blocks(for: [
            hearing("2-1/2026", time: "09:30")
        ])

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .single)
        XCTAssertEqual(blocks[0].startMinutes, 9 * 60 + 30)
        XCTAssertEqual(blocks[0].top, 180)
        XCTAssertEqual(blocks[0].height, 120)
        XCTAssertEqual(blocks[0].cardHeight, 36)
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

    func testCompactGroupsKeepJudgeFieldsForDisclosure() {
        let blocks = CalendarWeekLayout.blocks(for: [
            hearing("5-1/2026", time: "09:30"),
            hearing("5-2/2026", time: "09:30")
        ])

        guard let block = blocks.first else { return XCTFail("Expected a grouped block") }
        XCTAssertEqual(block.kind, .stack)
        XCTAssertEqual(block.height, 120) // reserve the one-hour timeline interval
        XCTAssertEqual(block.cardHeight, 76) // badge + two compact rows
        XCTAssertEqual(block.hearings.map(\.judge), ["Колосова Н. Е.", "Колосова Н. Е."])
    }

    func testGroupedJudgeLabelsPreserveFollowingHourPosition() {
        let blocks = CalendarWeekLayout.blocks(for: [
            hearing("5-1/2026", time: "09:00"),
            hearing("5-2/2026", time: "09:00"),
            hearing("5-3/2026", time: "10:00")
        ])

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].height, 120)
        XCTAssertLessThanOrEqual(blocks[0].top + blocks[0].height, blocks[1].top)
        XCTAssertEqual(blocks[1].top, 240)
    }

    func testGroupedRowsWithoutJudgeKeepCompactHeight() {
        let blocks = CalendarWeekLayout.blocks(for: [
            hearing("5-1/2026", time: "09:30", judge: ""),
            hearing("5-2/2026", time: "09:30", judge: "")
        ])

        guard let block = blocks.first else { return XCTFail("Expected a grouped block") }
        XCTAssertEqual(block.cardHeight, 76) // compact rows remain a fixed height
        XCTAssertTrue(block.hearings.allSatisfy { $0.judge.isEmpty })
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

    func testConflictRowsKeepTheirOwnDisclosureFields() {
        let blocks = CalendarWeekLayout.blocks(for: [
            hearing("5-1/2026", time: "12:00",
                    court: "Сыктывкарский городской суд", room: "каб. 605", judge: "Иванов И. И."),
            hearing("А29-1/2026", time: "12:30",
                    court: "Арбитражный суд Республики Коми", room: "зал 2", judge: "Петров П. П.")
        ])

        guard let block = blocks.first else { return XCTFail("Expected a conflict block") }
        XCTAssertEqual(block.hearings.map { "\($0.displayCourtLabel) · \($0.room) · \($0.judge)" }, [
            "Сыктывкарский городской суд · каб. 605 · Иванов И. И.",
            "Арбитражный суд Республики Коми · зал 2 · Петров П. П."
        ])
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

    /// Compact card geometry must fit inside the one-hour time interval so its
    /// text and hit target never spill into the next block.
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
        XCTAssertEqual(blocks[1].kind, .conflict)
        XCTAssertEqual(blocks[1].height, 120)
        XCTAssertEqual(blocks[1].cardHeight, 92)
        XCTAssertLessThan(blocks[1].top + blocks[1].height, gridHeight)
    }

    func testIssue337CompactConflictAndMaterialCardsDoNotOverlap() {
        let blocks = CalendarWeekLayout.blocks(for: [
            hearing("1-146/2026", time: "11:00", court: "Московский областной суд"),
            hearing("66а-757/2026", time: "11:00", court: "Верховный суд Республики Коми"),
            hearing("2-9143/2025", time: "12:00", court: "Сыктывкарский городской суд",
                    secondaryLabel: "Материал № 13-3241/2026")
        ])

        XCTAssertEqual(blocks.count, 2)
        let conflict = blocks[0]
        let material = blocks[1]
        XCTAssertEqual(conflict.kind, .conflict)
        XCTAssertEqual(Set(conflict.hearings.map(\.caseNumber)),
                       Set(["1-146/2026", "66а-757/2026"]))
        XCTAssertEqual(material.startMinutes, 12 * 60)
        XCTAssertEqual(material.hearings.first?.secondaryLabel, "Материал № 13-3241/2026")
        XCTAssertEqual(conflict.top, 3 * CalendarWeekLayout.hourHeight)
        XCTAssertEqual(material.top, 4 * CalendarWeekLayout.hourHeight)
        XCTAssertLessThanOrEqual(conflict.top + conflict.cardHeight, material.top)
        XCTAssertLessThanOrEqual(conflict.top + conflict.height, material.top)
        XCTAssertLessThanOrEqual(conflict.cardHeight, CalendarWeekLayout.hourHeight)

    }

    func testDenseConflictPreservesAllHearingsWithoutOverlappingNextHour() {
        let numbers = ["33-1234567890/2026", "33-1002/2026", "33-1003/2026",
                       "33-1004/2026", "33-1005/2026"]
        let group = numbers.enumerated().map { index, number in
            hearing(number, time: "11:00",
                    court: index.isMultiple(of: 2)
                        ? "Московский областной суд" : "Верховный суд Республики Коми")
        }
        let blocks = CalendarWeekLayout.blocks(for: group + [
            hearing("13-3241/2026", time: "12:00")
        ])
        XCTAssertEqual(blocks.count, 2)
        let conflict = blocks[0]
        XCTAssertEqual(conflict.kind, .conflict)
        XCTAssertEqual(Set(conflict.hearings.map(\.caseNumber)), Set(numbers))
        XCTAssertEqual(conflict.hearings.count, 5)
        XCTAssertEqual(conflict.cardHeight, 119)
        XCTAssertLessThanOrEqual(conflict.top + conflict.cardHeight, blocks[1].top)
        XCTAssertLessThanOrEqual(conflict.top + conflict.height, blocks[1].top)
    }

    func testWeekTitleWithinMonthIncludesItsOwnYear() {
        let start = DateUtil.parse("03.08.2026")!
        XCTAssertEqual(DateUtil.weekTitle(starting: start), "3 – 9 августа 2026")
    }

    func testWeekTitleAcrossMonthBoundary() {
        let start = DateUtil.parse("29.06.2026")!
        XCTAssertEqual(DateUtil.weekTitle(starting: start), "29 июня – 5 июля 2026")
    }

    func testWeekTitleAcrossYearBoundary() {
        let start = DateUtil.parse("29.12.2025")!
        XCTAssertEqual(DateUtil.weekTitle(starting: start), "29 декабря 2025 – 4 января 2026")
    }
}
