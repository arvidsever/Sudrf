import XCTest
@testable import SudrfKit

/// Тесты разбора страниц Верховного Суда РФ (vsrf.ru) на РЕАЛЬНЫХ фикстурах —
/// дело Воробьёва (Республика Коми): жалоба «3-КФ22-336-К3» → истребование →
/// дело «3-КГ23-1-К3» (УИД 11RS0001-01-2021-021221-14).
/// Фикстуры: vsrf_card_vorobyev.html (карточка), vsrf_search_uid/number/number_fio.html (выдача).
final class VSRFCardParserTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "html",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("Фикстура \(name).html не найдена в бандле теста")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Карточка

    func testCardTwoProductions() throws {
        let card = try VSRFCardParser.parse(html: try loadFixture("vsrf_card_vorobyev"))
        XCTAssertEqual(card.productions.count, 2)
        XCTAssertEqual(card.uid, "11RS0001-01-2021-021221-14")
        XCTAssertEqual(card.primaryNumber, "3-КГ23-1-К3")
    }

    func testCardComplaint() throws {
        let card = try VSRFCardParser.parse(html: try loadFixture("vsrf_card_vorobyev"))
        let j = try XCTUnwrap(card.productions.first { $0.kind == .complaint })
        XCTAssertEqual(j.cardID, "21-33970283")
        XCTAssertEqual(j.number, "3-КФ22-336-К3")
        XCTAssertEqual(j.incomingDate, "08.11.2022")
        XCTAssertNil(j.uid)
        // Ссылка жалобы — раздел appeals (даже на карточке, где раздел выводится из типа).
        XCTAssertEqual(j.cardURL?.absoluteString, "https://vsrf.ru/lk/practice/appeals/21-33970283")
        XCTAssertEqual(j.cassationCourt, "Третий кассационный суд общей юрисдикции - 28.09.2022")
        XCTAssertEqual(j.appealedAct, "Апелляционное определение от 09.06.2022")
        XCTAssertEqual(j.applicant, "ВОРОБЬЁВ ВИКТОР ВИКТОРОВИЧ")
        XCTAssertEqual(j.firstInstance.court, "Сыктывкарский городской суд")
        XCTAssertEqual(j.firstInstance.caseNumber, "2-1649/2022")
        XCTAssertEqual(j.firstInstance.decisionDate, "02.03.2022")
        XCTAssertNil(j.rapporteur)
        XCTAssertTrue(j.caseRequested)
        XCTAssertEqual(j.events.first { $0.text.contains("Истребовано дело") }?.date, "19.12.2022")
    }

    func testTruncatedLegacyComplaintCannotBecomeEmptyCard() {
        let header = #"<div data-subscribe-claim-id="21-12345678"><div class="vs-items-separate vs-appeal-title"><span class="vs-items-label"><a>3-КФ24-1-К1</a></span></div>"#
        XCTAssertThrowsError(try VSRFCardParser.parse(html: header + "</div>"))

        let receiptOnly = #"<div class="row vs-item-detail"><div class="col-md-3">Дата поступления:</div><div class="col-md-7">08.11.2022</div></div>"#
        XCTAssertThrowsError(try VSRFCardParser.parse(html: header + receiptOnly + "</div>"))
    }

    func testLegacyCardAcceptsExplicitlyEmptyEventListWithPublishedDetails() throws {
        let header = #"<div data-subscribe-claim-id="21-12345678"><div class="vs-items-separate vs-appeal-title"><span class="vs-items-label"><a>3-КФ24-1-К1</a></span></div>"#
        let details = #"<div class="row vs-item-detail"><div class="col-md-3">Дата поступления:</div><div class="col-md-7">08.11.2022</div></div><div class="row vs-item-detail"><div class="col-md-3">Кассационный суд:</div><div class="col-md-7">Третий кассационный суд общей юрисдикции</div></div>"#
        let card = try VSRFCardParser.parse(html: header + details + "</div>")
        let complaint = try XCTUnwrap(card.productions.first)
        XCTAssertEqual(complaint.incomingDate, "08.11.2022")
        XCTAssertEqual(complaint.cassationCourt, "Третий кассационный суд общей юрисдикции")
        XCTAssertTrue(complaint.events.isEmpty)
    }

    func testCardCase() throws {
        let card = try VSRFCardParser.parse(html: try loadFixture("vsrf_card_vorobyev"))
        let d = try XCTUnwrap(card.productions.first { $0.kind == .caseFile })
        XCTAssertEqual(d.cardID, "12-34154493")
        XCTAssertEqual(d.number, "3-КГ23-1-К3")
        XCTAssertEqual(d.uid, "11RS0001-01-2021-021221-14")
        XCTAssertEqual(d.procedureType, "Гражданское судопроизводство")
        XCTAssertEqual(d.instanceType, "Кассация на вступившее в силу судебное решение")
        XCTAssertEqual(d.firstInstance.judge, "О.А. Машкалева")
        XCTAssertEqual(d.firstInstance.result, "Иск удовлетворён полностью")
        XCTAssertEqual(d.claimants, ["Воробьёв Виктор Викторович"])
        XCTAssertEqual(d.respondents, ["Администрация муниципального округа Хамовники"])
        XCTAssertEqual(d.rapporteur, "Жубрин М.А.")
        XCTAssertEqual(d.cardURL?.absoluteString, "https://vsrf.ru/lk/practice/cases/12-34154493")
        XCTAssertTrue(d.events.contains { $0.text.contains("Передано судье") && $0.date == "25.01.2023" })
        XCTAssertTrue(d.events.contains { $0.text.contains("Отказ в передаче") && $0.date == "10.03.2023" })
    }

    func testCurrentCardKeepsEventsAndPublishedResult() throws {
        let card = try VSRFCardParser.parse(html: try loadFixture("vsrf_current_card_340"))
        let production = try XCTUnwrap(card.productions.first)
        XCTAssertEqual(card.productions.count, 1)
        XCTAssertEqual(production.cardID, "12-36321243")
        XCTAssertEqual(production.cardSection, .claims)
        XCTAssertEqual(production.number, "3-ИКАД25-3-А2")
        XCTAssertEqual(production.uid, "11OS0000-01-2025-000169-68")
        XCTAssertEqual(production.cardURL?.absoluteString, "https://www.vsrf.ru/lk/practice/claims/12-36321243")
        XCTAssertEqual(production.events.map(\.date), ["16.09.2025", "15.10.2025", "15.10.2025"])
        XCTAssertEqual(production.events.map(\.text), [
            "Передано судье", "Результат рассмотрения", "Назначение даты судебного заседания"
        ])
        XCTAssertEqual(production.events[1].details,
                       "Вынесено решение по существу. Определение. Жалоба (представление) оставлена без удовлетворения")
        XCTAssertEqual(production.events[2].details,
                       "Дата размещения информации о времени и месте заседания 16.09.2025 16:24")
        XCTAssertEqual(production.publishedResult, "Определение. Жалоба (представление) оставлена без удовлетворения")
    }

    func testCurrentCardCollectsPublishedPDFLinksOncePerProduction() throws {
        let first = #"<div class="CaseStyle_case_item__test"><div class="CaseStyle_cardTitleRow__test"><a id="12-101-HASH"></a><span>3-ИКАД25-3-А2</span></div><div class="CaseStyle_eventsRow__test"><div class="CaseStyle_eventsRow_title__test">Движение по делу</div></div><div class="FinalActRow_container__test"><div class="FinalActRow_date__test">15.10.2025</div><div class="FinalActRow_col__test"><span><a href="/lk/practice/stor_pdf/2496438"><svg></svg></a></span><a href="https://vsrf.ru/lk/practice/stor_pdf/2496438?source=card">Определение.</a> Жалоба оставлена без удовлетворения</div></div></div>"#
        let second = #"<div class="CaseStyle_case_item__test"><div class="CaseStyle_cardTitleRow__test"><a id="12-102-HASH"></a><span>3-ИКАД25-4-А2</span></div><div class="CaseStyle_eventsRow__test"><div class="CaseStyle_eventsRow_title__test">Движение по делу</div></div><div class="FinalActRow_container__test"><div class="FinalActRow_date__test">16.10.2025</div><div class="FinalActRow_col__test"><a href="/lk/practice/stor_pdf/2496439">Постановление.</a><a href="/lk/practice/archive/second-round-act.pdf">Дополнительный PDF</a></div></div></div>"#
        let unrelated = #"<a href="https://example.com/lk/practice/stor_pdf/should-not-attach">Внешний акт</a>"#
        let html = #"<html><body>"# + first + second + unrelated + "</body></html>"

        let card = try VSRFCardParser.parse(html: html)

        XCTAssertEqual(card.productions.count, 2)
        let firstProduction = try XCTUnwrap(card.productions.first { $0.cardID == "12-101" })
        XCTAssertEqual(firstProduction.publishedActs, [
            VSRFPublishedAct(url: URL(string: "https://www.vsrf.ru/lk/practice/stor_pdf/2496438")!,
                            date: "15.10.2025", title: "Определение")
        ])
        let secondProduction = try XCTUnwrap(card.productions.first { $0.cardID == "12-102" })
        XCTAssertEqual(secondProduction.publishedActs.map(\.url.absoluteString), [
            "https://www.vsrf.ru/lk/practice/stor_pdf/2496439",
            "https://www.vsrf.ru/lk/practice/archive/second-round-act.pdf"
        ])
    }

    func testCurrentCardIgnoresNonVSOrNonPublishedFileURLs() throws {
        let html = #"<div class="CaseStyle_case_item__test"><div class="CaseStyle_cardTitleRow__test"><a id="12-103-HASH"></a><span>3-ИКАД25-5-А2</span></div><div class="CaseStyle_eventsRow__test"><div class="CaseStyle_eventsRow_title__test">Движение по делу</div></div><div class="FinalActRow_container__test"><div class="FinalActRow_date__test">15.10.2025</div><div class="FinalActRow_col__test"><a href="http://www.vsrf.ru/lk/practice/stor_pdf/1">HTTP</a><a href="https://vsrf.ru/lk/practice/cases/12-104">Карточка</a><a href="https://example.com/lk/practice/stor_pdf/2">Другой суд</a><a href="https://mos-gorsud.ru/documents/foreign.pdf">Решение</a></div></div></div>"#
        let production = try XCTUnwrap(VSRFCardParser.parse(html: html).productions.first)
        XCTAssertTrue(production.publishedActs.isEmpty)
    }

    func testLegacyCardCollectsOnlyPublishedActsFromTheirOwnProductionRows() throws {
        let first = #"<div data-subscribe-claim-id="21-111"><div class="vs-items-separate vs-appeal-title"><span class="vs-items-label"><a>3-КФ26-1-К1</a></span></div><div class="row vs-item-detail"><div class="col-md-3">Дата поступления:</div><div class="col-md-7">01.10.2025</div></div><div class="row vs-item-detail"><div class="col-md-3">Вид судопроизводства:</div><div class="col-md-7">Гражданское</div></div><div class="row vs-item-detail"><div class="col-md-3">Опубликованный судебный акт:</div><div class="col-md-7"><a href="/lk/practice/stor_pdf/301">Определение от 15.10.2025</a><a href="https://vsrf.ru/lk/practice/stor_pdf/301?copy=1">Определение от 15.10.2025</a></div></div></div>"#
        let second = #"<div data-subscribe-claim-id="12-222"><div class="vs-items-separate vs-case-title"><span class="vs-items-label"><a>3-КГ26-2-К1</a></span></div><div class="row vs-item-detail"><div class="col-md-3">Дата поступления:</div><div class="col-md-7">02.10.2025</div></div><div class="row vs-item-detail"><div class="col-md-3">Вид судопроизводства:</div><div class="col-md-7">Гражданское</div></div><div class="row vs-item-detail"><div class="col-md-3">Опубликованный судебный акт:</div><div class="col-md-7"><a href="/lk/practice/stor_pdf/302">Заочное решение от 16.10.2025</a></div></div></div>"#
        let html = "<html><body>" + first + second + "</body></html>"

        let card = try VSRFCardParser.parse(html: html)
        XCTAssertEqual(card.productions.count, 2)
        let complaint = try XCTUnwrap(card.productions.first { $0.cardID == "21-111" })
        XCTAssertEqual(complaint.publishedActs, [
            VSRFPublishedAct(url: URL(string: "https://www.vsrf.ru/lk/practice/stor_pdf/301")!,
                            date: "15.10.2025", title: "Определение")
        ])
        let caseFile = try XCTUnwrap(card.productions.first { $0.cardID == "12-222" })
        XCTAssertEqual(caseFile.publishedActs, [
            VSRFPublishedAct(url: URL(string: "https://www.vsrf.ru/lk/practice/stor_pdf/302")!,
                            date: "16.10.2025", title: "Заочное решение")
        ])
    }

    func testLegacyPublishedActDoesNotBorrowDateOrKindFromNeighboringRows() {
        let header = #"<div data-subscribe-claim-id="21-333"><div class="vs-items-separate vs-appeal-title"><span class="vs-items-label"><a>3-КФ26-3-К1</a></span></div><div class="row vs-item-detail"><div class="col-md-3">Дата поступления:</div><div class="col-md-7">01.10.2025</div></div>"#
        let missingOwnDate = #"<div class="row vs-item-detail"><div class="col-md-3">Опубликованный судебный акт:</div><div class="col-md-7"><a href="/lk/practice/stor_pdf/303">Определение</a></div></div><div class="row vs-item-detail"><div class="col-md-3">Обжалуется:</div><div class="col-md-7">Решение от 15.10.2025</div></div>"#
        XCTAssertThrowsError(try VSRFCardParser.parse(html: header + missingOwnDate + "</div>"))

        let missingOwnKind = #"<div class="row vs-item-detail"><div class="col-md-3">Опубликованный судебный акт:</div><div class="col-md-7"><a href="/lk/practice/stor_pdf/304">Скачать</a> 15.10.2025</div></div><div class="row vs-item-detail"><div class="col-md-3">Обжалуется:</div><div class="col-md-7">Определение от 15.10.2025</div></div>"#
        XCTAssertThrowsError(try VSRFCardParser.parse(html: header + missingOwnKind + "</div>"))
    }

    func testCurrentCardRequiresMovementSectionButAcceptsExplicitEmptySection() throws {
        let title = #"<div class="CaseStyle_cardTitleRow__test"><a id="12-1-HASH"></a><span>Дело №</span><span>3-КГ1-1-К1</span></div>"#
        let empty = #"<div class="CaseStyle_eventsRow__test"><div class="CaseStyle_eventsRow_title__test">Движение по делу</div></div>"#
        let card = try VSRFCardParser.parse(html: #"<div class="CaseStyle_case_item__test">"# + title + empty + "</div>")
        XCTAssertTrue(try XCTUnwrap(card.productions.first).events.isEmpty)
        XCTAssertThrowsError(try VSRFCardParser.parse(html: #"<div class="CaseStyle_case_item__test">"# + title + "</div>"))
    }

    func testCurrentCardRejectsMalformedMovementRow() {
        let html = #"<div class="CaseStyle_case_item__test"><div class="CaseStyle_cardTitleRow__test"><a id="12-1-HASH"></a><span>3-КГ1-1-К1</span></div><div class="CaseStyle_eventsRow__test"><div class="CaseStyle_eventsRow_title__test">Движение по делу</div><div>15.10.2025 сломанная строка</div></div></div>"#
        XCTAssertThrowsError(try VSRFCardParser.parse(html: html))
    }

    func testCurrentCardRejectsIncompletePublishedAct() {
        let card = #"<div class="CaseStyle_case_item__test"><div class="CaseStyle_cardTitleRow__test"><a id="12-1-HASH"></a><span>3-КГ1-1-К1</span></div><div class="CaseStyle_eventsRow__test"><div class="CaseStyle_eventsRow_title__test">Движение по делу</div></div>"#
        let malformed = [
            #"<div class="FinalActRow_container__test"><div class="FinalActRow_date__test">15.10.2025</div></div>"#,
            #"<div class="FinalActRow_container__test"><div class="FinalActRow_col__test">Определение</div></div>"#,
            #"<div class="FinalActRow_container__test"><div class="FinalActRow_date__test">15.10.2025</div><div class="FinalActRow_col__test"></div></div>"#
        ]
        for finalAct in malformed {
            XCTAssertThrowsError(try VSRFCardParser.parse(html: card + finalAct + "</div>"))
        }
    }

    func testCurrentCardKeepsAmbiguousPublishedResultAsSeparateEvent() throws {
        let header = #"<div class="CaseStyle_cardTitleRow__test"><a id="12-1-HASH"></a><span>3-КГ1-1-К1</span></div>"#
        let section = #"<div class="CaseStyle_eventsRow__test"><div class="CaseStyle_eventsRow_title__test">Движение по делу</div>"#
        let row = #"<div><div class="CaseStyle_appealEventRow_date__test">15.10.2025</div><div><div class="CaseStyle_case_value__test">Результат рассмотрения<br/>Вынесено решение по существу</div></div></div>"#
        let finalAct = #"<div class="FinalActRow_container__test"><div class="FinalActRow_date__test">15.10.2025</div><div class="FinalActRow_col__test">Определение. Жалоба оставлена без удовлетворения</div></div>"#
        let html = #"<div class="CaseStyle_case_item__test">"# + header + section + row + row + "</div>" + finalAct + "</div>"
        let production = try XCTUnwrap(VSRFCardParser.parse(html: html).productions.first)
        XCTAssertEqual(production.events.count, 3)
        XCTAssertEqual(production.events[0].details, "Вынесено решение по существу")
        XCTAssertEqual(production.events[1].details, "Вынесено решение по существу")
        XCTAssertEqual(production.events[2].text, "Определение. Жалоба оставлена без удовлетворения")
        XCTAssertNil(production.events[2].details)
    }

    func testUnknownAndEmptyCardMarkupFailsClosed() {
        XCTAssertThrowsError(try VSRFCardParser.parse(html: ""))
        XCTAssertThrowsError(try VSRFCardParser.parse(html: "<html><body><p>blocked</p></body></html>"))
    }

    // MARK: - Выдача

    func testLegacySearchDoesNotPublishOrValidateDocumentLinksBeforeCardFetch() throws {
        let html = try loadFixture("vsrf_search_uid").replacingOccurrences(of: "</body>", with:
            #"<div class="row vs-item-detail"><div class="col-md-7"><a href="/lk/practice/stor_pdf/123">Скачать</a></div></div></body>"#)
        let results = try VSRFSearchParser.parse(html: html)
        XCTAssertEqual(results.results.count, 1)
        XCTAssertTrue(results.results.allSatisfy { $0.publishedActs.isEmpty })
    }

    func testSearchByUID() throws {
        let res = try VSRFSearchParser.parse(html: try loadFixture("vsrf_search_uid"))
        XCTAssertEqual(res.total, 1)
        XCTAssertEqual(res.results.count, 1)
        let d = try XCTUnwrap(res.results.first)
        XCTAssertEqual(d.kind, .caseFile)
        XCTAssertEqual(d.cardID, "12-34154493")
        XCTAssertEqual(d.uid, "11RS0001-01-2021-021221-14")
        XCTAssertEqual(d.number, "3-КГ23-1-К3")
        XCTAssertEqual(d.cardURL?.absoluteString, "https://vsrf.ru/lk/practice/cases/12-34154493")
    }

    func testSearchByNumberFIO() throws {
        let res = try VSRFSearchParser.parse(html: try loadFixture("vsrf_search_number_fio"))
        XCTAssertEqual(res.total, 2)
        XCTAssertEqual(res.results.count, 2)
        let d = try XCTUnwrap(res.results.first { $0.kind == .caseFile })
        let j = try XCTUnwrap(res.results.first { $0.kind == .complaint })
        XCTAssertEqual(d.uid, "11RS0001-01-2021-021221-14")
        XCTAssertNil(j.uid)
        // Жалоба в выдаче тоже несёт ссылку — раздел appeals.
        XCTAssertEqual(j.cardID, "21-33970283")
        XCTAssertEqual(j.cardURL?.absoluteString, "https://vsrf.ru/lk/practice/appeals/21-33970283")
        XCTAssertEqual(d.cardURL?.absoluteString, "https://vsrf.ru/lk/practice/cases/12-34154493")
    }

    /// Ключевой сценарий: поиск по № дела 1-й инстанции возвращает дела РАЗНЫХ
    /// регионов с тем же номером (НАЙДЕНО: 10), а тройка отбирает ровно наши два
    /// производства (дело с УИД + жалоба без УИД).
    func testSearchByNumberFiltersByTriple() throws {
        let res = try VSRFSearchParser.parse(html: try loadFixture("vsrf_search_number"))
        XCTAssertEqual(res.total, 10)
        XCTAssertEqual(res.results.count, 10)

        let key = VSRFLinkKey(uid: "11RS0001-01-2021-021221-14",
                              firstInstanceCourt: "Сыктывкарский городской суд",
                              firstInstanceCaseNumber: "2-1649/2022",
                              applicantName: "Воробьёв Виктор Викторович")
        let mine = res.matching(key)
        XCTAssertEqual(mine.count, 2)                                  // дело + жалоба
        XCTAssertNotNil(mine.first { $0.uid != nil && $0.cardID == "12-34154493" })
        let complaint = try XCTUnwrap(mine.first { $0.uid == nil && $0.number == "3-КФ22-336-К3" })
        XCTAssertEqual(complaint.cardID, "21-33970283")
        XCTAssertEqual(complaint.cardURL?.absoluteString, "https://vsrf.ru/lk/practice/appeals/21-33970283")

        // Посторонние дела с тем же номером, но иным судом/ФИО — не матчатся.
        XCTAssertFalse(res.results.contains {
            $0.firstInstance.court == "Советский районный суд г. Нижний Новгород"
                && $0.linkKey.matches(key)
        })
    }

    func testCurrentSearchResultPreservesLinkageAndClaimsURL() throws {
        let res = try VSRFSearchParser.parse(html: try loadFixture("vsrf_current_search_positive"))
        XCTAssertEqual(res.total, 1)
        XCTAssertEqual(res.results.count, 1)
        let d = try XCTUnwrap(res.results.first)
        XCTAssertEqual(d.kind, .caseFile)
        XCTAssertEqual(d.cardID, "12-34154493")
        XCTAssertEqual(d.cardSection, .claims)
        XCTAssertEqual(d.cardURL?.absoluteString, "https://www.vsrf.ru/lk/practice/claims/12-34154493")
        XCTAssertEqual(d.number, "3-КГ23-1-К3")
        XCTAssertEqual(d.uid, "11RS0001-01-2021-021221-14")
        XCTAssertEqual(d.firstInstance.court, "Сыктывкарский городской суд")
        XCTAssertEqual(d.firstInstance.caseNumber, "2-1649/2022")
        XCTAssertEqual(d.firstInstance.decisionDate, "02.03.2022")
        XCTAssertEqual(d.firstInstance.judge, "О.А. Машкалева")
        XCTAssertEqual(d.firstInstance.result, "Иск удовлетворён полностью")
        XCTAssertEqual(d.claimants, ["Заявитель"])
        XCTAssertEqual(d.respondents, ["Ответчик"])
    }

    func testCurrentSearchEmptyResultRequiresExplicitZeroEvidence() throws {
        let result = try VSRFSearchParser.parse(html: try loadFixture("vsrf_current_search_empty"))
        XCTAssertEqual(result.total, 0)
        XCTAssertTrue(result.results.isEmpty)
    }

    func testUnknownSearchMarkupFailsClosed() {
        XCTAssertThrowsError(try VSRFSearchParser.parse(html: "<html><body><p>blocked</p></body></html>"))
    }

    func testCurrentSearchContainerWithoutCountCannotBecomeEmptySuccess() {
        let html = #"<div class="SearchPage_resultsBlock__test"><div class="SearchPage_results__test"></div></div>"#
        XCTAssertThrowsError(try VSRFSearchParser.parse(html: html))
    }

    func testPositiveCountWithoutProductionFailsClosed() {
        let html = #"<div class="SearchPage_resultsBlock__test"><span>Найдено: 1</span></div>"#
        XCTAssertThrowsError(try VSRFSearchParser.parse(html: html))
    }

    func testZeroCountWithProductionIsInconsistent() {
        let html = #"<div class="SearchPage_resultsBlock__test"><span>Найдено: 0</span><div class="CaseStyle_case_item__test"><a class="CaseStyle_case_link__test" href="/lk/practice/claims/12-34154493">3-КГ23-1-К3</a><span class="CaseStyle_registerDateRow_attribute__test">Уникальный идентификатор дела:</span><span class="CaseStyle_case_value__test">11RS0001-01-2021-021221-14</span></div></div>"#
        XCTAssertThrowsError(try VSRFSearchParser.parse(html: html))
    }

    func testCurrentRowWithoutLinkageEvidenceFailsClosed() {
        let html = #"<div class="SearchPage_resultsBlock__test"><span>Найдено: 1</span><div class="CaseStyle_case_item__test"><a class="CaseStyle_case_link__test" href="/lk/practice/claims/12-34154493">3-КГ23-1-К3</a></div></div>"#
        XCTAssertThrowsError(try VSRFSearchParser.parse(html: html))
    }

    func testMalformedUIDWithoutFirstInstanceTripleFailsClosed() {
        let html = #"<div class="SearchPage_resultsBlock__test"><span>Найдено: 1</span><div class="CaseStyle_case_item__test"><a class="CaseStyle_case_link__test" href="/lk/practice/claims/12-34154493">3-КГ23-1-К3</a><div class="RowElement_container__test"><span class="CaseStyle_registerDateRow_attribute__test">Уникальный идентификатор дела:</span><span class="CaseStyle_case_value__test">not-a-uid</span></div></div></div>"#
        XCTAssertThrowsError(try VSRFSearchParser.parse(html: html))
    }

    func testCurrentComplaintUsesBeneficiaryForLinkage() throws {
        let html = #"<div class="SearchPage_resultsBlock__test"><span>Найдено: 1</span><div class="CaseStyle_case_item__test"><a class="CaseStyle_case_link__test" href="/lk/practice/claims/21-00000001">3-КФ00-1-К0</a><div class="RowElement_container__test"><span class="CaseStyle_registerDateRow_attribute__test">Суд 1-й инстанции:</span><span class="CaseStyle_case_value__test">Городской суд. Решение от 01.01.2000. Судья: С. Судья Номер дела 1-й инстанции: 2-1/2000</span></div><div class="CaseStyle_case_personalList_item__test"><span class="CaseStyle_registerDateRow_attribute__test">Заявители:</span><span class="CaseStyle_case_personalListName__test">Никулин</span></div><div class="CaseStyle_case_personalList_item__test"><span class="CaseStyle_registerDateRow_attribute__test">В интересах:</span><span class="CaseStyle_case_personalListName__test">Воробьёв</span></div></div></div>"#
        let result = try VSRFSearchParser.parse(html: html)
        let complaint = try XCTUnwrap(result.results.first)
        XCTAssertEqual(complaint.kind, .complaint)
        XCTAssertEqual(complaint.claimants, ["Никулин"])
        XCTAssertEqual(complaint.applicant, "Воробьёв")
    }

    func testSearchCountMayExceedCurrentPageRows() throws {
        let fixture = try loadFixture("vsrf_search_number")
        let paginated = fixture.replacingOccurrences(of: "НАЙДЕНО: 10", with: "НАЙДЕНО: 11")
        let result = try VSRFSearchParser.parse(html: paginated)
        XCTAssertEqual(result.total, 11)
        XCTAssertEqual(result.results.count, 10)
    }

    // MARK: - Привязка по тройке (без УИД, иной формат ФИО)

    func testLinkToLowerCourtByTriple() throws {
        let res = try VSRFSearchParser.parse(html: try loadFixture("vsrf_search_number"))
        // Ключ из карточки нижестоящего суда без УИД: тот же суд+№, фамилия в
        // формате «Воробьев В.В.» (е вместо ё) — тройка должна совпасть.
        let lower = VSRFLinkKey(firstInstanceCourt: "СЫКТЫВКАРСКИЙ ГОРОДСКОЙ СУД",
                                firstInstanceCaseNumber: "2-1649/2022",
                                applicantName: "Воробьев В.В.")
        XCTAssertEqual(res.matching(lower).count, 2)
    }

    // MARK: - Сборка URL

    func testEndpointURLs() {
        XCTAssertEqual(VSRFEndpoint.searchURL(uniqueNumber: "11RS0001-01-2021-021221-14")?.absoluteString,
                       "https://vsrf.ru/lk/practice/claims?registerDateExact=off&considerationDateExact=off&numberExact=true&uniqueNumber=11RS0001-01-2021-021221-14")
        XCTAssertEqual(VSRFEndpoint.cardURL(productionID: "12-34154493", section: .cases)?.absoluteString,
                       "https://vsrf.ru/lk/practice/cases/12-34154493")
        XCTAssertEqual(VSRFEndpoint.cardURL(productionID: "21-33970283", section: .appeals)?.absoluteString,
                       "https://vsrf.ru/lk/practice/appeals/21-33970283")
        XCTAssertEqual(VSRFEndpoint.cardURL(productionID: "12-00000001", section: .claims)?.absoluteString,
                       "https://www.vsrf.ru/lk/practice/claims/12-00000001")
    }
}
