import Foundation
import XCTest
@testable import SudrfKit

final class LegalCalendarTests: XCTestCase {
    func testPackagedArchiveCoversEveryDateFrom2013Through2026() throws {
        let calendar = try LegalCalendar.load()
        XCTAssertEqual(calendar.archive.revisions.map(\.year).sorted(), Array(2013...2026))
        XCTAssertEqual(calendar.archive.revisions.reduce(0) { $0 + $1.days.count }, 5_113)

        for year in 2013...2026 {
            let revision = try XCTUnwrap(calendar.revision(for: year))
            XCTAssertEqual(revision.calendarSourceID, "consultant-calendar-\(year)")
            XCTAssertEqual(revision.days.filter { $0.kind == .holiday }.count, 14,
                           "Every article 112 holiday keeps its legal kind in \(year)")
        }
    }

    func testAnnualAndAutomaticTransferReasonsStayDistinct() throws {
        let calendar = try LegalCalendar.load()
        XCTAssertEqual(calendar.day(on: date(2013, 2, 25))?.kind, .working)
        XCTAssertEqual(calendar.day(on: date(2013, 2, 25))?.reasonIDs, ["transfer-2013"])
        XCTAssertEqual(calendar.day(on: date(2014, 2, 24))?.reasonIDs,
                       ["transfer-2014", "transferred-shortened"])
        XCTAssertEqual(calendar.day(on: date(2026, 1, 9))?.reasonIDs, ["transfer-2026"])
        XCTAssertEqual(calendar.day(on: date(2026, 3, 9))?.reasonIDs, ["tk-112-transfer"])
        XCTAssertEqual(calendar.day(on: date(2024, 4, 27))?.kind, .transferredWorkingDay)
        XCTAssertFalse(try XCTUnwrap(calendar.day(on: date(2024, 4, 27))).isShortened)
    }

    func testSpecialDaysUseAuditedCodeSpecificPolicyAndOtherwiseFailClosed() throws {
        let calendar = try LegalCalendar.load()
        for day in [date(2020, 4, 1), date(2020, 5, 6),
                    date(2021, 5, 4), date(2021, 11, 3)] {
            XCTAssertEqual(calendar.day(on: day)?.kind, .specialNonWorking)
            XCTAssertEqual(calendar.day(on: day)?.proceduralStatus(for: "GPK"), .working)
            XCTAssertEqual(calendar.day(on: day)?.proceduralStatus(for: "KAS"), .working)
            XCTAssertEqual(calendar.day(on: day)?.proceduralStatus(for: "UPK"), .working)
            XCTAssertEqual(calendar.day(on: day)?.proceduralStatus(for: "KOAP"), .unknown)
        }
        XCTAssertEqual(calendar.day(on: date(2020, 6, 24))?.proceduralStatus(for: "GPK"),
                       .unknown)
        XCTAssertEqual(calendar.day(on: date(2020, 7, 1))?.proceduralStatus(for: "UPK"),
                       .unknown)
    }

    func testWorkingDayArithmeticStartsOnFollowingDayAndCrossesYears() throws {
        let calendar = try LegalCalendar.load()
        let may = try XCTUnwrap(calendar.addingWorkingDays(
            5, to: date(2026, 4, 27), forCode: "GPK"))
        XCTAssertEqual(may.date, date(2026, 5, 5))
        XCTAssertEqual(may.trace.countedWorkingDays, 5)
        XCTAssertEqual(may.trace.revisions.map(\.year), [2026])

        let january = try XCTUnwrap(calendar.addingWorkingDays(
            2, to: date(2025, 12, 30), forCode: "KAS"))
        XCTAssertEqual(january.date, date(2026, 1, 13))
        XCTAssertEqual(january.trace.revisions.map(\.year), [2025, 2026])
        XCTAssertTrue(january.trace.skipped.contains(date(2026, 1, 9)))
        XCTAssertNil(calendar.addingWorkingDays(
            1, to: date(2026, 12, 30), forCode: "GPK"))
        XCTAssertNil(calendar.movingToNextWorkingDay(
            date(2026, 12, 31), forCode: "GPK"))
        XCTAssertNil(calendar.movingToNextWorkingDay(
            date(2012, 12, 31), forCode: "GPK"))
    }

    func testEndDateMovesAcrossHolidaysButKeepsWorkingSaturday() throws {
        let calendar = try LegalCalendar.load()
        XCTAssertEqual(calendar.movingToNextWorkingDay(
            date(2026, 1, 1), forCode: "GPK")?.date, date(2026, 1, 12))
        XCTAssertEqual(calendar.movingToNextWorkingDay(
            date(2024, 4, 27), forCode: "GPK")?.date, date(2024, 4, 27))
        XCTAssertNil(calendar.movingToNextWorkingDay(
            date(2020, 6, 24), forCode: "GPK"))
        XCTAssertNil(calendar.addingWorkingDays(
            1, to: date(2020, 3, 31), forCode: "KOAP"))
    }

