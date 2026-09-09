import Foundation
import XCTest
@testable import SudrfKit

final class ProductionCalendarImporterTests: XCTestCase {
    func testParsesSpecialAddressesAndKnownMarkers() throws {
        let year2020 = try parse("consultant-2020b", year: 2020)
        XCTAssertEqual(year2020.days.count, 366)
        XCTAssertEqual(day(in: year2020, 2020, 6, 24)?.kind, .specialNonWorking)
        XCTAssertEqual(day(in: year2020, 2020, 7, 1)?.kind, .specialNonWorking)

        let year2021 = try parse("consultant-2021", year: 2021)
        XCTAssertEqual(day(in: year2021, 2021, 5, 4)?.kind, .specialNonWorking)
        XCTAssertEqual(day(in: year2021, 2021, 11, 3)?.kind, .specialNonWorking)

        let year2024 = try parse("consultant-2024b", year: 2024)
        XCTAssertEqual(year2024.days.count, 366)
        XCTAssertEqual(day(in: year2024, 2024, 4, 27)?.kind, .transferredWorkingDay)
        XCTAssertEqual(day(in: year2024, 2024, 4, 29)?.kind, .transferredDayOff)
    }

    func testWeekendStatutoryHolidayKeepsHolidayKind() throws {
        let parsed = try parse("consultant-2026", year: 2026)
        XCTAssertEqual(day(in: parsed, 2026, 1, 3)?.kind, .holiday)
        XCTAssertEqual(parsed.days.filter { $0.kind == .holiday }.count, 14)
        XCTAssertEqual(parsed.monthlyTotals.count, 12)
        XCTAssertEqual(parsed.publishedWorkingDays, 247)
        XCTAssertEqual(parsed.publishedDaysOff, 118)
    }

    func testRejectsRedirectDraftAndUnapprovedFutureYear() throws {
        let data = try fixture("consultant-2026")
        let requested = try XCTUnwrap(ProductionCalendarImporter.sourceURL(for: 2026))
        XCTAssertThrowsError(try ProductionCalendarImporter.parse(
            data: data, expectedYear: 2026, requestedURL: requested,
            finalURL: URL(string: "https://www.consultant.ru/law/ref/calendar/proizvodstvennye/2025/")!)) {
            XCTAssertEqual($0 as? ProductionCalendarImportError,
                           .unexpectedFinalURL(URL(string: "https://www.consultant.ru/law/ref/calendar/proizvodstvennye/2025/")!))
        }

        let draft = String(decoding: data, as: UTF8.self).replacingOccurrences(
            of: "Производственный календарь на 2026 год",
            with: "Производственный календарь на 2026 год (проект)")
        XCTAssertThrowsError(try ProductionCalendarImporter.parse(
            data: Data(draft.utf8), expectedYear: 2026,
            requestedURL: requested, finalURL: requested)) {
            XCTAssertEqual($0 as? ProductionCalendarImportError, .unapprovedDraft)
        }

        let future = try fixture("consultant-2027-project")
        let futureURL = URL(string: "https://www.consultant.ru/law/ref/calendar/proizvodstvennye/2027/")!
        XCTAssertThrowsError(try ProductionCalendarImporter.parse(
            data: future, expectedYear: 2027, requestedURL: futureURL, finalURL: futureURL)) {
            XCTAssertEqual($0 as? ProductionCalendarImportError, .unsupportedYear(2027))
        }
    }

