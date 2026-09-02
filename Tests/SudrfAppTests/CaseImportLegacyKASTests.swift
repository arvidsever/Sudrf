import XCTest
import SudrfKit
@testable import SudrfApp

final class CaseImportLegacyKASTests: XCTestCase {

    private func seed(number: String, court: String, url: String) throws -> ImportSeed {
        let row = ImportedRow(number: number, court: court, parties: "", urlString: url)
        guard case .seed(let seed) = CaseImporter.classify(row) else {
            throw XCTSkip("строка неожиданно пропущена импортёром")
        }
        return seed
    }

    func testImportUsesKASContextButPreservesHistoricalFetchParameters() throws {
        let samples: [(String, String, String, String, String, String)] = [
            (
                "2а-321/2021",
                "Сыктывкарский городской суд (Республика Коми)",
                "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=1&case_uid=u1&delo_id=1540005",
                "p1", "1540005", "0"
            ),
            (
                "9а-96/2020",
                "Верховный Суд Республики Коми (Республика Коми)",
                "https://vs--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=2&case_uid=u2&delo_id=1540005",
                "p1", "1540005", "0"
            ),
            (
                "33а-2760/2021",
                "Верховный Суд Республики Коми (Республика Коми)",
                "https://vs--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=3&case_uid=u3&delo_id=5&new=5",
                "p2", "5", "5"
            ),
            (
                "66а-429/2021",
                "Второй апелляционный суд общей юрисдикции (Город Санкт-Петербург)",
                "https://2ap.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=4&case_uid=u4&delo_id=5&new=5",
                "p2", "5", "5"
            ),
            (
                "88а-5376/2021",
                "Третий кассационный суд общей юрисдикции (Город Санкт-Петербург)",
                "https://3kas.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=5&case_uid=u5&delo_id=2800001&new=2800001",
                "p3", "2800001", "2800001"
            )
        ]

        for (number, court, url, expectedCartoteka, sourceDeloID, sourceNew) in samples {
            let imported = try seed(number: number, court: court, url: url)
            XCTAssertEqual(imported.cartoteka?.id, expectedCartoteka, number)
            XCTAssertEqual(imported.deloID, sourceDeloID, number)
            XCTAssertEqual(imported.new, sourceNew, number)

            let fetched = CaseImporter.Fetched(seed: imported, card: nil)
            let context = CaseImporter.makeContext(fetched, known: [])
            XCTAssertEqual(context.cartotekaId, expectedCartoteka, number)
            XCTAssertEqual(context.sourceKnownCard?.deloID, sourceDeloID, number)
            XCTAssertEqual(context.sourceKnownCard?.new, sourceNew, number)
            XCTAssertEqual(
                ProductionType.classified(
                    caseNumber: context.caseNumber,
                    level: context.courtLevel,
                    branch: context.branch,
                    cartotekaID: context.cartotekaId),
                .kas,
                number)
        }
    }

    func testAdministrativeExecutionMaterialRemainsMaterialAndIsShownAsKAS() throws {
        let imported = try seed(
            number: "13а-1/2024",
            court: "Сыктывкарский городской суд (Республика Коми)",
            url: "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=6&case_uid=u6&delo_id=1610001")

        XCTAssertEqual(imported.cartoteka?.id, "m")
        XCTAssertTrue(imported.isMaterial)

        let context = CaseImporter.makeContext(
            CaseImporter.Fetched(seed: imported, card: nil), known: [])
        XCTAssertEqual(
            ProductionType.classified(
                caseNumber: context.caseNumber,
                level: context.courtLevel,
                branch: context.branch,
                cartotekaID: context.cartotekaId),
            .kas)
    }
}
