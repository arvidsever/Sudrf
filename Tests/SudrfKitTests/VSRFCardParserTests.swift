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

    // MARK: - Выдача

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
