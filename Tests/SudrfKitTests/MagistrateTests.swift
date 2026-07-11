import XCTest
@testable import SudrfKit

final class MagistrateTests: XCTestCase {

    func testDirectoryParserKeepsSupportedAndUnsupportedSites() {
        let html = """
        <html><body>
        <table class="msSearchResultTbl">
          <tr><td>
            <a onclick="listcontrol(0,&quot;11MS0010&quot;);">Первомайский судебный участок г. Сыктывкара Республики Коми</a>
            <div class="courtInfoCont" id="mir_0">
              <b>Классификационный код:</b> 11MS0010
              <a href="https://pervomaysky.komi.msudrf.ru">сайт</a>
            </div>
          </td></tr>
          <tr><td>
            <a onclick="listcontrol(1,&quot;78MS0001&quot;);">Судебный участок № 1 Санкт-Петербурга</a>
            <div class="courtInfoCont" id="mir_1">
              <a href="https://mirsud.spb.ru/cases">сайт</a>
            </div>
          </td></tr>
        </table>
        </body></html>
        """

        let courts = MagistrateCourtParser.parse(html: html, portalSubject: "11")

        XCTAssertEqual(courts.count, 2)
        XCTAssertTrue(courts.contains {
            $0.code == "11MS0010"
                && $0.domain == "pervomaysky.komi.msudrf.ru"
                && $0.isSupported
        })
        XCTAssertTrue(courts.contains {
            $0.code == "78MS0001"
                && $0.domain == "unsupported-ms:78MS0001"
                && !$0.isSupported
        })
    }

    func testDirectoryPrefersMSudrfLinkOverUnrelatedLink() {
        let html = """
        <table class="msSearchResultTbl"><tr><td>
        <a onclick="listcontrol(0,'11MS0010');">Участок</a>
        <div class="courtInfoCont"><a href="https://example.org">справка</a>
        <a href="https://site.komi.msudrf.ru">сайт</a></div>
        </td></tr></table>
        """
        XCTAssertEqual(MagistrateCourtParser.parse(html: html).first?.domain, "site.komi.msudrf.ru")
    }

