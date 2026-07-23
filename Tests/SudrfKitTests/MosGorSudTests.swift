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

    /// Карточка (гражданское дело, райсуд): пары div.left/div.right, латинская C
    /// в «Cудья», заседания из таблицы «Зал», акт по ссылке cases/docs/content.
    func testCardParserOnLiveCivilCard() throws {
        let card = try MosGorSudCardParser.parse(html: fixture("starodubtseva-card"))
        XCTAssertEqual(card.uid, "77RS0023-02-2024-021289-96")
        XCTAssertEqual(card.caseNumber, "02-3501/2025")
        XCTAssertEqual(card.judge, "Дроздова С.А.")   // ключ «Cудья» с латинской C
        XCTAssertEqual(card.receiptDate, "11.12.2024")
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
        XCTAssertGreaterThanOrEqual(card.actLinks.count, 1)
        XCTAssertTrue(card.participants.contains { $0.hasPrefix("Административный истец:") })
    }

    // MARK: - московская ветка движения

    private let uid = "77RS0021-01-2024-001234-56"

    private func firstRow() -> MosGorSudResult {
        MosGorSudResult(caseNumber: "02-1234/2024",
                        court: "Тверской районный суд",
                        cardURL: URL(string: "https://mos-gorsud.ru/rs/tverskoj/services/cases/civil/details/first1"))
    }

    private func mock() -> MockMosGorSud {
        let firstCard = MosGorSudCard(
            uid: uid, caseNumber: "02-1234/2024", court: "Тверской районный суд",
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
}

// MARK: - Моки

private struct MockMosGorSud: MosGorSudProviding {
    let searchByInstance: [Int: [MosGorSudResult]]
    let cards: [String: MosGorSudCard]   // ключ — последний сегмент cardURL

    func search(courtAlias: String?, uid: String?, caseNumber: String?,
                participant: String?, instance: Int,
                processType: MosGorSudProcessType) async throws -> [MosGorSudResult] {
        searchByInstance[instance] ?? []
    }
    func fetchCard(url: URL) async throws -> MosGorSudCard {
        guard let card = cards[url.lastPathComponent] else {
            throw SudrfError.http(status: 404)
        }
        return card
    }
}

private actor MockEmptyCase: CaseProviding {
    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] { [] }
    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        throw SudrfError.http(status: 404)
    }
    func fetchCard(url: URL) async throws -> CaseCard {
        throw SudrfError.http(status: 404)
    }
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
