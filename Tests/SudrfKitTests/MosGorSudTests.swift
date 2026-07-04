import XCTest
@testable import SudrfKit

/// Endpoint, маршрутизация картотек и московская ветка движения (mos-gorsud.ru).
/// Эталон URL — боевой паттерн tochno-st/sudrfscraper (MOSGORSUD_PATTERN).
final class MosGorSudTests: XCTestCase {

    // MARK: - endpoint

    func testSearchURL() throws {
        let url = try XCTUnwrap(MosGorSudEndpoint.searchURL(
            uid: "77RS0021-01-2024-001234-56", instance: 1, processType: .civil))
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("https://mos-gorsud.ru/search?"))
        XCTAssertTrue(s.contains("formType=fullForm"))
        XCTAssertTrue(s.contains("uid=77RS0021-01-2024-001234-56"))
        XCTAssertTrue(s.contains("instance=1"))
        XCTAssertTrue(s.contains("processType=2"))
        XCTAssertTrue(s.contains("courtAlias=&") || s.hasSuffix("courtAlias="))
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
        XCTAssertEqual(route(.subject, "u2")?.1, 2)
        XCTAssertEqual(route(.subject, "g33")?.1, 3)
        XCTAssertEqual(route(.subject, "u33")?.1, 3)
    }

    func testIsMosGorSudDomain() {
        XCTAssertTrue(MosGorSudRouting.isMosGorSud(domain: "mos-gorsud.ru"))
        XCTAssertTrue(MosGorSudRouting.isMosGorSud(domain: "www.mos-gorsud.ru"))
        XCTAssertFalse(MosGorSudRouting.isMosGorSud(domain: "syktsud--komi.sudrf.ru"))
    }

    // MARK: - парсер выдачи (синтетика; живая фикстура — TODO)

    func testResultsParserOnSyntheticRow() throws {
        let html = """
        <html><body><table>
        <tr>
          <td><a href="/mgs/services/cases/civil/details/abc123">02-1234/2024</a></td>
          <td>77RS0021-01-2024-001234-56</td>
          <td>Тверской районный суд</td>
          <td>15.03.2024</td>
          <td>Иванов И.И. к Петрову П.П.</td>
        </tr>
        </table></body></html>
        """
        let rows = try MosGorSudResultsParser.parse(html: html)
        XCTAssertEqual(rows.count, 1)
        let r = try XCTUnwrap(rows.first)
        XCTAssertEqual(r.caseNumber, "02-1234/2024")
        XCTAssertEqual(r.uid, "77RS0021-01-2024-001234-56")
        XCTAssertEqual(r.court, "Тверской районный суд")
        XCTAssertEqual(r.receiptDate, "15.03.2024")
        XCTAssertEqual(r.cardURL?.absoluteString,
                       "https://mos-gorsud.ru/mgs/services/cases/civil/details/abc123")
    }

    func testCardParserOnSyntheticCard() throws {
        let html = """
        <html><body>
        <table>
          <tr><th>Номер дела</th><td>02-1234/2024</td></tr>
          <tr><th>Уникальный идентификатор дела</th><td>77RS0021-01-2024-001234-56</td></tr>
          <tr><th>Судья</th><td>Сидорова А.А.</td></tr>
          <tr><th>Категория дела</th><td>Споры о защите прав потребителей</td></tr>
          <tr><th>Результат</th><td>Удовлетворено</td></tr>
        </table>
        <h2>Судебные заседания</h2>
        <table>
          <tr><td>20.05.2024 10:30</td><td>Судебное заседание</td><td>Заседание отложено</td></tr>
          <tr><td>17.06.2024 12:00</td><td>Судебное заседание</td><td>Вынесено решение</td></tr>
        </table>
        <a href="/mgs/case/attachments/decision.pdf">Решение</a>
        </body></html>
        """
        let card = try MosGorSudCardParser.parse(html: html)
        XCTAssertEqual(card.caseNumber, "02-1234/2024")
        XCTAssertEqual(card.uid, "77RS0021-01-2024-001234-56")
        XCTAssertEqual(card.judge, "Сидорова А.А.")
        XCTAssertEqual(card.category, "Споры о защите прав потребителей")
        XCTAssertEqual(card.result, "Удовлетворено")
        XCTAssertEqual(card.sessions.count, 2)
        XCTAssertEqual(card.sessions.first?.date, "20.05.2024")
        XCTAssertEqual(card.sessions.first?.time, "10:30")
        XCTAssertEqual(card.sessions.last?.result, "Вынесено решение")
        XCTAssertEqual(card.actLinks.first?.absoluteString,
                       "https://mos-gorsud.ru/mgs/case/attachments/decision.pdf")
    }

    // TODO: живые фикстуры mgs_search_uid.html / mgs_card.html — снять на машине
    // с доступом к mos-gorsud.ru и добавить тесты на реальной разметке.

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
