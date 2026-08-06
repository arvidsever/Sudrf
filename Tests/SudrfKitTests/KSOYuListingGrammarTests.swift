import XCTest
import SwiftSoup
@testable import SudrfKit

/// Регрессия на грамматику сплошного перечня дел КСОЮ.
///
/// Фикстуры сняты живьём 06.08.2026 со Второго КСОЮ (`2kas.sudrf.ru`, капчи
/// на поиске нет) и Третьего КСОЮ (`3kas.sudrf.ru`, капча есть). Приложению
/// сплошной перечень не нужен — он нужен харвестеру правовой базы, поэтому
/// тест фиксирует **разметку страниц**, а не поведение `SudrfClient`.
/// Провенанс и разбор параметров — `Docs/architecture/ksoyu-listing-grammar.md`.
final class KSOYuListingGrammarTests: XCTestCase {

    /// 2 КСОЮ как `Court` — справочник хранит кассационные суды
    /// в `TerritorialCourt`, отсюда явное преобразование.
    private static let secondKSOYu = Court(
        domain: "2kas.sudrf.ru",
        title: "Второй кассационный суд",
        level: .cassation
    )

    private func loadFixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "html",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("Фикстура \(name).html не найдена в бандле теста")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Перечень: счётчик, страница, колонки

    /// `ksoyu_listing_acts.html` — гражданская кассация 2 КСОЮ, окно по дате
    /// **публикации** 01.06.2026–07.06.2026.
    func testListingCounterAndPageSize() throws {
        let html = try loadFixture("ksoyu_listing_acts")

        // Счётчик — единственный источник общего числа дел: разбивка по
        // страницам в разметке больше нигде не дублируется.
        let counter = try XCTUnwrap(
            html.range(of: #"Всего по запросу найдено — (\d+)\."#, options: .regularExpression)
                .map { String(html[$0]) }
        )
        XCTAssertEqual(counter, "Всего по запросу найдено — 530.")
        XCTAssertTrue(html.contains("На странице записи с 1"))

        let doc = try SwiftSoup.parse(html)
        let table = try XCTUnwrap(try doc.select("table#tablcont").first(),
                                  "перечень живёт в table#tablcont")
        let rows = try table.select("tr").array()
        // 1 шапка + 25 дел. 25 записей на страницу — постоянная величина
        // движка, а не следствие параметров запроса.
        XCTAssertEqual(rows.count, 26)
    }

    func testListingHasEightColumns() throws {
        let doc = try SwiftSoup.parse(try loadFixture("ksoyu_listing_acts"))
        let header = try XCTUnwrap(try doc.select("table#tablcont tr").first())
        let titles = try header.select("th").array().map {
            try $0.text().replacingOccurrences(of: "\n", with: " ")
        }
        XCTAssertEqual(titles.count, 8)
        XCTAssertEqual(titles.first, "№ дела")
        // Последняя колонка — «Судебные акты»; ради неё харвестеру хватает
        // одного запроса на дело вместо двух (см. testActLinkInLastColumn).
        XCTAssertEqual(titles.last, "Судебные акты")
    }

    /// Строка выдачи самодостаточна: номер, дата поступления, категория,
    /// судья, дата и результат берутся без открытия карточки.
    func testListingRowCarriesFullRequisites() throws {
        let results = try ResultsParser.parse(html: try loadFixture("ksoyu_listing_acts"),
                                              court: Self.secondKSOYu)
        XCTAssertEqual(results.count, 25)

        let first = try XCTUnwrap(results.first)
        XCTAssertEqual(first.caseNumber, "8Г-15211/2026 [88-14715/2026]")
        XCTAssertEqual(first.caseID, "18223875")
        XCTAssertEqual(first.caseUID, "3128af6a-aafd-43ab-a873-18c4f46b860e")
        XCTAssertEqual(first.receiptDate, "28.04.2026")
        XCTAssertEqual(first.judge, "Попова Елена Викторовна")
        XCTAssertEqual(first.decisionDate, "14.05.2026")
        XCTAssertTrue((first.essence ?? "").contains("КАТЕГОРИЯ"))
    }

    /// `ResultsParser` забирает ссылку на текст акта из живой строки выдачи.
    /// Под фильтром по дате публикации она есть у каждого дела на странице.
    func testResultsParserPicksUpActLinks() throws {
        let results = try ResultsParser.parse(html: try loadFixture("ksoyu_listing_acts"),
                                              court: Self.secondKSOYu)
        XCTAssertEqual(results.count, 25)
        XCTAssertTrue(results.allSatisfy { $0.actTextLinks.count == 1 })

        let link = try XCTUnwrap(results.first?.actTextLinks.first)
        XCTAssertEqual(link.number, "18565938")
        XCTAssertEqual(link.textNumber, 1)
        XCTAssertEqual(link.kind, "Постановления")
        XCTAssertEqual(link.url.host, "2kas.sudrf.ru")
    }

    /// Без фильтра по публикации акт есть не у всех: 262-ФЗ публикует не всё.
    /// Пустой `actTextLinks` — законное состояние, а не сбой разбора.
    func testActLinksAreOptionalInKoAPListing() throws {
        let results = try ResultsParser.parse(html: try loadFixture("ksoyu_listing_adm33_koap"),
                                              court: Self.secondKSOYu)
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.contains { $0.actTextLinks.isEmpty })
        XCTAssertTrue(results.allSatisfy { $0.actTextLinks.allSatisfy { !$0.number.isEmpty } })
    }

