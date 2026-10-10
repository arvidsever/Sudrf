import XCTest
@testable import SudrfKit

final class MilitaryCartotekaParityTests: XCTestCase {
    private struct Evidence: Decodable {
        let rows: [Row]
        struct Row: Decodable {
            let key: String
            let title: String
            let submission: [String: String]
            let identityFields: [String]
        }
    }

    func testAllSeventeenPublishedFormContractsAndRequestFields() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let evidence = try JSONDecoder().decode(Evidence.self, from: Data(contentsOf:
            root.appendingPathComponent("Docs/qa/issue-350/form-contracts-2026-10-10.json")))
        let historicalIDs = ["u-old-cassation": "u3_old", "u-old-supervisory": "u_supervisory_old",
                             "g-old-cassation": "g3_old", "g-old-supervisory": "g_supervisory_old"]
        let catalogs = CartotekaRegistry.searchDimensions(branch: .military, tier: .subject).cartoteki
        XCTAssertEqual(catalogs.count, 17)
        XCTAssertEqual(catalogs.map(\.id), evidence.rows.map { historicalIDs[$0.key] ?? $0.key })
        let builder = SudrfURLBuilder(court: Court(domain: "1zovs.spb.sudrf.ru",
                                                  title: "1-й Западный окружной военный суд", level: .subject))
        for (catalog, source) in zip(catalogs, evidence.rows) {
            XCTAssertTrue(catalog.title.hasSuffix(source.title))
            XCTAssertEqual(catalog.deloID, source.submission["delo_id"])
            XCTAssertEqual(catalog.new, source.submission["new"])
            XCTAssertEqual(catalog.deloTable, source.submission["delo_table"])
            for (field, name) in [(SearchField.caseNumber, catalog.caseNumberField),
                                  (.uid, catalog.uidField), (.name, catalog.nameField)] {
                XCTAssertTrue(source.identityFields.contains(name))
                let url = try builder.searchURL(cartoteka: catalog, field: field, value: "synthetic")
                let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
                for (key, value) in source.submission {
                    XCTAssertEqual(items.first { $0.name == key }?.value, value)
                }
                XCTAssertEqual(items.first { $0.name == name }?.value, "synthetic")
            }
            if historicalIDs[source.key] != nil { XCTAssertTrue(catalog.prefixes.isEmpty) }
        }
    }

    func testMilitaryDirectoryOwnershipUsesOnlyExactKnownHosts() {
        XCTAssertEqual(CourtDirectory.militaryCourt(forDomain: "1zovs.spb.sudrf.ru")?.level, .subject)
        XCTAssertEqual(CourtDirectory.militaryCourt(forDomain: "1zovs--spb.sudrf.ru")?.level, .subject)
        XCTAssertEqual(CourtDirectory.militaryCourt(forDomain: CourtDirectory.appellateMilitaryCourt.domain)?.level, .appeal)
        XCTAssertEqual(CourtDirectory.militaryCourt(forDomain: CourtDirectory.cassationMilitaryCourt.domain)?.level, .cassation)
        for host in ["vs.komi.sudrf.ru", "unknown.sudrf.ru", "1zovs.spb.sudrf.ru.example.org"] {
            XCTAssertNil(CourtDirectory.militaryCourt(forDomain: host))
        }
    }

    func testHistoricalExactTuplesAndModernAliasesRemainBranchScoped() throws {
        for (delo, new, expected) in [("4", "0", "u3_old"), ("2450001", "0", "u_supervisory_old"),
                                      ("5", "0", "g3_old"), ("2800001", "0", "g_supervisory_old"),
                                      ("4", "2450001", "u33"), ("5", "2800001", "g33")] {
            XCTAssertEqual(CartotekaRegistry.resolve(branch: .military, tier: .subject,
                deloID: delo, new: new, caseNumber: "")?.id, expected)
            if expected.hasSuffix("old") {
                XCTAssertNotEqual(CartotekaRegistry.resolve(level: .subject,
                    deloID: delo, new: new, caseNumber: "")?.id, expected)
            }
        }
        XCTAssertEqual(CartotekaRegistry.searchDimensions(branch: .military, tier: .district).cartoteki.map(\.id),
                       ["u1", "g1", "p1", "adm", "admj", "m"])
        XCTAssertEqual(CartotekaRegistry.searchDimensions(branch: .military, tier: .appeal).cartoteki.map(\.id),
                       ["u2", "g2", "p2"])
        XCTAssertEqual(CartotekaRegistry.searchDimensions(branch: .military, tier: .cassation).cartoteki.map(\.id),
                       ["u3", "g3", "p3", "adm3", "m"])
    }
}
