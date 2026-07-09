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

    func testKSOYUInlineCaptchaFormIsCaptcha() {
        let html = """
        <html><body><form>
        <table><tr>
        <td>Проверочный код</td>
        <td>
          <input name="captcha" autocomplete="off" id="captcha" type="text">
          <img src="data: image/png;base64,iVBORw0KGgo=">
          <input name="captchaid" type="hidden" value="7q82qmq5gannfo1f03b69bigk7">
        </td>
        </tr></table>
        </form></body></html>
        """

        XCTAssertEqual(SearchPageClassifier.classify(html: html), .captcha)
    }

    func testKSOYUCounterWithEncodedCaptchaParamsDoesNotForceCaptcha() {
        let html = """
        <html><body>
        <div>Данных по запросу не обнаружено</div>
        <div class="counter">
          <img src="//counter.sudrf.ru/cnt.php?ssid=78KJ0003&amp;show=1&amp;ref=https%3A%2F%2F3kas.sudrf.ru%2Fmodules.php%3Fname%3Dsud_delo%26name_op%3Dr%26captcha%3D38957%26captchaid%3Dlcl5smco99g7sbpeoggtm15345&amp;pg=https%3A%2F%2F3kas.sudrf.ru%2Fmodules.php%3Fname%3Dsud_delo%26name_op%3Dcase">
        </div>
        </body></html>
        """

        XCTAssertEqual(SearchPageClassifier.classify(html: html), .empty)
    }

    func testCaptchaTextFallbackAllowsHiddenStateBesideEditableInput() {
        let html = """
        <html><body>
        <h2>Проверочный код</h2>
        <div><input type="hidden" name="session" value="abc"></div>
        <div><input type="text" name="answer"></div>
        </body></html>
        """

        XCTAssertTrue(CaptchaDetector.hasCaptcha(in: html))
    }

    func testCaptchaTextFallbackIgnoresHiddenOnlyInput() {
        let html = """
        <html><body>
        <h2>Проверочный код</h2>
        <div><input type="hidden" name="session" value="abc"></div>
        </body></html>
        """

        XCTAssertFalse(CaptchaDetector.hasCaptcha(in: html))
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