    // MARK: - Ссылка на текст акта

    /// Ключ к экономике сбора: в последней колонке лежит прямая ссылка
    /// `name_op=doc`. Фильтр по дате публикации гарантирует её у каждой
    /// строки — акт попадает в выборку именно потому, что уже опубликован.
    func testActLinkInLastColumn() throws {
        let doc = try SwiftSoup.parse(try loadFixture("ksoyu_listing_acts"))
        let rows = try doc.select("table#tablcont tr").array().dropFirst()

        var links: [String] = []
        for row in rows {
            let cells = try row.select("td").array()
            XCTAssertEqual(cells.count, 8)
            let hrefs = try XCTUnwrap(cells.last).select("a").array()
                .compactMap { try? $0.attr("href") }
            // Ровно один акт на дело: 270 дел четырёх картотек, снятых
            // по фильтру публикации, не дали ни одной строки с двумя
            // ссылками. Несколько актов на дело возможны, но редки.
            let label = (try? row.select("td").first()?.text()) ?? nil
            XCTAssertEqual(hrefs.count, 1, "строка \(label ?? "?")")
            links.append(contentsOf: hrefs)
        }
        XCTAssertEqual(links.count, 25)

        let sample = try XCTUnwrap(links.first)
        XCTAssertEqual(ResultsParser.queryValue("name_op", in: sample), "doc")
        XCTAssertEqual(ResultsParser.queryValue("number", in: sample), "18565938")
        XCTAssertEqual(ResultsParser.queryValue("delo_id", in: sample), "2800001")
        // Номер акта внутри дела. При единственном акте это всегда 1;
        // `text_number=2` на таком деле отдаёт «ПУСТОЙ ДОКУМЕНТ».
        XCTAssertEqual(ResultsParser.queryValue("text_number", in: sample), "1")
    }

    /// `ksoyu_act_doc.html` — страница `name_op=doc` по ссылке из строки выше.
    ///
    /// Текст акта приклеен к странице как вложенный документ
    /// (`<HTML><BODY><SPAN style="TEXT-ALIGN: justify">…`) и попадает
    /// в `div#content`. `div#doccont` — это только кнопка печати, за текстом
    /// туда ходить нельзя.
    func testActDocumentPageCarriesRulingText() throws {
        let html = try loadFixture("ksoyu_act_doc")
        let doc = try SwiftSoup.parse(html)

        XCTAssertEqual(try doc.select("div#doccont").first()?.text(), "",
                       "div#doccont — кнопка печати, а не текст акта")

        let container = try XCTUnwrap(try doc.select("div#content").first(),
                                      "текст акта лежит в div#content")
        let text = try container.text()
        XCTAssertTrue(text.contains("Дело № 88-14715/2026"))
        XCTAssertTrue(text.contains("УИД 77RS0020-02-2025-007285-88"))
        XCTAssertTrue(text.contains("О П Р Е Д Е Л Е Н И Е"))
        XCTAssertFalse(text.contains("ПУСТОЙ ДОКУМЕНТ"))

        // 262-ФЗ: персональные данные в публикуемом тексте обезличены
        // до ФИО1/ФИО2 и ДД.ММ.ГГГГ — сторон из акта восстановить нельзя,
        // реквизиты берутся из строки выдачи.
        XCTAssertTrue(text.contains("ФИО1"))
        XCTAssertTrue(text.contains("ДД.ММ.ГГГГ"))
    }

