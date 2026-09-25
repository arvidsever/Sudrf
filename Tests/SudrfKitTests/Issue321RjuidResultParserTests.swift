import XCTest
@testable import SudrfKit

final class Issue321RjuidResultParserTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "html",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("Фикстура \(name).html не найдена в бандле теста")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testSPBUIDResultsPreserveCrossCourtURLAndShiftAllColumns() throws {
        let sourceCourt = Court(
            domain: "vos.spb.sudrf.ru",
            title: "Василеостровский районный суд города Санкт-Петербурга",
            level: .district)

        let results = try ResultsParser.parse(html: loadFixture("issue321_rjuid_spb"),
                                              court: sourceCourt)
        guard case .results = SearchPageClassifier.classify(
            html: try loadFixture("issue321_rjuid_spb")) else {
            return XCTFail("Санитизированная выдача СПб должна классифицироваться как результат")
        }
        let completeResults = try ResultsParser.parseComplete(
            html: loadFixture("issue321_rjuid_spb"), court: sourceCourt)
        XCTAssertEqual(results.map(\.caseNumber), ["12-538/2026", "12-1156/2026"])
        XCTAssertEqual(completeResults, results)

        let earlier = try XCTUnwrap(results.first { $0.caseNumber == "12-538/2026" })
        XCTAssertEqual(earlier.courtTitle, "Василеостровский районный суд города Санкт-Петербурга")
        XCTAssertEqual(earlier.cardURL?.host, "vos.spb.sudrf.ru")
        XCTAssertEqual(earlier.receiptDate, "11.03.2026")
        XCTAssertEqual(earlier.judge, "Хабарова Елена Михайловна")
        XCTAssertEqual(earlier.decisionDate, "16.07.2026")
        XCTAssertEqual(earlier.result, "Направлено по подведомственности")

        let result = try XCTUnwrap(results.first { $0.caseNumber == "12-1156/2026" })