    func testURLBuilderUsesUTF8QueryAndNoUIDSearch() throws {
        let court = Court(domain: "petrozavodskoj.komi.msudrf.ru",
                          title: "Петрозаводский судебный участок", level: .magistrate)
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "g1"))
        let url = try MagistrateURLBuilder(court: court)
            .searchURL(cartoteka: cart, field: .name, value: "Вороб")

        XCTAssertTrue(url.absoluteString.contains("op=sf"))
        XCTAssertTrue(url.absoluteString.contains("delo_id=1540005"))
        XCTAssertTrue(url.absoluteString.contains("G1_PARTS__NAMESS=%D0%92%D0%BE%D1%80%D0%BE%D0%B1"))
        XCTAssertThrowsError(try MagistrateURLBuilder(court: court)
            .searchURL(cartoteka: cart, field: .uid, value: "11MS..."))
    }

    func testResultsParserParsesRowsAndPagination() throws {
        let html = """
        <div id="search_results">
          <div class="case-count">Найдено дел: 2</div>
          <a href="/modules.php?name=sud_delo&delo_id=1540005&op=sf&pageNum_Recordset1=1">2</a>
          <table id="tablcont" class="tablcont">
            <tr><td>Номер дела</td><td>Дата поступления</td><td>Информация по делу</td><td>Судья</td><td>Дата решения</td><td>Решение</td><td>Судебные акты</td></tr>
            <tr>
              <td><a href="/modules.php?name=sud_delo&amp;op=cs&amp;case_id=128701125&amp;delo_id=1540005">2-4004/2024</a></td>
              <td>10.10.2024</td><td>ИСТЕЦ: ООО</td><td>Бердашкевич</td><td>14.10.2024</td><td>Иск удовлетворен</td><td></td>
            </tr>
            <tr>
              <td><a href="/modules.php?name=sud_delo&amp;op=cs&amp;case_id=128701125&amp;delo_id=1540005">2-4004/2024</a></td>
              <td>10.10.2024</td><td>дубль стороны</td><td>Бердашкевич</td><td>14.10.2024</td><td>Иск удовлетворен</td><td></td>
            </tr>
          </table>
        </div>
        """
        let court = Court(domain: "petrozavodskoj.komi.msudrf.ru",
                          title: "Петрозаводский судебный участок", level: .magistrate)

        let rows = try MagistrateResultsParser.parse(html: html, court: court)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].caseNumber, "2-4004/2024")
        XCTAssertEqual(rows[0].caseID, "128701125")
        XCTAssertEqual(rows[0].caseUID, nil)
        XCTAssertEqual(rows[0].cardURL?.host, "petrozavodskoj.komi.msudrf.ru")
        XCTAssertEqual(MagistrateResultsParser.pageNumbers(html: html), [1])
    }

    func testCardParserReadsMagistrateTabs() throws {
        let html = """
        <div class="content lawcase-content">
          <h2>ДЕЛО № 2-4004/2024</h2>
          <div id="contentt">
            <div class="tab-content">
              <table>
                <tr><td>Уникальный идентификатор дела:</td><td>11MS0062-01-2024-005302-40</td></tr>
                <tr><td>Категория</td><td>О взыскании задолженности</td></tr>
                <tr><td>Председательствующий судья:</td><td>Бердашкевич Е. В.</td></tr>
                <tr><td>Дело рассмотрено (выдан приказ):</td><td>14.10.2024</td></tr>
                <tr><td>Результат рассмотрения:</td><td>Иск удовлетворен (Обжаловано)</td></tr>
                <tr><td>Дата вступления в законную силу:</td><td>14.08.2025</td></tr>
              </table>
            </div>
            <div class="tab-content">
              <table>
                <tr><td>Наименование события</td><td>Результат события</td><td>Дата события</td><td>Время события</td><td>Судья</td><td>Дата размещения</td></tr>
                <tr><td>Регистрация иска</td><td>Зарегистрировано</td><td>10.10.2024</td><td>09:00</td><td>Бердашкевич</td><td>10.10.2024</td></tr>
              </table>
            </div>
            <div class="tab-content">
              <table>
                <tr><td>Процессуальный статус лица</td><td>Лицо</td><td>Требования</td></tr>
                <tr><td>ИСТЕЦ</td><td>ООО Север</td><td></td></tr>
                <tr><td>ОТВЕТЧИК</td><td>Иванов И. И.</td><td></td></tr>
              </table>
            </div>
            <div class="tab-content"><div class="WordSection1"><p>РЕШЕНИЕ</p><p>Именем Российской Федерации</p></div></div>
          </div>
        </div>
        """

        let card = try MagistrateCardParser.parse(html: html)

        XCTAssertEqual(card.caseNumber, "2-4004/2024")
        XCTAssertEqual(card.uid, "11MS0062-01-2024-005302-40")
        XCTAssertEqual(card.judge, "Бердашкевич Е. В.")
        XCTAssertEqual(card.decisionDate, "14.10.2024")
        XCTAssertEqual(card.legalForceDate, "14.08.2025")
        XCTAssertEqual(card.sessions.first?.event, "Регистрация иска")
        XCTAssertEqual(card.parties.plaintiffs, ["ООО Север"])
        XCTAssertEqual(card.parties.defendants, ["Иванов И. И."])
        XCTAssertTrue(card.actText?.contains("Именем Российской Федерации") == true)
    }

    func testKCaptchaDetectedAndDateRules() {
        let html = """
        <h2>Для продолжения необходимо пройти дополнительную проверку</h2>
        <form method="post" id="kcaptchaForm">
          <img src="/captcha.php">
          <input type="text" name="captcha-response">
        </form>
        """

        XCTAssertTrue(CaptchaDetector.hasCaptcha(in: html))
        XCTAssertEqual(MagistratePageClassifier.classify(html: html), .captcha)
        XCTAssertTrue(MovementDateRule.before2026.matches(legalForceDate: "14.08.2025"))
        XCTAssertFalse(MovementDateRule.from2026.matches(legalForceDate: "14.08.2025"))
        XCTAssertFalse(MovementDateRule.before2026.matches(legalForceDate: "01.01.2026"))
        XCTAssertTrue(MovementDateRule.from2026.matches(legalForceDate: "01.01.2026"))
        XCTAssertTrue(MovementDateRule.before2026.matches(legalForceDate: nil))
        XCTAssertTrue(MovementDateRule.from2026.matches(legalForceDate: nil))
    }
}