    /// Экономика сбора: текст с `name_op=doc` совпадает с блоком `cont_doc1`
    /// вкладки «Судебные акты» карточки того же дела (case_id=18223875).
    /// Значит на дело хватает **одного** запроса, а не двух.
    func testActTextEqualsCaseCardBlock() throws {
        let fromDoc = try XCTUnwrap(
            try SwiftSoup.parse(try loadFixture("ksoyu_act_doc"))
                .select("span[style*=TEXT-ALIGN]").first()?.text()
        )
        let fromCard = try XCTUnwrap(
            try SwiftSoup.parse(try loadFixture("ksoyu_case_card"))
                .select("div#cont_doc1 span[style*=TEXT-ALIGN]").first()?.text()
        )
        XCTAssertFalse(fromDoc.isEmpty)
        XCTAssertEqual(fromDoc, fromCard)
    }

    // MARK: - КАС против КоАП

    /// Спор источников о кассационной картотеке КАС решается разметкой:
    /// `delo_id=2550001` / `adm33_case` — это не КАС, а дела об
    /// **административных правонарушениях** (КоАП). Видно и по номерам
    /// (`16-…` вместо `8а-…/88а-…`), и по заголовку третьей колонки.
    func testAdm33CartotekaIsKoAPNotKAS() throws {
        let doc = try SwiftSoup.parse(try loadFixture("ksoyu_listing_adm33_koap"))
        let header = try XCTUnwrap(try doc.select("table#tablcont tr").first())
        let titles = try header.select("th").array().map { try $0.text() }
        XCTAssertEqual(titles[2], "Правонарушение / Нижестоящий суд (мировой судья)")

        let results = try ResultsParser.parse(html: try loadFixture("ksoyu_listing_adm33_koap"),
                                              court: Self.secondKSOYu)
        let first = try XCTUnwrap(results.first)
        XCTAssertEqual(first.caseNumber, "16-4366/2026")
        XCTAssertTrue((first.essence ?? "").contains("КоАП РФ"))
        XCTAssertFalse(first.caseNumber.contains("8а-"))
    }

    // MARK: - Тихие отказы

    /// Худший режим отказа платформы: `delo_id=2800001` с `new=0` —
    /// заведомо неполный запрос — отдаёт 200, форму поиска и текст
    /// «Данных по запросу не обнаружено». Ни `tablcont`, ни счётчика.
    ///
    /// Для харвестера это значит: **пустая выдача не доказывает отсутствие
    /// дел**. Отличать надо по наличию `table#tablcont`, а не по счётчику
    /// и не по маркеру пустоты.
    func testWrongNewParameterLooksLikeAnEmptyResultSet() throws {
        let html = try loadFixture("ksoyu_listing_bad_new")

        XCTAssertTrue(html.contains("Данных по запросу не обнаружено"))
        XCTAssertFalse(html.contains("Всего по запросу найдено"))
        let doc = try SwiftSoup.parse(html)
        XCTAssertTrue(try doc.select("table#tablcont").isEmpty())

        // Текущее поведение SudrfKit: кривой запрос неотличим от честного
        // «дел нет». Приложению это не вредит (оно шлёт `new` из
        // CartotekaRegistry), но харвестеру одного классификатора мало —
        // он обязан дополнительно требовать `table#tablcont`.
        XCTAssertEqual(SearchPageClassifier.classify(html: html), .empty)
        XCTAssertTrue(try ResultsParser.parse(html: html, court: Self.secondKSOYu).isEmpty)
    }

    /// Капча-суд (`3kas`) на запрос перечня **без** пары `captcha`+`captchaid`
    /// отвечает не формой и не пустотой, а видимым `div#error` «Неверно указан
    /// проверочный код с картинки». То есть отсутствующий код сервер трактует
    /// как неверный — сигнал чистый и отличим от тихого отказа выше.
    func testCaptchaCourtGatesTheListing() throws {
        let html = try loadFixture("ksoyu_listing_captcha_gate")

        XCTAssertFalse(html.contains("Всего по запросу найдено"))
        XCTAssertFalse(html.contains("Данных по запросу не обнаружено"))

        let doc = try SwiftSoup.parse(html)
        let error = try XCTUnwrap(try doc.select("div#error").first()).text()
        XCTAssertTrue(error.hasPrefix("Неверно указан проверочный код с картинки"))

        XCTAssertEqual(SearchPageClassifier.classify(html: html), .captchaRejected)
    }
}