    func testRejectsIncompleteTableUnknownClassAndUnknownFootnote() throws {
        let requested = try XCTUnwrap(ProductionCalendarImporter.sourceURL(for: 2026))
        let html = String(decoding: try fixture("consultant-2026"), as: UTF8.self)
        let tableRange = try XCTUnwrap(html.range(
            of: #"(?s)<table class="cal".*?</table>"#, options: .regularExpression))
        let incomplete = html.replacingCharacters(in: tableRange, with: "")
        XCTAssertThrowsError(try ProductionCalendarImporter.parse(
            data: Data(incomplete.utf8), expectedYear: 2026,
            requestedURL: requested, finalURL: requested)) {
            XCTAssertEqual($0 as? ProductionCalendarImportError, .incompleteMonths(11))
        }

        let unknownClass = html.replacingOccurrences(of: #"class="""#,
                                                     with: #"class="mystery""#,
                                                     options: [], range: html.startIndex..<html.endIndex)
        XCTAssertThrowsError(try ProductionCalendarImporter.parse(
            data: Data(unknownClass.utf8), expectedYear: 2026,
            requestedURL: requested, finalURL: requested)) {
            guard case .unknownDayClass = $0 as? ProductionCalendarImportError else {
                return XCTFail("Unexpected error: \($0)")
            }
        }

        let url2020 = try XCTUnwrap(ProductionCalendarImporter.sourceURL(for: 2020))
        let marker = String(decoding: try fixture("consultant-2020b"), as: UTF8.self)
            .replacingOccurrences(of: "#noworkday3", with: "#noworkday999")
        XCTAssertThrowsError(try ProductionCalendarImporter.parse(
            data: Data(marker.utf8), expectedYear: 2020,
            requestedURL: url2020, finalURL: url2020)) {
            XCTAssertEqual($0 as? ProductionCalendarImportError, .unknownDayMarker)
        }
    }

    func testBuilderPreservesHistoryAndRejectsRevisionReplacementOrMetadataConflict() throws {
        let data = try fixture("consultant-2026")
        let firstManifest = try manifest(data: data, revision: 1)
        let first = try ProductionCalendarArchiveBuilder.build(
            manifest: firstManifest, pagesByYear: [2026: page(data, year: 2026)])

        let secondManifest = try manifest(data: data, revision: 2)
        let second = try ProductionCalendarArchiveBuilder.build(
            manifest: secondManifest, pagesByYear: [2026: page(data, year: 2026)],
            retaining: first)
        XCTAssertEqual(second.revisions.map(\.revision).sorted(), [1, 2])

        let legacySource = LegalCalendarSource(
            id: "legacy", title: "Legacy", url: URL(string: "https://example.test/legacy")!)
        let legacyReason = LegalCalendarReason(id: "legacy-reason", title: "Legacy",
                                               sourceIDs: [legacySource.id])
        let enriched = LegalCalendarArchive(
            sources: second.sources + [legacySource], reasons: second.reasons + [legacyReason],
            revisions: second.revisions)
        let third = try ProductionCalendarArchiveBuilder.build(
            manifest: try manifest(data: data, revision: 3),
            pagesByYear: [2026: page(data, year: 2026)], retaining: enriched)
        XCTAssertNotNil(third.sources.first { $0.id == legacySource.id })
        XCTAssertNotNil(third.reasons.first { $0.id == legacyReason.id })

        let changed = data + Data("<!-- changed -->".utf8)
        XCTAssertThrowsError(try ProductionCalendarArchiveBuilder.build(
            manifest: try manifest(data: changed, revision: 1),
            pagesByYear: [2026: page(changed, year: 2026)], retaining: first)) {
            XCTAssertEqual($0 as? ProductionCalendarArchiveBuilderError,
                           .immutableRevision(year: 2026, revision: 1))
        }

        var conflicting = try manifest(data: data, revision: 2)
        let calendar = conflicting.sources[0]
        let replacement = LegalCalendarSource(
            id: calendar.id, title: "Changed title", url: calendar.url,
            sha256: calendar.sha256)
        conflicting = ProductionCalendarImportManifest(
            weekendReasonID: conflicting.weekendReasonID,
            automaticTransferReasonID: conflicting.automaticTransferReasonID,
            holidayReasonID: conflicting.holidayReasonID,
            shortenedReasonID: conflicting.shortenedReasonID,
            transferredShortenedReasonID: conflicting.transferredShortenedReasonID,
            sources: [replacement] + Array(conflicting.sources.dropFirst()),
            reasons: conflicting.reasons, years: conflicting.years)
        XCTAssertThrowsError(try ProductionCalendarArchiveBuilder.build(
            manifest: conflicting, pagesByYear: [2026: page(data, year: 2026)],
            retaining: first)) {
            XCTAssertEqual($0 as? ProductionCalendarArchiveBuilderError,
                           .conflictingMetadata("source", "calendar"))
        }
    }

    private func parse(_ name: String, year: Int) throws -> ImportedProductionCalendarYear {
        let url = try XCTUnwrap(ProductionCalendarImporter.sourceURL(for: year))
        return try ProductionCalendarImporter.parse(
            data: fixture(name), expectedYear: year, requestedURL: url, finalURL: url)
    }

    private func day(in year: ImportedProductionCalendarYear,
                     _ y: Int, _ m: Int, _ d: Int) -> ImportedProductionCalendarDay? {
        year.days.first { $0.date == LegalCalendarDate(year: y, month: m, day: d)! }
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "html",
            subdirectory: "Fixtures/production-calendar"))
        return try Data(contentsOf: url)
    }

    private func page(_ data: Data, year: Int) -> ProductionCalendarImportPage {
        let url = ProductionCalendarImporter.sourceURL(for: year)!
        return ProductionCalendarImportPage(data: data, requestedURL: url, finalURL: url)
    }

    private func manifest(data: Data, revision: Int) throws
        -> ProductionCalendarImportManifest {
        let url = try XCTUnwrap(ProductionCalendarImporter.sourceURL(for: 2026))
        let parsed = try ProductionCalendarImporter.parse(
            data: data, expectedYear: 2026, requestedURL: url, finalURL: url)
        let sources = [
            LegalCalendarSource(id: "calendar", title: "Calendar", url: url,
                                sha256: parsed.sourceHash),
            LegalCalendarSource(id: "law", title: "Law",
                                url: URL(string: "https://example.test/law")!),
        ]
        let reasons = ["weekend", "automatic", "holiday", "shortened",
                       "transferred-shortened", "transfer"].map {
            LegalCalendarReason(id: $0, title: $0, sourceIDs: ["law"])
        }
        let config = ProductionCalendarYearImport(
            year: 2026, revision: revision,
            verifiedOn: LegalCalendarDate(year: 2026, month: 9, day: 9)!,
            sourceIDs: ["calendar", "law"], calendarSourceID: "calendar",
            observedFinalURL: url, transferReasonID: "transfer",
            decreeReasonDates: [LegalCalendarDate(year: 2026, month: 1, day: 9)!,
                                LegalCalendarDate(year: 2026, month: 12, day: 31)!])
        return ProductionCalendarImportManifest(
            weekendReasonID: "weekend", automaticTransferReasonID: "automatic",
            holidayReasonID: "holiday", shortenedReasonID: "shortened",
            transferredShortenedReasonID: "transferred-shortened",
            sources: sources, reasons: reasons, years: [config])
    }
}
