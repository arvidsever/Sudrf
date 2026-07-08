import XCTest
@testable import SudrfKit

final class ResultsParserTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "html",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("Фикстура \(name).html не найдена в бандле теста")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private let fixture = """
    <html><body>
    <div>Всего по запросу найдено: 1</div>
    <table id="tablcont">
      <tr><th>№</th><th>Дата пост.</th><th>Стороны</th><th>Судья</th><th>Дата реш.</th><th>Результат</th></tr>
      <tr>
        <td><a href="modules.php?name=sud_delo&amp;srv_num=1&amp;name_op=case&amp;case_id=98765&amp;case_uid=ABC-123-GUID&amp;delo_id=1500001">5-470/2026</a></td>
        <td>14.05.2026</td>
        <td>Иванов И.И.</td>
        <td>Петров П.П.</td>
        <td>20.05.2026</td>
        <td>Назначено наказание</td>
      </tr>
    </table>
    </body></html>
    """

    func testParsesSingleRow() throws {
        let results = try ResultsParser.parse(html: fixture, court: .syktyvkarskiy)
        XCTAssertEqual(results.count, 1)
        let r = results[0]
        XCTAssertEqual(r.caseNumber, "5-470/2026")
        XCTAssertEqual(r.caseID, "98765")
        XCTAssertEqual(r.caseUID, "ABC-123-GUID")
        XCTAssertEqual(r.receiptDate, "14.05.2026")
        XCTAssertEqual(r.judge, "Петров П.П.")
        XCTAssertEqual(r.result, "Назначено наказание")
        XCTAssertEqual(r.cardURL?.host, "syktsud--komi.sudrf.ru")
    }

    func testEmptyWhenNoCaseLinks() throws {
        let results = try ResultsParser.parse(html: "<html><body>нет ссылок</body></html>",
                                              court: .syktyvkarskiy)
        XCTAssertTrue(results.isEmpty)
    }

    func testHrefQueryExtraction() {
        let href = "modules.php?name=sud_delo&name_op=case&case_id=42&case_uid=XYZ"
        XCTAssertEqual(ResultsParser.queryValue("case_id", in: href), "42")
        XCTAssertEqual(ResultsParser.queryValue("case_uid", in: href), "XYZ")
    }

    /// Часть винтажных судов даёт ссылку на карточку ТОЛЬКО с `_uid`, без `_id`
    /// (живой пример — Благовещенский городской суд): идентификаторов для
    /// канонического URL нет, но cardURL самодостаточен.
    func testParsesVintageUIDOnlyLink() throws {
        let html = """
        <html><body><table>
          <tr><td><a href="modules.php?name=sud_delo&amp;name_op=case&amp;_uid=526a6a50-2f9e-433b-bda4-f508936e9bf4&amp;_deloId=1540005&amp;_caseType=0&amp;_new=0&amp;srv_num=1&amp;_hideJudge=0">2-5/2026 ~ М-7523/2025</a></td></tr>
        </table></body></html>
        """
        let results = try ResultsParser.parse(html: html, court: .syktyvkarskiy)
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0].caseID)
        XCTAssertEqual(results[0].caseUID, "526a6a50-2f9e-433b-bda4-f508936e9bf4")
        let cardURL = try XCTUnwrap(results[0].cardURL)
        XCTAssertTrue(cardURL.absoluteString.contains("_uid=526a6a50"))
    }

    /// Винтажный интерфейс (VNKOD-суды) даёт ссылки на карточку с параметрами
    /// _id/_uid (живой пример — Заволжский районный суд г. Ульяновска).
    func testParsesVintageCardLink() throws {
        let html = """
        <html><body><table>
          <tr><td><a href="modules.php?name=sud_delo&amp;name_op=case&amp;_id=137806682&amp;_uid=f455716b-ca7a-448d-91cf-55a56d28fb5a&amp;_deloId=1540005&amp;_caseType=0&amp;_new=0&amp;srv_num=1">2-5/2026</a></td></tr>
        </table></body></html>
        """
        let results = try ResultsParser.parse(html: html, court: .syktyvkarskiy)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].caseID, "137806682")
        XCTAssertEqual(results[0].caseUID, "f455716b-ca7a-448d-91cf-55a56d28fb5a")
    }

    func testParsesSamaraKASAppealUIDResults() throws {
        let html = try loadFixture("samara_kas_appeal_uid_results")
        let court = Court(domain: "oblsud--sam.sudrf.ru",
                          title: "Самарский областной суд", level: .subject)
        let results = try ResultsParser.parse(html: html, court: court)

        XCTAssertEqual(results.count, 1)
        let r = results[0]
        XCTAssertEqual(r.caseNumber, "33а-647/2026 (33а-11786/2025;)")
        XCTAssertEqual(r.receiptDate, "10.11.2025")
        XCTAssertEqual(r.judge, "Пудовкина Е. С.")
        XCTAssertEqual(r.decisionDate, "13.01.2026")
        XCTAssertEqual(r.result, "РЕШЕНИЕ оставлено БЕЗ ИЗМЕНЕНИЯ")
        XCTAssertEqual(r.caseID, "45090185")
        XCTAssertEqual(r.caseUID, "70f25bb3-b647-4795-a592-61e457a42ea7")
        XCTAssertTrue(r.cardURL?.absoluteString.contains("_deloId=1540005") == true)
        XCTAssertTrue(r.cardURL?.absoluteString.contains("_new=5") == true)
    }
}
