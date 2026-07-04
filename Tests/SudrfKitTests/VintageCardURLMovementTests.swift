import XCTest
@testable import SudrfKit

/// Сценарий Благовещенского городского суда: винтажная выдача даёт ссылку на
/// карточку ТОЛЬКО с `_uid` (без `_id`) — пары идентификаторов нет, движение
/// должно собираться по готовой ссылке (cardURL-first), а не сваливаться в
/// minimalMovement.
final class VintageCardURLMovementTests: XCTestCase {

    private let uid = "28RS0004-01-2025-018120-67"
    private let cardURLString = "https://blag-gs--amr.sudrf.ru/modules.php?name=sud_delo&name_op=case"
        + "&_uid=526a6a50-2f9e-433b-bda4-f508936e9bf4&_deloId=1540005&_caseType=0&_new=0&srv_num=1&_hideJudge=0"

    private func base() -> CaseSearchResult {
        CaseSearchResult(caseNumber: "2-5/2026 ~ М-7523/2025",
                         receiptDate: "15.12.2025",
                         judge: "Приходько А.В.",
                         caseID: nil, caseUID: "526a6a50-2f9e-433b-bda4-f508936e9bf4",
                         cardURL: URL(string: cardURLString))
    }

    private func card() -> CaseCard {
        CaseCard(rawText: "", actText: nil,
                 sessions: [CaseSession(date: "15.12.2025", time: "10:00",
                                        event: "Регистрация иска (заявления, жалобы) в суде")],
                 judge: "Приходько А.В.", result: nil,
                 uid: uid, caseNumber: "2-5/2026 ~ М-7523/2025")
    }

    func testMovementBuiltFromCardURLOnlyRow() async throws {
        let client = MockURLCase(cardsByURL: [cardURLString: card()])
        let service = MovementService(client: client, higherCourtDomains: [])
        let court = Court(domain: "blag-gs--amr.sudrf.ru",
                          title: "Благовещенский городской суд", level: .district)
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let mv = try await service.movement(for: base(), court: court, cartoteka: cart)

        // НЕ minimalMovement: карточка загружена по ссылке, УИД добрался.
        XCTAssertEqual(mv.uid, uid)
        let first = try XCTUnwrap(mv.instances.first)
        XCTAssertEqual(first.judge, "Приходько А.В.")
        XCTAssertFalse(first.sessions.isEmpty, "сессии из карточки должны попасть в движение")
        XCTAssertTrue(first.sessions[0].event.contains("Регистрация иска"))
        // По УИД сервис затем ищет другие круги в том же суде.
        let fetched = await client.fetchedURLs
        XCTAssertEqual(fetched, [cardURLString])
    }

    func testRowWithoutAnyAccessFallsBackToMinimal() async throws {
        let client = MockURLCase(cardsByURL: [:])
        let service = MovementService(client: client, higherCourtDomains: [])
        let court = Court(domain: "blag-gs--amr.sudrf.ru", title: "БГС", level: .district)
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        let row = CaseSearchResult(caseNumber: "2-1/2026")   // ни ID, ни ссылки

        let mv = try await service.movement(for: row, court: court, cartoteka: cart)
        XCTAssertEqual(mv.uid, "")
        XCTAssertEqual(mv.instances.count, 1)
        XCTAssertTrue(mv.instances[0].sessions.isEmpty)
    }
}

private actor MockURLCase: CaseProviding {
    private let cardsByURL: [String: CaseCard]
    private(set) var fetchedURLs: [String] = []

    init(cardsByURL: [String: CaseCard]) { self.cardsByURL = cardsByURL }

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] { [] }
    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        throw SudrfError.http(status: 404)   // канонический путь в этом сценарии не используется
    }
    func fetchCard(url: URL) async throws -> CaseCard {
        fetchedURLs.append(url.absoluteString)
        guard let card = cardsByURL[url.absoluteString] else { throw SudrfError.http(status: 404) }
        return card
    }
}
