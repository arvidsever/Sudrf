import XCTest
@testable import SudrfKit

final class Issue322SourceFixtureTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "html",
                                                 subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTwoOfficialAppealsNameOneMoscowCardWithoutJudicialUID() throws {
        for (name, number, date) in [
            ("issue322_asoy_2013", "66а-2013/2020", "02.04.2020"),
            ("issue322_asoy_4311", "66а-4311/2020", "10.09.2020")
        ] {
            let card = try CaseCardParser.parse(html: fixture(name))
            XCTAssertEqual(card.caseNumber, number)
            XCTAssertNil(card.uid)
            XCTAssertEqual(card.decisionDate, date)
            XCTAssertEqual(card.lowerCourt?.caseNumber, "3а-3696/2020")
            XCTAssertEqual(card.lowerCourt?.courtTitle, "Московский городской суд")
            XCTAssertEqual(card.lowerCourt?.judge, "Севастьянова Наталия Юрьевна")
            XCTAssertNil(card.lowerCourt?.decisionDate)
        }
    }

    func testCassationReferencesKhamovnikiAndPublishedUID() throws {
        let card = try CaseCardParser.parse(html: fixture("issue322_ksoyu_8501"))
        XCTAssertEqual(card.uid, "77RS0030-02-2021-008181-07")
        XCTAssertEqual(card.lowerCourt?.courtTitle, "Хамовнический районный суд")
        XCTAssertEqual(card.lowerCourt?.caseNumber, "2а-419/2021")
    }

    func testMoscowCardsAndSearchRowsKeepTheirOwnLocatorAndChronology() throws {
        let first = try MosGorSudCardParser.parse(html: fixture("issue322_mgs_first"))
        XCTAssertEqual(first.uid, "77OS0000-01-2020-002855-77")
        XCTAssertEqual(first.caseNumber, "3а-3696/2020")
        XCTAssertTrue(first.rawText.contains("02.04.2020 Определение суда апелляционной инстанции"))
        XCTAssertTrue(first.rawText.contains("10.09.2020 Определение суда апелляционной инстанции"))

        let khamov = try MosGorSudCardParser.parse(html: fixture("issue322_mgs_hamov"))
        XCTAssertEqual(khamov.caseNumber, "02а-0419/2021")
        XCTAssertEqual(khamov.uid, "77RS0030-02-2021-008181-07")
        let appeal = try MosGorSudCardParser.parse(html: fixture("issue322_mgs_appeal"))
        XCTAssertEqual(appeal.caseNumber, "33а-6088/2021")
        XCTAssertEqual(appeal.uid, khamov.uid)

        let firstRows = try MosGorSudResultsParser.parse(html: fixture("issue322_mgs_search_first"))
        XCTAssertEqual(firstRows.map(\.caseNumber), ["3а-3696/2020"])
        XCTAssertEqual(firstRows.first?.cardURL?.host, "mos-gorsud.ru")
        let uidRows = try MosGorSudResultsParser.parse(html: fixture("issue322_mgs_search_uid"))
        XCTAssertEqual(Set(uidRows.map(\.caseNumber)), ["02а-0419/2021", "33а-6088/2021"])
    }
}
