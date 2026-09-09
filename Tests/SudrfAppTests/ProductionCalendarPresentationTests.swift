import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class ProductionCalendarPresentationTests: XCTestCase {
    private func calendar(overriding date: LegalCalendarDate,
                          with day: LegalCalendarDay) throws -> LegalCalendar {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let count = try XCTUnwrap(utc.range(of: .day, in: .year, for: start)?.count)
        let days = (0..<count).compactMap { offset -> LegalCalendarDay? in
            guard let value = utc.date(byAdding: .day, value: offset, to: start),
                  let key = LegalCalendarDate(date: value, timeZone: utc.timeZone) else { return nil }
            return key == date ? day : LegalCalendarDay(date: key, kind: .working)
        }
        let source = LegalCalendarSource(id: "calendar-2026", title: "К+ · производственный календарь 2026",
                                         url: try XCTUnwrap(URL(string: "https://example.test/calendar/2026")),
                                         sha256: String(repeating: "0", count: 64))
        let reason = LegalCalendarReason(id: "transfer", title: "Перенос выходного дня",
                                         sourceIDs: [source.id], note: "Проверенный перенос")
        let archive = LegalCalendarArchive(
            sources: [source], reasons: [reason],
            revisions: [LegalCalendarYearRevision(
                year: 2026, revision: 1,
                verifiedOn: try XCTUnwrap(LegalCalendarDate(year: 2026, month: 1, day: 1)),
                sourceIDs: [source.id], calendarSourceID: source.id,
                sourceHash: String(repeating: "0", count: 64), days: days)])
        return try LegalCalendar(archive: archive)
    }

    func testTransferredWorkingShortDayIsVisibleAndAccessible() throws {
        let date = try XCTUnwrap(LegalCalendarDate(year: 2026, month: 2, day: 21))
        let calendar = try calendar(overriding: date, with: LegalCalendarDay(
            date: date, kind: .transferredWorkingDay, isShortened: true,
            reasonIDs: ["transfer"]))

        let presentation = ProductionCalendarDayPresentation(
            date: DateUtil.parse("21.02.2026")!, calendar: calendar, timeZone: DateUtil.cal.timeZone)

        XCTAssertEqual(presentation.symbol, "↺½")
        XCTAssertEqual(presentation.title, "Рабочий день по переносу · сокращённый")
        XCTAssertFalse(presentation.isNonWorking)
        XCTAssertTrue(presentation.accessibilityLabel.contains("сокращённый"))
    }

    func testHolidayExposesReasonAndItsSourceInDayDetails() throws {
        let date = try XCTUnwrap(LegalCalendarDate(year: 2026, month: 5, day: 1))
        let calendar = try calendar(overriding: date, with: LegalCalendarDay(
            date: date, kind: .holiday, reasonIDs: ["transfer"]))

        let presentation = ProductionCalendarDayPresentation(
            date: DateUtil.parse("01.05.2026")!, calendar: calendar, timeZone: DateUtil.cal.timeZone)

        XCTAssertEqual(presentation.symbol, "✦")
        XCTAssertEqual(presentation.title, "Нерабочий праздничный день")
        XCTAssertTrue(presentation.isNonWorking)
        XCTAssertEqual(presentation.reasons.map(\.title), ["Перенос выходного дня"])
        XCTAssertEqual(presentation.sources.map(\.title), ["К+ · производственный календарь 2026"])
    }

    func testWorkingDayUsesOnlyTheCalendarSourceForItsYear() throws {
        let date = try XCTUnwrap(LegalCalendarDate(year: 2026, month: 4, day: 14))
        let calendar = try calendar(overriding: date, with: LegalCalendarDay(date: date, kind: .working))

        let presentation = ProductionCalendarDayPresentation(
            date: DateUtil.parse("14.04.2026")!, calendar: calendar, timeZone: DateUtil.cal.timeZone)

        XCTAssertTrue(presentation.reasons.isEmpty)
        XCTAssertEqual(presentation.sources.map(\.id), ["calendar-2026"])
    }

    func testWeekendUsesOnlyTheCalendarSourceForItsYear() throws {
        let date = try XCTUnwrap(LegalCalendarDate(year: 2026, month: 4, day: 11))
        let calendar = try calendar(overriding: date, with: LegalCalendarDay(
            date: date, kind: .weekend, reasonIDs: ["transfer"]))

        let presentation = ProductionCalendarDayPresentation(
            date: DateUtil.parse("11.04.2026")!, calendar: calendar, timeZone: DateUtil.cal.timeZone)

        XCTAssertEqual(presentation.sources.map(\.id), ["calendar-2026"])
    }

    func testMissingCoverageDoesNotInventWeekendRule() {
        let presentation = ProductionCalendarDayPresentation(
            date: DateUtil.parse("01.01.2012")!, calendar: nil, timeZone: DateUtil.cal.timeZone)

        XCTAssertNil(presentation.kind)
        XCTAssertEqual(presentation.title, "Производственный календарь не подтверждён")
        XCTAssertFalse(presentation.isNonWorking)
        XCTAssertTrue(presentation.reasons.isEmpty)
    }
}
