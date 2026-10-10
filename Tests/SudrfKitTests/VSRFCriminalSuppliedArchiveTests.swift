// © 2026 Воробьёв Виктор Викторович. SPDX-License-Identifier: CC-BY-NC-ND-4.0

import Foundation
import XCTest
@testable import SudrfKit

/// Local supplied-source diagnosis; raw archives and participants stay outside the repository.
final class VSRFCriminalSuppliedArchiveTests: XCTestCase {
    private func suppliedHTML(_ variable: String, sourceURL: String) throws -> String {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else {
            throw XCTSkip("Supplied archive diagnosis is opt-in")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let archive = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any])
        let resource = try XCTUnwrap(archive["WebMainResource"] as? [String: Any])
        XCTAssertEqual(resource["WebResourceURL"] as? String, sourceURL)
        let bytes = try XCTUnwrap(resource["WebResourceData"] as? Data)
        return try XCTUnwrap(String(data: bytes, encoding: .utf8))
    }

    func testSuppliedCriminalSearchFindsExactCaseCard() throws {
        let html = try suppliedHTML("SUDRF_165_SEARCH_ARCHIVE", sourceURL: "https://www.vsrf.ru/lk/practice")
        let rows = try VSRFDOM.extractSearchProductions(VSRFCardParser.document(html))
        for row in rows {
            print("ISSUE165_SEARCH id=\(row.cardID ?? "missing") kind=\(row.kind.rawValue)"
                  + " numberPresent=\(row.number != nil) courtPresent=\(row.firstInstance.court != nil)"
                  + " lowerNumberPresent=\(row.firstInstance.caseNumber != nil)"
                  + " applicantPresent=\(row.applicant != nil) uidPresent=\(row.uid != nil)")
        }
        let search = try VSRFSearchParser.parse(html: html)
        XCTAssertEqual(search.total, 7)
        let production = try XCTUnwrap(search.results.first { $0.cardID == "17-35241305" })
        XCTAssertEqual(production.number, "222-УД24-28-А6")
        XCTAssertEqual(production.kind, .caseFile)
        XCTAssertEqual(production.cardURL?.absoluteString,
                       "https://www.vsrf.ru/lk/practice/claims/17-35241305")
        XCTAssertEqual(production.firstInstance.caseNumber, "2-273/2023")
    }

    func testSuppliedCriminalCardPreservesOwnIdentityMovementAndActLink() throws {
        let html = try suppliedHTML("SUDRF_165_CARD_ARCHIVE",
                                    sourceURL: "https://www.vsrf.ru/lk/practice/claims/17-35241305")
        let card = try VSRFCardParser.parse(html: html)
        let production = try XCTUnwrap(card.productions.first { $0.cardID == "17-35241305" })
        XCTAssertEqual(production.kind, .caseFile)
        XCTAssertEqual(production.number, "222-УД24-28-А6")
        XCTAssertEqual(production.firstInstance.caseNumber, "2-273/2023")
        XCTAssertEqual(production.resolvedInstanceLevel, .vsCassation)
        XCTAssertNil(production.uid)
        XCTAssertTrue(production.events.contains { $0.date == "05.06.2024" })
        XCTAssertTrue(production.publishedActs.contains {
            $0.url.absoluteString == "https://www.vsrf.ru/lk/practice/stor_pdf/2374414"
        })
    }
}
