import XCTest
@testable import SudrfKit

/// Endpoint, маршрутизация картотек и московская ветка движения (mos-gorsud.ru).
/// Эталон URL и коды instance/processType — из живого портала (webarchive,
/// scripts.js: instanceTypes/processTypes, mgsLinksMapping/rsLinksMapping).
final class MosGorSudTests: XCTestCase {

    // MARK: - endpoint

    func testSearchURL() throws {
        let url = try XCTUnwrap(MosGorSudEndpoint.searchURL(
            uid: "77RS0021-01-2024-001234-56", instance: 1, processType: .civil))
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("https://mos-gorsud.ru/search?"))
        XCTAssertTrue(s.contains("uid=77RS0021-01-2024-001234-56"))
        XCTAssertTrue(s.contains("instance=1"))
        XCTAssertTrue(s.contains("processType=2"))
        XCTAssertTrue(s.contains("courtAlias="))
        // page/formType в живом URL портала отсутствуют — не шлём.
        XCTAssertFalse(s.contains("formType"))
        XCTAssertFalse(s.contains("page="))
    }

    func testSearchURLEncodesCyrillicAsUTF8() throws {
        let url = try XCTUnwrap(MosGorSudEndpoint.searchURL(
            participant: "Иванов", instance: 2, processType: .criminal))
        let s = url.absoluteString
        // UTF-8 percent-encoding (не cp1251, как у sud_delo): «И» → %D0%98
        XCTAssertTrue(s.contains("participant=%D0%98%D0%B2%D0%B0%D0%BD%D0%BE%D0%B2"))
        XCTAssertTrue(s.contains("processType=6"))
        XCTAssertTrue(s.contains("instance=2"))
    }

    // MARK: - маршрутизация картотек

    func testRoutingMap() {
        func route(_ level: CourtLevel, _ id: String) -> (MosGorSudProcessType, Int)? {
            CartotekaRegistry.find(level: level, id: id).map {
                let r = MosGorSudRouting.map(cartoteka: $0)
                return (r.processType, r.instance)
            }
        }
        XCTAssertEqual(route(.district, "u1")?.0, .criminal)
        XCTAssertEqual(route(.district, "u1")?.1, 1)
        XCTAssertEqual(route(.district, "g1")?.0, .civil)
        XCTAssertEqual(route(.district, "p1")?.0, .cas)
        XCTAssertEqual(route(.district, "adm")?.0, .admin)
        XCTAssertEqual(route(.district, "admj")?.0, .admin)
        XCTAssertEqual(route(.district, "admj")?.1, 1)
        XCTAssertEqual(route(.district, "m")?.0, .material)
        XCTAssertEqual(route(.subject, "u2")?.1, MosGorSudInstance.appeal)     // 2
        // Кассация нашего реестра (суффикс 3/33) на портале — `4` (Кассационная),
        // НЕ `3` (это «Второй пересмотр»/надзор).
        XCTAssertEqual(route(.subject, "g33")?.1, MosGorSudInstance.cassation) // 4
        XCTAssertEqual(route(.subject, "u33")?.1, MosGorSudInstance.cassation) // 4
    }

    func testInstanceCodes() {
        XCTAssertEqual(MosGorSudInstance.first, 1)
        XCTAssertEqual(MosGorSudInstance.appeal, 2)
        XCTAssertEqual(MosGorSudInstance.review, 3)     // Второй пересмотр (надзор)
        XCTAssertEqual(MosGorSudInstance.cassation, 4)  // Кассационная
    }

    func testMoscowRegistrationNumbersAcceptOnlyEquivalentZeroPadding() {
        XCTAssertTrue(MosGorSudRouting.sameRegistrationNumber("2-1/2026", "02-0001/2026"))
        XCTAssertFalse(MosGorSudRouting.sameRegistrationNumber("2-1/2026", "2-10/2026"))
        XCTAssertFalse(MosGorSudRouting.sameRegistrationNumber("2-1/2026", "2-1/2025"))
    }

    func testSectionSegments() {
        // Первая × Гражданское → CS → first-civil (МГС) / civil (райсуд).
        XCTAssertEqual(MosGorSudRouting.sectionSegments(processType: .civil, instance: 1),
                       ["first-civil", "civil"])
        // Первая × КАС → CS_KAS → first-admin (МГС) / kas (райсуд).
        XCTAssertTrue(MosGorSudRouting.sectionSegments(processType: .cas, instance: 1)
                        .contains("first-admin"))
        // Апелляция × Уголовное → UA(+UA_APPEAL) → appeal-criminal (+board-criminal).
        XCTAssertTrue(MosGorSudRouting.sectionSegments(processType: .criminal, instance: 2)
                        .contains("appeal-criminal"))
    }

    /// Кассация (instance = 4): у гражданских/уголовных/КАС ключи CN/UN/CN_KAS,
    /// которых нет в маппингах САМОГО портала — кассации (КСОЮ, ВС) на
    /// mos-gorsud не публикуются. Пустое множество здесь — правда о портале,
    /// а не пробел; фильтр в этом случае просто не применяется (fail-open).
    func testCassationSectionsAbsentOnPortalExceptKoAP() {
        let cassation = MosGorSudInstance.cassation
        XCTAssertTrue(MosGorSudRouting.sectionSegments(processType: .civil, instance: cassation).isEmpty)
        XCTAssertTrue(MosGorSudRouting.sectionSegments(processType: .criminal, instance: cassation).isEmpty)
        XCTAssertTrue(MosGorSudRouting.sectionSegments(processType: .cas, instance: cassation).isEmpty)
        // Единственное «верхнее», что на портале есть, — КоАП-надзор (ключ AN).
        XCTAssertEqual(MosGorSudRouting.sectionSegments(processType: .admin, instance: cassation),
                       ["review-supervision"])
        XCTAssertEqual(MosGorSudRouting.sectionSegments(processType: .admin,
                                                        instance: MosGorSudInstance.review),
                       ["review-supervision"])
    }

    func testIsMosGorSudDomain() {
        XCTAssertTrue(MosGorSudRouting.isMosGorSud(domain: "mos-gorsud.ru"))
        XCTAssertTrue(MosGorSudRouting.isMosGorSud(domain: "www.mos-gorsud.ru"))
        XCTAssertFalse(MosGorSudRouting.isMosGorSud(domain: "syktsud--komi.sudrf.ru"))
    }

    // MARK: - парсеры на ЖИВЫХ фикстурах портала

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "html",
                              subdirectory: "Fixtures/mosgorsud"),
            "фикстура \(name).html отсутствует")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Выдача поиска: строки — `<tr data-href=…>`, раздел из пути, колонки по
    /// заголовкам. Фикстура — живой поиск по МГС (participant=Воробьёв, КАС).
    func testResultsParserOnLiveSearchFixture() throws {
        let rows = try MosGorSudResultsParser.parse(html: fixture("search-mgs-participant"))
        XCTAssertEqual(rows.count, 11)
        // Все строки этого поиска — раздел first-admin (КАС первой инстанции МГС).
        XCTAssertTrue(rows.allSatisfy { $0.section == "first-admin" })
        let first = try XCTUnwrap(rows.first)
        XCTAssertEqual(first.caseNumber, "3а-2719/2023")
        XCTAssertEqual(first.judge, "Баталова И.С.")
        XCTAssertEqual(first.result, "Вступило в силу, 05.04.2023")
        XCTAssertEqual(
            first.cardURL?.absoluteString,
            "https://mos-gorsud.ru/mgs/services/cases/first-admin/details/df043061-4638-11ed-8d08-f17fce8d2817")
    }

    func testSearchParserAcceptsOnlyExplicitEmptyShape() throws {
        let empty = "<table><thead><tr><th>№ дела</th><th>Стороны</th></tr></thead><tbody></tbody></table>"
        XCTAssertEqual(try MosGorSudResultsParser.parse(html: empty), [])
        XCTAssertThrowsError(try MosGorSudResultsParser.parse(
            html: "<html><script>location='/protection'</script></html>"))
    }

    func testSearchAndCardParsersRejectMaintenanceStub() {
        let html = "<main>Информация временно недоступна. Попробуйте обратиться позже.</main>"
        XCTAssertThrowsError(try MosGorSudResultsParser.parse(html: html))
        XCTAssertThrowsError(try MosGorSudCardParser.parse(html: html))
    }

    func testCardParserRejectsUnknownHTML() {
        XCTAssertThrowsError(try MosGorSudCardParser.parse(
            html: "<html><script>location='/protection'</script></html>"))
    }

    /// Карточка (гражданское дело, райсуд): пары div.left/div.right, латинская C
    /// в «Cудья», заседания из таблицы «Зал», акт по ссылке cases/docs/content.
    func testCardParserOnLiveCivilCard() throws {
        let card = try MosGorSudCardParser.parse(html: fixture("starodubtseva-card"))
        XCTAssertEqual(card.uid, "77RS0023-02-2024-021289-96")
        XCTAssertEqual(card.caseNumber, "02-3501/2025")
        XCTAssertEqual(card.judge, "Дроздова С.А.")   // ключ «Cудья» с латинской C
        XCTAssertEqual(card.receiptDate, "11.12.2024")
        XCTAssertEqual(card.result, "Обжаловано в кассации, 08.06.2026")
        XCTAssertEqual(card.legalForceDate, "14.04.2026")
        XCTAssertEqual(card.higherNumber, "33-13563/2026")
        XCTAssertEqual(card.category?.hasPrefix("219"), true)
        XCTAssertEqual(card.sessions.count, 5)
        let s0 = try XCTUnwrap(card.sessions.first)
        XCTAssertEqual(s0.date, "27.02.2025")
        XCTAssertEqual(s0.time, "09:55")
        XCTAssertEqual(s0.event, "Беседа")
        XCTAssertEqual(s0.result, "Проведена")
        XCTAssertEqual(
            card.actLinks.first?.absoluteString,
            "https://mos-gorsud.ru/rs/savelovskij/cases/docs/content/d3e5cea0-a297-11f0-b7af-e567c7a96e10")
        XCTAssertTrue(card.participants.contains("Истец: Стародубцева Е.Н."))
        XCTAssertTrue(card.participants.contains("Ответчик: ПАО Банк ВТБ"))
    }

    /// Карточка КАС (МГС): другой раздел, УИД 77OS…, вложений несколько.
    func testCardParserOnLiveKasCard() throws {
        let card = try MosGorSudCardParser.parse(html: fixture("first-admin-card"))
        XCTAssertEqual(card.uid, "77OS0000-01-2020-003295-18")
        XCTAssertEqual(card.caseNumber, "3а-3843/2020")
        XCTAssertEqual(card.judge, "Михалева Т.Д.")
        XCTAssertEqual(card.receiptDate, "18.03.2020")
        XCTAssertEqual(card.sessions.count, 8)
        XCTAssertEqual(card.actFiles.count, 4)
        XCTAssertEqual(card.actFiles.map(\.date),
                       ["20.03.2020", "20.03.2020", "26.10.2020", "05.10.2021"])
        XCTAssertEqual(card.actFiles.map(\.title), [
            "Определение о подготовке дела к судебному разбирательству",
            "Определение об отказе в применении мер по обеспечению (предварительной защите) иска",
            "Мотивированное решение",
            "ОПРЕДЕЛЕНИЕ",
        ])
        XCTAssertEqual(Set(card.actLinks).count, 4)
        XCTAssertTrue(card.participants.contains { $0.hasPrefix("Административный истец:") })
    }

    func testIssue413OwnAppealFieldsAreNotTakenFromLowerInstance() throws {
        for (name, number) in [("issue413-appeal-2020", "33-20562/2020"),
                               ("issue413-appeal-2021", "33-6416/2021")] {
            let card = try MosGorSudCardParser.parse(html: fixture(name))
            XCTAssertEqual(card.uid, "77RS0032-01-2020-000111-11")
            XCTAssertEqual(card.caseNumber, number)
            XCTAssertNil(card.court, "source identity is not available to a context-free parse")
            XCTAssertNil(card.judge, "lower-instance judge must not become the appeal judge")
        }
    }

    func testIssue413LowerOnlyFieldsDoNotBecomeOwnFields() throws {
        let html = """
        <div class="row"><div class="left">Уникальный идентификатор дела</div><div class="right">77RS0032-01-2020-000111-11</div></div>
        <div class="row"><div class="left">Номер дела в суде нижестоящей инстанции</div><div class="right">02-0001/2020</div></div>
        <div class="row"><div class="left">Суд первой инстанции, судья</div><div class="right">Синтетический районный суд (Синтетический судья А.А.)</div></div>
        """
        let card = try MosGorSudCardParser.parse(html: html)
        XCTAssertEqual(card.uid, "77RS0032-01-2020-000111-11")
        XCTAssertNil(card.caseNumber)
        XCTAssertNil(card.court)
        XCTAssertNil(card.judge)
    }

    func testIssue413ExactJudgeFieldsKeepLatinAndCyrillicC() throws {
        for label in ["Cудья", "Судья"] {
            let html = """
            <div class="row"><div class="left">Уникальный идентификатор дела</div><div class="right">77RS0032-01-2020-000111-11</div></div>
            <div class="row"><div class="left">Номер жалобы ~ дела</div><div class="right">33-1/2026</div></div>
            <div class="row"><div class="left">Суд первой инстанции, судья</div><div class="right">Синтетический районный суд (Синтетический судья А.А.)</div></div>
            <div class="row"><div class="left">\(label)</div><div class="right">Собственный судья Б.Б.</div></div>
            """
            XCTAssertEqual(try MosGorSudCardParser.parse(html: html).judge, "Собственный судья Б.Б.")
        }
    }

    func testIssue413KeepsDecisionFallbackWhenCurrentStateIsAbsent() throws {
        let card = try MosGorSudCardParser.parse(html: """
        <div class="left">Номер дела</div><div class="right">02-1/2026</div>
        <div class="left">Решение первой инстанции</div><div class="right">Иск удовлетворён, 01.02.2026</div>
        <div class="left">Дата вступления решения в силу</div><div class="right">12.02.2026</div>
        <div class="left">Номер дела в суде вышестоящей инстанции</div><div class="right">33-2/2026</div>
        """)
        XCTAssertEqual(card.result, "Иск удовлетворён, 01.02.2026")
        XCTAssertEqual(card.legalForceDate, "12.02.2026")
        XCTAssertEqual(card.higherNumber, "33-2/2026")
    }

    func testIssue413DistrictOwnCourtMatchesShortAndFullDirectoryTitleOnly() throws {
        let sourceURL = try XCTUnwrap(URL(string:
            "https://mos-gorsud.ru/rs/cheremushkinskij/services/cases/first-civil/details/synthetic"))
        for title in ["Черёмушкинский районный суд",
                      "Черемушкинский районный суд города Москвы"] {
            let card = try MosGorSudCardParser.parse(
                html: """
                <div class="left">Номер дела</div><div class="right">02-1/2026</div>
                <div class="left">Наименование суда</div><div class="right">\(title)</div>
                """,
                sourceURL: sourceURL)
            XCTAssertEqual(card.court, "Черёмушкинский районный суд")
        }

        for title in ["Тверской районный суд",
                      "Черемушкинский районный суд города Твери"] {
            XCTAssertThrowsError(try MosGorSudCardParser.parse(
                html: """
                <div class="left">Номер дела</div><div class="right">02-1/2026</div>
                <div class="left">Наименование суда</div><div class="right">\(title)</div>
                """,
                sourceURL: sourceURL))
        }
    }

    func testIssue413ForeignAppealSectionIsRejectedAtMovementBoundary() async throws {
        let foreignURL = try XCTUnwrap(URL(string:
            "https://mos-gorsud.ru/mgs/services/cases/appeal-criminal/details/foreign"))
        let uid = "77RS0032-01-2020-000111-11"
        let provider = MockMosGorSud(
            searchByInstance: [MosGorSudInstance.appeal: [
                MosGorSudResult(caseNumber: "33-6416/2021", uid: uid, cardURL: foreignURL),
            ]],
            cards: [
                "synthetic-base": MosGorSudCard(uid: uid, caseNumber: "02-0001/2020",
                                                 court: "Черёмушкинский районный суд"),
                "foreign": MosGorSudCard(uid: uid, caseNumber: "33-6416/2021",
                                          court: "Московский городской суд"),
            ])
        let service = MovementService(client: MockEmptyCase(), higherCourtDomains: [],
                                      mosgorsud: provider)
        let baseURL = try XCTUnwrap(URL(string:
            "https://mos-gorsud.ru/rs/cheremushkinskij/services/cases/civil/details/synthetic-base"))
        let base = MosGorSudResult(caseNumber: "02-0001/2020", uid: uid,
                                   court: "Черёмушкинский районный суд", cardURL: baseURL)
        let cartoteka = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let movement = try await service.moscowMovement(for: base, cartoteka: cartoteka)
        XCTAssertFalse(movement.instances.contains { $0.level == .appeal })
        assertMoscowAppealCoverageIsPartial(movement)
    }

    func testIssue413ParsedSourceFlowsThroughClientIntoMovement() async throws {
        for (cardName, number) in [("issue413-appeal-2020", "33-20562/2020"),
                                   ("issue413-appeal-2021", "33-6416/2021")] {
            let movement = try await issue413Movement(
                appealCardName: cardName, resultNumber: number,
                resultUID: "77RS0032-01-2020-000111-11")
            let first = try XCTUnwrap(movement.instances.first)
            XCTAssertEqual(first.caseNumber, "02-0001/2020")
            XCTAssertEqual(first.court, "Черёмушкинский районный суд")
            XCTAssertEqual(first.judge, "Собственный районный судья")
            let appeal = try XCTUnwrap(movement.instances.first { $0.level == .appeal })
            XCTAssertEqual(appeal.caseNumber, number)
            XCTAssertEqual(appeal.court, "Московский городской суд")
            XCTAssertNil(appeal.judge)
            XCTAssertNotEqual(first.caseNumber, appeal.caseNumber)
        }
    }

    func testIssue413UpperCandidateIdentityMustMatchBeforeCoverage() async throws {
        let wrongNumber = try await issue413Movement(
            appealCardName: "issue413-appeal-2020",
            resultNumber: "33-6416/2021",
            resultUID: "77RS0032-01-2020-000111-11")
        XCTAssertFalse(wrongNumber.instances.contains { $0.level == .appeal })
        assertMoscowAppealCoverageIsPartial(wrongNumber)

        let wrongUID = try await issue413Movement(
            appealCardName: "issue413-appeal-2021",
            resultNumber: "33-6416/2021",
            resultUID: "77RS0032-01-2020-000112-12")
        XCTAssertFalse(wrongUID.instances.contains { $0.level == .appeal })
        assertMoscowAppealCoverageIsPartial(wrongUID)

        let contradictoryCourtCard = try fixture("issue413-appeal-2021") + """
        <div class="row"><div class="left">Наименование суда</div><div class="right">Синтетический другой суд</div></div>
        """
        let wrongCourt = try await issue413Movement(
            appealCardName: "issue413-appeal-2021",
            resultNumber: "33-6416/2021",
            resultUID: "77RS0032-01-2020-000111-11",
            appealCardOverride: contradictoryCourtCard)
        XCTAssertFalse(wrongCourt.instances.contains { $0.level == .appeal })
        assertMoscowAppealCoverageIsPartial(wrongCourt)
    }

    private func issue413Movement(appealCardName: String, resultNumber: String,
                                  resultUID: String,
                                  appealCardOverride: String? = nil) async throws -> CaseMovement {
        let urlProtocol = MosGorSudFixtureURLProtocol.self
        urlProtocol.install(
            baseCard: """
            <div class="row"><div class="left">Уникальный идентификатор дела</div><div class="right">77RS0032-01-2020-000111-11</div></div>
            <div class="row"><div class="left">Номер дела ~ материала</div><div class="right">02-0001/2020</div></div>
            <div class="row"><div class="left">Наименование суда</div><div class="right">Черёмушкинский районный суд</div></div>
            <div class="row"><div class="left">Cудья</div><div class="right">Собственный районный судья</div></div>
            """,
            appealCard: try appealCardOverride ?? fixture(appealCardName),
            appealURL: try XCTUnwrap(URL(string:
                "https://mos-gorsud.ru/mgs/services/cases/appeal-civil/details/synthetic-appeal")),
            resultNumber: resultNumber, resultUID: resultUID)
        defer { urlProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.protocolClasses = [urlProtocol]
        let client = MosGorSudClient(session: URLSession(configuration: configuration), minInterval: 0)
        let service = MovementService(client: MockEmptyCase(), higherCourtDomains: [], mosgorsud: client)
        let baseURL = try XCTUnwrap(URL(string:
            "https://mos-gorsud.ru/rs/cheremushkinskij/services/cases/civil/details/synthetic-base"))
        let base = MosGorSudResult(caseNumber: "02-0001/2020",
                                  uid: "77RS0032-01-2020-000111-11",
                                  court: "Черёмушкинский районный суд",
                                  cardURL: baseURL)
        let cartoteka = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        return try await service.moscowMovement(for: base, cartoteka: cartoteka)
    }

    private func assertMoscowAppealCoverageIsPartial(_ movement: CaseMovement,
                                                     file: StaticString = #filePath,
                                                     line: UInt = #line) {
        let moscowCourt = movement.sourceRefreshCoverage?.first(where: {
            $0.sourceFamily == "mosgorsud" && $0.courtKey == MosGorSudCourtDirectory.mgsAlias
        })
        XCTAssertEqual(moscowCourt?.kind, .partial, file: file, line: line)
        XCTAssertTrue(moscowCourt?.loadedCardIdentities.isEmpty == true, file: file, line: line)
    }

    func testCardParserDropsUnsafePublishedActLinks() throws {
        let html = """
        <div class="left">Номер дела</div><div class="right">3а-1/2026</div>
        <table><tr><td>01.01.2026</td><td>
        <a href="https://example.test/cases/docs/content/phishing">Скачать файл</a>
        </td></tr><tr><td>02.01.2026</td><td>
        <a href="http://mos-gorsud.ru/mgs/cases/docs/content/insecure">Скачать файл</a>
        </td></tr><tr><td>03.01.2026</td><td>
        <a href="https://user:secret@mos-gorsud.ru/mgs/cases/docs/content/credentials">Скачать файл</a>
        </td></tr></table>
        """
        let card = try MosGorSudCardParser.parse(html: html)
        XCTAssertTrue(card.actFiles.isEmpty)
    }

    // MARK: - московская ветка движения

    private let uid = "77RS0021-01-2024-001234-56"

    private func firstRow() -> MosGorSudResult {
        MosGorSudResult(caseNumber: "02-1234/2024",
                        court: "Тверской районный суд",
                        cardURL: URL(string: "https://mos-gorsud.ru/rs/tverskoj/services/cases/civil/details/first1"))
    }

    private func mock() -> MockMosGorSud {
        mock(baseUID: uid)
    }

    private func mock(baseUID: String?) -> MockMosGorSud {
        let firstCard = MosGorSudCard(
            uid: baseUID, caseNumber: "02-1234/2024", court: "Тверской районный суд",
            judge: "Сидорова А.А.", category: "Споры ЗПП", result: "Удовлетворено",
            sessions: [CaseSession(date: "17.06.2024", event: "Судебное заседание",
                                   result: "Вынесено решение")],
            actLinks: [URL(string: "https://mos-gorsud.ru/a/1.pdf")!])
        let appealRow = MosGorSudResult(
            caseNumber: "33-4567/2024", uid: uid, court: "Московский городской суд",
            cardURL: URL(string: "https://mos-gorsud.ru/mgs/services/cases/appeal-civil/details/app1"))
        let appealCard = MosGorSudCard(
            uid: uid, caseNumber: "33-4567/2024", court: "Московский городской суд",
            judge: "Кузнецова В.В.", result: "решение оставлено без изменения",
            sessions: [CaseSession(date: "10.09.2024", event: "Судебное заседание",
                                   result: "оставлено без изменения")])
        return MockMosGorSud(
            searchByInstance: [2: [appealRow]],
            cards: ["first1": firstCard, "app1": appealCard])
    }

    func testMoscowColdAnchorAcceptsPublishedZeroPaddedNumber() async throws {
        let url = URL(string: "https://mos-gorsud.ru/rs/tverskoj/services/cases/civil/details/first1")!
        let base = MosGorSudResult(caseNumber: "2-1/2026", uid: nil,
                                   court: "Тверской районный суд", cardURL: url)
        let provider = MockMosGorSud(
            searchByInstance: [:],
            cards: ["first1": MosGorSudCard(caseNumber: "02-0001/2026",
                                              court: "Тверской районный суд")])
        let service = MovementService(client: MockEmptyCase(), higherCourtDomains: [],
                                      mosgorsud: provider)
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let movement = try await service.moscowMovement(for: base, cartoteka: cart)

        XCTAssertEqual(movement.instances.first?.caseNumber, "2-1/2026")
        XCTAssertTrue(movement.sourceRefreshCoverage?.first(where: {
            $0.sourceFamily == "mosgorsud" && $0.courtKey == "tverskoj"
        })?.isFull == true)
    }

    func testMoscowColdAnchorNeedsItsOwnPublishedCaseNumber() async throws {
        let url = URL(string: "https://mos-gorsud.ru/rs/tverskoj/services/cases/civil/details/first1")!
        let base = MosGorSudResult(caseNumber: "2-1/2026", uid: nil,
                                   court: "Тверской районный суд", cardURL: url)
        let provider = MockMosGorSud(
            searchByInstance: [:],
            cards: ["first1": MosGorSudCard(caseNumber: nil,
                                              court: "Тверской районный суд")])
        let service = MovementService(client: MockEmptyCase(), higherCourtDomains: [],
                                      mosgorsud: provider)
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        do {
            _ = try await service.moscowMovement(for: base, cartoteka: cart)
            XCTFail("неподтверждённый номер собственной карточки не должен считаться свежим")
        } catch { }
    }

    func testMoscowMovementIncludesPublishedSupremeCourtActMetadata() async throws {
        let pdfURL = URL(string: "https://www.vsrf.ru/lk/practice/stor_pdf/34500001")!
        let production = VSRFProduction(cardID: "12-34500001", cardSection: .claims,
            kind: .caseFile, number: "3-КГ25-1-К3", incomingDate: "01.10.2025", uid: uid,
            firstInstance: VSRFFirstInstance(court: "Тверской районный суд", caseNumber: "02-1234/2024"),
            events: [VSRFEvent(date: "15.10.2025", text: "Результат рассмотрения")],
            publishedActs: [VSRFPublishedAct(url: pdfURL, date: "15.10.2025", title: "Определение")])
        let service = MovementService(client: MockEmptyCase(), higherCourtDomains: [],
            vsrf: MoscowPublishedVSRF(production: production), mosgorsud: mock())
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        let movement = try await service.moscowMovement(for: firstRow(), cartoteka: cart)
        let act = try XCTUnwrap(movement.acts.first { $0.sourceFileURL == pdfURL })
        XCTAssertEqual(act.productionNumber, production.number)
        XCTAssertEqual(act.instanceLevel, .vsCassation)
        XCTAssertTrue(movement.instances.contains { $0.linkedActIDs.contains(act.id) })
    }

    func testMoscowMovementStitchesPortalInstances() async throws {
        let service = MovementService(client: MockEmptyCase(), higherCourtDomains: [],
                                      mosgorsud: mock())
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        let mv = try await service.moscowMovement(for: firstRow(), cartoteka: cart)

        XCTAssertEqual(mv.uid, uid, "УИД добирается из карточки первой инстанции")
        XCTAssertEqual(mv.instances.count, 2)

        let first = try XCTUnwrap(mv.instances.first { $0.level == .first })
        XCTAssertEqual(first.court, "Тверской районный суд")
        XCTAssertEqual(first.judge, "Сидорова А.А.")
        XCTAssertEqual(first.actURL?.absoluteString, "https://mos-gorsud.ru/a/1.pdf")

        let appeal = try XCTUnwrap(mv.instances.first { $0.level == .appeal })
        XCTAssertEqual(appeal.caseNumber, "33-4567/2024")
        XCTAssertEqual(appeal.court, "Московский городской суд")
        XCTAssertTrue(appeal.foundByUID)
        XCTAssertEqual(appeal.judge, "Кузнецова В.В.")

        // Порядок: первая инстанция раньше апелляции.
        XCTAssertLessThan(try XCTUnwrap(mv.instances.firstIndex(of: first)),
                          try XCTUnwrap(mv.instances.firstIndex(of: appeal)))
        XCTAssertEqual(mv.category, "Споры ЗПП")

        let baseCoverage = try XCTUnwrap(mv.sourceRefreshCoverage?.first {
            $0.sourceFamily == "mosgorsud" && $0.courtKey == "tverskoj"
        })
        XCTAssertTrue(baseCoverage.loadedCardIdentities.contains {
            $0.cartotekaKey == "g1" && $0.sourceNativeID == "first1"
        })
        let appealCoverage = try XCTUnwrap(mv.sourceRefreshCoverage?.first {
            $0.sourceFamily == "mosgorsud" && $0.courtKey == "mgs"
        })
        XCTAssertTrue(appealCoverage.loadedCardIdentities.contains {
            $0.cartotekaKey == "g2" && $0.sourceNativeID == "app1"
        }, "appeal card uses its own canonical registry section")
    }

    func testMoscowFailedAppealCardBlocksOnlyItsNativeCourtAlias() async throws {
        let baseCard = MosGorSudCard(uid: uid, caseNumber: "02-1234/2024",
                                     court: "Тверской районный суд")
        let loadedCard = MosGorSudCard(uid: uid, caseNumber: "33-2/2024",
                                       court: "Басманный районный суд")
        let brokenRow = MosGorSudResult(
            caseNumber: "33-1/2024", uid: uid,
            cardURL: URL(string:
                "https://mos-gorsud.ru/rs/tverskoj/services/cases/appeal-civil/details/broken"))
        let loadedRow = MosGorSudResult(
            caseNumber: "33-2/2024", uid: uid,
            cardURL: URL(string:
                "https://mos-gorsud.ru/rs/basmannyj/services/cases/appeal-civil/details/loaded"))
        let provider = MockMosGorSud(
            searchByInstance: [MosGorSudInstance.appeal: [brokenRow, loadedRow]],
            cards: ["first1": baseCard, "loaded": loadedCard])
        let service = MovementService(client: MockEmptyCase(), higherCourtDomains: [],
                                      mosgorsud: provider)
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        let movement = try await service.moscowMovement(for: firstRow(), cartoteka: cart)

        let tverskoy = try XCTUnwrap(movement.sourceRefreshCoverage?.first {
            $0.sourceFamily == "mosgorsud" && $0.courtKey == "tverskoj"
        })
        XCTAssertEqual(tverskoy.kind, .partial)
        XCTAssertTrue(tverskoy.loadedCardIdentities.contains {
            $0.cartotekaKey == "g1" && $0.sourceNativeID == "first1"
        })
        let basmanny = try XCTUnwrap(movement.sourceRefreshCoverage?.first {
            $0.sourceFamily == "mosgorsud" && $0.courtKey == "basmannyj"
        })
        XCTAssertTrue(basmanny.isFull)
        XCTAssertTrue(basmanny.loadedCardIdentities.contains {
            $0.cartotekaKey == "g2" && $0.sourceNativeID == "loaded"
        })
    }

    func testMoscowConfirmedEmptyUpperSearchNamesItsKnownTarget() async throws {
        let baseCard = MosGorSudCard(uid: uid, caseNumber: "02-1234/2024",
                                     court: "Тверской районный суд")
        let provider = MockMosGorSud(searchByInstance: [:], cards: ["first1": baseCard])
        let service = MovementService(client: MockEmptyCase(), higherCourtDomains: [],
                                      mosgorsud: provider)
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let movement = try await service.moscowMovement(for: firstRow(), cartoteka: cart)

        let mgsCoverage = try XCTUnwrap(movement.sourceRefreshCoverage?.first {
            $0.sourceFamily == "mosgorsud" && $0.courtKey == "mgs"
        })
        XCTAssertEqual(mgsCoverage.kind, .honestZero)
        XCTAssertTrue(mgsCoverage.loadedCardIdentities.isEmpty)
    }

    func testMoscowMovementPublishesEveryVerifiedAttachment() async throws {
        let firstURL = URL(string: "https://mos-gorsud.ru/mgs/cases/docs/content/first")!
        let secondURL = URL(string: "https://mos-gorsud.ru/mgs/cases/docs/content/second")!
        func file(_ url: URL, text: String, hash: String) -> PublishedActFile {
            PublishedActFile(
                text: text,
                provenance: PublishedActProvenance(
                    sourceURL: url, finalURL: url, format: .docx,
                    contentType: "application/octet-stream", contentHash: hash,
                    byteCount: text.utf8.count, fetchedAt: Date(timeIntervalSince1970: 1),
                    extractorVersion: 1))
        }
        let card = MosGorSudCard(
            caseNumber: "3а-3843/2020", court: "Московский городской суд",
            receiptDate: "10.01.2025",
            actFiles: [
                MosGorSudActLink(url: firstURL, date: "20.03.2020", title: "Определение"),
                MosGorSudActLink(url: secondURL, title: "Решение"),
            ])
        let cardURL = URL(string: "https://mos-gorsud.ru/mgs/services/cases/first-admin/details/base")!
        let provider = MockMosGorSud(
            searchByInstance: [:], cards: ["base": card],
            publishedActs: [
                firstURL: file(firstURL, text: "Текст определения", hash: "01"),
                secondURL: file(secondURL, text: "Текст решения", hash: "02"),
            ])
        let base = MosGorSudResult(caseNumber: "3а-3843/2020",
                                   court: "Московский городской суд", cardURL: cardURL)
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .subject, id: "p1"))
        let movement = try await MovementService(client: MockEmptyCase(),
                                                 higherCourtDomains: [], mosgorsud: provider)
            .moscowMovement(for: base, cartoteka: cart)

        let instance = try XCTUnwrap(movement.instances.first)
        XCTAssertEqual(instance.linkedActIDs.count, 2)
        XCTAssertEqual(instance.linkedActURLs, [firstURL, secondURL])
        XCTAssertEqual(movement.acts.map(\.title), ["Определение", "Решение"])
        XCTAssertEqual(movement.acts.map(\.date), ["20.03.2020", "—"])
        XCTAssertEqual(Set(movement.actBodies.values), ["Текст определения", "Текст решения"])
        XCTAssertEqual(movement.acts.map { $0.fileProvenance?.contentHash }, ["01", "02"])
    }

    func testMoscowMovementReachesKSOYuOnSudrf() async throws {
        // Кассация 2-го КСОЮ — на общей платформе sudrf: sudrf-клиент отвечает
        // на УИД-поиск в кассационной картотеке.
        let kasRow = CaseSearchResult(caseNumber: "88-9999/2025",
                                      receiptDate: "10.01.2025",
                                      judge: "Смирнов С.С.",
                                      caseID: "k1", caseUID: "kguid")
        let kasCard = CaseCard(rawText: "", actText: "Определение…",
                               sessions: [CaseSession(date: "05.02.2025", event: "Заседание")],
                               judge: "Смирнов С.С.", result: "оставлено без изменения",
                               uid: uid, caseNumber: "88-9999/2025")
        let sudrf = MockKas(row: kasRow, card: kasCard)
        let service = MovementService(client: sudrf,
                                      higherCourtDomains: ["2kas.sudrf.ru"],
                                      mosgorsud: mock())
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        let mv = try await service.moscowMovement(for: firstRow(), cartoteka: cart)

        let kas = try XCTUnwrap(mv.instances.first { $0.level == .cassation })
        XCTAssertEqual(kas.caseNumber, "88-9999/2025")
        XCTAssertTrue(kas.foundByUID)
        XCTAssertEqual(kas.domain, "2kas.sudrf.ru")
        XCTAssertNotNil(kas.actID, "текст акта КСОЮ — инлайновый, через actID")
        XCTAssertEqual(mv.actBodies[kas.actID ?? ""], "Определение…")
    }

    func testMoscowMovementDirectlyRefreshesKnownAppellateCardsWithoutUID() async throws {
        let firstURL = try XCTUnwrap(URL(string:
            "https://1ap.sudrf.ru/modules.php?name=sud_delo&name_op=case"
            + "&case_id=1&case_uid=guid&delo_id=2800001&new=2800001"))
        let secondURL = try XCTUnwrap(URL(string:
            "https://2ap.sudrf.ru/modules.php?name=sud_delo&name_op=case"
            + "&case_id=2&case_uid=guid-2&delo_id=2800001&new=2800001"))
        let firstKnownCard = KnownCard(
            domain: "1ap.sudrf.ru", courtTitle: "Первый апелляционный суд",
            caseID: "1", caseUID: "guid", deloID: "2800001", new: "2800001",
            caseNumber: "8а-7078/2022", levelRaw: CaseInstance.Level.appeal.rawValue,
            cartotekaID: "g1", sourceURL: firstURL)
        let secondKnownCard = KnownCard(
            domain: "2ap.sudrf.ru", courtTitle: "Второй апелляционный суд",
            caseID: "2", caseUID: "guid-2", deloID: "2800001", new: "2800001",
            caseNumber: "8а-601/2022", levelRaw: CaseInstance.Level.appeal.rawValue,
            cartotekaID: "g1", sourceURL: secondURL)
        let firstCard = CaseCard(rawText: "", actText: "Апелляционное определение",
                                 sessions: [CaseSession(date: "01.10.2020", event: "Заседание")],
                                 judge: "Иванова И.И.", result: "Оставлено без изменения",
                                 caseNumber: firstKnownCard.caseNumber)
        let secondCard = CaseCard(rawText: "", actText: "Апелляционное определение",
                                  judge: "Петров П.П.", result: "Без изменения",
                                  caseNumber: secondKnownCard.caseNumber)
        let client = MockEmptyCase(directCards: [firstURL: firstCard,
                                                  secondURL: secondCard])
        let service = MovementService(client: client,
                                      knownCards: [firstKnownCard, secondKnownCard,
                                                   firstKnownCard],
                                      mosgorsud: mock(baseUID: nil))
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let movement = try await service.moscowMovement(for: firstRow(), cartoteka: cart)

        XCTAssertEqual(movement.uid, "")
        XCTAssertEqual(movement.instances.filter { $0.domain == "1ap.sudrf.ru" }.count, 1)
        XCTAssertEqual(movement.instances.first { $0.domain == "1ap.sudrf.ru" }?.judge,
                       "Иванова И.И.")
        XCTAssertEqual(movement.instances.first { $0.domain == "2ap.sudrf.ru" }?.judge,
                       "Петров П.П.")
        let directFetchCalls = await client.recordedDirectURLs()
        XCTAssertEqual(directFetchCalls, [firstURL, secondURL])
        XCTAssertEqual(Set(movement.incompleteHigherCourtDomains ?? []),
                       Set(["mos-gorsud.ru", "1ap.sudrf.ru", "2ap.sudrf.ru"]))
    }

    func testFailedKnownFirstAppellateRefreshStaysPartialAndPreservesCache() async throws {
        let url = try XCTUnwrap(URL(string:
            "https://1ap.sudrf.ru/modules.php?name=sud_delo&name_op=case"
            + "&case_id=1&case_uid=guid&delo_id=2800001&new=2800001"))
        let knownCard = KnownCard(
            domain: "1ap.sudrf.ru", courtTitle: "Первый апелляционный суд",
            caseID: "1", caseUID: "guid", deloID: "2800001", new: "2800001",
            caseNumber: "8а-7078/2022", levelRaw: CaseInstance.Level.appeal.rawValue,
            cartotekaID: "g1", sourceURL: url)
        let service = MovementService(client: MockEmptyCase(),
                                      knownCards: [knownCard],
                                      mosgorsud: mock(baseUID: nil))
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        let fresh = try await service.moscowMovement(for: firstRow(), cartoteka: cart)
        let cached = CaseMovement(
            uid: "", caseNumber: firstRow().caseNumber, inForce: false,
            instances: [CaseInstance(
                level: .appeal, court: knownCard.courtTitle,
                caseNumber: knownCard.caseNumber ?? "—", judge: "Старый судья",
                domain: knownCard.domain, foundByUID: false,
                result: "Сохранённый результат", sessions: [], sourceURL: url)],
            complaints: [:], acts: [])

        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)

        XCTAssertEqual(Set(fresh.incompleteHigherCourtDomains ?? []),
                       ["mos-gorsud.ru", "1ap.sudrf.ru"])
        XCTAssertTrue(merged.instances.contains {
            $0.domain == "1ap.sudrf.ru" && $0.result == "Сохранённый результат"
        })
    }

    func testPortalFailureMarksPartialAndPreservesCachedAppeal() async throws {
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        let cached = try await MovementService(client: MockEmptyCase(), higherCourtDomains: [],
                                               mosgorsud: mock())
            .moscowMovement(for: firstRow(), cartoteka: cart)
        var failing = mock()
        failing.searchFailures = [MosGorSudInstance.appeal]
        let fresh = try await MovementService(client: MockEmptyCase(), higherCourtDomains: [],
                                              mosgorsud: failing)
            .moscowMovement(for: firstRow(), cartoteka: cart)

        XCTAssertEqual(fresh.incompleteHigherCourtDomains, [MosGorSudEndpoint.host])
        XCTAssertEqual(SourceOutcomeClassifier.attempt(for: fresh, sourceFamily: "mosgorsud",
                                                       host: MosGorSudEndpoint.host).kind,
                       .partial)
        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)
        XCTAssertTrue(merged.instances.contains { $0.caseNumber == "33-4567/2024" })
    }

    func testEmptyKSOYuListingIsAnAffectedSource() async throws {
        let service = MovementService(client: MockEmptyCase(),
                                      higherCourtDomains: ["2kas.sudrf.ru"],
                                      mosgorsud: mock())
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        let movement = try await service.moscowMovement(for: firstRow(), cartoteka: cart)

        XCTAssertTrue(movement.honestZeroDomains?.contains("2kas.sudrf.ru") == true)
        XCTAssertEqual(SourceOutcomeClassifier.attempt(for: movement, sourceFamily: "mosgorsud",
                                                       host: MosGorSudEndpoint.host).kind,
                       .partial)
    }

    func testMovementForBranchesToMoscow() async throws {
        // Общая точка входа movement(for:) распознаёт домен портала — этим
        // путём идёт перезапрос отслеживаемого дела (RefreshCenter).
        let service = MovementService(client: MockEmptyCase(), higherCourtDomains: [],
                                      mosgorsud: mock())
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        let base = CaseSearchResult(
            caseNumber: "02-1234/2024",
            cardURL: URL(string: "https://mos-gorsud.ru/rs/tverskoj/services/cases/civil/details/first1"))
        let court = Court(domain: "mos-gorsud.ru", title: "Тверской районный суд",
                          level: .district)
        let mv = try await service.movement(for: base, court: court, cartoteka: cart)
        XCTAssertEqual(mv.uid, uid)
        XCTAssertTrue(mv.instances.contains { $0.level == .appeal })
    }

    func testMoscowMovementWithoutClientThrows() async throws {
        let service = MovementService(client: MockEmptyCase())
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        do {
            _ = try await service.moscowMovement(for: firstRow(), cartoteka: cart)
            XCTFail("должно бросить: клиент mos-gorsud не подключён")
        } catch {}
    }

    func testClientPreservesHTTP502FromSearchAndCardTransport() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MosGorSudHTTPFailureStub.self]
        let client = MosGorSudClient(session: URLSession(configuration: configuration),
                                     minInterval: 0)

        do {
            _ = try await client.search(uid: "77OS0000-01-2020-002855-77",
                                        instance: 1, processType: .cas)
            XCTFail("search should surface the server status")
        } catch let error as SudrfError {
            guard case .http(let status) = error else {
                return XCTFail("expected HTTP status, got \(error)")
            }
            XCTAssertEqual(status, 502)
        }

        let cardURL = try XCTUnwrap(URL(string:
            "https://mos-gorsud.ru/mgs/services/cases/first-admin/details/11111111-1111-4111-8111-111111111111"))
        do {
            _ = try await client.fetchCard(url: cardURL)
            XCTFail("card fetch should surface the server status")
        } catch let error as SudrfError {
            guard case .http(let status) = error else {
                return XCTFail("expected HTTP status, got \(error)")
            }
            XCTAssertEqual(status, 502)
        }

    }
}