        XCTAssertEqual(result.courtTitle, "Кировский районный суд города Санкт-Петербурга")
        XCTAssertEqual(result.receiptDate, "27.07.2026")
        XCTAssertEqual(result.essence, "<стороны скрыты>")
        XCTAssertEqual(result.judge, "Костин Федор Вячеславович")
        XCTAssertEqual(result.decisionDate, "23.09.2026")
        XCTAssertEqual(result.result, "Оставлено без изменения")
        XCTAssertNil(result.legalForceDate)
        XCTAssertEqual(result.caseID, "984441524")
        XCTAssertEqual(result.caseUID, "94fbe307-53f6-4f36-bf53-fd709a865d09")
        XCTAssertEqual(result.cardURL?.absoluteString,
                       "http://krv.spb.sudrf.ru/modules.php?name=sud_delo"
                        + "&name_op=case&case_id=984441524"
                        + "&case_uid=94fbe307-53f6-4f36-bf53-fd709a865d09"
                        + "&delo_id=1502001&case_type=0&new=0&srv_num=1")
        XCTAssertEqual(result.cardURL?.host, "krv.spb.sudrf.ru")
    }

    func testKomiUIDResultsPreserveSyktyvkarHostForBothRegistrations() throws {
        let sourceCourt = Court(domain: "uwsud.komi.sudrf.ru",
                                title: "Усть-Вымский районный суд",
                                level: .district)
        let results = try ResultsParser.parse(
            html: loadFixture("issue321_rjuid_komi"), court: sourceCourt)
        guard case .results = SearchPageClassifier.classify(
            html: try loadFixture("issue321_rjuid_komi")) else {
            return XCTFail("Санитизированная выдача Коми должна классифицироваться как результат")
        }
        let completeResults = try ResultsParser.parseComplete(
            html: loadFixture("issue321_rjuid_komi"), court: sourceCourt)

        XCTAssertEqual(results.map(\.caseNumber), ["12-56/2026", "12-461/2026", "12-879/2026"])
        XCTAssertEqual(completeResults, results)
        XCTAssertEqual(results.map(\.courtTitle), [
            "Усть-Вымский районный суд Республики Коми",
            "Сыктывкарский городской суд Республики Коми",
            "Сыктывкарский городской суд Республики Коми",
        ])
        XCTAssertEqual(results.compactMap(\.cardURL?.host), [
            "uwsud.komi.sudrf.ru",
            "syktsud.komi.sudrf.ru",
            "syktsud.komi.sudrf.ru",
        ])
        XCTAssertEqual(results.map(\.receiptDate), ["02.04.2026", "13.04.2026", "19.06.2026"])
        XCTAssertEqual(results.map(\.judge), [
            "Балашенко Артем Игоревич",
            "Печинина Людмила Анатольевна",
            "Леконцев Александр Пантелеевич",
        ])
        XCTAssertEqual(results.map(\.decisionDate), ["06.04.2026", "25.05.2026", "25.08.2026"])
        XCTAssertEqual(results.map(\.result), [
            "Направлено по подведомственности",
            "Отменено с возвращением на новое рассмотрение",
            "Оставлено без изменения",
        ])
        XCTAssertEqual(results[1].caseID, "35190605")
        XCTAssertEqual(results[1].caseUID, "cff76120-b056-45fc-93cc-55f1ad2fbbbd")
        XCTAssertEqual(results[2].caseID, "38789069")
        XCTAssertEqual(results[2].caseUID, "bd3a69d0-4f96-445c-93ca-26ac9d56cee8")
    }

    func testRjuidTableWithoutCaseLinkDoesNotProduceARegistration() throws {
        let html = """
        <html><body><table id="tablcont">
          <tr><th>Суд</th><th>№ дела</th><th>Дата поступления</th></tr>
          <tr><td>Сыктывкарский городской суд</td><td>12-879/2026</td><td>22.09.2026</td></tr>
        </table></body></html>
        """

        XCTAssertTrue(try ResultsParser.parse(html: html, court: .syktyvkarskiy).isEmpty)
    }

    func testCardKeepsPublishedUIDListingURLInsteadOfRebuildingVNkodFromUID() throws {
        let kirovURL = URL(string: "https://krv.spb.sudrf.ru/modules.php"
            + "?name=sud_delo&name_op=case&case_id=984441524"
            + "&case_uid=94fbe307-53f6-4f36-bf53-fd709a865d09"
            + "&delo_id=1502001&case_type=0&new=0&srv_num=1")!
        let kirovHTML = try loadFixture("issue321_card_kirov")
        let kirov = try CaseCardParser.parse(html: kirovHTML, cardURL: kirovURL)
        XCTAssertEqual(kirov.uid, "78RS0001-01-2026-002203-86")
        XCTAssertEqual(kirov.caseNumber, "12-1156/2026")
        XCTAssertEqual(kirov.uidListingURL?.host, "krv.spb.sudrf.ru")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(kirov.uidListingURL),
                                     resolvingAgainstBaseURL: false)?.queryItems?.first {
            $0.name == "vnkod"
        }?.value, "78RS0006")

        let syktyvkarURL = URL(string: "https://syktsud.komi.sudrf.ru/modules.php"
            + "?name=sud_delo&name_op=case&case_id=38789069"
            + "&case_uid=bd3a69d0-4f96-445c-93ca-26ac9d56cee8"
            + "&delo_id=1502001&case_type=0&new=0&srv_num=1")!
        let syktyvkarHTML = try loadFixture("issue321_card_syktyvkar")
        let syktyvkar = try CaseCardParser.parse(html: syktyvkarHTML,
                                                 cardURL: syktyvkarURL)
        XCTAssertEqual(syktyvkar.uid, "11RS0020-01-2026-000655-63")
        XCTAssertEqual(syktyvkar.caseNumber, "12-879/2026")
        XCTAssertEqual(syktyvkar.uidListingURL?.host, "syktsud.komi.sudrf.ru")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(syktyvkar.uidListingURL),
                                     resolvingAgainstBaseURL: false)?.queryItems?.first {
            $0.name == "vnkod"
        }?.value, "11RS0001")
    }

    func testCardDiscardsUIDListingLinkWithDifferentJudicialUID() throws {
        let html = """
        <div class="casenumber">ДЕЛО № 12-879/2026</div>
        <div id="cont1"><table><tr><td>Уникальный идентификатор дела</td><td>\(uid)</td></tr></table></div>
        <a href="/modules.php?name=sud_delo&name_op=r_juid&vnkod=11RS0001&srv_num=1&delo_id=1502001&case_type=0&judicial_uid=11RS0001-01-2026-000655-63">УИД</a>
        """
        let cardURL = URL(string: "https://syktsud.komi.sudrf.ru/modules.php"
            + "?name=sud_delo&name_op=case&case_id=38789069"
            + "&case_uid=bd3a69d0-4f96-445c-93ca-26ac9d56cee8"
            + "&delo_id=1502001&case_type=0&new=0&srv_num=1")!
        let card = try CaseCardParser.parse(html: html, cardURL: cardURL)
        XCTAssertEqual(card.uid, uid)
        XCTAssertNil(card.uidListingURL)
    }

    private var uid: String { "11RS0020-01-2026-000655-63" }

}
