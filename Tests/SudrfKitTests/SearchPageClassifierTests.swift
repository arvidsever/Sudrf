import XCTest
@testable import SudrfKit

final class SearchPageClassifierTests: XCTestCase {

    // Выдача с одной строкой (та же синтетика, что у ResultsParserTests, —
    // живой HTML выдачи в фикстурах отсутствует, см. TODO внизу).
    func testResultsTableIsResults() {
        let html = """
        <html><body><table id="tablcont">
        <tr><td><a href="modules.php?name=sud_delo&amp;name_op=case&amp;case_id=98765&amp;case_uid=ABC">5-470/2026</a></td></tr>
        </table></body></html>
        """
        XCTAssertEqual(SearchPageClassifier.classify(html: html), .results)
    }

    // Ссылки на карточки побеждают капчу: на страницах КСОЮ капча-форма боковой
    // панели соседствует с выдачей — если дела найдены, это .results.
    func testResultsBeatEmbeddedCaptchaForm() {
        let html = """
        <html><body>
        <form><label>Проверочный код</label><input name="captcha"></form>
        <table><tr><td><a href="modules.php?name=sud_delo&amp;name_op=case&amp;case_id=1&amp;case_uid=X">88-1/2026</a></td></tr></table>
        </body></html>
        """
        XCTAssertEqual(SearchPageClassifier.classify(html: html), .results)
    }

    func testCaptchaInputIsCaptcha() {
        let html = "<html><form><input name=\"captcha\"><input name=\"captchaid\"></form></html>"
        XCTAssertEqual(SearchPageClassifier.classify(html: html), .captcha)
    }

    func testExpiredSessionIsCaptcha() {
        let html = "<html><body>Время жизни сессии закончилось</body></html>"
        XCTAssertEqual(SearchPageClassifier.classify(html: html), .captcha)
    }

    func testEmptyMarkersAreEmpty() {
        for marker in ["Данных по запросу не обнаружено",
                       "Данных по запросу не найдено",
                       "Ничего не найдено",
                       "Всего по запросу найдено — 0"] {
            let html = "<html><body><table><tr><td>\(marker)</td></tr></table></body></html>"
            XCTAssertEqual(SearchPageClassifier.classify(html: html), .empty, marker)
        }
    }

    func testJSStubIsUnrecognized() {
        // Заглушка с JS-редиректом — так выглядит анти-бот прослойка.
        let html = "<html><head><script>window.location.href='/challenge';</script></head><body></body></html>"
        XCTAssertEqual(SearchPageClassifier.classify(html: html), .unrecognized)
    }

    func testBlankPageIsUnrecognized() {
        XCTAssertEqual(SearchPageClassifier.classify(html: ""), .unrecognized)
    }

    // TODO: фикстура живой выдачи винтажного (VNKOD) суда — снять на машине
    // с доступом к sudrf.ru (например, anninsky--vrn.sudrf.ru) и проверить .results.
}