// MARK: - Моки

private struct MockMosGorSud: MosGorSudProviding {
    let searchByInstance: [Int: [MosGorSudResult]]
    let cards: [String: MosGorSudCard]   // ключ — последний сегмент cardURL
    var searchFailures: Set<Int> = []
    var publishedActs: [URL: PublishedActFile] = [:]

    func search(courtAlias: String?, uid: String?, caseNumber: String?,
                participant: String?, instance: Int,
                processType: MosGorSudProcessType) async throws -> [MosGorSudResult] {
        if searchFailures.contains(instance) { throw SudrfError.http(status: 503) }
        return searchByInstance[instance] ?? []
    }
    func fetchCard(url: URL) async throws -> MosGorSudCard {
        guard let card = cards[url.lastPathComponent] else {
            throw SudrfError.http(status: 404)
        }
        return card
    }
    func fetchPublishedAct(url: URL) async throws -> PublishedActFile {
        guard let file = publishedActs[url] else { throw SudrfError.http(status: 404) }
        return file
    }
}

private final class MosGorSudHTTPFailureStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == MosGorSudEndpoint.host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 502,
                                             httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MosGorSudFixtureURLProtocol: URLProtocol {
    private struct Fixture {
        let baseCard: Data
        let appealCard: Data
        let appealPath: String
        let resultNumber: String
        let resultUID: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixture: Fixture?

    static func install(baseCard: String, appealCard: String, appealURL: URL,
                        resultNumber: String = "33-6416/2021",
                        resultUID: String = "77RS0032-01-2020-000111-11") {
        lock.lock()
        fixture = Fixture(baseCard: Data(baseCard.utf8), appealCard: Data(appealCard.utf8),
                          appealPath: appealURL.path, resultNumber: resultNumber,
                          resultUID: resultUID)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        fixture = nil
        lock.unlock()
    }

    private static func currentFixture() -> Fixture? {
        lock.lock()
        defer { lock.unlock() }
        return fixture
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let fixture = Self.currentFixture() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        let body: Data
        if url.path == "/search" {
            let instance = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "instance" })?.value
            let rows = instance == String(MosGorSudInstance.appeal)
                ? "<tr data-href=\"\(fixture.appealPath)\"><td>\(fixture.resultNumber)</td><td>\(fixture.resultUID)</td><td></td><td></td><td></td></tr>"
                : ""
            body = Data("""
            <table><thead><tr><th>№ дела</th><th>Стороны</th><th>Состояние</th><th>Категория</th><th>Судья</th></tr></thead>
            <tbody>\(rows)</tbody></table>
            """.utf8)
        } else if url.path.hasSuffix("/synthetic-base") {
            body = fixture.baseCard
        } else if url.path == fixture.appealPath {
            body = fixture.appealCard
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "text/html; charset=utf-8"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor MockEmptyCase: CaseProviding {
    let directCards: [URL: CaseCard]
    private var directFetchCalls: [URL] = []

    init(directCards: [URL: CaseCard] = [:]) {
        self.directCards = directCards
    }

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] { [] }
    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        throw SudrfError.http(status: 404)
    }
    func fetchCard(url: URL) async throws -> CaseCard {
        throw SudrfError.http(status: 404)
    }
    func fetchCardWithResponseURL(url: URL) async throws -> SudrfCaseCardFetchResult {
        directFetchCalls.append(url)
        guard let card = directCards[url] else { throw SudrfError.http(status: 404) }
        return SudrfCaseCardFetchResult(card: card, responseURL: url)
    }
    func recordedDirectURLs() -> [URL] { directFetchCalls }
}

private actor MockKas: CaseProviding {
    let row: CaseSearchResult
    let card: CaseCard
    init(row: CaseSearchResult, card: CaseCard) { self.row = row; self.card = card }
    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] {
        cartoteka.id == "g3" ? [row] : []
    }
    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard { card }
    func fetchCard(url: URL) async throws -> CaseCard { card }
}

private struct MoscowPublishedVSRF: VSRFProviding {
    let production: VSRFProduction
    func search(uniqueNumber: String?, oldCaseNumber: String?, keywords: String?) async throws -> VSRFSearchResults {
        VSRFSearchResults(total: 1, results: [production])
    }
    func fetchCard(productionID: String, section: VSRFCardSection) async throws -> VSRFCard {
        VSRFCard(productions: [production])
    }
}
