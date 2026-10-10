// © 2026 Воробьёв Виктор Викторович. SPDX-License-Identifier: CC-BY-NC-ND-4.0
import XCTest
@testable import SudrfKit

final class VSRFCriminalParserTests: XCTestCase {
    private func fixture(_ role: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vsrf_supplied_criminal_\(role)",
            withExtension: "html", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testSuppliedSevenRowsPreserveNativeKindsWithoutInventingLinkEvidence() throws {
        let page = try VSRFSearchParser.parse(html: fixture("search"))
        XCTAssertEqual(page.total, 7)
        XCTAssertEqual(page.results.count, 7)
        XCTAssertEqual(Set(page.results.compactMap(\.cardID)).count, 7)
        XCTAssertTrue(try fixture("search").contains("/lk/practice/claims/17-35550509"))
        XCTAssertFalse(page.results.contains { $0.cardID == "17-35550509" })
        for row in page.results {
            XCTAssertEqual(row.kind, row.cardID?.hasPrefix("17-") == true ? .caseFile : .complaint)
            XCTAssertEqual(row.cardSection, .claims)
            XCTAssertNil(row.uid)
            XCTAssertFalse(row.linkKey.matches(VSRFLinkKey(firstInstanceCourt: row.firstInstance.court,
                firstInstanceCaseNumber: row.firstInstance.caseNumber)), "Incomplete lower key must not link")
        }
        let own = try XCTUnwrap(page.results.first { $0.cardID == "17-35241305" })
        XCTAssertEqual(own.number, "222-УД24-28-А6")
        XCTAssertEqual(own.firstInstance.caseNumber, "2-273/2023")
        XCTAssertEqual(own.cardURL?.absoluteString, "https://www.vsrf.ru/lk/practice/claims/17-35241305")
    }

    func testSuppliedFourCardSectionsKeepOwnIdentityEventsAndPublishedAct() throws {
        let card = try VSRFCardParser.parse(html: fixture("card"))
        XCTAssertEqual(card.productions.count, 4)
        XCTAssertEqual(Set(card.productions.compactMap(\.cardID)),
            ["17-35241305", "22-35288352", "22-35309375", "22-35487586"])
        let own = try XCTUnwrap(card.productions.first { $0.cardID == "17-35241305" })
        XCTAssertEqual(own.kind, .caseFile)
        XCTAssertEqual(own.number, "222-УД24-28-А6")
        XCTAssertEqual(own.firstInstance.caseNumber, "2-273/2023")
        XCTAssertEqual(own.resolvedInstanceLevel, .vsCassation)
        XCTAssertNil(own.uid)
        XCTAssertEqual(own.events.count, 4) // Three source movement facts plus the separately published result.
        XCTAssertEqual(own.events.prefix(3).map(\.date), ["02.05.2024", "03.05.2024", "05.06.2024"])
        XCTAssertTrue(own.events[0].text.contains("Передано судье"))
        XCTAssertTrue(own.events[1].text.contains("Вынесено постановление"))
        XCTAssertTrue(own.events[2].text.contains("Слушание"))
        XCTAssertEqual(own.publishedActs.first?.url.absoluteString,
            "https://www.vsrf.ru/lk/practice/stor_pdf/2374414")
        for complaint in card.productions.filter({ $0.cardID != own.cardID }) {
            XCTAssertEqual(complaint.kind, .complaint)
            XCTAssertNil(complaint.uid)
        }
    }

    func testOwnAnchorCannotBeBorrowedFromRelatedCaseAndNativeFamiliesAreExact() throws {
        let html = try fixture("card")
        XCTAssertTrue(html.contains("/lk/practice/claims/17-35550509"))
        XCTAssertThrowsError(try VSRFCardParser.parse(html: html.replacingOccurrences(
            of: "17-35241305-redacted", with: "99-35241305-redacted")))
        for (id, kind) in [("12-1", VSRFProductionKind.caseFile), ("17-1", .caseFile),
                           ("21-1", .complaint), ("22-1", .complaint)] {
            XCTAssertEqual(VSRFDOM.currentKind(cardID: id), kind)
        }
        for id in ["117-1", "17-", "17-1suffix", "22-1-2", "99-1"] {
            XCTAssertNil(VSRFDOM.currentKind(cardID: id))
        }
    }

    func testSearchAdmissionStillRejectsForeignLinksMissingIdentityAndBadCounts() throws {
        let html = try fixture("search")
        for invalid in [
            html.replacingOccurrences(of: "/lk/practice/claims/17-35551714", with: "https://example.org/lk/practice/claims/17-35551714"),
            html.replacingOccurrences(of: "/lk/practice/claims/17-35551714", with: "/lk/practice/claims/99-35551714"),
            html.replacingOccurrences(of: "/lk/practice/claims/17-35551714", with: "/lk/practice/claims/17-35551714/extra"),
            html.replacingOccurrences(of: "222-Д24-2-А6", with: ""),
            html.replacingOccurrences(of: "Найдено: 7", with: "Найдено: 0"),
            html.replacingOccurrences(of: "Найдено: 7", with: "Найдено: 6")
        ] { XCTAssertThrowsError(try VSRFSearchParser.parse(html: invalid)) }
    }

    func testLegacyClaimsRowsStillRequirePublishedLinkageEvidence() {
        for id in ["12-1", "17-1"] {
            let html = """
            <form id="filter-form"></form><div class="count-label">Найдено: 1</div>
            <div id="vs-search-items"><div class="vs-items-separate">
            <span class="vs-items-label"><a href="/lk/practice/claims/\(id)">222-УД24-28-А6</a></span>
            </div></div>
            """
            XCTAssertThrowsError(try VSRFSearchParser.parse(html: html))
        }
    }
}
