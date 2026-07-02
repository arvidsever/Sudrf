import XCTest
@testable import SudrfKit

final class ResultsParserTests: XCTestCase {

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
}