    func testDateConversionRequiresExplicitTimeZone() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T21:30:00Z"))
        XCTAssertEqual(LegalCalendarDate(date: instant, timeZone: .gmt), date(2026, 1, 1))
        XCTAssertEqual(LegalCalendarDate(date: instant, timeZone: LegalCalendar.federalTimeZone),
                       date(2026, 1, 2))
    }

    func testSelectedRevisionReplaysOldCalculationAfterNewRevisionIsAdded() throws {
        let first = revision(year: 2026, revision: 1, hash: String(repeating: "a", count: 64),
                             override: (date(2026, 1, 12), .weekend))
        let second = revision(year: 2026, revision: 2, hash: String(repeating: "b", count: 64))
        let archive = LegalCalendarArchive(sources: [source], reasons: [],
                                           revisions: [first, second])
        let latest = try LegalCalendar(archive: archive)
        let replay = try LegalCalendar(archive: archive, selecting: [first.reference])
        XCTAssertEqual(latest.movingToNextWorkingDay(
            date(2026, 1, 12), forCode: "GPK")?.date, date(2026, 1, 12))
        XCTAssertEqual(replay.movingToNextWorkingDay(
            date(2026, 1, 12), forCode: "GPK")?.date, date(2026, 1, 13))
    }

    func testArchiveRejectsDuplicateSelectionAndInvalidUnselectedRevision() throws {
        let valid = revision(year: 2026, revision: 1, hash: String(repeating: "a", count: 64))
        let archive = LegalCalendarArchive(sources: [source], reasons: [], revisions: [valid])
        XCTAssertThrowsError(try LegalCalendar(
            archive: archive, selecting: [valid.reference, valid.reference])) {
            XCTAssertEqual($0 as? LegalCalendarError,
                           .invalidArchive("повторяющиеся выбранные редакции"))
        }

        let invalidDate = try JSONDecoder().decode(
            LegalCalendarDate.self, from: Data(#"{"year":2026,"month":2,"day":31}"#.utf8))
        var invalidDays = fullYear(2026)
        invalidDays[0] = LegalCalendarDay(date: invalidDate, kind: .working)
        let damaged = LegalCalendarYearRevision(
            year: 2026, revision: 1, verifiedOn: date(2026, 9, 9),
            sourceIDs: [source.id], calendarSourceID: source.id,
            sourceHash: String(repeating: "c", count: 64), days: invalidDays)
        let latest = revision(year: 2026, revision: 2, hash: String(repeating: "d", count: 64))
        XCTAssertThrowsError(try LegalCalendar(archive: LegalCalendarArchive(
            sources: [source], reasons: [], revisions: [damaged, latest])))

        let mismatchedSource = LegalCalendarSource(
            id: source.id, title: source.title, url: source.url,
            sha256: String(repeating: "e", count: 64))
        let boundRevision = LegalCalendarYearRevision(
            year: 2026, revision: 1, verifiedOn: date(2026, 9, 9),
            sourceIDs: [source.id], calendarSourceID: source.id,
            sourceHash: String(repeating: "a", count: 64), days: fullYear(2026))
        XCTAssertThrowsError(try LegalCalendar(archive: LegalCalendarArchive(
            sources: [mismatchedSource], reasons: [], revisions: [boundRevision])))
    }

    private let source = LegalCalendarSource(
        id: "calendar", title: "Calendar", url: URL(string: "https://example.test/calendar")!,
        sha256: String(repeating: "a", count: 64))

    private func revision(year: Int, revision: Int, hash: String,
                          override: (LegalCalendarDate, LegalDayKind)? = nil)
        -> LegalCalendarYearRevision {
        var days = fullYear(year)
        if let override, let index = days.firstIndex(where: { $0.date == override.0 }) {
            days[index] = LegalCalendarDay(date: override.0, kind: override.1)
        }
        return LegalCalendarYearRevision(
            year: year, revision: revision, verifiedOn: date(2026, 9, 9),
            sourceIDs: [source.id],
            sourceHash: hash, days: days)
    }

    private func fullYear(_ year: Int) -> [LegalCalendarDay] {
        var result: [LegalCalendarDay] = []
        var current = date(year, 1, 1)
        while current.year == year {
            result.append(LegalCalendarDay(date: current, kind: .working))
            guard let instant = current.date(timeZone: .gmt) else { break }
            current = LegalCalendarDate(
                date: instant.addingTimeInterval(86_400), timeZone: .gmt)!
        }
        return result
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> LegalCalendarDate {
        LegalCalendarDate(year: year, month: month, day: day)!
    }
}
